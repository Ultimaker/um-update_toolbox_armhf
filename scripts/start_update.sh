#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

# Common directory variables
PREFIX="${PREFIX:-/usr/local}"
EXEC_PREFIX="${PREFIX}"
LIBEXECDIR="${EXEC_PREFIX}/libexec"
SYSCONFDIR="${SYSCONFDIR:-/etc}"

# Script mandatory arguments
# The mount point of the update toolbox, used as chroot root.
TOOLBOX_MOUNT=""
# The mount point where the update archive and this toolbox where found
UPDATE_MOUNT=""
# The target update storage device
TARGET_STORAGE_DEVICE=""

# Toolbox execution environment arguments
# The directory in the chroot environment containing the system update and configuration files.
SYSTEM_UPDATE_CONF_DIR="${SYSTEM_UPDATE_CONF_DIR:-${SYSCONFDIR}/jedi_system_update/}"
SYSTEM_UPDATE_SCRIPT_DIR="${SYSTEM_UPDATE_SCRIPT_DIR:-${LIBEXECDIR}/jedi_system_update.d/}"
# The partition table file to use, default jedi_emmc_sfdisk.table, should exist in the system update dir.
PARTITION_TABLE_FILE="${PARTITION_TABLE_FILE:-jedi_emmc_sfdisk.table}"
# The exclude file list when updating the firmware files, should exist in the system update dir.
UPDATE_EXCLUDE_LIST_FILE="${UPDATE_EXCLUDE_LIST_FILE:-jedi_update_exclude_list.txt}"
# The directory in the chroot environment containing the source update files.
UPDATE_ROOTFS_SOURCE="/mnt/update_rootfs_source"

update_rootfs_archive=""


usage()
{
    echo "Usage: ${0} [OPTIONS] <TOOLBOX_MOUNT> <UPDATE_MOUNT> <TARGET_STORAGE_DEVICE>"
    echo "This is the update entry point script, it is responsible for setting up the"
    echo "environment in which the update toolbox can be used to configure and update"
    echo "the firmware."
    echo "  -h Print this help text and exit"
}

cleanup()
{
    if [ -d "${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}" ]; then
        echo "Cleaning up, unmount: '${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}' files."
        umount "${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}"
    fi

    if grep -q "${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}" "/proc/mounts"; then
        echo "Cleaning up, unmount: '${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}'."
        umount "${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}"
    fi

    if grep -q "${TOOLBOX_MOUNT}/proc" "/proc/mounts"; then
        echo "Cleaning up, unmount: '${TOOLBOX_MOUNT}/proc'."
        umount "${TOOLBOX_MOUNT}/proc"
    fi

    if grep -q "${TOOLBOX_MOUNT}/tmp" "/proc/mounts"; then
        echo "Cleaning up, unmount: '${TOOLBOX_MOUNT}/tmp'."
        umount "${TOOLBOX_MOUNT}/tmp"
    fi
}

prepare()
{
    echo "Preparing update..."

    if ! grep -q "${TOOLBOX_MOUNT}/proc" "/proc/mounts"; then
        mount -t proc none "${TOOLBOX_MOUNT}/proc"
    fi

    if ! grep -q "${TOOLBOX_MOUNT}/dev" "/proc/mounts"; then
        mount -t devtmpfs none "${TOOLBOX_MOUNT}/dev"
    fi

    if ! grep -q "${TOOLBOX_MOUNT}/tmp" "/proc/mounts"; then
        mount -t tmpfs none "${TOOLBOX_MOUNT}/tmp"
    fi

    if ! mount -t tmpfs none "${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}"; then
        echo "Error, update failed: temporary source update directory: '${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}' cannot be mounted."
        exit 1
    fi
}

extract_update_rootfs()
{
    echo "Extracting update files..."

    update_rootfs_pattern="rootfs*.tar.xz"

    echo "Looking for update rootfs files with the pattern '${update_rootfs_pattern}' on '${UPDATE_MOUNT}/${update_rootfs_archive}'."
    nr_files="$(find "${UPDATE_MOUNT}" -maxdepth 1 -iname "${update_rootfs_pattern}" | wc -l)"
    if [ "${nr_files}" -eq 0 ]; then
        echo "Error, update failed: no update rootfs with the pattern '${update_rootfs_pattern}' found on '${UPDATE_MOUNT}'."
        exit 1
    fi

    if [ "${nr_files}" -gt 1 ]; then
        echo "Error, update failed: multiple update filesystem archives found on '${UPDATE_MOUNT}'."
        exit 1
    fi

    # shellcheck disable=SC2086
    # Allow file globing for ${update_rootfs_pattern}
    update_rootfs_archive="$(basename "${UPDATE_MOUNT}/"${update_rootfs_pattern})"
    echo "Found '${update_rootfs_archive}', attempting to extract to '${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}'."
    if ! tar -tJf "${UPDATE_MOUNT}/${update_rootfs_archive}" > /dev/null 2> /dev/null; then
        echo "Error, update failed: ${UPDATE_MOUNT}/${update_rootfs_archive} is corrupt."
        exit 1
    fi

    if [ ! -d "${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}" ]; then
        echo "Error, update failed: source update directory: '${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}' does not exist."
        exit 1
    fi

    if ! tar -xJf "${UPDATE_MOUNT}/${update_rootfs_archive}" -C "${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}" \
            > /dev/null 2> /dev/null; then
        echo "Error: unable to extract '${UPDATE_MOUNT}/${update_rootfs_archive}' to '${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}'."
        exit 1
    fi

    echo "Successfully extracted '${UPDATE_MOUNT}/${update_rootfs_archive}' to '${TOOLBOX_MOUNT}/${UPDATE_ROOTFS_SOURCE}'."
}

