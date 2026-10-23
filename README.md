# xe-mshybrid-backlight-fix

Real, hardware OLED brightness control in MSHybrid mode (Intel `xe` GPU
driving the panel, NVIDIA dGPU present as a PRIME `on-demand` offload
device) on a Clevo/Tongfang laptop barebone.

**Status as of 2026-10-23: the actual root cause is now confirmed.**
Earlier versions of this README (and a lot of real debugging time)
believed the fix required controlling kernel module load order
(`xe-after-nvidia.conf`) on top of two kernel source bugs. That turned
out to be wrong — see "2026-10-23: the real root cause" below for the
full story. The actual bug: this panel supports a second, higher-range
DPCD *luminance* backlight-control mode, but `xe`'s own capability check
for that mode requires a second capability bit
(`DP_EDP_SMOOTH_BRIGHTNESS_CAPABLE`) this panel doesn't set, alongside
the one it does (`DP_EDP_PANEL_LUMINANCE_CONTROL_CAPABLE`) — so `xe`
silently fell back to a legacy backlight path that, on this panel,
writes correctly over DisplayPort AUX but the panel's own controller
(TCON) never visibly acts on. Relaxing that check to match this
project's own already-proven dGPU-mode fix (see
[clevo-control-panel](https://github.com/arbitrary-string/clevo-control-panel))
is the fix that actually matters. The other bugs below are real and
worth fixing regardless, but **none of them, together or alone, were
ever sufficient without the luminance-capability fix** — confirmed by
hours of direct hardware-level evidence, not reasoning. The
load-order fix (`xe-after-nvidia.conf`) is very likely unnecessary now
and is being kept installed, unchanged, only out of caution until that's
separately confirmed; don't assume you need it for a similar symptom on
different hardware.

Without the real fix, the brightness slider silently does nothing in
MSHybrid mode: writes succeed as DisplayPort AUX-channel transactions,
but the panel's own controller (TCON) doesn't visibly react.

## Is this relevant to your hardware?

The **kernel source patch** (`oled-mshybrid-backlight.patch`) fixes
three bugs in `drivers/gpu/drm/i915/display/intel_dp_aux_backlight.c`
(shared display code used by both `i915` and `xe`) that plausibly affect
*any* eDP panel with the same DPCD capability-bit quirks, on any Intel
GPU using this driver path — not specific to this exact board. Bug 1
(missing `DP_EDP_BACKLIGHT_AUX_ENABLE_CAP` check removal) was already
fixed upstream on 2026-07-16 in commit `a411ea4a87`
("Remove DP_EDP_BACKLIGHT_AUX_ENABLE_CAP check for DPCD backlight") --
check if your kernel already has it before patching. Bug 2 (the
boot-time atomic-readout skip) may or may not be fixed upstream; check
the "Verifying whether a future kernel already has the fix" section
below either way. **Bug 3 (the luminance capability gate) is the one
that actually fixes real-world brightness control on this panel** --
if your eDP panel advertises `PANEL_LUMINANCE_CONTROL_CAPABLE` (DPCD
`0x703` bit 4) without `SMOOTH_BRIGHTNESS_CAPABLE`, this is very likely
relevant to you too, on any board, with or without NVIDIA/MSHybrid
involved at all.

The **modprobe load-order fix** (`xe-after-nvidia.conf`) is kept in this
repo and still installed by `rebuild-and-install.sh`, but is no longer
believed to be load-bearing -- see "2026-10-23: the real root cause"
below. Treat it as legacy/unconfirmed-unnecessary rather than part of
the real fix if you're applying this to different hardware.

## Prerequisites (clean Ubuntu install)

- A currently-installed, currently-running kernel matching the
  `linux-image-unsigned-<version>` package you intend to patch (this was
  developed against `7.0.0-31-generic`; adjust for whatever version you
  have -- `uname -r`).
- Matching headers: `sudo apt install linux-headers-$(uname -r)`
- `deb-src` enabled in your apt sources, so `apt-get source` can fetch
  full kernel source (not just headers) -- on modern Ubuntu (deb822
  `.sources` format), add `deb-src` to the `Types:` line in
  `/etc/apt/sources.list.d/ubuntu.sources`, then `sudo apt-get update`.
- Build tooling: `sudo apt install build-essential bc flex bison libssl-dev
  libelf-dev dwarves zstd`
- ~15GB free disk space temporarily (kernel source + a full `vmlinux`
  build; cleaned up automatically except for the final small patched
  module and a backup of the original).
- For the modprobe fix specifically: NVIDIA's proprietary driver
  installed with the `nvidia_drm`/`nvidia_modeset`/`nvidia` kernel
  modules (i.e. `ubuntu-drivers`/`nvidia-driver-<version>`, not the
  open-source `nouveau` driver), and `prime-select` available
  (`nvidia-prime` package).

## Usage

```
git clone https://github.com/arbitrary-string/xe-mshybrid-backlight-fix.git
cd xe-mshybrid-backlight-fix
sudo ./rebuild-and-install.sh              # defaults to `uname -r`
sudo ./rebuild-and-install.sh 7.0.0-31-generic   # or target a specific kernel
sudo reboot
```

This one script does everything:
1. Fetches the exact matching kernel source via `apt-get source`.
2. Applies `oled-mshybrid-backlight.patch` (skips if already applied --
   safe to re-run).
3. Builds `xe.ko` against your exact running config (builds `vmlinux`
   first for symbol resolution, then the whole `drivers/gpu/drm/`
   subtree, since `xe.ko` links against several other DRM helper
   modules -- both confirmed necessary, this isn't a quick single-module
   out-of-tree build).
4. Backs up whatever module is currently installed for that kernel
   version (once, the first time), then installs the patched one,
   `depmod`/`update-initramfs`.
5. Installs `xe-after-nvidia.conf` to `/etc/modprobe.d/` and re-runs
   `depmod` -- this is the load-order fix, needed independently of the
   source patch above.
6. If an older version of this project's own boot-time suspend/resume
   workaround (see "Superseded approach" below) is present, disables and
   removes it.

Safe to re-run for the same kernel version; re-run after every future
kernel update that replaces the currently-patched kernel, before
rebooting into it -- if you forget, the panel just falls back to dim,
non-functional legacy PWM control (a safe failure mode, not a
boot-breaking one).

**Not packaged as DKMS.** `xe.ko` doesn't fit DKMS's usual model at all
-- it needs the full matching kernel source (not just the
`/usr/src/linux-headers-*` package DKMS normally builds against), a
fully-built `vmlinux`, and the whole `drivers/gpu/drm/` subtree built
alongside it for cross-module symbol resolution. A DKMS package
replicating that would mean a multi-minute, multi-GB, internet-dependent
rebuild on every kernel update, with a real chance of the patch someday
failing to apply cleanly against changed upstream/Ubuntu source --
deliberately chose this manual, transparent, run-when-needed script
instead.

## Files

- `oled-mshybrid-backlight.patch` -- the kernel source patch (see
  "What the patch does" below).
- `rebuild-and-install.sh` -- fetches, patches, builds, and installs
  everything, including the fix below.
- `xe-after-nvidia.conf` -- the modprobe load-order fix. Installed to
  `/etc/modprobe.d/`. Read the extensive comments in this file for the
  full investigation into *why* this is needed and how it was narrowed
  down -- genuinely the most interesting part of this repo.
- `oled-mshybrid-backlight-fixup.service`, `.sh`,
  `oled-mshybrid-fixup-wake-arm.sh` -- an earlier, superseded fix
  attempt (forcing a real suspend/resume cycle before the login screen
  appears, since that also independently fixes the symptom). Kept for
  reference / as a fallback approach in case a future kernel or NVIDIA
  driver update ever breaks the modprobe-ordering fix. **Not installed
  by `rebuild-and-install.sh`** as of the version in this repo.

## What the patch does

Three independent bugs in the same function chain
(`intel_dp_aux_vesa_setup_backlight()`/`_enable_backlight()`/
`intel_dp_aux_supports_vesa_backlight()`), in
`drivers/gpu/drm/i915/display/intel_dp_aux_backlight.c`:

1. `intel_dp_aux_vesa_check_support()` required both
   `DP_EDP_BACKLIGHT_AUX_ENABLE_CAP` and
   `DP_EDP_BACKLIGHT_BRIGHTNESS_AUX_SET_CAP` to be set in the panel's
   DPCD capabilities before enabling AUX-based backlight control at
   all. This exact panel sets the second bit but not the first --
   confirmed via direct DPCD capability reads -- so the driver silently
   fell back to the legacy (much lower resolution) PWM-based brightness
   path entirely. Already fixed upstream as of 2026-07-16 (commit
   `a411ea4a87`); this patch just drops the same check for kernels that
   predate that fix.
2. Even with (1) fixed, boot-time DRM atomic state readout sees the
   panel already lit by firmware and skips the encoder's `enable`
   callback (`intel_dp_aux_vesa_enable_backlight()`) -- the one that
   actually writes `DP_EDP_BACKLIGHT_MODE_SET_REGISTER` (DPCD `0x721`)
   to switch the panel's TCON from legacy PWM into DPCD-controlled
   mode. Without that write, subsequent brightness writes to DPCD
   `0x722`/`0x723` succeed as AUX transactions but the panel ignores
   them, since its TCON is still in PWM mode. This patch moves the same
   AUX mode-switch + initial-level write into
   `intel_dp_aux_vesa_setup_backlight()` instead, which (unlike
   `enable`) always runs at boot regardless of that atomic-readout
   optimization.
3. **The actual fix that matters on this panel**, found 2026-10-23:
   `intel_dp_aux_supports_vesa_backlight()` only enables the panel's
   higher-range *luminance* backlight-control mode (DPCD `0x734`,
   `TARGET_LUMINANCE`) when the panel sets **both**
   `DP_EDP_PANEL_LUMINANCE_CONTROL_CAPABLE` (DPCD `0x703` bit 4) *and*
   `DP_EDP_SMOOTH_BRIGHTNESS_CAPABLE`. This panel sets only the first.
   Without luminance mode, `xe` uses the legacy path (DPCD `0x722`),
   which on this panel writes correctly over AUX but produces *no
   visible effect at all* -- confirmed directly, byte-for-byte identical
   successful AUX writes whether the panel responds or not. The actual
   difference: luminance mode also sets DPCD `0x721` bit 7
   (`DP_EDP_PANEL_LUMINANCE_CONTROL_ENABLE`), which this project's own
   `clevo-control-panel` already independently proved, via NVIDIA's RM
   API in dGPU mode, is what makes this panel's TCON actually honor
   brightness writes at all. Relaxed the check to only require the first
   capability bit, matching that already-proven fix.

### Verifying whether a future kernel already has this fix built in

Worth checking before re-patching a new kernel version: enable
`drm.debug` (`echo 0x106 | sudo tee /sys/module/drm/parameters/debug`),
clear `dmesg` (`sudo dmesg -C`), write a value to
`/sys/class/backlight/intel_backlight/brightness`, and check whether it
visibly changes the panel, and whether `max_brightness` reads a
DPCD-derived scale (e.g. `4095`, a 12-bit AUX-VESA range) rather than a
much larger legacy PWM scale (`96000` on this exact panel -- will vary
by panel).

## What the modprobe fix does, and how it was found

Even with both source-patch bugs fixed, real brightness control still
didn't durably take effect from a cold boot -- only a genuine
suspend/resume cycle fixed it, every time. The actual root cause,
confirmed live through direct experimentation rather than kernel-source
reading alone:

- This only ever happens with NVIDIA's proprietary driver loaded in
  PRIME `on-demand` mode (`prime-select on-demand`) -- never with
  `prime-select intel` (NVIDIA fully unloaded). Confirmed across
  multiple consecutive cold boots each way.
- `on-demand` mode uniquely creates a **second** DRM connector
  (`card1-eDP-2`, owned by `nvidia_drm`) for the *same physical panel*
  that `xe` (`card0-eDP-1`) exclusively drives in MSHybrid mode --
  visible via `ls /sys/class/drm/`.
- Kernel function tracing (`ftrace`, function tracer, filtered to
  `intel_dp_aux_vesa_{enable,disable,set,get,setup}_backlight`) showed
  `intel_dp_aux_vesa_enable_backlight` -- the function that actually
  performs the DPCD mode-switch write -- genuinely never gets called at
  all at cold boot in `on-demand` mode. Not called-and-failing: simply
  skipped by `xe`'s own atomic-check decision of whether anything needs
  to change. A real suspend/resume calls `disable_backlight` then
  `enable_backlight` as part of the normal DRM atomic modeset flow, and
  that's what actually fixes it.
- Connector-level sysfs (`status`/`enabled`/`dpms` on both connectors)
  is identical in both the broken and fixed states -- ruling out a
  simple "wrong connector marked connected" theory. Whatever
  `nvidia_drm`'s parallel connector disturbs, it's something feeding
  `xe`'s atomic-check computation more subtly than that (plausibly
  EDID/mode data read during its own probe, though this wasn't
  confirmed at the kernel-source level).
