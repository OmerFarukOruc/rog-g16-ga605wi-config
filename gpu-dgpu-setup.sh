#!/bin/bash
# Installs the hardened KWin DRM script + the dGPU-test safety harness.
# Run once with: sudo bash /tmp/gpu-dgpu-setup.sh
set -e

echo "== syntax check =="
bash -n /tmp/gpu-mux-kwin-fix.sh
bash -n /tmp/gpu-dgpu-diag.sh
bash -n /tmp/gpu-dgpu-guard.sh

echo "== install scripts =="
install -m 755 /tmp/gpu-mux-kwin-fix.sh /usr/local/bin/gpu-mux-kwin-fix.sh
install -m 755 /tmp/gpu-dgpu-diag.sh    /usr/local/bin/gpu-dgpu-diag.sh
install -m 755 /tmp/gpu-dgpu-guard.sh   /usr/local/bin/gpu-dgpu-guard.sh
install -m 644 /tmp/gpu-dgpu-guard.service /etc/systemd/system/gpu-dgpu-guard.service

echo "== arm dead-man's switch (no-op until you boot dGPU) =="
systemctl daemon-reload
systemctl enable gpu-dgpu-guard.service

echo "== verify =="
ls -l /usr/local/bin/gpu-mux-kwin-fix.sh /usr/local/bin/gpu-dgpu-diag.sh /usr/local/bin/gpu-dgpu-guard.sh /etc/systemd/system/gpu-dgpu-guard.service
echo -n "guard enabled: "; systemctl is-enabled gpu-dgpu-guard.service
echo "== dGPU branch of installed main script =="
grep -n "dGPU mode - setting\|NVIDIA card not found\|supergfxctl --get" /usr/local/bin/gpu-mux-kwin-fix.sh
echo
echo "DONE. Harness armed. To run the test:  sudo supergfxctl -m AsusMuxDgpu && sudo reboot"