perform_update()
{
    echo "Performing update..."
    chroot_environment=" \
        PARTITION_TABLE_FILE=${PARTITION_TABLE_FILE} \
        SYSTEM_UPDATE_CONF_DIR=${SYSTEM_UPDATE_CONF_DIR} \
        SYSTEM_UPDATE_SCRIPT_DIR=${SYSTEM_UPDATE_SCRIPT_DIR} \
        TARGET_STORAGE_DEVICE=${TARGET_STORAGE_DEVICE}\
        UPDATE_EXCLUDE_LIST_FILE=${UPDATE_EXCLUDE_LIST_FILE} \
        UPDATE_ROOTFS_SOURCE=${UPDATE_ROOTFS_SOURCE} \
    "

    echo "chroot script execution additional environment: "
    echo "${chroot_environment}" | tr -s "${IFS}" '\n'

    for script in "${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_SCRIPT_DIR}/"[0-9][0-9]_*.sh; do
        if [ ! -x "${script}" ]; then
            continue
        fi

        script_to_execute="${script#"${TOOLBOX_MOUNT}"}"
        echo "executing: ${script_to_execute}"
        eval "${chroot_environment}" chroot "${TOOLBOX_MOUNT}" "${script_to_execute}"
    done

    echo "Successfully performed update."
}

while getopts ":h" options; do
    case "${options}" in
    h)
        usage
        exit 0
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

trap cleanup EXIT

if [ "${#}" -lt 3 ]; then
    echo "Missing arguments."
    usage
    exit 1
fi

if [ "${#}" -gt 3 ]; then
    echo "Too many arguments."
    usage
    exit 1
fi

TOOLBOX_MOUNT="${1}"
UPDATE_MOUNT="${2}"
TARGET_STORAGE_DEVICE="${3}"


if [ -z "${TOOLBOX_MOUNT}" ]; then
    echo "Error, update failed: Missing arguments <TOOLBOX_MOUNT>."
    exit 1
fi

if [ ! -d "${TOOLBOX_MOUNT}" ]; then
    echo "Error, update failed: ${TOOLBOX_MOUNT} is not a directory."
    exit 1
fi

if [ -z "${UPDATE_MOUNT}" ]; then
    echo "Error, update failed: update mount dir is not provided."
    exit 1
fi

if [ ! -d "${UPDATE_MOUNT}" ]; then
    echo "Error, update failed: ${UPDATE_MOUNT} is not a directory."
    exit 1
fi

if [ -z "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Error, update failed: target storage device not provided."
    exit 1
fi

if [ ! -b "${TARGET_STORAGE_DEVICE}" ]; then
    echo "Error, update failed: '${TARGET_STORAGE_DEVICE}' is not a block device."
    exit 1
fi

if [ -z "${SYSTEM_UPDATE_CONF_DIR}" ]; then
    echo "Error, update failed: system update configuration dir is not provided."
    exit 1
fi

if [ -z "${SYSTEM_UPDATE_SCRIPT_DIR}" ]; then
    echo "Error, update failed: system update scripts dir is not provided."
    exit 1
fi

if [ ! -d "${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR}" ]; then
    echo "Error, update failed: ${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR} is not a directory."
    exit 1
fi

if [ ! -f "${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}" ]; then
    echo "Error, update failed: '${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}' not found."
    exit 1
fi

if [ ! -f "${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}.sha512" ]; then
    echo "Error, update failed: '${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR}/${PARTITION_TABLE_FILE}.sha512' not found."
    exit 1
fi

if [ ! -f "${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR}/${UPDATE_EXCLUDE_LIST_FILE}" ]; then
    echo "Error, update failed: '${TOOLBOX_MOUNT}/${SYSTEM_UPDATE_CONF_DIR}/${UPDATE_EXCLUDE_LIST_FILE}' not found."
    exit 1
fi

trap cleanup EXIT

prepare
extract_update_rootfs
perform_update

exit 0
