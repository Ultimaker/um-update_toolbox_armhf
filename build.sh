#!/bin/sh
#
# Copyright (C) 2018 Ultimaker B.V.
# Copyright (C) 2018 Raymond Siudak <raysiudak@gmail.com>
# Copyright (C) 2018 Olliver Schinagl <oliver@schinagl.nl>
#
# SPDX-License-Identifier: AGPL-3.0+

set -eu

# common directory variables
PREFIX="${PREFIX:-/usr/local}"
DATAROOTDIR="${PREFIX}/share"
DATADIR="${DATAROOTDIR}"
EXEC_PREFIX="${PREFIX}"
LIBEXECDIR="${EXEC_PREFIX}/libexec"
SYSCONFDIR="${SYSCONFDIR:-/etc}"

ARCH="${ARCH:-armhf}"
ARM_EMU_BIN="${ARM_EMU_BIN:-}"

ALPINE_VERSION="${ALPINE_VERSION:-latest-stable}"
ALPINE_REPO="${ALPINE_REPO:-http://dl-cdn.alpinelinux.org/alpine}"

TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-um-update_toolbox.xz.img}"

SRC_DIR="$(pwd)"
NAME_TEMPLATE_BUILD_DIR=".build_${ARCH}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/${NAME_TEMPLATE_BUILD_DIR}}"
ROOTFS_DIR="${BUILD_DIR}/rootfs"

SYSTEM_UPDATE_SCRIPT_DIR="${LIBEXECDIR}/jedi_system_update.d"
UPDATE_ROOTFS_SOURCE="/mnt/update_rootfs_source"

PACKAGES="blkid busybox e2fsprogs-extra f2fs-tools rsync sfdisk"

# Debian package information
PACKAGE_NAME="${PACKAGE_NAME:-um-update-toolbox}"
INSTALL_DIR="${INSTALL_DIR:-${DATADIR}/${PACKAGE_NAME}}"
RELEASE_VERSION="${RELEASE_VERSION:-9999.99.99}"


cleanup()
{
    mounts="$(grep "${ROOTFS_DIR}" /proc/mounts || true)"

    if [ ! -d "${BUILD_DIR}" ]; then
        return
    fi
    if [ -n "${mounts}" ]; then
        echo "Cannot delete '${BUILD_DIR}', unmount the following mount points first:"
        echo "${mounts}"
        exit 1
    fi

    if [ -z "${BUILD_DIR##*${NAME_TEMPLATE_BUILD_DIR}*}" ]; then
        rm -rf "${BUILD_DIR:?}"
    fi
}

bootstrap_prepare()
{
    if [ ! -x "${ARM_EMU_BIN}" ]; then
        echo "Invalid or missing ARMv7 interpreter. Please set ARM_EMU_BIN to a valid interpreter."
        echo "Run 'tests/buildenv.sh' to check emulation status."
        exit 1
    fi

    mkdir -p "${ROOTFS_DIR}/usr/bin"
    touch "${ROOTFS_DIR}/${ARM_EMU_BIN}"
    mount -o ro --bind "${ARM_EMU_BIN}" "${ROOTFS_DIR}/${ARM_EMU_BIN}"
}

bootstrap_unprepare()
{
    if [ ! -e "${ROOTFS_DIR}/${ARM_EMU_BIN}" ]; then
        return
    fi

    if grep -q "$(realpath "${ROOTFS_DIR}/${ARM_EMU_BIN}")" "/proc/mounts"; then
        umount "${ROOTFS_DIR}/${ARM_EMU_BIN}"
    fi
    if [ -f "${ROOTFS_DIR}/${ARM_EMU_BIN}" ]; then
        unlink "${ROOTFS_DIR}/${ARM_EMU_BIN}"
    fi
}

add_update_scripts()
{
    target_script_dir="${ROOTFS_DIR}/${SYSTEM_UPDATE_SCRIPT_DIR}"
    if [ ! -d "${target_script_dir}" ]; then
        mkdir -p "${target_script_dir}"
    fi

    target_system_executable_dir="${ROOTFS_DIR}/sbin"
    if [ ! -d "${target_system_executable_dir}" ]; then
        mkdir -p "${target_system_executable_dir}"
    fi

    local_script_dir="${SRC_DIR}/scripts"
    for script in "${local_script_dir}"/[0-9][0-9]_*.sh; do
        basename="${script##*/}"
        echo "Installing ${script} on '${target_script_dir}/${basename}'."
        cp "${script}" "${target_script_dir}/${basename}"
    done

    entrypoint_script="start_update.sh"
    cp "${local_script_dir}/${entrypoint_script}" "${target_system_executable_dir}/${entrypoint_script}"
}

