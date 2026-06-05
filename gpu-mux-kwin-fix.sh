#!/bin/bash
# Auto-configure KWIN_DRM_DEVICES based on ASUS GPU MUX mode + supergfxctl mode.
# Runs before plasmalogin so KWin uses the correct DRM device(s) per mode.
#
# All card paths are detected by vendor ID at boot (cardN numbering is unstable).
# Per-mode behaviour:
#   MUX=0  (AsusMuxDgpu / dGPU-only)        -> KWIN_DRM_DEVICES = NVIDIA only
#       NOTE: dGPU-only black-screens under Wayland on this laptop (see reference doc).
#   MUX=1 + Integrated                      -> KWIN_DRM_DEVICES = AMD only (hide powered-off dGPU)
#   MUX=1 + Hybrid, external display on NV  -> KWIN_DRM_DEVICES = NVIDIA:AMD  (+ColorSpace)
#       NVIDIA composites -> no cross-GPU copy lag on the external monitor. The dGPU is
#       already awake driving that display, so this costs ~no extra power.
#   MUX=1 + Hybrid, internal panel only     -> no override (KWin auto-detects AMD; RTD3 sleeps dGPU)
#
# Hotplug caveat: detection happens at boot. If you dock AFTER boot, log out/in to pick up
# nvidia-primary (or re-run this service).

