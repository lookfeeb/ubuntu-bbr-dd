"""Version-locked Ubuntu-only adapter for bin456789/reinstall; never runs it.

The release script embeds this module and its assets. Every patch anchor must
match exactly once; upstream changes require explicit review and a new pin.
"""
import base64
import hashlib
from datetime import datetime
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import urllib.request

COMMIT = '8ac9db68f9bca0b26c4143b2f3e206f2aa342d6b'
ARCHIVE_SHA = 'e16ac96823636556b0281ca85074f29c534e8c3f0be0c6b30c26a44eb5bb86bb'
ASSETS = {}  # Replaced by sync_embedded.py in the standalone release.


def asset(name):
    if ASSETS:
        return base64.b64decode(ASSETS[name])
    return Path(__file__).with_name(name).read_bytes()


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'Patch anchor mismatch: {old[:100]!r}')
    return text.replace(old, new, 1)


def hook(kind):
    return (f'    local dd_rc=0\n    dd_resource {kind} "$@" || dd_rc=$?\n'
            '    if [ "$dd_rc" != 125 ]; then return "$dd_rc"; fi\n')


def patch_host(text):
    # Send the final Ubuntu login password through a private descriptor owned
    # by dd.sh. Never put plaintext in the resource bundle or initramfs.
    text = replace(text, 'prompt_password() {\n',
                   'dd_report_login() {\n'
                   '    [ "${DD_LOGIN_FD:-}" = 8 ] || return 0\n'
                   '    [ "$distro" = ubuntu ] && [ "$username" = root ] &&\n'
                   '        [ "${ssh_port:-22}" = 22 ] && [ -z "${ssh_keys:-}" ] &&\n'
                   '        [ -n "$password" ] || error_and_exit "Unexpected DD login settings"\n'
                   '    printf \'%s\' "$password" >&8 || error_and_exit "Cannot record DD login"\n'
                   '}\n\nprompt_password() {\n')
    text = replace(text, "info 'info'\necho \"$distro $releasever\"",
                   "dd_report_login\ninfo 'info'\necho \"$distro $releasever\"")
    text = replace(text, '        IFS= read -r -p "Password: " password',
                   '        IFS= read -r -s -p "请输入 root 登录密码（留空随机生成）：" password || error_and_exit "未收到密码输入"\n'
                   '        printf "\\n"')
    text = replace(text, '            IFS= read -r -p "Retype password: " password_confirm',
                   '            IFS= read -r -s -p "请再次输入密码：" password_confirm || error_and_exit "未收到确认密码"\n'
                   '            printf "\\n"')
    text = replace(text, 'error "Passwords don\'t match. Try again."',
                   'error "两次密码不一致，请重新输入。"')
    text = replace(text, f'confhome=https://raw.githubusercontent.com/bin456789/reinstall/main',
                   f'confhome=https://raw.githubusercontent.com/bin456789/reinstall/{COMMIT}')
    text = replace(text, 'confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/main',
                   f'confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/{COMMIT}\n'
                   ': "${DD_BUNDLE:?Run through dd.sh}"\n. "$DD_BUNDLE/dd_resources.sh"')
    text = replace(text, 'curl() {\n', 'curl() {\n' + hook('curl'))
    if text.count('command curl --insecure') != 2:
        raise ValueError('Unexpected curl bypass count')
    text = text.replace('command curl --insecure', "command curl --proto '=https' --proto-redir '=https' --tlsv1.2")
    for old in ['http://www.qualcomm.cn', 'http://mirror.nju.edu.cn/alpine', 'http://dl-cdn.alpinelinux.org/alpine']:
        text = text.replace(old, old.replace('http:', 'https:'))
    text = replace(text, '    curl -Lo $initrd_dir/trans.sh $confhome/trans.sh',
                   '    mkdir -p "$initrd_dir/configs/dd"\n'
                   '    cp -a "$DD_BUNDLE/." "$initrd_dir/configs/dd/"\n'
                   '    curl -Lo $initrd_dir/trans.sh $confhome/trans.sh')
    # Alpine initramfs on OCI Arm can start with an unset clock. Carry the
    # host CA bundle and a trusted time floor instead of disabling TLS checks.
    text = replace(text, 'mod_initrd_alpine() {\n', 'mod_initrd_alpine() {\n'
                   '    [ -s /etc/ssl/certs/ca-certificates.crt ] || error_and_exit "CA bundle missing"\n'
                   '    mkdir -p "$initrd_dir/etc/ssl/certs"\n'
                   '    cp /etc/ssl/certs/ca-certificates.crt "$initrd_dir/etc/ssl/certs/"\n'
                   '    local dd_epoch\n    dd_epoch=$(date +%s)\n'
                   '    grep -q "^#!/bin/sh" init || error_and_exit "Unexpected Alpine init"\n'
                   '    insert_into_file init after "^#!/bin/sh" <<EOF\n'
                   'if [ "\\$(/bin/busybox date +%s)" -lt "$dd_epoch" ]; then /bin/busybox date -u -s @$dd_epoch; fi\n'
                   'EOF\n')
    text = replace(text, '        cp /trans.sh \\$sysroot/etc/local.d/trans.start',
                   '        mkdir -p \\$sysroot/etc/ssl/certs\n'
                   '        cp /etc/ssl/certs/ca-certificates.crt \\$sysroot/etc/ssl/certs/\n'
                   '        cp /trans.sh \\$sysroot/etc/local.d/trans.start')
    return text


