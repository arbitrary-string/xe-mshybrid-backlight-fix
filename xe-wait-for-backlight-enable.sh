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
# Real bug found and fixed 2026-10-23, the first time this script
# actually hit a cold boot: it did nothing at all. journalctl showed
# `sys-kernel-tracing.mount`/`sys-kernel-debug.mount` (systemd's own
# managed mounts for these) didn't actually mount until *several seconds
# after* nvidia_drm had already initialized -- this script's own
# `[ -d "$TRACE" ] || exit 0` safety check saw nothing there yet at the
# point this modprobe install hook actually runs (which happens via
# early udev coldplug processing, well before systemd gets to mounting
# these later in boot) and silently exited immediately, turning the
# whole fix into a no-op. Not the theoretical module-loading race this
# comment used to warn about -- a much more mundane "the filesystem we
# need isn't mounted yet" problem. Fixed by mounting tracefs ourselves
# below instead of depending on systemd's own timing for it; harmless
# no-op if it's already mounted by the time this runs.
#
# Fails open throughout: any missing prerequisite (tracefs genuinely
# unavailable, function not present in this kernel's xe build) just
# exits 0 immediately rather than risking blocking boot.
set -u

TRACE=/sys/kernel/tracing
FUNC=intel_dp_aux_vesa_enable_backlight
POLL_INTERVAL_SECONDS=0.2
MAX_POLL_ITERATIONS=100 # 100 * 0.2s = 20s ceiling
LOG=/var/log/xe-wait-for-backlight-enable.log

# Temporary diagnostic logging (2026-10-23): this fix has now silently
# failed at real cold boot twice in a row for two different confirmed
# reasons, each only found after the fact via indirect evidence (dmesg
# timestamps, live re-simulation that may not perfectly match the real
# early-boot environment/sandboxing). Logging exactly what happens at
# each step, every real boot, until this is confirmed solid across
# several boots -- direct evidence beats another round of guessing.
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%3N')" "$*" >> "$LOG" 2>/dev/null || true; }

log "=== start, PID $$ ==="

if mountpoint -q "$TRACE" 2>/dev/null; then
	log "tracefs already mounted"
else
	if mount -t tracefs tracefs "$TRACE" 2>>"$LOG"; then
		log "self-mounted tracefs"
	else
		log "FAILED to self-mount tracefs, exit code $?"
	fi
fi

if [ ! -d "$TRACE" ]; then
	log "EXIT: $TRACE still not a directory after mount attempt"
	exit 0
fi

if ! grep -q "^${FUNC} " "$TRACE/available_filter_functions" 2>>"$LOG"; then
	log "EXIT: $FUNC not found in available_filter_functions"
	exit 0
fi
log "confirmed $FUNC is traceable"

if ! echo nop > "$TRACE/current_tracer" 2>>"$LOG"; then
	log "EXIT: failed to reset current_tracer to nop"
	exit 0
fi
: > "$TRACE/set_ftrace_filter" 2>>"$LOG"
if ! echo "$FUNC" >> "$TRACE/set_ftrace_filter" 2>>"$LOG"; then
	log "EXIT: failed to write filter"
	exit 0
fi
if ! echo function > "$TRACE/current_tracer" 2>>"$LOG"; then
	log "EXIT: failed to enable function tracer"
	exit 0
fi
: > "$TRACE/trace" 2>>"$LOG"
log "armed: current_tracer=$(cat "$TRACE/current_tracer" 2>/dev/null), filter=$(tr '\n' ',' < "$TRACE/set_ftrace_filter" 2>/dev/null)"

i=0
found=0
while [ "$i" -lt "$MAX_POLL_ITERATIONS" ]; do
	if grep -q "$FUNC" "$TRACE/trace" 2>/dev/null; then
		found=1
		break
	fi
	sleep "$POLL_INTERVAL_SECONDS"
	i=$((i + 1))
done

if [ "$found" -eq 1 ]; then
	log "DETECTED after $i iterations (~$(awk "BEGIN{print $i*$POLL_INTERVAL_SECONDS}")s): $(grep "$FUNC" "$TRACE/trace" 2>/dev/null | head -3)"
else
	log "TIMED OUT after $MAX_POLL_ITERATIONS iterations, never saw $FUNC. Trace buffer tail: $(tail -5 "$TRACE/trace" 2>/dev/null)"
fi

# Don't leave function tracing permanently armed system-wide just because
# this ran once during boot.
echo nop > "$TRACE/current_tracer" 2>/dev/null || true
: > "$TRACE/set_ftrace_filter" 2>/dev/null || true
log "=== end ==="
