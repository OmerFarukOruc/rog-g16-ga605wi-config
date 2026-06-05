# ASUS ROG Zephyrus G16 (GA605WI) — Power & Thermal Control on Linux

**Single source of truth** for how this laptop's power, thermal, fan, RGB and GPU control is set up.

The machine briefly ran the **g-helper-linux** fork (utajum) from 2026-05-30. That was **reverted to the native `asusctl` stack on 2026-06-04** after g-helper was found to conflict with `power-profiles-daemon` (it wedged the CPU power state) and to weaken the system's permission model. The "why" and the g-helper rollback path are at the end.

- **Machine:** ASUS ROG Zephyrus **G16 GA605WI**, CachyOS (Arch-based, `pacman`), kernel 7.x
- **CPU:** AMD **Ryzen AI 9 HX 370** (Strix Point, Zen 5; `amd_pstate = active`)
- **dGPU:** NVIDIA **RTX 4070 Laptop**, driver **610.43.02**
- **SMU firmware:** 11.93.11.0
- **Updated:** 2026-06-04 (rev: corrected the CPU-boost story + switched to g-helper-style setup — see [CPU boost & frequency](#cpu-boost--frequency--amd_pstate-g-helper-style-setup))

---

## TL;DR — current state

- **Control stack:** `asusctl` + `rog-control-center` **6.3.7-2** (cachyos repo), `asusd` daemon (D-Bus activated), `supergfxctl` for GPU MUX.
- **CPU boost (g-helper-style):** stock **`amd_pstate=active`** + a soft `cpufreq/boost` toggle, exactly like g-helper-linux; thermals via PPT limits + fan curves. ⚠ Note `boost=0` is **cosmetic** in active mode on this chip (firmware still drives cores to ~5.1 GHz). A *real* clock cap needs **`amd_pstate=passive`** — kept as an optional alternative, not the default. See [CPU boost & frequency](#cpu-boost--frequency--amd_pstate-g-helper-style-setup).
- **Fan curves:** an **aggressive curve is enabled on the Performance profile**; Quiet uses a custom curve; Balanced uses the firmware's stock table.
- **Profiles:** **AC → Performance**, **battery → Quiet** (auto-switch), EPP linked per profile, per-profile PPT / GPU tuning — all in `/etc/asusd/asusd.ron`.
- asusctl **coexists** with `power-profiles-daemon` and KDE's power applet (they stay in sync via the kernel `platform_profile` interface — no conflict).
- ⚠ **CPU undervolt is NOT possible on this chip** (Zen 5 SMU). It is cosmetic-only in _any_ tool — don't chase it.

---

## Machine profile

| Field            | Value                                   |
| ---------------- | --------------------------------------- |
| Model            | ROG Zephyrus G16 GA605WI                |
| CPU              | Ryzen AI 9 HX 370 (Strix Point, Zen 5)  |
| dGPU             | RTX 4070 Laptop                         |
| NVIDIA driver    | 610.43.02                               |
| SMU firmware     | 11.93.11.0                              |
| Distro           | CachyOS (Arch-based), `pacman` / `paru` |
| amd_pstate       | `active` (stock) — no real freq cap; `passive` needed to cap |
| CPU boost node   | `/sys/devices/system/cpu/cpufreq/boost` |
| platform_profile | choices: quiet / balanced / performance |
| asusctl / RCC    | 6.3.7-2 (cachyos repo)                  |

---

## Why asusctl, not g-helper

Three findings drove the move back to the native stack:

1. **g-helper jams `power-profiles-daemon` (PPD).** g-helper writes the _global_ `cpufreq/boost` node directly. With `amd_pstate=active`, forcing global boost to `0` makes the kernel reject PPD's _per-policy_ boost writes with `EINVAL`. PPD then aborts every profile transition and stays wedged on whatever profile it was on — pinning the governor and EPP (e.g. stuck at `performance`/`performance`) and making **KDE's power applet silently fail to switch**. Verified by driving PPD over D-Bus and watching `…/cpufreq/policyN/boost: Invalid argument`; re-enabling global boost (`echo 1`) un-wedged it (governor flipped `performance → powersave`, EPP → `balance_performance`). asusd does **not** poke `cpufreq/boost`, so it does not cause this.

2. **CPU undervolt doesn't work on this CPU — so g-helper's main advantage is moot here.** On Zen 5 / Strix Point, `ryzen_smu` can't write Curve Optimizer offsets. g-helper logs `SetCoAll … readback=0 … WARNING readback differs from requested`, then _cosmetically_ prints "applied." `ryzenadj` hits the same SMU mailbox and fails identically. There is no undervolt on this machine until the kernel / `ryzen_smu` catches up.

3. **g-helper's installer weakens the permission model.** It `chmod 0666`s a wide set of sysfs/firmware nodes (including `cpu*/online`), adds a passwordless `sudoers` rule for its GPU helpers, and ships a "disable dGPU" path that deactivates the NVIDIA Vulkan ICD. The native asusctl stack (written by the same people who wrote the kernel's `asus-wmi` driver) needs none of that and integrates with `platform_profile`/PPD through the kernel notify path.

The only reason g-helper was ever installed was a **GUI CPU-boost toggle** — now replaced by `disable-cpu-boost.service` (below).

---

## Current configuration

### Profiles, EPP & power limits — `/etc/asusd/asusd.ron`

Key behaviour: charge limit 100%, **AC→Performance / battery→Quiet** auto-switch, EPP linked to the profile, and per-profile PPT power limits + NVIDIA dynamic-boost/temp-target (separate AC and DC tables).

```ron
(
    charge_control_end_threshold: 100,
    base_charge_control_end_threshold: 0,
    disable_nvidia_powerd_on_battery: true,
    ac_command: "",
    bat_command: "",
    platform_profile_linked_epp: true,
    platform_profile_on_battery: Quiet,
    change_platform_profile_on_battery: true,
    platform_profile_on_ac: Performance,
    change_platform_profile_on_ac: true,
    profile_quiet_epp: Power,
    profile_balanced_epp: BalancePower,
    profile_custom_epp: Performance,
    profile_performance_epp: BalancePower,
    ac_profile_tunings: {
        Quiet: ( enabled: true, group: {
            PptPl1Spl: 15, PptPl2Sppt: 35, PptPl3Fppt: 35,
            NvTempTarget: 75, NvDynamicBoost: 5, DgpuTgp: 55 } ),
        Performance: ( enabled: true, group: {
            PptPl1Spl: 80, PptPl2Sppt: 80, PptPl3Fppt: 80,
            NvTempTarget: 87, NvDynamicBoost: 20, DgpuTgp: 85 } ),
        Balanced: ( enabled: true, group: {
            PptPl1Spl: 50, PptPl2Sppt: 60, PptPl3Fppt: 60,
            NvTempTarget: 87, NvDynamicBoost: 15, DgpuTgp: 75 } ),
    },
    dc_profile_tunings: {
        Performance: ( enabled: true, group: {
            PptPl1Spl: 35, PptPl2Sppt: 44, PptPl3Fppt: 65,
            NvTempTarget: 87, NvDynamicBoost: 0, DgpuTgp: 0 } ),
        Balanced: ( enabled: true, group: {
            PptPl1Spl: 80, PptPl2Sppt: 80, PptPl3Fppt: 80,
            NvTempTarget: 87, NvDynamicBoost: 20, DgpuTgp: 85 } ),
        Quiet: ( enabled: true, group: {
            PptPl1Spl: 25, PptPl2Sppt: 31, PptPl3Fppt: 45,
            NvTempTarget: 75, NvDynamicBoost: 20, DgpuTgp: 85 } ),
    },
    armoury_settings: { PanelOverdrive: 1 },
)
```

> `/etc/asusd/asusd.ron` is the live file and the real source of truth; the block above is the current content (formatted). RGB and Slash lighting live alongside it in `/etc/asusd/aura_19b6.ron` and `/etc/asusd/slash.ron`, managed through rog-control-center.

### Fan curves — `/etc/asusd/fan_curves.ron`

**Performance** carries the aggressive curve (temps 30→80 °C, `enabled: true`). **Quiet** has a custom curve (enabled). **Balanced** is `enabled: false` → firmware stock table. `pwm` is 0–255 (255 = 100%).

```ron
(
    profiles: (
        balanced: [
            ( fan: CPU, pwm: (12, 38, 56, 68, 104, 147, 165, 165), temp: (54, 56, 58, 60, 62, 74, 76, 76), enabled: false ),
            ( fan: GPU, pwm: (7, 28, 40, 58, 96, 147, 168, 168),  temp: (58, 60, 62, 67, 69, 72, 76, 76), enabled: false ),
            ( fan: MID, pwm: (20, 20, 38, 86, 142, 198, 198, 198), temp: (54, 56, 58, 60, 62, 74, 76, 76), enabled: false ),
        ],
        performance: [
            ( fan: CPU, pwm: (0, 23, 74, 125, 171, 214, 245, 255), temp: (30, 45, 55, 60, 65, 70, 75, 80), enabled: true ),
            ( fan: GPU, pwm: (0, 18, 69, 112, 156, 204, 240, 255), temp: (30, 45, 55, 60, 65, 70, 75, 80), enabled: true ),
            ( fan: MID, pwm: (0, 13, 61, 105, 145, 189, 232, 255), temp: (30, 45, 55, 60, 65, 70, 75, 80), enabled: true ),
        ],
        quiet: [
            ( fan: CPU, pwm: (0, 23, 51, 74, 125, 189, 240, 255), temp: (30, 40, 50, 55, 60, 70, 80, 90), enabled: true ),
            ( fan: GPU, pwm: (0, 18, 38, 61, 112, 176, 227, 255), temp: (30, 40, 50, 55, 60, 70, 80, 90), enabled: true ),
            ( fan: MID, pwm: (0, 13, 26, 48, 99, 163, 214, 255),  temp: (30, 40, 50, 55, 60, 70, 80, 90), enabled: true ),
        ],
        custom: [],
    ),
)
```

The Performance curve in human terms (temp → fan %): CPU 55→29, 60→49, 65→67, 70→84, 75→96, 80→100; GPU and Mid a few points lower. Set with `asusctl fan-curve` (see below) or rog-control-center.

### CPU boost & frequency — `amd_pstate` (g-helper-style setup)

This machine deliberately mirrors **how g-helper-linux handles the CPU**: stay in the stock **`amd_pstate=active`** driver and expose CPU boost as a single soft toggle on `/sys/devices/system/cpu/cpufreq/boost`. Thermals are managed the g-helper way — via **PPT power limits + fan curves**, not a frequency cap.

> **Important reality on this chip — `boost=0` is cosmetic in `active` mode.** Earlier versions of this doc claimed `disable-cpu-boost.service` caps the CPU at its 2.0 GHz base clock. **That is false in `amd_pstate=active`.** Verified: with `cpufreq/boost` reading `0` *and* the service active+enabled, cores still ran at **5.13–5.16 GHz**.

**Why.** `amd_pstate=active` is the *firmware-autonomous* CPPC path: the SMU/firmware picks the P-state and the OS's `cpufreq/boost`, `scaling_max_freq`, and EPP are all just *hints*. On this Preferred-Core HX 370 the firmware drives the favoured cores to CPPC `highest_perf` (`highest_perf≈196–202` vs `nominal_perf≈76`; ≈2.6 × the 2.0 GHz base ≈ 5.3 GHz) regardless of the boost toggle. This is upstream-acknowledged (kernel Bugzilla **217931**; Arch forum *"amd-pstate-epp driver not limiting CPU Frequency"*; the `18d9b522` "use nominal perf for limits when boost is disabled" commit is present in our 7.x kernel yet still doesn't cap here).

**Both g-helper ports do exactly the same soft toggle — there is no missed lever:**

- **g-helper-linux** v1.0.79 (`src/Platform/Linux/LinuxPowerManager.cs`, `SetCpuBoost`) for AMD just writes `cpufreq/boost`; it never switches `amd_pstate` to passive. Same "reads 0 but still 5.1 GHz" behaviour here.
- **Windows g-helper** (`app/Mode/PowerNative.cs`, `SetCPUBoost`) writes the Windows `PERFBOOSTMODE` setting, which per Microsoft only takes effect under *non-autonomous (OS-led) CPPC* — which Windows uses, so it sticks there. The Linux equivalent of that OS-led mode is `amd_pstate=passive` (see the optional cap below).

So in this g-helper-style setup the boost toggle is a **cosmetic/labelled control**: leave it `0` (g-helper's "boost off" button) and rely on the Performance/Quiet **PPT limits + fan curves** to govern heat and sustained clocks. Full single-thread performance is retained.

#### `disable-cpu-boost.service` — `/etc/systemd/system/disable-cpu-boost.service`

Mirrors g-helper's `SetCpuBoost(false)` at boot by writing the boost node. `ExecStop` re-enables boost, so `systemctl stop` is "boost back on." Ordered `After=multi-user.target` (a `tmpfiles.d w` write to this node was avoided — it can deadlock early boot). **In `active` mode this only changes the node, not the actual clocks** — keep it only if you want the boost node parked at `0` for parity with g-helper.

```ini
[Unit]
Description=Park AMD cpufreq/boost at 0 (cosmetic in amd_pstate=active; g-helper parity)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'
ExecStop=/bin/sh -c 'echo 1 > /sys/devices/system/cpu/cpufreq/boost'

[Install]
WantedBy=multi-user.target
```

> **Cleanup note:** an orphan `/etc/tmpfiles.d/amd-pstate-boost.conf` (g-helper-era leftover, owned by no package, single line `w …/cpufreq/boost - - - - 1`) was writing `boost=1` early at every boot and fighting this service. It was removed (`sudo rm`). The boost node had also been left world-writable (`0666`) by g-helper's old udev rule; that is a stale runtime state and self-heals to `0644` on the next reboot.

#### Optional: a *real* frequency cap via `amd_pstate=passive`

If you ever want an actual hard ceiling (cooler/quieter at the cost of peak clocks), switch the driver to passive — then `cpufreq/boost` and `scaling_max_freq` are genuinely **enforced**. This departs from the g-helper-style setup (asusd's per-profile EPP linking goes inert; fan curves + PPT still work).

```bash
echo passive | sudo tee /sys/devices/system/cpu/amd_pstate/status   # reversible: echo active
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost             # hard cap at 2.0 GHz nominal
# …OR an intermediate ceiling (boost on, cap via scaling_max_freq):
#   echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost
#   for p in /sys/devices/system/cpu/cpufreq/policy*; do echo 3500000 | sudo tee $p/scaling_max_freq; done
```

Verified: in passive + `boost=0`, `cpuinfo_max_freq` = `2000000` and cores stay ≤ 2.0 GHz under all-core load (vs ~5.15 GHz in active). Trade-off: a 2.0 GHz cap removes ~60% of peak single-thread clock. Switching the driver **resets** boost to `1` and `scaling_max_freq` to full, so re-apply them *after* the switch. To persist: add `amd_pstate=passive` to the kernel cmdline via **Limine** (`/etc/default/limine`, then re-run the `limine-mkinitcpio-hook`) and keep `disable-cpu-boost.service` enabled to re-apply `boost=0` after boot. **Current machine state: `active` (g-helper-style); passive is not persisted.**

---

## Thermal levers on this machine

- **Work:** fan curves; PPT power limits (`PptPl1Spl` / `PptPl2Sppt` / `PptPl3Fppt`); platform profile + linked **EPP** (the main CPU-heat lever in `active` mode — `BalancePower` is cooler than `Performance`). For a hard frequency cap you must leave `active` mode for `amd_pstate=passive`.
- **Cosmetic in `active` mode:** the `cpufreq/boost` toggle / `disable-cpu-boost.service` — sets the node but doesn't change real clocks on this chip.
- **Does NOT work:** CPU Curve-Optimizer **undervolt** — `ryzen_smu` can't write CO on Zen 5; `ryzenadj` shares the same dead SMU mailbox. Re-test only after a kernel / `ryzen_smu` update, and only trust it if `readback == requested`.
- **GPU tab (rog-control-center):** TGP / Dynamic Boost / Temp Target are hardware-bounded and safe at any value. Core/Memory **offset** and **clock/VRAM lock** are the only damage-risk rows → leave at 0/Off unless deliberately OCing in tiny steps; verify with `nvidia-smi -q -d CLOCK`, not the UI label.
- ⚠ Never use a "disable dGPU" control (that was a g-helper footgun that hid the NVIDIA Vulkan ICD).

---

## How to operate

- **Switch profile:** KDE power applet, rog-control-center, or `asusctl profile set Quiet|Balanced|Performance` (also `list` / `get` / `next`). On AC it auto-selects Performance, on battery Quiet. For cool daily on AC, switch to `Balanced`/`Quiet` or change `platform_profile_on_ac` in `asusd.ron`.
- **CPU boost:** `sudo systemctl stop disable-cpu-boost` → boost node **1**; `start` → **0**; `disable --now` → leave it alone. Check: `cat /sys/devices/system/cpu/cpufreq/boost`. ⚠ In `amd_pstate=active` this only sets the node — it does **not** change actual clocks (cores still reach ~5.1 GHz). For a real cap use `amd_pstate=passive` (see [CPU boost & frequency](#cpu-boost--frequency--amd_pstate-g-helper-style-setup)). The everyday heat lever in active mode is **EPP** (`profile_performance_epp`, now `BalancePower`) + PPT + fan curves.
- **Edit a fan curve:**
  ```bash
  asusctl fan-curve --mod-profile Performance --fan cpu \
    --data "30c:0%,45c:9%,55c:29%,60c:49%,65c:67%,70c:84%,75c:96%,80c:100%"
  asusctl fan-curve --mod-profile Performance --enable-fan-curves true
  ```
  (`--fan gpu|mid` for the others; rog-control-center does the same with sliders.)
- **Battery charge limit:** `charge_control_end_threshold` in `asusd.ron` / the rog-control-center battery slider (currently 100).

## Verify

```bash
systemctl is-active asusd disable-cpu-boost
asusctl profile get
cat /sys/firmware/acpi/platform_profile
cat /sys/devices/system/cpu/cpufreq/boost                       # expect 0
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor       # expect powersave
asusctl fan-curve --mod-profile Performance                     # shows enabled curves
sensors | grep -iE "fan:|Tctl|edge"
```

`asusd` is D-Bus activated (`static`) — it applies the profile + fan curves when the desktop/rog-control-center first queries it, same as a normal asus-linux setup. After a reboot, confirm `cpufreq/boost == 0` and `asusctl profile get`.

---

## Rollback to g-helper (only if ever wanted again)

Not recommended on this machine (see "Why asusctl, not g-helper"). If you must:

```bash
# install (read the warning first)
curl -sL https://raw.githubusercontent.com/utajum/g-helper-linux/master/install/install.sh | sudo bash
# uninstall (also restores the NVIDIA Vulkan ICD if it was hidden)
curl -sL https://raw.githubusercontent.com/utajum/g-helper-linux/master/install/install.sh | sudo bash -s -- --uninstall
```

Before installing, know that the installer opens broad `0666` permissions on hardware nodes, adds a passwordless `sudoers` rule, and enables a GPU boot service — and that its "disable dGPU" control can break the NVIDIA driver setup on this laptop. The full installer is the upstream `install/install.sh`; it is idempotent and supports `--appimage` and `--uninstall`.

To go back to native asusctl from g-helper: run the uninstall above, then `sudo pacman -S --needed asusctl rog-control-center && sudo systemctl enable --now asusd`. `/etc/asusd/*.ron` is not package-owned, so a prior `pacman -R` leaves it in place and asusd picks it straight back up.