def patch_network_unit(text):
    # Ubuntu's cloud-init-local runs before sysinit. A regular service ordered
    # before it must not also inherit After=basic/sysinit or wait for D-Bus.
    text = replace(text, '[Unit]\n', '[Unit]\nDefaultDependencies=no\n'
                   'Wants=systemd-udev-settle.service\n'
                   'Conflicts=shutdown.target\nBefore=shutdown.target\n')
    return replace(text, 'After=dbus.service\n',
                   'After=systemd-remount-fs.service systemd-udev-settle.service\n')


def patch_trans(text):
    # Ignore the old /configs/xda cache and reject cloned table IDs instead of
    # selecting the first enumerated device. Identity is sealed by the host.
    matches = re.findall(r'^find_xda\(\) \{\n.*?^\}', text, re.M | re.S)
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous upstream disk selector')
    # Alpine ships the blockdev command in util-linux-misc, not a blockdev APK.
    text = replace(text, matches[0], 'find_xda() {\n'
                   '    apk add lsblk util-linux-misc eudev\n'
                   '    dd_find_target_disk\n'
                   '    set_config xda "$xda"\n}')
    text = replace(text, 'get_ubuntu_kernel_flavor() {\n', 'dd_upstream_kernel_flavor() {\n')
    text = replace(text, 'wget() {\n', 'wget() {\n' + hook('wget'))
    text = replace(text, 'download() {\n', 'download() {\n' + hook('download'))
    # All external file downloads used by the Ubuntu path go through strict
    # HTTPS. APK/APT keep their native signed-package validation.
    text = replace(text, '    local url=$1\n    local path=$2\n    local can_use_cn_mirror=',
                   '    case "$1" in https://*) ;; *) dd_fail "Non-HTTPS download refused" ;; esac\n'
                   '    dd_https --output "$2" "$1"\n    return\n'
                   '    local url=$1\n    local path=$2\n    local can_use_cn_mirror=')
    text = replace(text, '    show_url_in_args "$@" >&2\n    if command wget',
                   '    dd_wget "$@"\n    return\n    show_url_in_args "$@" >&2\n    if command wget')
    text = replace(text, ': main\n', ': main\n'
                   'DD_BUNDLE=/configs/dd\n'
                   '(cd "$DD_BUNDLE" && sha256sum -c resources.sha256 >/dev/null) || exit 1\n'
                   '. "$DD_BUNDLE/dd_resources.sh"\n'
                   '. "$DD_BUNDLE/dd_disk.sh"\n'
                   '. "$DD_BUNDLE/dd_runtime.sh"\n'
                   '. "$DD_BUNDLE/dd_packages.sh"\n'
                   '[ "$#" = 0 ] || dd_fail "Stage updates and alternate installations are disabled"\n'
                   'dd_install_begin\n')
    # The upstream retry hint restarts repartitioning. After disk writes begin,
    # preserve the installer and explain the actual failure boundary instead.
    begin = text.index('error_and_exit() {\n')
    end = text.index('\ntrap_err() {', begin)
    text = text[:begin] + 'error_and_exit() {\n    dd_fail "$@"\n}\n' + text[end:]
    begin = text.index('trap_err() {\n')
    end = text.index('\nis_run_from_locald() {', begin)
    text = text[:begin] + ('trap_err() {\n'
                          '    echo "DD command failed at line $1 (exit $2)" >&2\n'
                          '    exit "$2"\n}\n') + text[end:]
    text = replace(text, '    wget -O /trans.sh "$confhome/trans.sh"',
                   '    dd_fail "Self-update is disabled; prepare again with dd.sh"')
    text = replace(text, 'create_part() {\n', 'create_part() {\n    dd_require_partition\n')
    text = replace(text, '        qemu)\n            create_part\n            download_qcow',
                   '        qemu)\n            dd_prepare_install')
    # In disk mode the installer partition contains the live swap file. Keep
    # it mounted and retain it for target swap instead of removing a live swap.
    text = replace(text, '    umount /os/\n    umount /installer/\n',
                   '    umount /os/\n    dd_release_installer\n')
    text = replace(text, '    parted /dev/$xda -s -- rm 3\n    update_part\n    resize_after_install_cloud_image\n',
                   '    dd_finish_partition_layout\n')
    text = replace(text, '    create_swap_if_ram_less_than $need_ram /os/swapfile\n',
                   '    if ! dd_disk_cache; then create_swap_if_ram_less_than $need_ram /os/swapfile; fi\n')
    text = replace(text, '    # 删除 swapfile\n    swapoff -a\n    rm -f /os/swapfile\n',
                   '    # Disk cache swap remains available until reboot and in the target.\n'
                   '    if ! dd_disk_cache; then swapoff -a; rm -f /os/swapfile; fi\n')
    text = replace(text, '    remove_or_disable_cloud_init /os\n',
                   '    dd_finalize_target /os\n')
    text = replace(text, '    while ! blkid /dev/nbd0; do\n',
                   '    local dd_wait=0\n    while ! blkid /dev/nbd0; do\n'
                   '        dd_wait=$((dd_wait + 1))\n'
                   '        [ "$dd_wait" -le 24 ] || dd_fail "nbd attach timed out"\n')
    # Only the image handle matters here. Whole-filesystem fuser (-m) also
    # sees unrelated scratch/log files and can wait forever in disk mode.
    text = replace(text, '        while fuser -sm $qcow_file; do\n',
                   '        local dd_detach_wait=0\n'
                   '        while fuser -s "$qcow_file"; do\n'
                   '            dd_detach_wait=$((dd_detach_wait + 1))\n'
                   '            [ "$dd_detach_wait" -le 24 ] || dd_fail "nbd detach timed out"\n')
    # The preflight NBD must remain read-only until detached; later calls write
    # only the already checked disk copy. Pin format for all NBD use.
    text = replace(text, '    qemu-nbd -c /dev/nbd0 $qcow_file',
                   '    qemu-nbd --format=qcow2 -c /dev/nbd0 $qcow_file')
    text = replace(text, '    cp -a /nbd/* /os/\n',
                   '    dd_install_stage target-copy\n    cp -a /nbd/* /os/\n    dd_seed_packages /os\n')
    # Keep preflight APT URIs/index names unchanged. The image uses official
    # Ubuntu sources; a mirror switch here would invalidate the cached plan.
    begin = text.index('        # 更改源\n', text.index('    modify_ubuntu() {'))
    end = text.index('        # 安装 mbr\n', begin)
    text = text[:begin] + ('        dd_install_stage package-install\n'
                         '        dd_install_packages "$os_dir"\n'
                         '        # Retain unused bootloader packages; removing them can\n'
                         '        # trigger a different APT dependency transaction.\n\n') + text[end:]
    text = replace(text, '        chroot $os_dir apt-get update', '        dd_apt_update "$os_dir"')
    text = replace(text, 'chroot $os_dir apt-get install -y $pkgs', 'chroot $os_dir apt-get --no-download install -y $pkgs')
    text = replace(text, 'chroot $os_dir apt-get remove --purge --allow-remove-essential -y $pkgs',
                   'chroot $os_dir apt-get --no-download remove --purge -y $pkgs')
    text = replace(text, 'chroot $os_dir apt-get autoremove --purge -y',
                   'chroot $os_dir apt-get --no-download autoremove --purge -y')
    # No HTTP Date / certificate bypass is needed for the installer clock.
    start = text.index('sync_time() {\n')
    end = text.index('\nis_ubuntu_lts() {', start)
    text = text[:start] + 'sync_time() {\n    : # Keep the initramfs time floor; no unsigned HTTP clock source.\n}\n' + text[end:]
    text = replace(text, '    dd_finalize_target /os\n',
                   '    dd_install_stage target-validation\n    dd_finalize_target /os\n')
    text = replace(text, "    info 'done'\n", "    dd_install_stage complete\n    info 'done'\n")
    return text


