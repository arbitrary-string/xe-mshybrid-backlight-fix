#!/bin/bash
# Rebuilds xe.ko with the MSHybrid OLED backlight patch (see
# oled-mshybrid-backlight.patch in this same directory) for a given
# kernel, and installs it in place of the stock module.
#
# Run this once after every kernel update that replaces the currently
# patched kernel -- there is no DKMS automation for this. xe.ko turned
# out not to fit DKMS's usual model at all: building it needs the FULL
# matching kernel source (not just the /usr/src/linux-headers-*
# package DKMS normally builds against), a fully-built vmlinux, and the
# entire drivers/gpu/drm/ subtree built alongside it for cross-module
# symbol resolution -- confirmed the hard way, this doesn't work as a
# small, fast, standard out-of-tree module build. A full DKMS package
# replicating all of that would be a multi-minute, multi-hundred-MB
# rebuild on every kernel update, using internet access, with a real
# chance of the patch someday failing to apply cleanly against
# upstream/Ubuntu source changes -- explicitly decided against that in
# favor of this manual, transparent, run-when-needed script instead.
#
# Usage: sudo ./rebuild-and-install.sh [kernel-version]
#   kernel-version defaults to `uname -r` if not given -- pass one
#   explicitly to rebuild for a newly-installed kernel you haven't
#   booted into yet.
#
# Safe to re-run for the same kernel version (idempotent); always backs
# up whatever module is currently installed before overwriting it, the
# first time it touches a given kernel version.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this as root (sudo ./rebuild-and-install.sh ...)" >&2
    exit 1
fi

KVER="${1:-$(uname -r)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build-$KVER"
PATCH_FILE="$SCRIPT_DIR/oled-mshybrid-backlight.patch"
BACKUP_DIR="$SCRIPT_DIR/stock-module-backups"

echo "=== Building patched xe.ko for kernel $KVER ==="

if [ ! -f "/boot/config-$KVER" ]; then
    echo "ERROR: /boot/config-$KVER not found -- is $KVER actually installed?" >&2
    exit 1
fi
if [ ! -d "/usr/src/linux-headers-$KVER" ]; then
    echo "ERROR: /usr/src/linux-headers-$KVER not found -- install linux-headers-$KVER first." >&2
    exit 1
fi

if ! grep -rq "^Types:.*deb-src" /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2>/dev/null; then
    echo "ERROR: deb-src not enabled in apt sources -- this needs the actual kernel" >&2
    echo "source, not just headers. Add 'deb-src' to the Types line in" >&2
    echo "/etc/apt/sources.list.d/ubuntu.sources and run 'apt-get update' first." >&2
    exit 1
fi

# --- Figure out the matching apt source package version ---
SRC_PKG_VER="$(apt-cache showsrc "linux-image-unsigned-$KVER" 2>/dev/null | awk -F': ' '/^Version:/{print $2; exit}')"
if [ -z "$SRC_PKG_VER" ]; then
    echo "ERROR: could not find a source package version for linux-image-unsigned-$KVER" >&2
    echo "via apt-cache showsrc. Is this kernel from a currently-configured repo?" >&2
    exit 1
fi
echo "Source package: linux=$SRC_PKG_VER"

# --- Fetch source (skip if already fetched for this kernel) ---
mkdir -p "$BUILD_DIR"
SRC_DIR=""
for d in "$BUILD_DIR"/linux-*/; do
    [ -d "$d" ] && SRC_DIR="${d%/}"
done
if [ -z "$SRC_DIR" ]; then
    echo "Fetching kernel source (this downloads ~250MB)..."
    ( cd "$BUILD_DIR" && apt-get source "linux=$SRC_PKG_VER" )
    for d in "$BUILD_DIR"/linux-*/; do
        [ -d "$d" ] && SRC_DIR="${d%/}"
    done
fi
if [ -z "$SRC_DIR" ]; then
    echo "ERROR: apt-get source didn't produce a linux-* source directory in $BUILD_DIR" >&2
    exit 1
fi
echo "Source tree: $SRC_DIR"
cd "$SRC_DIR"

# --- Apply our patch (skip if already applied -- idempotent re-run) ---
if grep -q "Firmware leaves this panel's TCON in legacy PWM" \
    drivers/gpu/drm/i915/display/intel_dp_aux_backlight.c 2>/dev/null; then
    echo "Patch already applied in this build tree, skipping."
else
    echo "Applying $PATCH_FILE ..."
    if ! patch -p1 < "$PATCH_FILE"; then
        echo "ERROR: patch failed to apply. Upstream/Ubuntu source has likely changed" >&2
        echo "around this code since the patch was written -- it needs to be" >&2
        echo "hand-updated against the new source before this will work. See" >&2
        echo "$SRC_DIR/drivers/gpu/drm/i915/display/intel_dp_aux_backlight.c" >&2
        exit 1
    fi
fi

# --- Configure to exactly match the running kernel ---
cp "/boot/config-$KVER" .config
make olddefconfig
cp "/usr/src/linux-headers-$KVER/Module.symvers" .
make -j"$(nproc)" modules_prepare

