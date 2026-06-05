#!/bin/bash
# Dead-man's switch for testing dGPU-only (AsusMuxDgpu) mode.
# Only acts when booted in dGPU mode (MUX=0). Waits WINDOW seconds for the user
# to confirm the screen works (sudo touch /run/dgpu-keep). If no confirmation,
# it captures diagnostics and reverts to Hybrid + reboots, so a black screen
# self-recovers without SSH or Windows. Disarms itself after acting once.
WINDOW=120

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

MUX_FILE=$(find_mux_file || true)
[ -n "$MUX_FILE" ] || exit 0
# Not in dGPU mode this boot: stay armed, do nothing.
[ "$(cat "$MUX_FILE" 2>/dev/null)" = "0" ] || exit 0

echo "gpu-dgpu-guard: dGPU boot detected, waiting ${WINDOW}s for /run/dgpu-keep"
sleep "$WINDOW"

# Capture diagnostics regardless of outcome.
/usr/local/bin/gpu-dgpu-diag.sh 2>/dev/null

# We have acted once in dGPU mode -> disarm so we never auto-revert again.
systemctl disable gpu-dgpu-guard.service 2>/dev/null || true

if [ -e /run/dgpu-keep ]; then
    echo "gpu-dgpu-guard: /run/dgpu-keep present -> keeping dGPU mode"
    exit 0
fi

echo "gpu-dgpu-guard: no keep flag -> reverting to Hybrid and rebooting"
# Hardened: never let a hung supergfxctl freeze the recovery. The direct MUX
# write + supergfxd.conf edit are the reliable path out of AsusMuxDgpu.
timeout 30 supergfxctl -m Hybrid 2>/dev/null || true
echo 1 > "$MUX_FILE" 2>/dev/null || true
sed -i 's/"mode": "[^"]*"/"mode": "Hybrid"/' /etc/supergfxd.conf 2>/dev/null || true
sync
systemctl reboot