def build(archive, target):
    archive, target = Path(archive), Path(target)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise ValueError('Upstream archive SHA-256 mismatch')
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'r:gz') as tar:
        for item in tar:
            parts = PurePosixPath(item.name).parts
            if not parts or parts[0] != f'reinstall-{COMMIT}' or '..' in parts:
                raise ValueError('Unsafe archive path')
            # Only root-level regular helper files are used by Ubuntu.
            if len(parts) != 2 or not item.isfile():
                continue
            path = target / parts[1]
            if path.is_symlink():
                raise ValueError('Symlink in bundle output')
            path.write_bytes(tar.extractfile(item).read())
    for name, patch in [('reinstall.sh', patch_host), ('trans.sh', patch_trans),
                        ('fix-eth-name.service', patch_network_unit)]:
        p = target / name
        p.write_text(patch(p.read_text(encoding='utf-8')), encoding='utf-8', newline='\n')
    for name in ['dd_resources.sh', 'dd_disk.sh', 'dd_runtime.sh', 'dd_packages.sh', 'ubuntu-cloudimage-keyring.gpg']:
        (target / name).write_bytes(asset(name))
    seal(target)


def seal(target):
    target = Path(target)
    lines = []
    for path in sorted(target.iterdir()):
        if path.is_file() and path.name != 'resources.sha256':
            lines.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n')
    (target / 'resources.sha256').write_text(''.join(lines), encoding='ascii')