- Controlling module load order via `modprobe.d` was the empirical fix,
  found by trial: forcing `nvidia_drm` to load first (with, and without,
  an explicit delay before it) did **not** fix it. Forcing `xe` to load
  first, with a real delay before `nvidia_drm` loads, fixed it
  completely -- confirmed reliably across 4 consecutive boots (2 full
  shutdown+power-on cycles, 2 warm reboots).

`xe-after-nvidia.conf`:
```
softdep nvidia_drm pre: xe
install xe /sbin/modprobe --ignore-install xe && sleep 5
```
Take the "5 seconds" as "generous, not exact" -- in practice `xe` loads
at its own normal early time regardless (via its own independent udev
trigger, not through this softdep chain), and what this rule actually
delays is `nvidia_drm.ko`'s own insertion, which lands several seconds
after `xe` starts, not exactly 5 seconds after. The practical effect --
`nvidia_drm`'s connector registration happening well after `xe` has
completed its own atomic modeset -- is what matters.

**This whole section is very likely describing a red herring, not the
real fix -- see below.** Kept as-is for historical accuracy about what
was actually tried, tested, and believed at the time.

## 2026-10-23: the real root cause, and why the above wasn't it

A kernel update eventually surfaced a much more direct test of the
load-order theory above: on the same panel, same board, with the
load-order fix's underlying mechanism directly instrumented via
`drm.debug`, a boot with a *provably correct, byte-for-byte identical*
sequence of DPCD writes (`BACKLIGHT_MODE_SET_REGISTER` at `0x721`,
brightness level at `0x722`, frequency registers at `0x724`/`0x728`,
every single AUX transaction returning success, no errors) still left
the panel completely unresponsive -- while the exact same sequence,
same values, same success codes, produced a working panel immediately
after a real suspend/resume. Identical software behavior, different
hardware outcome. That ruled out *everything* about `xe`'s own AUX
write path, including the load-order fix above (which only ever
affected *when* that path ran, not what it did), as the actual
mechanism -- something about the panel itself wasn't responding to
otherwise-correct writes.

