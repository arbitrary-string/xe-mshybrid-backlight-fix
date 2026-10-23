#!/bin/sh
# Waits for confirmation that xe's atomic modeset has actually called
# intel_dp_aux_vesa_enable_backlight -- the real completion signal this
# whole fix cares about -- instead of guessing a fixed sleep duration.
#
# Why not a cheap sysfs poll (like the old btintel_pcie lsmod check used
# elsewhere in this project)? Confirmed live during the original
# investigation: the obvious candidate signals (intel_backlight existing,
# card0-eDP-1's own status/enabled sysfs attributes) read identically
# whether the bug is present or not -- the backlight device and its
# correct DPCD scale show up from setup_backlight() either way; what's
# actually missing in the broken case is specifically the enable_backlight
# call, which has no sysfs footprint at all. Kernel function tracing is
# the only method that's ever reliably told broken from fixed in this
# investigation.
#
# Why this replaced a fixed `sleep 5`: confirmed live 2026-10-2x that a
# newer NVIDIA driver (615.71.09, up from 595.99.02) made nvidia_drm
# initialize fast enough that the old 5-second margin stopped being
# enough, reintroducing the exact cold-boot bug this whole file exists to
# prevent. A bigger fixed number would only be a bigger guess -- and,
# worse, would tax *every* boot by that full amount unconditionally
# (the same category of mistake already made once with this project's
# RTC-wake-alarm timing) rather than actually fixing the fragility.
# Waiting for the real event instead means fast boots stay fast and slow
# ones still work correctly, regardless of how fast any future driver
# version gets.
#
# Known residual limitation, not fully closed: there's a narrow
# theoretical race where xe's own probe (via its own independent udev
# trigger, not this script) could finish calling enable_backlight in the
# brief window before this script arms tracing below. Not observed in
# practice as of this writing. If the bug ever resurfaces despite this
# fix, that race is the first thing to revisit -- e.g. by arming tracing
# even earlier, via a persistent kernel command-line ftrace filter set at
# boot, rather than from this modprobe install hook.
#
# Fails open throughout: any missing prerequisite (no tracefs, function
# not present in this kernel's xe build) just exits 0 immediately rather
# than risking blocking boot.
set -eu

TRACE=/sys/kernel/debug/tracing
FUNC=intel_dp_aux_vesa_enable_backlight
POLL_INTERVAL_SECONDS=0.2
MAX_POLL_ITERATIONS=100 # 100 * 0.2s = 20s ceiling

[ -d "$TRACE" ] || exit 0
grep -q "^${FUNC} " "$TRACE/available_filter_functions" 2>/dev/null || exit 0

echo nop > "$TRACE/current_tracer" 2>/dev/null || exit 0
: > "$TRACE/set_ftrace_filter" 2>/dev/null || exit 0
echo "$FUNC" >> "$TRACE/set_ftrace_filter" 2>/dev/null || exit 0
echo function > "$TRACE/current_tracer" 2>/dev/null || exit 0
: > "$TRACE/trace" 2>/dev/null || true

i=0
while [ "$i" -lt "$MAX_POLL_ITERATIONS" ]; do
	if grep -q "$FUNC" "$TRACE/trace" 2>/dev/null; then
		break
	fi
	sleep "$POLL_INTERVAL_SECONDS"
	i=$((i + 1))
done

# Don't leave function tracing permanently armed system-wide just because
# this ran once during boot.
echo nop > "$TRACE/current_tracer" 2>/dev/null || true
: > "$TRACE/set_ftrace_filter" 2>/dev/null || true
