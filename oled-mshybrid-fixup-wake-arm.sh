#!/bin/sh
# Arms a short RTC wake alarm right before the kernel actually commits to
# suspend -- but ONLY for oled-mshybrid-backlight-fixup.sh's deliberate
# boot-time suspend/resume cycle (see MARKER below), never for a normal
# later suspend (lid close, manual suspend), which must be free to stay
# asleep indefinitely.
#
# Why a separate hook instead of just arming the alarm from inside
# oled-mshybrid-backlight-fixup.sh before calling `systemctl suspend`:
# confirmed live (`man systemd-suspend.service`) that all
# /usr/lib/systemd/system-sleep/ scripts run in PARALLEL, with the actual
# suspend held off until every one of them finishes -- so simply naming
# this script to sort after btintel_pcie-workaround.sh would NOT make it
# run after that script's `modprobe -r btintel_pcie` actually completes.
# That module removal is the real, confirmed-live source of this board's
# variable pre-suspend delay (0.37s-16.97s measured across real boots) --
# so instead of guessing when it's done from a script that starts at the
# same time, this one polls for the one thing that actually, directly
# means it's done: btintel_pcie no longer showing up in `lsmod`. Only
# once that's true (or a generous timeout elapses, as a safety net
# against some unrelated hang) does it arm the wake alarm -- at that
# point the real variable-time work is already behind us, so a short,
# fixed window is safe again, without taxing every boot with the
# worst-case delay the way a single wider fixed alarm would.
MARKER=/run/oled-mshybrid-backlight-fixup.pending
WAKE_SECONDS=8
POLL_INTERVAL_SECONDS=0.2
MAX_POLL_ITERATIONS=100 # 100 * 0.2s = 20s ceiling, past the 16.97s worst case observed

case "$1" in
	pre)
		[ -e "$MARKER" ] || exit 0
		rm -f "$MARKER"

		i=0
		while lsmod | grep -q '^btintel_pcie ' && [ "$i" -lt "$MAX_POLL_ITERATIONS" ]; do
			sleep "$POLL_INTERVAL_SECONDS"
			i=$((i + 1))
		done

		rtcwake -m no -s "$WAKE_SECONDS" 2>/dev/null || true
		;;
esac