The missing piece turned out to be sitting in this same project's own
*other*, already-shipped fix: `clevo-control-panel`'s dGPU-mode OLED
brightness feature (`oled_luminance.py`) had already independently
discovered and fixed the exact same panel's real backlight-enable
mechanism months earlier, using NVIDIA's own RM API instead of `xe`,
and documented it in its own source comments:

> DPCD `0x721` bit 7 (the "luminance control enable" flag) reads 0 by
> default. Setting that single bit... immediately unlocked real
> full-range brightness on this exact panel, live-verified.

`xe`'s own kernel code already has the exact mechanism to set that same
bit (`drm_edp_backlight_enable()`'s `DP_EDP_PANEL_LUMINANCE_CONTROL_ENABLE`),
gated behind a `bl->luminance_set` flag that `xe`'s own
`intel_dp_aux_supports_vesa_backlight()` decides -- and that function
requires *both* `DP_EDP_PANEL_LUMINANCE_CONTROL_CAPABLE` and
`DP_EDP_SMOOTH_BRIGHTNESS_CAPABLE` before even attempting it, while
`oled_luminance.py`'s own already-proven check only ever required the
first. `xe`'s own dmesg on this exact panel had, every single boot all
along, only ever logged the legacy-path message
(`"AUX Backlight Control Supported!"`), never the luminance-path one
(`"AUX Luminance Based Backlight Control Supported!"`) -- direct
confirmation the stricter combined check was failing here the entire
time. Relaxing it to match the simpler check (bug 3 above) is what
actually fixed real brightness control: confirmed live, the
luminance-path message now logs, `max_brightness` reports the real
luminance scale instead of the legacy one, and the slider works
correctly from a plain cold boot -- no suspend/resume, no load-order
tricks.

**The lesson, if you're debugging something similar:** before spending
hours re-deriving kernel-level behavior from scratch, check whether a
*different* project against the *same* hardware already solved an
adjacent version of the same problem -- `oled_luminance.py` had the
exact DPCD register and bit that mattered sitting in its own source
comments the entire time this investigation was happening.

## Superseded approach: boot-time suspend/resume fixup

Before the modprobe fix above was found, this repo used a different
workaround that also fixes the symptom (since a real suspend/resume
cycle independently works, as established above): a `oneshot` systemd
service, ordered `Before=display-manager.service`, that forces one real
suspend/resume cycle before the login screen ever appears -- invisible
in normal use, but at the cost of real boot-time delay (several seconds
to tens of seconds, depending on hardware-specific suspend/resume
overhead).

This is **no longer installed** by `rebuild-and-install.sh`, but the
files are kept in this repo (`oled-mshybrid-backlight-fixup.service`,
`.sh`, `oled-mshybrid-fixup-wake-arm.sh`) in case a future kernel or
NVIDIA driver update ever breaks the modprobe-ordering fix and this
fallback is needed again. If you do need it: install
`oled-mshybrid-backlight-fixup.sh` to `/usr/local/sbin/`,
`oled-mshybrid-backlight-fixup.service` to `/etc/systemd/system/`,
`oled-mshybrid-fixup-wake-arm.sh` to
`/usr/lib/systemd/system-sleep/`, then `systemctl daemon-reload &&
systemctl enable oled-mshybrid-backlight-fixup.service`.

Two real, independent bugs were found and fixed in this mechanism along
the way, both still worth knowing about if you reuse this pattern
elsewhere:

1. Its RTC wake alarm (`rtcwake`) needs to be armed via a *separate*
   `system-sleep` hook that actively waits for confirmation that
   whatever's slow in your own pre-suspend hooks has actually finished,
   not from the triggering script itself before calling
   `systemctl suspend` -- `man systemd-suspend.service` confirms
   `/usr/lib/systemd/system-sleep/` scripts all run in **parallel**, so
   naming a hook to sort after another one alphabetically does not make
   it run after that other script's work actually completes.
2. A signal used to nudge a long-running daemon (in this project's case,
   `SIGUSR1`) needs to be explicitly ignored from the very first line of
   that daemon's `main()`, before any slow startup work, or an early
   signal arriving during that window hits Python's/the language
   runtime's default disposition (commonly: terminate the process)
   instead of being handled gracefully once the daemon actually installs
   its real signal handler.

## License

GPL-2.0-or-later (see `LICENSE`) -- `oled-mshybrid-backlight.patch`
modifies GPL-2.0-only Linux kernel source, so this project is licensed
to match.