create_update_mount_points()
{
    if [ ! -d "${ROOTFS_DIR}/${UPDATE_ROOTFS_SOURCE}" ]; then
        echo "Creating update rootfs source directory '${ROOTFS_DIR}/${UPDATE_ROOTFS_SOURCE}'."
        mkdir -p  "${ROOTFS_DIR}/${UPDATE_ROOTFS_SOURCE}"
    fi
}

add_configuration_files()
{
    local_config_dir="${SRC_DIR}/config"
    target_config_dir="${ROOTFS_DIR}/${SYSCONFDIR}/jedi_system_update"

    if [ ! -d "${target_config_dir}" ]; then
        mkdir -p "${target_config_dir}"
    fi

    for config_file in "${local_config_dir}/"*; do
        basename="${config_file##*/}"
        echo "Installing ${config_file} on '${target_config_dir}/${basename}'."
        cp "${config_file}" "${target_config_dir}/${basename}"
    done
}

bootstrap_rootfs()
{
    echo "Bootstrapping Alpine Linux rootfs in to '${ROOTFS_DIR}'."

    mkdir -p "${ROOTFS_DIR}/${SYSCONFDIR}/apk"
    echo "${ALPINE_REPO}/${ALPINE_VERSION}/main" > "${ROOTFS_DIR}/${SYSCONFDIR}/apk/repositories"

    # Install rootfs with base applications
    # shellcheck disable=SC2086
    # allow word splitting for ${PACKAGES}
    apk --root "${ROOTFS_DIR}" --update-cache \
       add --allow-untrusted --initdb --arch "${ARCH}" \
       ${PACKAGES}

    # Add baselayout etc files
    echo "Adding baselayout"
    apk --root "${ROOTFS_DIR}" \
       fetch --allow-untrusted --arch "${ARCH}" --stdout alpine-base | tar -xvz -C "${ROOTFS_DIR}" etc
    rm -f "${ROOTFS_DIR}/var/cache/apk"/*
}

compress_rootfs()
{
    if [ -f "${BUILD_DIR}/${TOOLBOX_IMAGE}" ]; then
        rm -f "${BUILD_DIR}/${TOOLBOX_IMAGE}"
    fi

    echo "Compressing rootfs"
    mksquashfs "${ROOTFS_DIR}" "${BUILD_DIR}/${TOOLBOX_IMAGE}" -comp xz
    echo "Created ${BUILD_DIR}/${TOOLBOX_IMAGE}."
}

create_debian_package()
{
    DEB_DIR="${BUILD_DIR}/debian_deb_build"

    mkdir -p "${DEB_DIR}/DEBIAN"
    sed -e 's/@ARCH@/'"${ARCH}"'/g' \
        -e 's/@PACKAGE_NAME@/'"${PACKAGE_NAME}"'/g' \
        -e 's/@RELEASE_VERSION@/'"${RELEASE_VERSION}"'/g' \
        "${SRC_DIR}/debian/control.in" > "${DEB_DIR}/DEBIAN/control"

    mkdir -p "${DEB_DIR}/${INSTALL_DIR}"
    cp "${BUILD_DIR}/${TOOLBOX_IMAGE}" "${DEB_DIR}/${INSTALL_DIR}/"

    dpkg-deb --build "${DEB_DIR}" "${BUILD_DIR}/${PACKAGE_NAME}_${ARCH}-${RELEASE_VERSION}.deb"
}

usage()
{
cat <<-EOT
    Usage: ${0} [OPTIONS]
        -c   Explicitly cleanup the build directory
        -h   Print this usage
    NOTE: This script requires root permissions to run.
EOT
}

while getopts ":hc" options; do
    case "${options}" in
    c)
        cleanup
        exit 0
        ;;
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

if [ "$(id -u)" -ne 0 ]; then
    echo "Warning: this script requires root permissions."
    echo "Run this script again with 'sudo ${0}'."
    echo "See ${0} -h for more info."
    exit 1
fi

trap bootstrap_unprepare EXIT

cleanup
bootstrap_prepare
bootstrap_rootfs
add_update_scripts
create_update_mount_points
add_configuration_files
bootstrap_unprepare
compress_rootfs
create_debian_package

exit 0
