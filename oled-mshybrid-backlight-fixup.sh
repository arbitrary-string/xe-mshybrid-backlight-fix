#!/bin/sh
# Works around a real bug in the patched xe.ko backlight fix (see
# check_if_vesa_backlight_possible.patch / setup-time-enable.patch in
# this same directory): at boot, DRM's atomic state readout sees the
# panel already lit by firmware and skips the encoder "enable" callback
# that would normally switch the panel's TCON into DPCD-controlled
# backlight mode -- so real brightness control silently does nothing
# until that callback runs for real, which only happens on a full
# suspend/resume. Confirmed live 2026-09-14 that this is specifically
# tied to `prime-select on-demand` (NVIDIA driver loaded and
# initializing alongside xe during boot) -- multiple consecutive cold
# boots in `prime-select intel` (NVIDIA fully unloaded) never hit this
# bug at all, brightness control just worked. See the prime-select check
# below.
#
# This runs a real (not skippable) suspend/resume cycle once, automatically,
# before the display manager starts -- so it's invisible: by the time GDM
# shows the login screen, the fix has already taken effect.
#
# Deliberately NOT `rtcwake -m mem` by itself -- confirmed live that bypasses
# systemd's sleep hooks entirely, and this board's NVIDIA driver then fails
# to suspend at all (PM: pci_pm_suspend returns -5), aborting the cycle
# before the display ever powers down. Setting the wake alarm with
# `rtcwake -m no` and then suspending via `systemctl suspend` instead goes
# through the actual systemd-sleep hooks this laptop already needs for
# suspend/resume to work at all (see project_suspend_investigation.md).
set -eu

# Only applicable when Intel is actually driving the panel (MSHybrid mode)
# -- this class doesn't exist at all in dGPU mode, where this bug doesn't
# apply and this whole cycle would just be a pointless boot delay.
if [ ! -e /sys/class/backlight/intel_backlight ]; then
    exit 0
fi

# Also skip when prime-select is "intel" -- confirmed live the bug this
# whole cycle exists for doesn't reproduce there at all, so running it
# anyway would just be a pointless boot delay, same as the dGPU-mode
# case above. Only actually skip on an explicit "intel" result; fall
# through (run the fixup) for "on-demand", "nvidia", or if prime-select
# is missing/unqueryable -- those are exactly the cases the bug is
# confirmed to still happen in, or haven't been ruled out for.
if command -v prime-select >/dev/null 2>&1; then
    PRIME_MODE="$(prime-select query 2>/dev/null || true)"
    if [ "$PRIME_MODE" = "intel" ]; then
        exit 0
    fi
fi

# The RTC wake alarm is NOT armed here anymore -- see
# /usr/lib/systemd/system-sleep/oled-mshybrid-fixup-wake-arm.sh for why.
# In short: arming it here, before calling systemctl suspend, races
# against this board's systemd-sleep hooks (ec-modern-standby-fix.sh,
# btintel_pcie-workaround.sh -- notably a real, variable-duration
# `modprobe -r btintel_pcie` module unbind) that run in between --
# confirmed live across real boots to take anywhere from 0.37s to
# 16.97s. A fixed alarm set from here either misses (fires before the
# machine is actually asleep, leaving it stuck until a physical keypress
# -- confirmed live 2026-09-14) or, if widened enough to never miss,
# blindly adds that same worst-case delay to every single boot instead
# of just the rare slow one. Neither is right. Instead this script only
# leaves a marker for that hook to find, so the alarm can be armed at
# the actual right moment -- immediately after the slow step is
# confirmed done, not a fixed guess from before it even started.
MARKER=/run/oled-mshybrid-backlight-fixup.pending

touch "$MARKER"
# Don't let `set -e` skip the marker cleanup below if suspend itself
# somehow fails (inhibited, etc.) -- a leftover marker would otherwise
# make some later, unrelated real suspend (lid close, manual suspend)
# incorrectly get a surprise short wake-up from the hook above.
systemctl suspend || true
rm -f "$MARKER"
