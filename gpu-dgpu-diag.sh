#!/bin/bash
# Capture GPU/display diagnostics for debugging the dGPU-mode Wayland black screen.
# Safe to run anytime; writes a single overwriting log.
OUT="/var/log/gpu-dgpu-diag-latest.log"

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

{
    echo "===== gpu-dgpu-diag $(date -Is 2>/dev/null) ====="
    echo "## MUX mode (0=dGPU 1=Hybrid/Integrated)"
    mux=$(find_mux_file || true)
    [ -n "$mux" ] && echo "$mux = $(cat "$mux" 2>/dev/null)" || echo "no gpu_mux_mode found"
    echo "## supergfxctl --get / -S"
    supergfxctl --get 2>/dev/null; supergfxctl -S 2>/dev/null
    echo "## DRM connectors (status)"
    for s in /sys/class/drm/card*-*/status; do
        [ -e "$s" ] || continue
        echo "$(basename "$(dirname "$s")"): $(cat "$s" 2>/dev/null)"
    done
    echo "## EDID bytes per connector (0 = panel not seen)"
    for e in /sys/class/drm/card*-*/edid; do
        [ -e "$e" ] || continue
        echo "$(basename "$(dirname "$e")"): $(stat -c%s "$e" 2>/dev/null) bytes"
    done
    echo "## Backlight"
    for b in /sys/class/backlight/*; do
        [ -e "$b" ] || continue
        echo "$(basename "$b"): $(cat "$b/brightness" 2>/dev/null)/$(cat "$b/max_brightness" 2>/dev/null)"
    done
    echo "## drm_info connectors+modes"
    timeout 10 drm_info 2>/dev/null | grep -iE "Connector|Driver:|status|eDP|HDMI|DP-|modes|made for|preferred" | head -120
    echo "## nvidia-smi"
    timeout 10 nvidia-smi 2>/dev/null | head -20
    echo "## kwin_wayland environ (KWIN/GBM/GLX/WAYLAND)"
    for p in $(pgrep -x kwin_wayland 2>/dev/null); do
        echo "-- pid $p --"
        tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -iE "KWIN|GBM|GLX|WAYLAND_DISPLAY|XDG_SESSION"
    done
    echo "## journal this boot: kwin/greeter/drm/nvidia (tail 80)"
    journalctl -b 0 --no-pager 2>/dev/null \
        | grep -iE "kwin|plasma-login|nvidia-modeset|\[drm\]|atomic|output|eDP" \
        | grep -ivE "Failed to gain real time|cursor theme|xkbcomp" \
        | tail -80
} > "$OUT" 2>&1
echo "wrote $OUT"
