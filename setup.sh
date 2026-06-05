#!/bin/bash
# Install persistent NVIDIA-primary KWin compositing (Hybrid mode) and remove the old
# dGPU-dedicated-mode test harness. Run from the repo dir:  sudo bash ./setup.sh
set -e
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

echo "== remove old dGPU test harness (dedicated-mode is a dead end on this laptop) =="
systemctl disable --now gpu-dgpu-guard.service 2>/dev/null || true
systemctl disable --now gpu-mux-kwin-fix.service 2>/dev/null || true
rm -f /usr/local/bin/gpu-dgpu-guard.sh /usr/local/bin/gpu-dgpu-diag.sh
rm -f /usr/local/bin/gpu-mux-kwin-fix.sh /usr/local/bin/gpu-mux-kwin-fix.sh.*   # base + .before-debug/.orig-* backups
rm -f /etc/systemd/system/gpu-dgpu-guard.service /etc/systemd/system/gpu-mux-kwin-fix.service
rm -f /var/log/gpu-dgpu-diag-latest.log

echo "== install persistent nvidia-primary compositing =="
bash -n "$SRC/kwin-nvidia-primary.sh"
install -m 755 "$SRC/kwin-nvidia-primary.sh"      /usr/local/bin/kwin-nvidia-primary.sh
install -m 644 "$SRC/kwin-nvidia-primary.service" /etc/systemd/system/kwin-nvidia-primary.service
systemctl daemon-reload
systemctl enable kwin-nvidia-primary.service

echo "== apply now (so a logout/login is enough, no reboot needed) =="
/usr/local/bin/kwin-nvidia-primary.sh

echo "== done =="
systemctl is-enabled kwin-nvidia-primary.service
ls -l /usr/local/bin/kwin-nvidia-primary.sh /etc/systemd/system/kwin-nvidia-primary.service
echo
echo "Log out and back in to apply. Verify: 'nvidia-smi' should list kwin_wayland after relogin."