# Force the built module's version string (vermagic) to match $KVER
# exactly -- the raw upstream Makefile's own VERSION/PATCHLEVEL/SUBLEVEL
# numbers don't match Ubuntu's actual release numbering at all (confirmed:
# this tree's own Makefile says something like 7.0.14, not 7.0.0-31-generic),
# and a mismatched vermagic makes the kernel flatly refuse to load the
# module.
IFS='.' read -r V P REST <<< "$KVER"
SUB="${REST%%-*}"
EXTRA="-${REST#*-}"
sed -i \
    -e "s/^VERSION = .*/VERSION = $V/" \
    -e "s/^PATCHLEVEL = .*/PATCHLEVEL = $P/" \
    -e "s/^SUBLEVEL = .*/SUBLEVEL = $SUB/" \
    -e "s/^EXTRAVERSION.*/EXTRAVERSION = $EXTRA/" \
    Makefile
rm -f include/generated/utsrelease.h
make -j"$(nproc)" prepare
ACTUAL_RELEASE="$(make -s kernelrelease)"
if [ "$ACTUAL_RELEASE" != "$KVER" ]; then
    echo "ERROR: computed kernelrelease '$ACTUAL_RELEASE' doesn't match target '$KVER'" >&2
    echo "-- the Makefile version-override logic above needs adjusting for this" >&2
    echo "kernel's version string format." >&2
    exit 1
fi

# --- Build (vmlinux first, needed for module symbol resolution; then
# the whole drivers/gpu/drm/ subtree, since xe.ko links against several
# other DRM helper modules -- both confirmed necessary the hard way) ---
echo "Building vmlinux (needed for module symbol resolution, not booted)..."
make -j"$(nproc)" vmlinux
echo "Building drivers/gpu/drm/ (xe.ko plus everything it links against)..."
make -j"$(nproc)" M=drivers/gpu/drm modules

XE_KO="drivers/gpu/drm/xe/xe.ko"
if [ ! -f "$XE_KO" ]; then
    echo "ERROR: build finished but $XE_KO doesn't exist" >&2
    exit 1
fi

BUILT_VERMAGIC="$(modinfo -F vermagic "$XE_KO" | awk '{print $1}')"
if [ "$BUILT_VERMAGIC" != "$KVER" ]; then
    echo "ERROR: built module vermagic '$BUILT_VERMAGIC' != '$KVER'" >&2
    exit 1
fi

# --- Strip debug symbols and compress to match the installed format ---
STAGE_DIR="$BUILD_DIR/staged"
mkdir -p "$STAGE_DIR"
cp "$XE_KO" "$STAGE_DIR/xe.ko"
strip --strip-debug "$STAGE_DIR/xe.ko"
zstd -19 -f "$STAGE_DIR/xe.ko" -o "$STAGE_DIR/xe.ko.zst"

# --- Back up whatever's currently installed for this kernel, once ---
INSTALLED="/lib/modules/$KVER/kernel/drivers/gpu/drm/xe/xe.ko.zst"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/xe.ko.zst.$KVER.stock-backup"
if [ -f "$INSTALLED" ] && [ ! -f "$BACKUP_FILE" ]; then
    echo "Backing up current module to $BACKUP_FILE"
    cp "$INSTALLED" "$BACKUP_FILE"
fi

# --- Install ---
echo "Installing patched module to $INSTALLED"
cp "$STAGE_DIR/xe.ko.zst" "$INSTALLED"
depmod -a "$KVER"
update-initramfs -u -k "$KVER"

# --- Real fix (found 2026-09-14): xe's cold-boot atomic-check skips
# enabling real DPCD-controlled backlight mode when NVIDIA's nvidia_drm
# module registers its own competing eDP-2 connector for this same
# physical panel too close in time to xe's own probe -- confirmed live,
# repeatedly (2 full shutdowns + 2 warm reboots), that giving xe a
# genuine head start before nvidia_drm loads fixes this completely, no
# suspend/resume needed at all. See xe-after-nvidia.conf's own comments
# for the full investigation (three ordering/delay attempts -- only
# "xe first" actually worked). Supersedes the boot-time suspend/resume
# fixup below entirely.
if [ -f "$SCRIPT_DIR/xe-after-nvidia.conf" ]; then
    install -m 0644 "$SCRIPT_DIR/xe-after-nvidia.conf" \
        /etc/modprobe.d/xe-after-nvidia.conf
    depmod -a "$KVER"
fi

# --- Obsolete as of 2026-09-14, superseded by xe-after-nvidia.conf
# above -- actively disable/clean up rather than leave silently enabled
# if an earlier install left it that way. Files kept in this repo for
# reference (and as a fallback mechanism if a future kernel/driver
# update ever breaks the modprobe-ordering fix), but no longer installed
# fresh on any (re)build. ---
systemctl disable --now oled-mshybrid-backlight-fixup.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/oled-mshybrid-backlight-fixup.service \
    /usr/local/sbin/oled-mshybrid-backlight-fixup.sh \
    /usr/lib/systemd/system-sleep/oled-mshybrid-fixup-wake-arm.sh
systemctl daemon-reload

echo
echo "=== Done. Reboot into $KVER and verify brightness control works. ==="
