#!/usr/bin/env bash
# Native local build only: no swap, package installation or service changes.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=${1:?Usage: bash tools/build_nginx.sh /absolute/build-directory}
[[ $build == /* && $build != / && ! -L $build ]] || { echo 'Use an absolute, non-symlink build directory.' >&2; exit 1; }
mkdir -p "$build"
build=$(cd "$build" && pwd)
exec 8>"$build/build.lock"
flock -n 8 || { echo 'Another Nginx build is using this directory.' >&2; exit 1; }
# shellcheck source=/dev/null
source "$root/bbr.sh"
read_os
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die '当前预编译发布目标为 Ubuntu 24.04；请使用匹配的本地 Linux / WSL。'
[[ $(dpkg --print-architecture) == amd64 ]] || die '当前预编译发布目标为 amd64。'
work=$(mktemp -d "$build/work.XXXXXX")
trap 'echo "Build files: $work"' EXIT
exec > >(tee "$work/build.log") 2>&1
nginx_build_stage "$work" "$build/cache" "$work/stage"
out=$work/assets
mkdir "$out"
name=nginx-ubuntu-${VERSION_ID}-${NGX_ARCH}
nginx_package_tool pack "$work/stage" "$out/$name.tar.gz"
cp "$build/cache/$NGX_RECIPE.sources.tar.gz" "$out/$name-sources.tar.gz"
cp "$work/stage/nginx-build.json" "$out/$name-build.json"
(cd "$out"; sha256sum "$name.tar.gz" "$name-sources.tar.gz" "$name-build.json" > NGINX_SHA256SUMS)
printf '%s\n' "$out" > "$build/latest-assets"
say "本地 Nginx 预编译资产：$out；尚未发布。"
