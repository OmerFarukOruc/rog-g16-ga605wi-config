# ASUS ROG Zephyrus G16 GA605WI — GPU & KWin Reference

> **Purpose:** single source of truth for GPU mode switching, KWin/Wayland multi-GPU config, the external-monitor lag fix, and the dGPU black-screen issue on this laptop. Written to be fed to an LLM for diagnosis — current state first, then details, then the resolved investigation.
>
> **Last verified:** 2026-06-05 · kernel `7.0.10-2-cachyos` · `nvidia-open` 610.43.02 · KDE Plasma/KWin 6.6.5 Wayland.

---

## TL;DR — Current State (read first)

- **Daily driver = Hybrid mode + `prime-run`.** This is the supported, stable setup. Internal panel on AMD; run apps on the dGPU with `prime-run <app>`.
- **External monitor is auto-accelerated.** The boot script promotes NVIDIA to KWin's compositor when an external display is connected to it (HDMI/DP route to the dGPU) — fixes the cross-GPU lag. Falls back to AMD (battery-saving) when undocked. See [External-Monitor Lag Fix](#external-monitor-lag-fix-nvidia-primary-compositing).
- **dGPU-only (`AsusMuxDgpu`) mode = DEAD END under Wayland.** Black-screens the internal panel. Root cause not in config — colour pipeline, HDR/WCG all ruled out. **Do not use it.** See [Resolved: dGPU Black Screen](#resolved-dgpu-only-mode-black-screen-under-wayland).
- **Mostly on AC, docked, external monitor.** RTD3 power management is correct and unchanged.
- If a GPU mode switch ever black-screens you: [Recovery](#recovery-procedures) → Windows GHelper "Enable Hybrid", or SSH.

| Mode | Status | When to use |
|------|--------|-------------|
| **Hybrid** | ✅ daily driver | Always. `prime-run` for dGPU apps; auto nvidia-primary for external monitor. |
| **Integrated** | ✅ works | Max battery (dGPU fully off). |
| **AsusMuxDgpu (dGPU-only)** | ❌ black-screens under Wayland | Don't. X11-only; not worth losing HDR/240 Hz. |

---

## System Specification

| Component | Value |
|-----------|-------|
| **Laptop** | ASUS ROG Zephyrus G16 **GA605WI** (AMD iGPU + NVIDIA dGPU) |
| **dGPU** | NVIDIA GeForce RTX 4070 Laptop / Max-Q (PCI `65:00.0`, vendor `0x10de`) |
| **iGPU** | AMD Radeon 880M/890M (Strix Point, PCI `66:00.0`, vendor `0x1002`) |
| **CPU** | Ryzen AI 9 HX 370 (Strix Point, Zen 5) |
| **Internal panel** | `eDP` — 2560×1600 @ 240 Hz, HDR (Samsung `SDC`) |
| **External (typical)** | `HDMI-A-1` on the **NVIDIA** GPU — 2560×1440 @ 144 Hz |
| **OS / Kernel** | CachyOS · `7.0.10-2-cachyos` (LTS `6.18.33` also installed) |
| **NVIDIA driver** | 610.43.02 — `nvidia-open` (CUDA 13.3) |
| **Desktop** | KDE Plasma 6.6.5 / KWin **Wayland** |
| **Display Manager** | `plasmalogin` (greeter user `plasmalogin`, home `/var/lib/plasmalogin`) |
| **GPU mode manager** | `supergfxctl` 5.2.7 (modes: `Hybrid`, `Integrated`, `AsusMuxDgpu`) + `asusctl` |
| **Bootloader** | Limine — rebuild initramfs with `sudo limine-mkinitcpio` (NOT `mkinitcpio -P`) |
| **MUX switch** | `/sys/devices/platform/asus-nb-wmi/gpu_mux_mode` (**0 = dGPU, 1 = Hybrid/Integrated**). No BIOS MUX toggle — software only. |
| **Tailscale** | host `<your-host>` — `tailscale ip -4` or `tailscale status \| grep <host>` |

---

## Key Configuration Files

| File | Purpose |
|------|---------|
| `/etc/modprobe.d/nvidia.conf` | NVIDIA module options (modeset, fbdev, color_pipeline, power mgmt) |
| `/etc/supergfxd.conf` | supergfxctl persisted mode |
| `/usr/local/bin/gpu-mux-kwin-fix.sh` | **Boot script** — sets `KWIN_DRM_DEVICES` per mode (the core of this setup) |
| `/etc/systemd/system/gpu-mux-kwin-fix.service` | Runs the script before `plasmalogin` |
| `~/.config/environment.d/kwin-hdr.conf` | `KWIN_FORCE_ASSUME_HDR_SUPPORT=1` |
| `~/.config/environment.d/kwin-drm.conf` | **Auto-managed by the boot script** — never edit by hand |
| `/etc/mkinitcpio.conf` | `MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)` |
| `/usr/lib/udev/rules.d/80-nvidia-pm.rules` | RTD3 runtime-PM automation (package-provided) |
| `/etc/default/limine` | Kernel cmdline |

### `/etc/modprobe.d/nvidia.conf`
```
options nvidia_drm modeset=1 fbdev=1 color_pipeline=0
options nvidia NVreg_EnableS0ixPowerManagement=1 NVreg_DynamicPowerManagement=0x02
```
- `fbdev=1` — essential; stops `simpledrm` creating a conflicting framebuffer card.
- `color_pipeline=0` — disables the 610 driver's new DRM colour pipeline. Tested as a dGPU-black-screen fix; **did not help** (kept only because it's harmless and is NVIDIA's documented HDR-blank workaround for nvidia-driven outputs). Any change here needs `sudo limine-mkinitcpio` + reboot (loads from initramfs).
- `NVreg_DynamicPowerManagement=0x02` — fine-grained RTD3 (dGPU sleeps when idle). See [RTD3](#rtd3-power-management).

### `/etc/supergfxd.conf` (Hybrid = default safe mode)
```json
{ "mode": "Hybrid", "vfio_enable": false, "vfio_save": false,
  "always_reboot": false, "no_logind": false, "logout_timeout_s": 180, "hotplug_type": "Asus" }
```
`hotplug_type` must be `"Asus"` for ROG laptops.

### Kernel cmdline
```
quiet nowatchdog splash rw rootflags=subvol=/@ nvidia-drm.modeset=1 modprobe.blacklist=nouveau
```

---

## The Boot Script: `gpu-mux-kwin-fix.sh`

**Runs** before `plasmalogin.service`, after `supergfxd.service`. Detects GPUs **by vendor ID** every boot (cardN numbers are unstable — never hardcode them) and writes `KWIN_DRM_DEVICES` to `~/.config/environment.d/kwin-drm.conf` for each real user **and** the `plasmalogin` greeter.

| Mode (MUX + supergfxctl) | `KWIN_DRM_DEVICES` written | Why |
|--------------------------|---------------------------|-----|
| **MUX=0 (dGPU-only)** | `<nvidia>` (nvidia only) | Single card; avoid KWin choking on the AMD card. *(dGPU-only still black-screens — see resolved section.)* |
| **MUX=1 + Integrated** | `<amd>` (amd only) | Hide the powered-off dGPU so KWin doesn't crash on it. |
| **MUX=1 + Hybrid, external display on NVIDIA** | `<nvidia>:<amd>` + `KWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1` | NVIDIA composites → no cross-GPU copy lag on the external monitor. |
| **MUX=1 + Hybrid, internal panel only** | (override removed) | KWin auto-detects AMD; RTD3 can sleep the dGPU → battery. |

**Hotplug caveat:** the external-display check happens at **boot**. If you dock *after* boot, log out/in (or restart the service) to pick up nvidia-primary. A full udev hotplug hook would be the only way to make it instant — not implemented.

<details><summary><b>Full script source (rev 2026-06-05)</b></summary>

```bash
# See /usr/local/bin/gpu-mux-kwin-fix.sh on the machine for the authoritative copy.
# Key logic:
#  - detect NVIDIA (0x10de) / AMD (0x1002) cards by vendor ID
#  - NVIDIA_EXTERNAL=1 if a non-eDP connector on the nvidia card is "connected"
#  - MUX=0 -> KWIN_DRM_DEVICES=<nvidia>
#  - Integrated -> KWIN_DRM_DEVICES=<amd>
#  - Hybrid + NVIDIA_EXTERNAL -> KWIN_DRM_DEVICES=<nvidia>:<amd> + KWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1
#  - Hybrid + internal-only -> remove override
```
</details>

---

## External-Monitor Lag Fix (NVIDIA-primary compositing)

**Symptom:** desktop feels laggy/stuttery, especially dragging windows on the external monitor.

**Cause:** the external monitor is wired to the **NVIDIA** GPU (HDMI/DP path), but in Hybrid KWin composites on the **AMD** iGPU by default. Every frame for the external display is copied AMD→NVIDIA across PCIe — at 144 Hz that copy is the lag. (`nvidia-smi` shows the dGPU at ~30 % util doing copy work.)

**Fix:** make NVIDIA KWin's primary compositor via `KWIN_DRM_DEVICES=<nvidia>:<amd>` (nvidia first) + `KWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1` (keeps HDR working). NVIDIA then drives the external natively (no copy) and composites everything. **Confirmed smooth.**

This is now **automatic** via the boot script — applied only when an external display is on the dGPU, so it doesn't waste battery when mobile. **Power is "free" when docked:** the dGPU is already awake driving the external monitor (RTD3 can't sleep a GPU that's driving a display), so moving compositing onto it costs ~nothing.

- Requires a **logout/login** (or reboot) to take effect — `KWIN_DRM_DEVICES` is read at session start.
- Verify it's active: `tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland|head -1)/environ | grep KWIN_DRM`
- Still not perfectly smooth? Next knob: `KWIN_DRM_DISABLE_TRIPLE_BUFFERING=0`.

---

## RTD3 Power Management

Already configured correctly — leave as is. `NVreg_DynamicPowerManagement=0x02` (fine-grained), `80-nvidia-pm.rules` present, `power/control=auto`, `/proc/driver/nvidia/gpus/*/power` shows `Runtime D3 status: Enabled (fine-grained)`.

Key behaviour (from NVIDIA's RTD3 doc): **the dGPU stays active whenever it is driving a display.** So with the external monitor plugged in, the dGPU is always awake — expected, and fine on AC. RTD3 only powers it fully off (D3cold, vram off) when no display and no app use the dGPU (i.e. undocked, internal-only) → that's where the battery savings come from, and why the lag fix is conditional.

---

## Switching GPU Modes

> All mode switches require a **full reboot**, not just a logout. A logout-only leaves a stale `kwin_wayland` that crash-loops the greeter (`start-limit-hit`).

### To Hybrid (default)
```bash
sudo sed -i 's/"mode": "[^"]*"/"mode": "Hybrid"/' /etc/supergfxd.conf
sudo reboot
```
> **Use the `sed` edit, NOT `supergfxctl -m Hybrid`.** The `-m` form does not persist a switch *out* of `AsusMuxDgpu` — it sets runtime mode but leaves `supergfxd.conf` reading `AsusMuxDgpu`, so every boot relies on supergfxd's safety-check fallback. `-m` only persists reliably going *into* MUX mode. (Verified 2026-06-04.)

### To Integrated (best battery)
```bash
sudo sed -i 's/"mode": "[^"]*"/"mode": "Integrated"/' /etc/supergfxd.conf
sudo reboot
```

### To AsusMuxDgpu (dGPU-only) — ⚠ black-screens under Wayland, avoid
```bash
sudo supergfxctl -m AsusMuxDgpu && sudo reboot   # will black-screen; recover via GHelper/SSH
```

---

## Resolved: dGPU-only Mode Black Screen Under Wayland

**Status: bug is in nvidia-open 610's eDP scanout layer for Ada Mobile, below the compositor.** Userspace is fully exonerated. In `AsusMuxDgpu` the internal eDP is hardware-MUXed to the NVIDIA GPU. KWin completes a clean modeset, attaches a 2560×1600 10-bit framebuffer to a CRTC, allocates planes, processes Wayland clients — and the panel stays dark anyway. **X11 works; Wayland does not**, compositor-independent (KWin/Sway/Hyprland), kernel-independent (cachyos 7.0 + LTS 6.18). Reproduced on multiple GA605WI machines including [kiia.ione](https://discuss.cachyos.org/t/trying-to-solve-hybrid-gpu-problem-for-asus-amd-nvidia-laptops/17935): "switching the BIOS GPU mode to dGPU Only results in the internal display going completely blank, showing only a blinking cursor in the top-left corner. ... I also tested the linux-g14 kernel ... but the problem remained."

**Ruled out empirically (do NOT re-chase):**
- **`color_pipeline=0`** — confirmed active (sysfs `N`, in initramfs); still black.
- **HDR + Wide Color Gamut OFF** with `color_pipeline=0` = zero colour management; still black. → colour/HDR conclusively NOT the cause despite matching the 610 release-note wording.
- Boot script ran, `KWIN_DRM_DEVICES` set, `fbdev=1`, simpledrm unbound — all verified correct.
- asusd per-profile tunings — unrelated.
- **NVIDIA-only `KWIN_DRM_DEVICES`** (boot script's MUX=0 branch, dropping the AMD card) — retested 2026-06-05 on kernel 7.0; same black screen. AMD card was not the trigger.
- **LTS kernel 6.18.33-2-cachyos-lts** in dGPU mode — retested 2026-06-05; identical behaviour. Not a 7.0-kernel regression.
- **Boot-script hang on `supergfxctl --get`** (separate bug that masked the real symptom in pre-2026-06-05 reproductions; `multi-user.target` was wedged so KWin never started) — fixed in commit 956b292 (`timeout 5` wrapper). With the fix, every dGPU boot now reaches `graphical.target` cleanly and `gpu-dgpu-guard` actually fires.
- **"KWin never presents" hypothesis** — **disproved 2026-06-05** with verbose KWin logging (`QT_LOGGING_RULES=kwin.*=true;qt.qpa.*=true` + `WAYLAND_DEBUG=server` injected into the boot script's MUX=0 branch). KWin runs the full pipeline.
- **`KWIN_FORCE_SW_CURSOR=1`** (hardware-cursor regression suspicion, from KDE Bug 517987 / Arch BBS 310531) — disproved 2026-06-05. With SW cursor set, DRM debugfs confirms cursor plane[58] detaches (`crtc=(null), fb=0`) and only the primary plane[53] (2560×1600 ABGR2101010) stays attached to crtc-0. Panel is still black. So hardware-cursor / multi-GPU GL-framebuffer regression from 517987 is not the cause on this path — that was a different upstream bug already fixed in 6.6.5.

### What KWin actually does in dGPU mode (verbose-logged, 2026-06-05)

- `kwin_wayland` journal grows from **5 lines to 12,450 lines** of normal Wayland traffic.
- **Zero** error / warning / fail / cannot / denied / atomic-commit-failed lines anywhere in the verbose log.
- Wayland clients (plasmashell, panel widgets, splash) connect, register globals (`wp_color_manager_v1`, `wp_presentation`, `kde_output_management_v2`, `linux_drm_syncobj`, …), commit surfaces, and receive frame callbacks.
- DRM state in `/sys/kernel/debug/dri/0000:65:00.0/state` shows:
  - `CRTCs: 64 fb=145 pos=(0,0) size=(2560x1600)` — CRTC active.
  - `plane[53] crtc=crtc-0 fb=150 size=2560x1600 format=AB30 (ABGR2101010) allocated by kwin_wayland` — 10-bit framebuffer attached.
  - `plane[58] crtc=crtc-0 fb=144 size=256x256 format=AR24` — cursor plane attached.
  - `GAMMA_LUT` populated (1024-entry blob), `DEGAMMA_LUT` populated.
  - `VRR_ENABLED=0`, `NV_CRTC_REGAMMA_TF=Default`.
- `modetest -M nvidia-drm` reports `eDP-1: connected, 2560x1600@240`, encoder 136 bound to CRTC 64.
- `nvidia-smi` reports **GPU-Util 100 %**, **629 MiB** memory used, `Disp.A: On`.
- Kernel journal shows nvidia-drm loaded cleanly, `fbcon: nvidia-drmdrmfb (fb0) is primary device`, no NVRM/nvidia errors.
- Backlight `nvidia_0: brightness=100/100, bl_power=0`.

Everything in software thinks scanout is happening normally. The panel just doesn't show the signal.

### What's actually broken

The bug is in the hardware-to-panel path that the open NVIDIA 610 driver controls on this hardware combination — eDP link training, PSR sequencing, panel power-state handoff after MUX switch, or a similar low-level eDP topic. Indicators worth carrying into the upstream bug report:
- The plane state shows `color-encoding=ITU-R BT.709 YCbCr` and `color-range=YCbCr full range` even though the framebuffer is RGB (`AB30 = ABGR2101010`). On an eDP laptop panel this is unusual and may be cosmetic (NVIDIA-internal property), but worth flagging.
- All AMD-side eDP connectors (`amdgpu` log lines) report `PSR support 0, DC PSR ver -1` — so the panel itself doesn't advertise PSR to amdgpu. But amdgpu doesn't drive the panel in dGPU mode; whether nvidia-open agrees on PSR state is unknown.
- The panel is high-spec (Samsung SDC, 2560×1600 @ 240 Hz, HDR). It may want a specific eDP DPCD wake sequence after MUX hand-off that nvidia-open doesn't issue.

### Where to file

- **NVIDIA Linux Open GPU Kernel Modules** issue tracker (https://github.com/NVIDIA/open-gpu-kernel-modules/issues). Use the dGPU-debug evidence above (verbose KWin log shows everything is fine in userspace; nvidia driver-only modeset succeeds; panel stays dark). Reference the two other GA605WI reproductions to establish it's not one-off hardware.
- **CachyOS / asus-linux** forums for any model-specific workaround (eDP DPCD quirks, link-rate clamps, PSR disable). The CachyOS thread already has one other GA605WI reproduction.
- **KDE Bugzilla is no longer the right venue** — KWin is doing everything correctly per the verbose log; an upstream KWin bug would be the wrong destination.

**Why no standard tool does this:** the supported answer is "don't MUX-switch on Wayland — stay Hybrid + prime-run." `supergfxctl`/`asusctl` flip the MUX only; `switcheroo-control` does per-app offload; KWin auto-detects in Hybrid. The per-mode `KWIN_DRM_DEVICES` automation (this script) fills a gap for an unsupported edge case.

Sources: [CachyOS GA605WI thread](https://discuss.cachyos.org/t/trying-to-solve-hybrid-gpu-problem-for-asus-amd-nvidia-laptops/17935) · [asus-linux FAQ](https://asus-linux.org/faq/) ("Use X11 instead of Wayland").

---

## Recovery Procedures

### From a dGPU/MUX black screen (the OS boots fine — only the display is dead)
1. **Windows → GHelper → "Enable Hybrid"** (simplest, proven). Flips the firmware MUX back to Optimus; carries into Linux. GA605 has **no BIOS MUX toggle**.
2. **SSH** (Tailscale): `ssh oruc@<ip>` → `sudo supergfxctl -m Hybrid && sudo reboot`.
3. After either, `supergfxd.conf` may read `AsusMuxDgpu` (stale; masked by supergfxd's boot safety-check). Clean it: `sudo sed -i 's/"mode": "[^"]*"/"mode": "Hybrid"/' /etc/supergfxd.conf`.

### Stuck at login after switching to Integrated (logout instead of reboot)
Stale `kwin_wayland` + the NVIDIA card still in `/dev/dri/` → greeter crash-loops `start-limit-hit`. SSH in:
```bash
sudo killall -9 kwin_wayland plasmalogin plasmalogin-helper
sudo systemctl reset-failed plasmalogin && sudo systemctl restart plasmalogin
sudo sed -i 's/"mode": "[^"]*"/"mode": "Hybrid"/' /etc/supergfxd.conf
sudo reboot
```

### Generic SSH rescue
```bash
tailscale status | grep rog                 # find IP
ssh oruc@<TAILSCALE_IP>
# force Hybrid + clear overrides, then reboot:
sudo sed -i 's/"mode": "[^"]*"/"mode": "Hybrid"/' /etc/supergfxd.conf
rm -f ~/.config/environment.d/kwin-drm.conf
sudo limine-mkinitcpio   # only if you changed nvidia.conf / fbdev
sudo reboot
```

### Login loop (password → back to greeter)
| Cause | Check | Fix |
|-------|-------|-----|
| Bad `KWIN_DRM_DEVICES` | `~/.config/environment.d/kwin-*.conf` | remove file, let boot script handle it |
| NVIDIA module not loaded | `nvidia-smi` fails / `lsmod\|grep nvidia` empty | `sudo modprobe nvidia nvidia_drm nvidia_modeset nvidia_uvm` |
| Wrong supergfxctl mode | `supergfxctl -g` | edit `/etc/supergfxd.conf`, reboot |
| `fbdev=0` | `grep fbdev /etc/modprobe.d/nvidia.conf` | set `fbdev=1`, `sudo limine-mkinitcpio`, reboot |

---

## Diagnostic Commands

```bash
supergfxctl -g                                   # current GPU mode
cat /sys/devices/platform/asus-nb-wmi/gpu_mux_mode   # MUX (0=dGPU,1=Hybrid)
for c in /sys/class/drm/card[0-9]; do echo "$(basename $c): $(cat $c/device/vendor)"; done  # which card is which
for d in /sys/class/drm/card*-*; do [ "$(cat $d/status 2>/dev/null)" = connected ] && echo "$(basename $d): connected"; done  # displays
nvidia-smi                                       # dGPU state + processes (Disp.A=On => driving a display)
cat /proc/driver/nvidia/gpus/*/power             # RTD3 status
kscreen-doctor -o | grep -iE 'Output|enabled|HDR|priority'   # KDE outputs + HDR
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland|head -1)/environ | grep KWIN_DRM  # is override active?
journalctl -b | grep gpu-mux-kwin-fix            # boot script log
journalctl -b -u plasma-login-kwin_wayland       # greeter KWin log (truncates on black screen)
```

---

## Lessons Learned

1. **Never hardcode `/dev/dri/cardX`** — numbering shifts between boots; detect by vendor ID.
2. **Never use `/dev/dri/by-path/`** in `KWIN_DRM_DEVICES` — KWin splits on every `:`, breaking PCI addresses. (Single-card values sidestep this.)
3. **`nvidia_drm fbdev=1` is essential** — prevents the `simpledrm` conflict. (Makes the script's simpledrm-unbind largely redundant.)
4. **`hotplug_type="Asus"`** required in `supergfxd.conf`.
5. **Rebuild initramfs with `sudo limine-mkinitcpio`** (not `mkinitcpio -P`) after `nvidia.conf` changes.
6. **`environment.d` changes need logout/login** (or reboot) — the user session caches env from login.
7. **Always reboot for MUX/mode switches** — logout-only leaves stale `kwin_wayland`.
8. **dGPU-only is a Wayland dead-end on this laptop** — colour/HDR ruled out; stay Hybrid + prime-run.
9. **External-monitor lag = cross-GPU copy** — fix by making NVIDIA KWin's primary (`KWIN_DRM_DEVICES=<nvidia>:<amd>`); free on AC because the dGPU is already driving the display.
10. **`supergfxctl -m Hybrid` doesn't persist out of dGPU mode** — edit `supergfxd.conf` directly.

---

## References
- [asus-linux Arch guide](https://asus-linux.org/guides/arch-guide/) · [supergfxctl manual](https://asus-linux.org/manual/supergfxctl-manual/) · [asus-linux FAQ](https://asus-linux.org/faq/)
- NVIDIA driver README — Ch. 22 RTD3 Power Management, App. L Wayland Known Issues (`color_pipeline=0` workaround)
- [CachyOS GA605WI hybrid-GPU thread](https://discuss.cachyos.org/t/trying-to-solve-hybrid-gpu-problem-for-asus-amd-nvidia-laptops/17935)
- supergfxctl is being phased out (asus-linux); for Hybrid, `prime-run` + the boot script is sufficient.
