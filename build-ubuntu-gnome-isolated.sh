#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_DIR}/build-ubuntu-gnome/artifacts}"
LOGS_DIR="${LOGS_DIR:-${REPO_DIR}/build-ubuntu-gnome/logs}"
BUILD_DIR="${BUILD_DIR:-${REPO_DIR}/build-ubuntu-gnome}"
WORK_DIR="${BUILD_DIR}/work"
DESKTOP_ENV="gnome"
DEVICE="sheng"

usage() {
    cat <<'EOF'
Usage: sudo bash ./build-ubuntu-gnome-isolated.sh <kernel_version> [github_repo]

Build Ubuntu 26 + GNOME in an isolated directory and place outputs under:
  build-ubuntu-gnome/artifacts/
  build-ubuntu-gnome/logs/

Arguments:
  kernel_version  Kernel bundle version, for example 7.1
  github_repo     Optional GitHub repo for gh release downloads, for example owner/repo

Environment:
  BUILD_DIR       Override isolated build directory
  ARTIFACTS_DIR   Override final artifact directory
  LOGS_DIR        Override final log directory
  SKIP_DOWNLOAD=1 Reuse existing .deb files in build-ubuntu-gnome/work/packages
EOF
    exit 1
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root because rootfs construction requires loop mounts and chroot."
    exit 1
fi

KERNEL_VERSION="$1"
GITHUB_REPO="${2:-}"
PACKAGE_DIR="${WORK_DIR}/packages"
RUN_DIR="${WORK_DIR}/run"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${LOGS_DIR}/ubuntu-gnome-${DEVICE}-${KERNEL_VERSION}-${TIMESTAMP}.log"

mkdir -p "$PACKAGE_DIR" "$RUN_DIR" "$ARTIFACTS_DIR" "$LOGS_DIR"

log() {
    printf '[%s] %s\n' "$(date +"%Y-%m-%d %H:%M:%S")" "$*"
}

download_packages() {
    if [ "${SKIP_DOWNLOAD:-0}" = "1" ]; then
        log "Skipping release download because SKIP_DOWNLOAD=1."
        return
    fi

    if [ -z "$GITHUB_REPO" ]; then
        GITHUB_REPO="$(git -C "$REPO_DIR" config --get remote.origin.url 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#; s#^https://github.com/##; s#\.git$##')"
    fi

    if [ -z "$GITHUB_REPO" ]; then
        echo "Unable to infer GitHub repo. Pass it explicitly as owner/repo." >&2
        exit 1
    fi

    log "Downloading kernel-bundle-${KERNEL_VERSION} from ${GITHUB_REPO}."
    rm -f "${PACKAGE_DIR}"/*.deb

    if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
        gh release download "kernel-bundle-${KERNEL_VERSION}" \
            --pattern "*.deb" \
            --repo "$GITHUB_REPO" \
            --dir "$PACKAGE_DIR" \
            --clobber
    else
        local assets_url="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/kernel-bundle-${KERNEL_VERSION}"
        curl -fsSL "$assets_url" \
            | grep -o 'https://[^" ]*/releases/download/[^" ]*\.deb' \
            | sort -u \
            | while read -r url; do
                curl -fL --retry 3 --retry-delay 2 -o "${PACKAGE_DIR}/$(basename "$url")" "$url"
            done
    fi
}

prepare_host() {
    if [ ! -e /usr/share/debootstrap/scripts/resolute ] && [ -e /usr/share/debootstrap/scripts/gutsy ]; then
        ln -s /usr/share/debootstrap/scripts/gutsy /usr/share/debootstrap/scripts/resolute
    fi

    if [ "$(uname -m)" != "aarch64" ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && [ -x /usr/lib/systemd/systemd-binfmt ]; then
        /usr/lib/systemd/systemd-binfmt >/dev/null 2>&1 || true
    fi
}

require_package() {
    local pattern="$1"
    local description="$2"

    if ! compgen -G "${PACKAGE_DIR}/${pattern}" >/dev/null; then
        echo "Missing ${description} package matching ${pattern} in ${PACKAGE_DIR}." >&2
        exit 1
    fi
}

validate_packages() {
    require_package "linux-*.deb" "kernel"
    require_package "firmware-*.deb" "firmware"
    require_package "alsa-*.deb" "ALSA"
    require_package "sheng-devauth*.deb" "sheng devauth"

    log "Package set:"
    ls -lh "${PACKAGE_DIR}"/*.deb
}

prepare_run_dir() {
    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    cp "${REPO_DIR}/build-ubuntu26-rootfs.sh" "$RUN_DIR/"
    cp "${PACKAGE_DIR}"/*.deb "$RUN_DIR/"
    chmod +x "$RUN_DIR/build-ubuntu26-rootfs.sh"
}

extract_image() {
    local archive="$1"
    local final_image="$2"
    local extract_dir="${WORK_DIR}/extract-${TIMESTAMP}"

    mkdir -p "$extract_dir"
    7z x -y -o"$extract_dir" "$archive" >/dev/null

    shopt -s nullglob
    local images=("$extract_dir"/*.img)
    shopt -u nullglob

    if [ "${#images[@]}" -ne 1 ]; then
        echo "Expected exactly one .img in ${archive}, found ${#images[@]}." >&2
        exit 1
    fi

    mv "${images[0]}" "$final_image"
}

verify_image() {
    local image="$1"
    local verify_dir="${WORK_DIR}/verify-${TIMESTAMP}"

    mkdir -p "${verify_dir}/mnt"
    mount -o loop "$image" "${verify_dir}/mnt"
    trap 'umount -l "${verify_dir}/mnt" 2>/dev/null || true' RETURN

    test -d "${verify_dir}/mnt/boot"
    test -d "${verify_dir}/mnt/lib/modules"
    test -d "${verify_dir}/mnt/lib/firmware"
    test -e "${verify_dir}/mnt/etc/systemd/system/default.target"
    test -e "${verify_dir}/mnt/lib/firmware/regulatory.db" || test -e "${verify_dir}/mnt/usr/lib/firmware/regulatory.db"

    if [ ! -e "${verify_dir}/mnt/etc/systemd/system/display-manager.service" ] \
        && [ ! -e "${verify_dir}/mnt/etc/systemd/system/graphical.target.wants/gdm3.service" ] \
        && [ ! -e "${verify_dir}/mnt/etc/systemd/system/multi-user.target.wants/gdm3.service" ]; then
        echo "Verification failed: gdm3/display-manager service link is missing." >&2
        exit 1
    fi

    umount "${verify_dir}/mnt"
    trap - RETURN
    log "Image verification completed."
}

main() {
    prepare_host
    download_packages
    validate_packages
    prepare_run_dir

    log "Starting Ubuntu 26 GNOME build in ${RUN_DIR}. Log: ${LOG_FILE}"
    (
        cd "$RUN_DIR"
        ./build-ubuntu26-rootfs.sh "$KERNEL_VERSION" "$DESKTOP_ENV"
    ) 2>&1 | tee "$LOG_FILE"

    shopt -s nullglob
    local archives=("${RUN_DIR}"/ubuntu26_${DESKTOP_ENV}_*.7z)
    shopt -u nullglob

    if [ "${#archives[@]}" -ne 1 ]; then
        echo "Expected exactly one rootfs archive, found ${#archives[@]}." >&2
        exit 1
    fi

    local artifact_base="ubuntu-gnome-${DEVICE}-${KERNEL_VERSION}-${TIMESTAMP}"
    local final_archive="${ARTIFACTS_DIR}/${artifact_base}.7z"
    local final_image="${ARTIFACTS_DIR}/${artifact_base}.img"
    mv "${archives[0]}" "$final_archive"
    extract_image "$final_archive" "$final_image"
    verify_image "$final_image"

    log "Build complete: ${final_image}"
    log "Compressed archive: ${final_archive}"
}

main "$@"
