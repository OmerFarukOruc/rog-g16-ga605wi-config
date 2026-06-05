#!/bin/bash
# Capture GPU/display diagnostics for debugging the dGPU-mode Wayland black screen.
# Safe to run anytime; writes a single overwriting log.
OUT="/var/log/gpu-dgpu-diag-latest.log"
{
    echo "===== gpu-dgpu-diag $(date -Is 2>/dev/null) ====="
    echo "## MUX mode (0=dGPU 1=Hybrid/Integrated)"
    cat /sys/bus/platform/drivers/asus-nb-wmi/*/gpu_mux_mode 2>/dev/null
    echo "## supergfxctl --get / -S"
    supergfxctl --get 2>/dev/null; supergfxctl -S 2>/dev/null
    echo "## DRM connectors (status)"
    for s in /sys/class/drm/card*-*/status; do
        echo "$(dirname "$s" | xargs basename): $(cat "$s" 2>/dev/null)"
    done
    echo "## EDID bytes per connector (0 = panel not seen)"
    for e in /sys/class/drm/card*-*/edid; do
        echo "$(dirname "$e" | xargs basename): $(stat -c%s "$e" 2>/dev/null) bytes"
    done
    echo "## Backlight"
    for b in /sys/class/backlight/*; do
        echo "$(basename "$b"): $(cat "$b/brightness" 2>/dev/null)/$(cat "$b/max_brightness" 2>/dev/null)"
    done
    echo "## drm_info connectors+modes"
    timeout 10 drm_info 2>/dev/null | grep -iE "^\[|Connector|Driver:|status|eDP|HDMI|DP-|modes|Â└|made for|preferred" | head -120
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
