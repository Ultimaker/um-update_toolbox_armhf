#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

# common directory variables
SYSCONFDIR="${SYSCONFDIR:-/etc}"

# system_update wide configuration settings with default values
SYSTEM_UPDATE_CONF_DIR="${SYSTEM_UPDATE_CONF_DIR:-${SYSCONFDIR}/jedi_system_update}"
PARTITION_TABLE_FILE="${PARTITION_TABLE_FILE:-jedi_emmc_sfdisk.table}"
TARGET_STORAGE_DEVICE="${TARGET_STORAGE_DEVICE:-}"
# end system_update wide configuration settings

BOOT_PARTITION_START="2048"

usage()
{
    echo "Usage: ${0} [OPTIONS]"
    echo "Prepare the target TARGET_STORAGE_DEVICE to a predefined disk layout."
    echo "  -d <TARGET_STORAGE_DEVICE>, the target storage device for the update (mandatory)"
    echo "  -h Print this help text and exit"
    echo "  -t <PARTITION_TABLE_FILE>, Partition table file (mandatory)"
    echo "Note: the PARTITION_TABLE_FILE and TARGET_STORAGE_DEVICE arguments can also be passed by"
    echo "adding them to the scripts runtime environment."
    echo "Warning: This script is destructive and will destroy your data."
}

is_integer()
{
    test "${1}" -eq "${1}" 2> /dev/null
}

is_comment()
{
    test -z "${1%%#*}"
}

verify_partition_file()
{
    cwd="$(pwd)"
    cd "${SYSTEM_UPDATE_CONF_DIR}" # change to update dir because path is hardcoded in the sha512 output.
    sha512sum -csw "${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}.sha512" || return 1
    cd "${cwd}"
}

# Returns 0 when resize is needed and 1 if not needed.
is_resize_needed()
{
    current_partition_table_file="$(mktemp)"
    sfdisk -d "${TARGET_STORAGE_DEVICE}" > "${current_partition_table_file}" || return 0
    resize_needed=false

    while IFS="${IFS}:=," read -r table_device _ table_start _ table_size _ _ _ table_name _; do
        if is_comment "${table_device}" || ! is_integer "${table_start}" || \
            ! is_integer "${table_size}"; then
            continue
        fi

        while IFS="${IFS}:=," read -r disk_device _ disk_start _ disk_size _; do
            if is_comment "${disk_device}" || ! is_integer "${disk_start}" || \
                ! is_integer "${disk_size}"; then
                continue
            fi

            if [ "${table_device}" != "${disk_device}" ]; then
                continue
            fi

            if [ "${table_start}" -ne "${disk_start}" ] || \
               [ "${table_size}" -ne "${disk_size}" ]; then
                resize_needed=true
                break 2
            fi
        done < "${current_partition_table_file}"
    done < "${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}"

    unlink "${current_partition_table_file}" || return 1

    if [ "${resize_needed}" = "true" ]; then
        return 0
    fi

    return 1
}

partition_sync()
{
    i=10
    while [ "${i}" -gt 0 ]; do
        if partprobe "${TARGET_STORAGE_DEVICE}"; then
            return
        fi

        echo "Partprobe failed, retrying."
        sleep 1

        i=$((i - 1))
    done

    echo "Partprobe failed, giving up."

    return 1
}

partitions_format()
{
    # Parse the output of sfdisk and temporally expand the Input Field Separator
    # with ':=,' and treat them as whitespaces, in other words, ignore them.
    sfdisk --quiet --dump "${TARGET_STORAGE_DEVICE}" | \
    while IFS="${IFS}:=," read -r disk_device _ disk_start _ disk_size _; do
        while IFS="${IFS}:=," read -r table_device _ table_start _ table_size _ _ _ table_name _; do
            if [ -z "${disk_start}" ] || [ -z "${table_start}" ] || \
               [ "${disk_start}" != "${table_start}" ]; then
                continue
            fi

            if [ ! -b "${disk_device}" ]; then
                echo "Error: '${disk_device}' is not a block device, cannot continue"
                exit 1
            fi

            if [ -z "${table_name}" ]; then
                echo "Error: partition label for ${disk_device} is empty"
                exit 1
            fi

            if grep -q "${disk_device}" /proc/mounts; then
                umount "${disk_device}"
            fi

            # Get the partition number from the device. e.g. /dev/loop0p1 -> p1
            # by grouping p with 1 or more digits and only printing the match,
            # with | being used as the command separator.
            # and then format the partition. If the partition was already valid,
            # just resize the existing one. If fsck or resize fails, reformat.
            partition="$(echo "${disk_device}" | sed -rn 's|.*(p[[:digit:]]+$)|\1|p')"
            if fstype="$(blkid -o value -s TYPE "${TARGET_STORAGE_DEVICE}${partition}")"; then
                echo "Attempting to resize partition ${TARGET_STORAGE_DEVICE}${partition}"
                case "${fstype}" in
                ext4)
                    fsck_cmd="fsck.ext4 -f -y"
                    fsck_ret_ok="1"
                    mkfs_cmd="mkfs.ext4 -F -L ${table_name} -O ^extents,^64bit"
                    resize_cmd="resize2fs"
                    ;;
                f2fs)
                    fsck_cmd="fsck.f2fs -f -p -y"
                    fsck_ret_ok="0"
                    mkfs_cmd="mkfs.f2fs -f -l ${table_name}"
                    resize_cmd="resize.f2fs"
                    ;;
                esac

                # In some cases of fsck, other values then 0 are acceptable,
                # as such we need to capture the return value or else set -u
                # will trigger eval as a failure and abort the script.
                fsck_status="$(eval "${fsck_cmd}" "${TARGET_STORAGE_DEVICE}${partition}" 1> /dev/null; echo "${?}")"
                if [ "${fsck_ret_ok}" -ge "${fsck_status}" ] && \
                   ! eval "${resize_cmd}" "${TARGET_STORAGE_DEVICE}${partition}"; then
                        echo "Resize failed, formatting instead."
                        eval "${mkfs_cmd}" "${TARGET_STORAGE_DEVICE}${partition}"
                fi
            else
                echo "Formatting ${TARGET_STORAGE_DEVICE}${partition}"
                if [ "${disk_start}" -eq "${BOOT_PARTITION_START}" ]; then
                    mkfs_cmd="mkfs.ext4 -F -L ${table_name} -O ^extents,^64bit"
                else
                    mkfs_cmd="mkfs.f2fs -f -l ${table_name}"
                fi

                eval "${mkfs_cmd}" "${TARGET_STORAGE_DEVICE}${partition}"
            fi
        done < "${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}"
    done
}

