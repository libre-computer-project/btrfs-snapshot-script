#!/bin/bash

cd $(readlink -f $(dirname ${BASH_SOURCE[0]}))

CONFIG_FILE=config.ini

exec >> snapshot.log 2>&1

if [ ! -f "$CONFIG_FILE" ]; then
	echo "$CONFIG_FILE does not exist." >&2
	exit 1
fi

. $CONFIG_FILE

if [ -z "$BB_MOUNT_PATH" ]; then
	echo "BB_MOUNT_PATH is not set." >&2
	exit 1
fi

if [ ! -d "$BB_MOUNT_PATH" ]; then
	echo "$BB_MOUNT_PATH is not a directory." >&2
	exit 1
fi

if ! sudo mount "$BB_MOUNT_PATH"; then
	echo "$BB_MOUNT_PATH could not be mounted." >&2
	exit 1
fi

trap "sudo umount $BB_MOUNT_PATH" EXIT

bb_backup_path="$BB_MOUNT_PATH/backup"
if [ ! -d "$bb_backup_path" ]; then
	sudo mkdir "$bb_backup_path"
fi

bb_backup_name="$bb_backup_path/$BB_SUBVOLUME-$($BB_SUFFIX)"
if [ -e "$bb_backup_name" ]; then
	echo "$bb_backup_name already exists." >&2
	exit 1
fi

bb_cmd="sudo btrfs subvolume snapshot -r $BB_MOUNT_PATH/$BB_SUBVOLUME $bb_backup_name"
if ! $bb_cmd; then
	echo "FAILED: $bb_cmd" >&2
	exit 1
fi