class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Non-HTTPS redirect refused')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def snapshot_base(client, version, codename):
    current = f'https://cloud-images.ubuntu.com/releases/{codename}/release/'
    with client.open(current, timeout=60) as response:
        if response.geturl() != current:
            raise ValueError('Release index redirected away from official current build')
        data = response.read(2 * 1024 * 1024)
    if len(data) >= 2 * 1024 * 1024:
        raise ValueError('Release index too large')
    # The official current-release heading identifies the published serial;
    # directory order and timestamps are not a reliable latest-build selector.
    matches = re.findall(r'<h1>Ubuntu ' + re.escape(version) +
                         r'(?=[ .])[^<]* release \[([0-9]{8}(?:\.[0-9]+)?)\]</h1>', data.decode('utf-8'))
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous Ubuntu release build')
    serial = matches[0]
    datetime.strptime(serial.split('.')[0], '%Y%m%d')
    return current.removesuffix('release/') + 'release-' + serial + '/', serial


def image_metadata(target, version, arch):
    target = Path(target)
    # A failed refresh must not leave a previously usable image policy behind.
    for field in ['image-url', 'image-build', 'image-bytes']:
        (target / field).unlink(missing_ok=True)
    codename = {'24.04': 'noble', '26.04': 'resolute'}[version]
    if arch not in ['amd64', 'arm64']:
        raise ValueError('Unsupported image architecture')
    name = f'ubuntu-{version}-server-cloudimg-{arch}.img'
    client = urllib.request.build_opener(HTTPSOnly())
    base, serial = snapshot_base(client, version, codename)
    for resource in ['SHA256SUMS', 'SHA256SUMS.gpg']:
        with client.open(base + resource, timeout=60) as response:
            if response.geturl() != base + resource:
                raise ValueError('Snapshot manifest redirected away from pinned build')
            data = response.read(2 * 1024 * 1024)
        if len(data) >= 2 * 1024 * 1024:
            raise ValueError('Manifest too large')
        (target / resource).write_bytes(data)
    import tempfile
    with tempfile.TemporaryDirectory(prefix='dd-gpg-') as home:
        subprocess.run(['gpgv', '--homedir', home, '--keyring', str(target.resolve() / 'ubuntu-cloudimage-keyring.gpg'),
                        str(target / 'SHA256SUMS.gpg'), str(target / 'SHA256SUMS')], check=True)
    matches = re.findall(r'^([a-f0-9]{64}) [ *]' + re.escape(name) + r'$',
                         (target / 'SHA256SUMS').read_text(encoding='ascii'), re.M)
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous signed Ubuntu image entry')
    with client.open(urllib.request.Request(base + name, method='HEAD'), timeout=60) as response:
        if response.geturl() != base + name:
            raise ValueError('Snapshot image redirected away from pinned build')
        size = int(response.headers['Content-Length'])
    if not 64 * 1024 * 1024 < size < 16 * 1024 ** 3:
        raise ValueError('Unexpected image size')
    (target / 'image-url').write_text(base + name + '\n', encoding='ascii')
    (target / 'image-build').write_text(serial + '\n', encoding='ascii')
    (target / 'image-bytes').write_text(str(size) + '\n', encoding='ascii')
    print(f'Ubuntu {version} {arch}, build {serial}: {size} bytes; signed SHA256 {matches[0]}')


if __name__ == '__main__':
    try:
        action, *args = sys.argv[1:]
        {'build': build, 'image': image_metadata, 'seal': seal}[action](*args)
    except Exception as exc:
        sys.exit(f'DD preparation stopped: {exc}')
