#!/bin/bash
#
# Validate that the snapshot script prerequisites are met.

set -u

cd "$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"

CONFIG_FILE=config.ini
errors=0

echo "Checking snapshot prerequisites..."

# Config
if [ ! -f "$CONFIG_FILE" ]; then
	echo "FAIL: $CONFIG_FILE not found. Copy config.ini.example and edit."
	exit 1
fi
. "$CONFIG_FILE"
echo "  OK: $CONFIG_FILE loaded"

# Mount path
if [ ! -d "$BB_MOUNT_PATH" ]; then
	echo "FAIL: BB_MOUNT_PATH=$BB_MOUNT_PATH does not exist."
	echo "  Create it: mkdir -p $BB_MOUNT_PATH"
	errors=$((errors + 1))
else
	echo "  OK: BB_MOUNT_PATH=$BB_MOUNT_PATH exists"
fi

# Absolute path check
case "$BB_MOUNT_PATH" in
	/*) echo "  OK: BB_MOUNT_PATH is absolute" ;;
	*)  echo "WARN: BB_MOUNT_PATH is relative -- use an absolute path"
	    errors=$((errors + 1)) ;;
esac

# fstab entry
if grep -q "$BB_MOUNT_PATH" /etc/fstab 2>/dev/null; then
	if grep "^#" /etc/fstab | grep -q "$BB_MOUNT_PATH"; then
		echo "FAIL: fstab entry for $BB_MOUNT_PATH is commented out."
		errors=$((errors + 1))
	else
		echo "  OK: fstab entry for $BB_MOUNT_PATH exists"
	fi
else
	echo "FAIL: No fstab entry for $BB_MOUNT_PATH."
	echo "  Add to /etc/fstab:"
	echo "  UUID=<btrfs-uuid> $BB_MOUNT_PATH btrfs noatime,subvolid=5,noauto 0 2"
	errors=$((errors + 1))
fi

# Test mount
if sudo mount "$BB_MOUNT_PATH" 2>/dev/null; then
	if [ -d "$BB_MOUNT_PATH/$BB_SUBVOLUME" ]; then
		echo "  OK: Subvolume $BB_SUBVOLUME accessible at $BB_MOUNT_PATH/$BB_SUBVOLUME"
	else
		echo "FAIL: Subvolume $BB_SUBVOLUME not found in $BB_MOUNT_PATH"
		echo "  Available subvolumes:"
		ls -d "$BB_MOUNT_PATH"/@* 2>/dev/null | sed 's|.*/|    |'
		errors=$((errors + 1))
	fi
	sudo umount "$BB_MOUNT_PATH"
else
	echo "FAIL: Could not mount $BB_MOUNT_PATH"
	errors=$((errors + 1))
fi

# btrfs tools
if ! command -v btrfs >/dev/null 2>&1; then
	echo "FAIL: btrfs command not found. Install btrfs-progs."
	errors=$((errors + 1))
else
	echo "  OK: btrfs $(btrfs --version 2>/dev/null | head -1)"
fi

# sudo
if ! sudo -n true 2>/dev/null; then
	echo "WARN: sudo requires a password. Cron jobs will fail."
	echo "  Add to sudoers: $USER ALL=(ALL) NOPASSWD: /usr/bin/btrfs, /usr/bin/mount, /usr/bin/umount"
	errors=$((errors + 1))
else
	echo "  OK: sudo works without password"
fi

# cron
if crontab -l 2>/dev/null | grep -q "snapshot.sh"; then
	echo "  OK: cron entry exists"
else
	echo "WARN: No cron entry for snapshot.sh"
	echo "  Add: 0 0 * * * $(readlink -f snapshot.sh)"
	errors=$((errors + 1))
fi

echo ""
if [ "$errors" -eq 0 ]; then
	echo "All checks passed."
else
	echo "$errors issue(s) found."
fi