partition_resize()
{
    boot_partition_available=false

    # sfdisk returns size in blocks, * (1024 / 512) converts to sectors
    target_disk_end="$(($(sfdisk --quiet --show-size "${TARGET_STORAGE_DEVICE}" 2> /dev/null) * 2))"

    # Temporally expand the Input Field Separator with ':=,' and treat them
    # as whitespaces, in other words, ignore them.
    while IFS="${IFS}:=," read -r device _ start _ size _; do
        if [ -z "${device}" ] || is_comment "${device}" || \
           ! is_integer "${start}" || ! is_integer "${size}"; then
            continue
        fi

        if [ "${start}" -eq "${BOOT_PARTITION_START}" ]; then
            boot_partition_available=true
        fi

        partition_end="$((start + size))"
        if [ "${partition_end}" -gt "${target_disk_end}" ]; then
            echo "Partition '${device}' is beyond the size of the disk (${partition_end} > ${target_disk_end}), cannot continue."
            exit 1
        fi
    done < "${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}"

    if ! "${boot_partition_available}"; then
        echo "Error, no boot partition available, cannot continue."
        exit 1
    fi

    sfdisk --quiet "${TARGET_STORAGE_DEVICE}" < "${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}"
}

backup_data()
{
    temp_mount_dir="$(mktemp -d)"

    sfdisk --quiet --dump "${TARGET_STORAGE_DEVICE}" | \
    while IFS="${IFS}:=," read -r disk_device _ disk_start _ disk_size _; do
        if [ -b "${disk_device}" ]; then

            if grep -q "${disk_device}" "/proc/mounts"; then
                umount "${disk_device}"
            fi

            backup_file="/tmp/backup${disk_device}.tar.gz"

            if mount "${disk_device}" "${temp_mount_dir}"; then
                mkdir -p "$(dirname "${backup_file}")"

                echo "Backing up ${disk_device} as ${backup_file}"
                if ! tar -czf "${backup_file}" -C "${temp_mount_dir}" . > /dev/null; then
                    echo "Backup failed, removing backup. Partition will be empty."
                    rm "${backup_file}"
                fi

                umount "${disk_device}"
            fi
        fi
    done

    rmdir "${temp_mount_dir}"
}

restore_data()
{
    temp_mount_dir="$(mktemp -d)"

    sfdisk --quiet --dump "${TARGET_STORAGE_DEVICE}" | \
    while IFS="${IFS}:=," read -r disk_device _ disk_start _ disk_size _; do
        if [ -b "${disk_device}" ]; then

            if grep -q "${disk_device}" "/proc/mounts"; then
                umount "${disk_device}"
            fi

            backup_file="/tmp/backup${disk_device}.tar.gz"
            if [ -f "${backup_file}" ]; then
                mount "${disk_device}" "${temp_mount_dir}"

                # We only restore if the parition looks empty. There can be a lost+found on an empty partition, so ignore that.
                if [ "$(find "${temp_mount_dir}" ! -name . -prune -print | grep -c /)" -lt 2 ]; then
                    echo "Restoring backup ${backup_file} to ${disk_device}"
                    tar -xzf "${backup_file}" -C "${temp_mount_dir}" . > /dev/null || \
                        echo "Restoring backup '${backup_file}' to '${disk_device}' failed."
                fi

                umount "${disk_device}"
            fi
        fi
    done

    rmdir "${temp_mount_dir}"
}

while getopts ":d:ht:" options; do
    case "${options}" in
    d)
        TARGET_STORAGE_DEVICE="${OPTARG}"
        ;;
    h)
        usage
        exit 0
        ;;
    t)
        PARTITION_TABLE_FILE="${OPTARG}"
        ;;
    :)
        echo "Option -${OPTARG} requires an argument."
        exit 1
        ;;
    ?)
        echo "Invalid option: -${OPTARG}"
        exit 1
        ;;
    esac
done
shift "$((OPTIND - 1))"

if [ -z "${PARTITION_TABLE_FILE}" ]; then
    echo "Missing mandatory option <PARTITION_TABLE_FILE>."
    usage
    exit 1
fi

if [ -z "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Missing mandatory argument <TARGET_STORAGE_DEVICE>."
    usage
    exit 1
fi

if [ ! -f "${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}" ]; then
    echo "Partition table file '${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}' does not exist, cannot continue."
    exit 1
fi

if [ ! -f "${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}.sha512" ]; then
    echo "Partition table checksum file '${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}' does not exist, cannot continue."
    exit 1
fi

if [ ! -b "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Error, block device '${TARGET_STORAGE_DEVICE}' does not exist."
    exit 1
fi

if ! verify_partition_file; then
    echo "Error: partition file crc error, cannot continue."
    exit 1
fi

if ! is_resize_needed; then
    echo "Partition resize not required."
    exit 0
fi

backup_data
partition_resize
partition_sync
partitions_format
restore_data

exit 0
