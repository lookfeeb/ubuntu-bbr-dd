#!/usr/bin/env bash
# Build locally; package installation and reboot tests run only inside QEMU.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
build=${1:?Usage: bash tools/build_release.sh /absolute/new-build [existing-kernel-tree]}
reuse=${2:-}
[[ $build == /* && ! -e $build ]] || { echo 'Use a new absolute build directory.' >&2; exit 1; }
git diff --quiet HEAD -- . || { echo 'Commit the release sources before building.' >&2; exit 1; }
# shellcheck source=/dev/null
source ./bbr.sh
mkdir -p "$build/clean"
archive=$build/linux-$KERNEL_VERSION.tar.xz
if [[ -n $reuse && -f ${reuse%/linux}/linux-$KERNEL_VERSION.tar.xz ]]; then
    cp -- "${reuse%/linux}/linux-$KERNEL_VERSION.tar.xz" "$archive"
fi
download_verified "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KERNEL_VERSION.tar.xz" "$archive" "$KERNEL_SHA256" 1
tar -xJf "$archive" --strip-components=1 -C "$build/clean"
python3 -B tools/kernel_patch.py "$build/clean"
python3 -B tools/wan_recovery.py --kernel-tree "$build/clean"
if [[ -n $reuse ]]; then
    [[ -f $reuse/Makefile && -f $reuse/.config ]] || { echo 'Invalid reusable kernel tree.' >&2; exit 1; }
    # Independent copy: never hard-link mutable objects or edit prior evidence.
    cp -a --reflink=auto -- "$reuse" "$build/linux"
else
    mkdir "$build/linux"
fi
# Refresh every upstream/patched source by content, retaining unchanged objects.
bash tools/release/sync_sources.sh "$build/clean" "$build/linux"
cp tools/release/config-amd64 "$build/linux/.config"
# Used by compile_kernel_source from bbr.sh. Reserve memory for the linker.
available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
jobs=$((available / 1048576 - 2)); (( jobs > 0 )) || jobs=1
(( jobs <= $(nproc) )) || jobs=$(nproc)
# shellcheck disable=SC2034
JOBS=$jobs
export KBUILD_BUILD_USER=release-builder KBUILD_BUILD_HOST=ubuntu-bbr-dd
KBUILD_BUILD_TIMESTAMP=$(git show -s --format=%cD HEAD)
export KBUILD_BUILD_TIMESTAMP
git rev-parse HEAD > "$build/source-commit"
compile_kernel_source "$build/linux" "$build" "$build/build.log"
[[ $(cat "$build/kernel-release") == "$PREBUILT_RELEASE" ]]
python3 -B tools/recovery_smoke.py --build "$build" \
    --image-package "$build/linux-image-${PREBUILT_RELEASE}_${PREBUILT_VERSION}_amd64.deb"
python3 -B tools/release_vm.py --build "$build"
python3 -B tools/package_recovery.py --build "$build" --upstream "$archive" --out "$build/assets"
