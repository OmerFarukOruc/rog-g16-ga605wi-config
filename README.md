# ROG Zephyrus G16 GA605WI — GPU scripts & reference

Persistent home for the GPU-mode scripts and the reference doc.
Laptop: ROG Zephyrus G16 GA605WI (Ryzen AI 9 HX 370 + RTX 4070), CachyOS, KDE Plasma Wayland.

## Files

| File | Installs to | Purpose |
|---|---|---|
| `gpu-mux-kwin-fix.sh` | `/usr/local/bin/` | Boot script: sets `KWIN_DRM_DEVICES` per GPU mode. dGPU→nvidia-only, Integrated→amd-only, Hybrid+external-on-nvidia→nvidia:amd (lag fix), Hybrid internal-only→no override. Runs before the display manager via `gpu-mux-kwin-fix.service`. |
| `gpu-dgpu-diag.sh` | `/usr/local/bin/` | Dumps GPU/display diagnostics to `/var/log/gpu-dgpu-diag-latest.log` (connector status, EDID bytes, drm_info, nvidia-smi, kwin environ, journal tail). |
| `gpu-dgpu-guard.sh` | `/usr/local/bin/` | Dead-man's switch for testing dGPU mode. Only arms when MUX=0. Waits 5 min for `/run/dgpu-keep`; if absent, captures diagnostics and auto-reverts to Hybrid + reboot. Self-disables after acting once. |
| `gpu-dgpu-guard.service` | `/etc/systemd/system/` | systemd unit for the guard. `TimeoutStartSec=infinity` so the 5-min wait isn't killed. |
| `gpu-dgpu-setup.sh` | run in place | One-shot installer for the four files above. Reads sources from `/tmp` — copy the others into `/tmp` first, or edit the paths to point here. |
| `rog-laptop-gpu-reference.md` | — | Full reference: current state, config files, recovery, lessons. |

## Test dGPU-only mode (the open problem)

```bash
# 1. install + arm (sources must be in /tmp; or edit setup paths to this dir)
sudo bash gpu-dgpu-setup.sh
# 2. unplug external monitor (clean test of internal panel), then:
sudo supergfxctl -m AsusMuxDgpu && sudo reboot
```

After reboot:
- **Screen works** → `sudo touch /run/dgpu-keep` (within 5 min), then `sudo systemctl disable gpu-dgpu-guard.service`.
- **Black** → wait 5 min (auto-reverts to Hybrid). Or SSH: `ssh oruc@<TAILSCALE_IP>` → `sudo supergfxctl -m Hybrid && sudo reboot`.
- Then read `/var/log/gpu-dgpu-diag-latest.log`.

## Status (2026-06-05)

- **Hybrid + prime-run** = daily driver. External-monitor lag fixed via nvidia-primary compositing.
- **dGPU-only (AsusMuxDgpu)** = black internal panel under Wayland in all prior tests — BUT those used a two-card `KWIN_DRM_DEVICES`; the **nvidia-only** config (now in the script) was never actually booted. That's the current experiment.
- Ruled out: `color_pipeline=0`, HDR/WCG off, backlight (nvidia_0 reads max).

See `rog-laptop-gpu-reference.md` for the full picture.
