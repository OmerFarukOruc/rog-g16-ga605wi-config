# ROG Zephyrus G16 GA605WI — GPU & KWin config

Persistent **NVIDIA-primary KWin compositing** for this laptop, plus the full GPU reference.
**ASUS ROG Zephyrus G16 GA605WI** (Ryzen AI 9 HX 370 + RTX 4070), CachyOS, KDE Plasma Wayland.

## What this does

Runs the KDE Plasma desktop with **KWin compositing on the NVIDIA dGPU**, persistently, in **Hybrid** mode — for a lag-free desktop (especially on an external/dock display). No MUX switching, no reboot-to-switch, no manual session picker.

A small boot service writes `KWIN_DRM_DEVICES=<nvidia>:<amd>` (nvidia = compositor primary) into `environment.d` before login. It resolves the cards by **PCI vendor ID** because `/dev/dri/cardN` renumbers between boots, and `/dev/dri/by-path` can't be used — its `:` collides with the `:` separator in `KWIN_DRM_DEVICES`.

## Files

| File | Installs to | Purpose |
|---|---|---|
| `kwin-nvidia-primary.sh` | `/usr/local/bin/` | Boot script: writes nvidia-primary `KWIN_DRM_DEVICES` for all real users + the `plasmalogin` greeter |
| `kwin-nvidia-primary.service` | `/etc/systemd/system/` | Runs the script before the display manager |
| `setup.sh` | run in place | Installs the two files, removes the old dGPU test harness, applies immediately |
| `rog-laptop-gpu-reference.md` | — | Full GPU reference: config, RTD3, recovery, the dGPU-dead-end investigation |
| `ghelper-linux-migration.md` | — | Power/thermal/fan/RGB reference (g-helper → asusctl migration) |

## Install

```bash
sudo bash setup.sh
```
Then **log out and back in**. Verify nvidia is compositing:
```bash
nvidia-smi | grep kwin_wayland                                   # should be listed
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland|head -1)/environ | grep KWIN_DRM
```

## Trade-off

NVIDIA composites everything, so the dGPU never RTD3-sleeps: smooth always, ~a few watts more, worse battery when undocked (plus a reverse iGPU copy for the internal panel). To make it relax to the iGPU when no external display is attached, see the "only when docked" note at the top of `kwin-nvidia-primary.sh`.

## Not done (by design)

- **dGPU-only (`AsusMuxDgpu`) mode** — black-screens the internal panel under Wayland. Confirmed dead-end with full DRM evidence (the atomic modeset is perfect, the panel still never lights; X11 works, Wayland doesn't). Details in the reference doc. Stay Hybrid.
- **Manual per-session nvidia picker** — dropped in favour of this automatic persistent setup.

## License
MIT — see `LICENSE`. These scripts write per-user `environment.d`; read before running on other hardware.
