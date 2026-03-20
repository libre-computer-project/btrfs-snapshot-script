#!/bin/bash
#
# Btrfs snapshot with tiered retention:
#   Days 1-7:    keep daily
#   Days 8-30:   keep weekly (one per 7-day window)
#   Days 31-365: keep monthly (one per calendar month)
#   Days 365+:   keep annually (one per calendar year)
#
# Safety: never deletes if fewer than 3 snapshots would remain.

set -u -o pipefail

cd "$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"

CONFIG_FILE=config.ini
LOG_FILE=snapshot.log

exec >> "$LOG_FILE" 2>&1

echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"

if [ ! -f "$CONFIG_FILE" ]; then
	echo "ERROR: $CONFIG_FILE does not exist."
	exit 1
fi

. "$CONFIG_FILE"

if [ -z "${BB_MOUNT_PATH:-}" ] || [ -z "${BB_SUBVOLUME:-}" ] || [ -z "${BB_SUFFIX:-}" ]; then
	echo "ERROR: BB_MOUNT_PATH, BB_SUBVOLUME, or BB_SUFFIX not set."
	exit 1
fi

if [ ! -d "$BB_MOUNT_PATH" ]; then
	echo "ERROR: $BB_MOUNT_PATH is not a directory."
	exit 1
fi

if ! sudo mount "$BB_MOUNT_PATH" 2>/dev/null; then
	# Already mounted or fstab issue -- check if already accessible
	if ! ls "$BB_MOUNT_PATH/$BB_SUBVOLUME" >/dev/null 2>&1; then
		echo "ERROR: $BB_MOUNT_PATH could not be mounted and $BB_SUBVOLUME not accessible."
		exit 1
	fi
fi

bb_mounted=1
cleanup() {
	if [ "$bb_mounted" = "1" ]; then
		sudo umount "$BB_MOUNT_PATH" 2>/dev/null
	fi
}
trap cleanup EXIT

bb_backup_path="$BB_MOUNT_PATH/backup"
if [ ! -d "$bb_backup_path" ]; then
	sudo mkdir -p "$bb_backup_path"
fi

# --- Create today's snapshot ---

bb_backup_name="$bb_backup_path/$BB_SUBVOLUME-$($BB_SUFFIX)"
if [ -e "$bb_backup_name" ]; then
	echo "Snapshot $bb_backup_name already exists, skipping creation."
else
	if ! sudo btrfs subvolume snapshot -r "$BB_MOUNT_PATH/$BB_SUBVOLUME" "$bb_backup_name"; then
		echo "ERROR: Failed to create snapshot $bb_backup_name"
		exit 1
	fi
	echo "Created: $bb_backup_name"
fi

# --- Tiered retention ---

MIN_KEEP=3
DAILY_DAYS=7
WEEKLY_DAYS=30
MONTHLY_DAYS=365

today_epoch=$(date +%s)

# Collect all snapshots for this subvolume, sorted oldest first
mapfile -t all_snapshots < <(
	find "$bb_backup_path" -maxdepth 1 -name "${BB_SUBVOLUME}-*" -type d | sort
)

total=${#all_snapshots[@]}
if [ "$total" -le "$MIN_KEEP" ]; then
	echo "Only $total snapshots, skipping retention (minimum $MIN_KEEP)."
	exit 0
fi

# Parse snapshot dates and classify
keep=()
delete=()

# Track what we've kept in each tier to enforce spacing
last_kept_weekly_epoch=0
last_kept_monthly=""    # YYYY-MM
last_kept_annual=""     # YYYY

for snap in "${all_snapshots[@]}"; do
	name=$(basename "$snap")
	# Extract date from name: @git-20250618 -> 20250618
	date_str="${name##*-}"

	if ! [[ "$date_str" =~ ^[0-9]{8}$ ]]; then
		keep+=("$snap")  # Don't delete things we can't parse
		continue
	fi

	snap_year="${date_str:0:4}"
	snap_month="${date_str:0:6}"
	snap_epoch=$(date -d "${date_str:0:4}-${date_str:4:2}-${date_str:6:2}" +%s 2>/dev/null)
	if [ -z "$snap_epoch" ]; then
		keep+=("$snap")
		continue
	fi

	age_days=$(( (today_epoch - snap_epoch) / 86400 ))

	if [ "$age_days" -le "$DAILY_DAYS" ]; then
		keep+=("$snap")
		echo "  KEEP  $name  ${age_days}d  [daily]"
	elif [ "$age_days" -le "$WEEKLY_DAYS" ]; then
		if [ $(( snap_epoch - last_kept_weekly_epoch )) -ge $((7 * 86400)) ]; then
			keep+=("$snap")
			last_kept_weekly_epoch=$snap_epoch
			echo "  KEEP  $name  ${age_days}d  [weekly]"
		else
			delete+=("$snap")
			echo "  DROP  $name  ${age_days}d  [weekly: <7d since last kept]"
		fi
	elif [ "$age_days" -le "$MONTHLY_DAYS" ]; then
		if [ "$snap_month" != "$last_kept_monthly" ]; then
			keep+=("$snap")
			last_kept_monthly="$snap_month"
			echo "  KEEP  $name  ${age_days}d  [monthly: first in ${date_str:0:4}-${date_str:4:2}]"
		else
			delete+=("$snap")
			echo "  DROP  $name  ${age_days}d  [monthly: dup ${date_str:0:4}-${date_str:4:2}]"
		fi
	else
		if [ "$snap_year" != "$last_kept_annual" ]; then
			keep+=("$snap")
			last_kept_annual="$snap_year"
			echo "  KEEP  $name  ${age_days}d  [annual: first in $snap_year]"
		else
			delete+=("$snap")
			echo "  DROP  $name  ${age_days}d  [annual: dup $snap_year]"
		fi
	fi
done

# Sanity check: never delete if it would leave fewer than MIN_KEEP
remaining=$(( total - ${#delete[@]} ))
if [ "$remaining" -lt "$MIN_KEEP" ]; then
	echo "SAFETY: Retention would leave $remaining snapshots (< $MIN_KEEP). Aborting cleanup."
	echo "  Total: $total, Would delete: ${#delete[@]}, Would keep: ${#keep[@]}"
	exit 0
fi

# Additional sanity: never delete more than 80% of snapshots in one run
max_delete=$(( total * 80 / 100 ))
if [ "${#delete[@]}" -gt "$max_delete" ]; then
	echo "SAFETY: Would delete ${#delete[@]}/$total snapshots (>80%). Aborting cleanup."
	exit 0
fi

if [ "${#delete[@]}" -eq 0 ]; then
	echo "Retention: nothing to prune. Keeping $total snapshots."
	exit 0
fi

echo "Retention: keeping ${#keep[@]}, pruning ${#delete[@]} of $total snapshots."

for snap in "${delete[@]}"; do
	if sudo btrfs subvolume delete "$snap"; then
		echo "  Deleted: $(basename "$snap")"
	else
		echo "  ERROR: Failed to delete $(basename "$snap")"
	fi
done

echo "Done. $(ls -d "$bb_backup_path/${BB_SUBVOLUME}-"* 2>/dev/null | wc -l) snapshots remain."