# Resolve the ASUS GPU MUX sysfs file across kernel/firmware path variants.
find_mux_file() {
    local path
    for path in \
        /sys/devices/platform/asus-nb-wmi/gpu_mux_mode \
        /sys/bus/platform/drivers/asus-nb-wmi/asus-nb-wmi/gpu_mux_mode \
        /sys/bus/platform/drivers/asus-nb-wmi/*/gpu_mux_mode; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

MUX_MODE_FILE=$(find_mux_file || true)
if [ -z "$MUX_MODE_FILE" ] || [ ! -f "$MUX_MODE_FILE" ]; then
    echo "gpu-mux-kwin-fix: No gpu_mux_mode found, skipping"
    exit 0
fi

MUX_MODE=$(cat "$MUX_MODE_FILE")

# Read current supergfxctl mode (live first, persisted config as fallback).
SUPERGFX_MODE=""
if command -v supergfxctl >/dev/null 2>&1; then
    SUPERGFX_MODE=$(supergfxctl --get 2>/dev/null | head -n1 | tr -d '[:space:]')
fi
if [ -z "$SUPERGFX_MODE" ] && [ -f /etc/supergfxd.conf ]; then
    SUPERGFX_MODE=$(grep -oP '"mode"\s*:\s*"\K[^"]+' /etc/supergfxd.conf)
fi
echo "gpu-mux-kwin-fix: MUX=$MUX_MODE supergfx_mode=$SUPERGFX_MODE"

# In dGPU MUX mode, unbind simpledrm to prevent a conflicting framebuffer card.
# (Largely redundant now that nvidia_drm.fbdev=1 is set, but harmless.)
if [ "$MUX_MODE" = "0" ]; then
    for fb in /sys/bus/platform/drivers/simple-framebuffer/simple-framebuffer.*; do
        if [ -e "$fb" ]; then
            echo "gpu-mux-kwin-fix: dGPU mode - unbinding $(basename "$fb")"
            echo "$(basename "$fb")" > /sys/bus/platform/drivers/simple-framebuffer/unbind 2>/dev/null
        fi
    done
    sleep 1
fi

# Find NVIDIA and AMD DRM cards by vendor ID (numbering changes between boots).
NVIDIA_CARD=""
AMD_CARD=""
NVIDIA_CARDNAME=""
for card in /sys/class/drm/card[0-9]; do
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    card_name=$(basename "$card")
    case $vendor in
        0x10de) NVIDIA_CARD="/dev/dri/$card_name"; NVIDIA_CARDNAME="$card_name" ;;
        0x1002) AMD_CARD="/dev/dri/$card_name" ;;
    esac
done

# Is an external display (HDMI/DP, not the internal eDP) connected to the NVIDIA GPU?
# If so, promote NVIDIA to compositor primary in Hybrid mode (fixes external-monitor lag).
NVIDIA_EXTERNAL=0
if [ -n "$NVIDIA_CARDNAME" ]; then
    for conn in /sys/class/drm/${NVIDIA_CARDNAME}-*; do
        [ -e "$conn/status" ] || continue
        case "$(basename "$conn")" in *eDP*) continue ;; esac
        if [ "$(cat "$conn/status" 2>/dev/null)" = "connected" ]; then
            NVIDIA_EXTERNAL=1
            break
        fi
    done
fi
echo "gpu-mux-kwin-fix: NVIDIA external display connected = $NVIDIA_EXTERNAL"

# Configure environment.d for a given user
configure_user() {
    local user_home="$1"
    local username="$2"
    local env_dir="$user_home/.config/environment.d"
    local env_file="$env_dir/kwin-drm.conf"

    if [ "$MUX_MODE" = "0" ]; then
        # dGPU MUX mode: NVIDIA only (single card; avoids KWin choking on the AMD card).
        if [ -n "$NVIDIA_CARD" ]; then
            echo "gpu-mux-kwin-fix: dGPU mode - setting KWIN_DRM_DEVICES=$NVIDIA_CARD for $username"
            mkdir -p "$env_dir"
            echo "KWIN_DRM_DEVICES=$NVIDIA_CARD" > "$env_file"
            chown "$username:$username" "$env_dir" "$env_file" 2>/dev/null
        else
            echo "gpu-mux-kwin-fix: dGPU mode - NVIDIA card not found, removing override for $username"
            rm -f "$env_file"
        fi
    elif [ "$SUPERGFX_MODE" = "Integrated" ]; then
        # Integrated mode: AMD only, force KWin to ignore the powered-off NVIDIA card
        if [ -n "$AMD_CARD" ]; then
            echo "gpu-mux-kwin-fix: Integrated mode - setting KWIN_DRM_DEVICES=$AMD_CARD for $username"
            mkdir -p "$env_dir"
            echo "KWIN_DRM_DEVICES=$AMD_CARD" > "$env_file"
            chown "$username:$username" "$env_dir" "$env_file" 2>/dev/null
        else
            echo "gpu-mux-kwin-fix: Integrated mode - no AMD card found, removing override for $username"
            rm -f "$env_file"
        fi
    elif [ "$NVIDIA_EXTERNAL" = "1" ] && [ -n "$NVIDIA_CARD" ] && [ -n "$AMD_CARD" ]; then
        # Hybrid + external monitor on NVIDIA: composite on NVIDIA to avoid cross-GPU copy lag.
        echo "gpu-mux-kwin-fix: Hybrid + ext display on NVIDIA - setting KWIN_DRM_DEVICES=$NVIDIA_CARD:$AMD_CARD for $username"
        mkdir -p "$env_dir"
        printf 'KWIN_DRM_DEVICES=%s:%s\nKWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1\n' "$NVIDIA_CARD" "$AMD_CARD" > "$env_file"
        chown "$username:$username" "$env_dir" "$env_file" 2>/dev/null
    else
        # Hybrid, internal panel only: let KWin auto-detect on AMD so RTD3 can sleep the dGPU.
        if [ -f "$env_file" ]; then
            echo "gpu-mux-kwin-fix: Hybrid (no ext display) - removing KWIN_DRM_DEVICES for $username"
            rm -f "$env_file"
        else
            echo "gpu-mux-kwin-fix: Hybrid (no ext display) - no override needed for $username"
        fi
    fi
}

# Configure real users
for user_home in /home/*; do
    [ -d "$user_home" ] || continue
    username=$(basename "$user_home")
    uid=$(id -u "$username" 2>/dev/null) || continue
    [ "$uid" -ge 1000 ] || continue
    configure_user "$user_home" "$username"
done

# Configure plasmalogin greeter user
PLASMA_LOGIN_HOME=$(getent passwd plasmalogin 2>/dev/null | cut -d: -f6)
if [ -n "$PLASMA_LOGIN_HOME" ]; then
    configure_user "$PLASMA_LOGIN_HOME" "plasmalogin"
fi

echo "gpu-mux-kwin-fix: Done. MUX=$MUX_MODE supergfx=$SUPERGFX_MODE ext=$NVIDIA_EXTERNAL NVIDIA=$NVIDIA_CARD AMD=$AMD_CARD"
