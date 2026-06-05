#!/bin/bash
# Installs the hardened KWin DRM script + the dGPU-test safety harness.
# Source of truth = this script's own directory, so run it from wherever the repo lives:
#   sudo bash ./gpu-dgpu-setup.sh
set -e

SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
echo "== installing from: $SRC =="

echo "== syntax check =="
bash -n "$SRC/gpu-mux-kwin-fix.sh"
bash -n "$SRC/gpu-dgpu-diag.sh"
bash -n "$SRC/gpu-dgpu-guard.sh"

echo "== install scripts =="
install -m 755 "$SRC/gpu-mux-kwin-fix.sh"      /usr/local/bin/gpu-mux-kwin-fix.sh
install -m 755 "$SRC/gpu-dgpu-diag.sh"         /usr/local/bin/gpu-dgpu-diag.sh
install -m 755 "$SRC/gpu-dgpu-guard.sh"        /usr/local/bin/gpu-dgpu-guard.sh
install -m 644 "$SRC/gpu-mux-kwin-fix.service" /etc/systemd/system/gpu-mux-kwin-fix.service
install -m 644 "$SRC/gpu-dgpu-guard.service"   /etc/systemd/system/gpu-dgpu-guard.service

echo "== enable boot service + arm dead-man's switch (guard no-ops until you boot dGPU) =="
systemctl daemon-reload
systemctl enable gpu-mux-kwin-fix.service
systemctl enable gpu-dgpu-guard.service

echo "== verify =="
ls -l /usr/local/bin/gpu-mux-kwin-fix.sh /usr/local/bin/gpu-dgpu-diag.sh /usr/local/bin/gpu-dgpu-guard.sh /etc/systemd/system/gpu-mux-kwin-fix.service /etc/systemd/system/gpu-dgpu-guard.service
echo -n "boot service enabled: "; systemctl is-enabled gpu-mux-kwin-fix.service
echo -n "guard enabled: "; systemctl is-enabled gpu-dgpu-guard.service
echo -n "guard timeout: "; systemctl cat gpu-dgpu-guard.service | grep -i timeout
echo "== dGPU branch of installed main script =="
grep -n "dGPU mode - setting\|NVIDIA card not found\|supergfxctl --get" /usr/local/bin/gpu-mux-kwin-fix.sh
echo
echo "DONE. Harness armed. To run the test:  sudo supergfxctl -m AsusMuxDgpu && sudo reboot"
