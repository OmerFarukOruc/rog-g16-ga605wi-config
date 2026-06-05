# ASUS ROG Zephyrus G16 GA605WI — GPU & KWin Reference

> **Purpose:** single source of truth for the GPU/KWin setup on this laptop. Current state first, then config, then the resolved dGPU-black-screen investigation. Written to be fed to an LLM.
>
> **Last verified:** 2026-06-05 · kernel `7.0.10-2-cachyos` · `nvidia-open` 610.43.02 · KDE Plasma/KWin 6.6.5 Wayland.

---

## TL;DR — Current State (read first)

- **Hybrid mode, permanently.** Never MUX-switch. dGPU-only black-screens (see below); Integrated is only for max battery.
- **KWin composites on the NVIDIA dGPU, persistently.** A boot service (`kwin-nvidia-primary.service`) writes `KWIN_DRM_DEVICES=<nvidia>:<amd>` into `environment.d` before login, so the whole desktop renders on the dGPU → lag-free, especially on an external/dock display. Cards are resolved by **vendor ID** (cardN renumbers; `by-path` is unusable — colon clash).
- **Trade-off accepted:** the dGPU never RTD3-sleeps (a few watts, worse battery undocked). Fine on AC/dock. To relax to the iGPU when undocked, see the note in `kwin-nvidia-primary.sh`.
- **Apps:** with nvidia as KWin's primary, clients render on nvidia by default. `prime-run` still works for explicit offload.
- If a GPU mode switch ever black-screens you: [Recovery](#recovery).

| Mode | Status | Use |
|------|--------|-----|
| **Hybrid + nvidia-primary KWin** | ✅ daily driver | Always. |
| **Integrated** | ✅ works | Max battery (dGPU fully off). |
| **AsusMuxDgpu (dGPU-only)** | ❌ black-screens under Wayland | Don't. X11-only. |

---

## System Specification

| Component | Value |
|-----------|-------|
| **Laptop** | ASUS ROG Zephyrus G16 **GA605WI** |
| **dGPU** | NVIDIA GeForce RTX 4070 Laptop (PCI `65:00.0`, vendor `0x10de`) |
| **iGPU** | AMD Radeon 890M (Strix Point, PCI `66:00.0`, vendor `0x1002`) |
| **CPU** | Ryzen AI 9 HX 370 (Strix Point, Zen 5) |
| **Internal panel** | `eDP` 2560×1600 @ 240 Hz, HDR (Samsung `SDC`). Hybrid: on AMD as `eDP-2`. |
| **External (typical)** | on the NVIDIA GPU (`HDMI-A-1`) |
| **OS / Kernel** | CachyOS · `7.0.10-2-cachyos` (LTS `6.18.33` also installed) |
| **NVIDIA driver** | 610.43.02 — `nvidia-open` |
| **Desktop / DM** | KDE Plasma 6.6.5 / KWin **Wayland** · `plasmalogin` greeter (home `/var/lib/plasmalogin`) |
| **GPU tools** | `supergfxctl` 5.2.7 (reliable MUX flip on this box) · `asusctl` armoury (`gpu_mux_mode` attribute; MUX set is flaky here — two-manager conflict) |
| **Bootloader** | Limine — rebuild initramfs with `sudo limine-mkinitcpio` (NOT `mkinitcpio -P`) |
| **MUX** | `/sys/devices/platform/asus-nb-wmi/gpu_mux_mode` **and** `/sys/devices/platform/asus-armoury/gpu_mux_mode` (**0 = dGPU, 1 = Hybrid**). No BIOS MUX toggle. |

---

## The Setup: persistent NVIDIA-primary compositing

**`/usr/local/bin/kwin-nvidia-primary.sh`** (run by `kwin-nvidia-primary.service`, before `plasmalogin`):
detects the NVIDIA (`0x10de`) and AMD (`0x1002`) cards by vendor ID, then writes for every real user **and** the `plasmalogin` greeter:

```
~/.config/environment.d/kwin-drm.conf
  KWIN_DRM_DEVICES=<nvidia>:<amd>          # nvidia first = KWin compositor primary
  KWIN_DRM_ALLOW_NVIDIA_COLORSPACE=1       # keeps HDR/colorspace working on nvidia
```

- **Why a script and not a static file:** `cardN` renumbers between boots, and `KWIN_DRM_DEVICES` splits on `:`, so `/dev/dri/by-path/pci-0000:65:00.0-card` (which contains colons) is misparsed. Vendor-ID detection sidesteps both.
- **Apply:** logout/login (env is read at session start). `setup.sh` also runs the script once on install so a relogin is enough.
- **"Only when docked" variant** (battery-friendly when mobile): gate the write on a connected non-eDP connector existing on the nvidia card — i.e. only set nvidia-primary when an external display is attached to the dGPU, else remove the override so the iGPU composites and RTD3 sleeps the dGPU. (This was the earlier auto-conditional behaviour; the current default is always-on per preference.)

Verify it's active:
```bash
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland|head -1)/environ | grep KWIN_DRM
nvidia-smi | grep kwin_wayland     # kwin shown on the dGPU = compositing on nvidia
```

### Why nvidia-primary fixes external-monitor lag
The external is wired to the NVIDIA GPU. If KWin composites on the AMD iGPU (the Hybrid default), every external-display frame is copied AMD→NVIDIA across PCIe — at high refresh that copy *is* the lag. Compositing on NVIDIA drives the external natively (no copy). "Free" power when docked: the dGPU is already awake driving that display (RTD3 can't sleep a GPU that's scanning out).

---

## Key Configuration Files

| File | Purpose |
|------|---------|
| `/usr/local/bin/kwin-nvidia-primary.sh` | Boot script — writes nvidia-primary `KWIN_DRM_DEVICES` |
| `/etc/systemd/system/kwin-nvidia-primary.service` | Runs it before `plasmalogin` |
| `~/.config/environment.d/kwin-drm.conf` | **Auto-managed** by the script — don't hand-edit |
| `~/.config/environment.d/kwin-hdr.conf` | `KWIN_FORCE_ASSUME_HDR_SUPPORT=1` (pre-existing, for panel HDR) |
| `/etc/modprobe.d/nvidia.conf` | `nvidia_drm modeset=1 fbdev=1 color_pipeline=0` + RTD3 power mgmt |
| `/etc/supergfxd.conf` | supergfxctl persisted mode (`"mode": "Hybrid"`) |

### `/etc/modprobe.d/nvidia.conf`
```
options nvidia_drm modeset=1 fbdev=1 color_pipeline=0
options nvidia NVreg_EnableS0ixPowerManagement=1 NVreg_DynamicPowerManagement=0x02
```
- `fbdev=1` — essential; stops `simpledrm` creating a conflicting framebuffer card.
- `color_pipeline=0` — kept (harmless; NVIDIA's documented HDR-blank workaround). **Did not** fix the dGPU black screen. Changes here need `sudo limine-mkinitcpio` + reboot.
- `NVreg_DynamicPowerManagement=0x02` — fine-grained RTD3.

---

## RTD3 Power Management
Configured correctly — leave as is (`0x02`, `80-nvidia-pm.rules`, `power/control=auto`). The dGPU stays awake whenever it drives a display **or** composites — which it now always does under this setup. RTD3 only fully powers it off when undocked *and* not compositing on it (i.e. only with the "only when docked" variant).

---

## Resolved: dGPU-only (`AsusMuxDgpu`) Black Screen — confirmed dead-end

In `AsusMuxDgpu` the internal eDP is hardware-MUXed to NVIDIA (becomes `eDP-1` on the nvidia card). The desktop never lights. Reproduced ~10× here and on another GA605WI. **X11 works; Wayland doesn't.** This is a Wayland/nvidia-eDP limitation, **not** a config problem and **not** a function of which tool flips the MUX.

**Definitive evidence (captured via SSH while black, nvidia-only `KWIN_DRM_DEVICES`):**
- MUX=0; `nvidia-smi`: **Display Attached: Yes, Display Active: Enabled**, backlight `nvidia_0 = 100/100`.
- DRM atomic state is **perfect**: `crtc-0 enable=1 active=1`, mode `2560x1600@240`, bound to `eDP-1`; `plane-0` has `fb=149` (allocated by `kwin_wayland`, `2560x1600`, format **AB30 = 10-bit ARGB2101010**).
- `eDP-1` **connected** with EDID + physical size `340x220mm`; nvidia-drm Connector eDP `connected` with modes.
- `kwin_wayland` log: only the harmless realtime-thread warning — **zero DRM/output errors**. KWin composes a flawless 10-bit scanout to a connected, backlit panel that stays black.

**Ruled out empirically:** `color_pipeline=0`; HDR+WCG off; nvidia-only vs two-card `KWIN_DRM_DEVICES`; backlight (reads max); EDID (present in `modetest`, the sysfs `0 bytes` is an nvidia sysfs quirk). The card-open / atomic-commit errors seen at recovery are **shutdown teardown noise**, not the cause.

**Tooling notes:** `supergfxctl -m AsusMuxDgpu` reliably flips the MUX on this box; `asusctl armoury set gpu_mux_mode 0` is **flaky here** ("Multiple asusd interfaces devices found" — `supergfxd` + `asusd` both claim the GPU interface, the exact two-manager conflict asus-linux warns about). supergfxctl is deprecated upstream but works today; the tool is irrelevant to the black screen regardless.

**Only untested lever** (researched, not tried on hardware): **`KWIN_DRM_NO_AMS=1`** — disable KWin atomic modesetting, forcing the legacy modeset path (what X11/nvidia uses, which lights the panel). Targets the exact symptom (perfect *atomic* state, black panel). If dGPU-only is ever revisited: set it in `environment.d` for the dGPU boot, behind the safety guard (git history has the guard harness).

---

## Recovery

### From a dGPU/MUX black screen (OS boots fine, only display is dead)
1. **Windows → GHelper → "Enable Hybrid"** — flips the firmware MUX back; carries into Linux. No BIOS MUX toggle on GA605.
2. **SSH** (Tailscale): `ssh oruc@<ip>` → `sudo supergfxctl -m Hybrid && sudo reboot`.
3. If `supergfxd.conf` is stale: `sudo sed -i 's/"mode": "[^"]*"/"mode": "Hybrid"/' /etc/supergfxd.conf`.

### Login loop (password → back to greeter)
| Cause | Check | Fix |
|-------|-------|-----|
| Bad `KWIN_DRM_DEVICES` | `~/.config/environment.d/kwin-*.conf` | `rm` the file; let the boot script rewrite it |
| NVIDIA module not loaded | `nvidia-smi` fails | `sudo modprobe nvidia nvidia_drm nvidia_modeset nvidia_uvm` |
| `fbdev=0` | `grep fbdev /etc/modprobe.d/nvidia.conf` | set `fbdev=1`, `sudo limine-mkinitcpio`, reboot |

---

## Diagnostics
```bash
supergfxctl -g                                                   # GPU mode
cat /sys/devices/platform/asus-armoury/gpu_mux_mode              # MUX (0=dGPU,1=Hybrid)
for c in /sys/class/drm/card[0-9]; do echo "$(basename $c): $(cat $c/device/vendor)"; done  # which card is which
nvidia-smi                                                       # dGPU state + processes (kwin listed => compositing on nvidia)
tr '\0' '\n' < /proc/$(pgrep -x kwin_wayland|head -1)/environ | grep KWIN_DRM
journalctl -b -u kwin-nvidia-primary                            # boot script log
```

---

## Lessons Learned
1. **Never hardcode `/dev/dri/cardX`** — renumbers between boots; detect by vendor ID.
2. **Never use `/dev/dri/by-path/` in `KWIN_DRM_DEVICES`** — KWin splits on every `:`, breaking PCI addresses. No working escape.
3. **`nvidia_drm fbdev=1` is essential** — prevents the `simpledrm` conflict.
4. **`environment.d` changes need logout/login** — env is cached at session start. `setup.sh` runs the script once so a relogin suffices.
5. **dGPU-only is a Wayland dead-end on this laptop** — *proven*: the atomic modeset is perfect and the panel still never lights. Colour/HDR/backlight/EDID all ruled out. The only untried lever is `KWIN_DRM_NO_AMS=1` (legacy modeset).
6. **External-monitor lag = cross-GPU copy** — fixed by making NVIDIA KWin's primary; free on AC because the dGPU already drives the display.
7. **`asusctl armoury` MUX set is flaky with `supergfxd` running** (two-manager conflict) — `supergfxctl` is the reliable flip on this box. Don't run two MUX managers.
8. **The tool (supergfxctl vs asusctl) never affects the black screen** — both flip the same firmware bit; the issue is nvidia+Wayland on the internal eDP.

---

## References
- [asus-linux Arch guide](https://asus-linux.org/guides/arch-guide/) · [supergfxctl manual](https://asus-linux.org/manual/supergfxctl-manual/) · [asus-linux FAQ](https://asus-linux.org/faq/)
- NVIDIA driver README — Ch. 22 RTD3, App. L Wayland Known Issues (`color_pipeline=0`)
- [CachyOS GA605WI hybrid-GPU thread](https://discuss.cachyos.org/t/trying-to-solve-hybrid-gpu-problem-for-asus-amd-nvidia-laptops/17935)
- KWIN_DRM_DEVICES + by-path colon clash: [KWin multi-GPU MR !1291](https://invent.kde.org/plasma/kwin/-/merge_requests/1291)
