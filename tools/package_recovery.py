"""Package the experimental guarded-recovery kernel and corresponding source.

Run on Linux after the build and smoke test. This prepares local artifacts;
it does not install, upload, or qualify them for general WAN deployment.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile

import wan_recovery

ROOT = Path(__file__).resolve().parents[1]
RELEASE = '7.3.5-bbrguard7r2only-674859761ded'
VERSION = '7.3.5-guard7r2.1'
UPSTREAM_SHA = '8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def verify_guard_config(text):
    if 'CONFIG_TCP_CONG_BBR_GUARD=m' not in text.splitlines():
        raise ValueError('Guard module is not enabled')
    if re.search(r'^CONFIG_TCP_CONG_(BBR|BBR3|BBR_WAN)=[ym]$', text, re.M):
        raise ValueError('Original BBR/BBR3/WAN is still enabled')


def verify_module_names(names, require_guard):
    old = re.compile(r'(^|/)tcp_bbr(?:3|_wan)?\.ko(?:\.(?:gz|xz|zst))?$')
    guard = re.compile(r'(^|/)tcp_bbr_guard\.ko(?:\.(?:gz|xz|zst))?$')
    if any(old.search(name) for name in names):
        raise ValueError('Package contains an original BBR/BBR3/WAN module')
    if require_guard and sum(bool(guard.search(name)) for name in names) != 1:
        raise ValueError('Expected exactly one packaged Guard module')


def verify_vm_report(report, packages, expected_commit):
    if (report.get('status') != 'pass' or report.get('kernel_release') != RELEASE or
            report.get('package_version') != VERSION or
            report.get('phases') != ['setup', 'install', 'new', 'rollback', 'old', 'return', 'clean'] or
            report.get('packages') != {p.name: digest(p) for p in packages}):
        raise ValueError('Missing matching installation/boot/headers/rollback/single-kernel validation')
    boots = report.get('boots', [])
    if (len(boots) != 4 or len({b.get('id') for b in boots}) != 4 or
            any(not b.get('ssh') or not re.fullmatch(r'[a-f0-9-]{36}', b.get('id', '')) for b in boots) or
            not report.get('original_kernel') or report['original_kernel'] == RELEASE):
        raise ValueError('Missing independent reboot/SSH and fallback evidence')
    if report.get('commit') != expected_commit:
        raise ValueError('Guest validation is from another commit')


def inspect_package(package, src, require_guard):
    names = []
    process = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(package)], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                path = PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts:
                    raise ValueError('Unexpected package path')
                names.append(member.name)
                if member.isfile() and path.suffix in ('.pem', '.key'):
                    if b'PRIVATE KEY' in archive.extractfile(member).read():
                        raise ValueError('Private signing key in package')
        if process.wait() != 0:
            raise ValueError('Could not inspect Debian package')
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
            process.wait()
    verify_module_names(names, require_guard)
    if require_guard:
        with tempfile.TemporaryDirectory(prefix='guard6-package-check-') as temporary:
            staging = Path(temporary)
            run('dpkg-deb', '-x', str(package), temporary)
            if digest(staging / 'boot' / ('vmlinuz-' + RELEASE)) != digest(src / 'arch/x86/boot/bzImage'):
                raise ValueError('Packaged kernel differs from build')
            config = staging / 'boot' / ('config-' + RELEASE)
            verify_guard_config(config.read_text())
            if digest(config) != digest(src / '.config'):
                raise ValueError('Packaged config differs from build')
            for driver in ('tcp_bbr_guard', 'sch_fq', 'gve', 'ena', 'virtio_net', 'virtio_blk', 'virtio_pci', 'nvme'):
                run('modinfo', '-b', temporary, '-k', RELEASE, driver, stdout=subprocess.DEVNULL)
    return {'files_checked': len(names), 'guard_only': True, 'private_signing_key_absent': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    build, out = args.build.resolve(), args.out.resolve()
    src = build / 'linux'
    if digest(args.upstream) != UPSTREAM_SHA:
        raise SystemExit('Upstream checksum mismatch')
    if (build / 'kernel-release').read_text().strip() != RELEASE:
        raise SystemExit('Unexpected kernel release')
    verify_guard_config((src / '.config').read_text())
    boot = (build / 'smoke/boot.log').read_text()
    smoke = json.loads((build / 'smoke/report.json').read_text())
    expected_artifacts = {'arch/x86/boot/bzImage', '.config', 'net/ipv4/tcp_bbr_guard.ko'}
    if set(smoke['sha256']) != expected_artifacts or any(digest(src / name) != value
                                                       for name, value in smoke['sha256'].items()):
        raise SystemExit('Build changed after smoke test')
    if ('DD_KERNEL_SMOKE_PASS' not in boot or 'DD_KERNEL_SMOKE_FAIL' in boot or
            f'DD_KERNEL_RELEASE={RELEASE} ARCH=x86_64' not in boot or
            'DD_ALGORITHM_OK=bbrguard\n' not in boot or 'DD_GUARD_INDEPENDENT=1' not in boot or
            smoke.get('algorithms') != ['bbrguard'] or smoke.get('removed_algorithms_unavailable') != ['bbr', 'bbr3', 'bbrwan']):
        raise SystemExit('Missing matching Guard-only package smoke result')
    packages = []
    inspections = {}
    for kind in ('image', 'headers'):
        package = build / f'linux-{kind}-{RELEASE}_{VERSION}_amd64.deb'
        fields = subprocess.check_output(['dpkg-deb', '-f', str(package),
                                          'Package', 'Version', 'Architecture'], text=True)
        for expected in (f'Package: linux-{kind}-{RELEASE}', f'Version: {VERSION}', 'Architecture: amd64'):
            if expected not in fields.splitlines():
                raise SystemExit('Unexpected package metadata: ' + package.name)
        packages.append(package)
        inspections[package.name] = inspect_package(package, src, kind == 'image')
        if kind == 'image' and smoke.get('packaged_image', {}).get('sha256') != digest(package):
            raise SystemExit('Image package differs from the boot-tested package')
    vm = json.loads((build / 'vm-evidence/report.json').read_text())
    commit = (build / 'source-commit').read_text().strip()
    current = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != current:
        raise SystemExit('Source commit changed after building')
    run('git', '-C', str(ROOT), 'diff', '--quiet', 'HEAD', '--', '.')
    verify_vm_report(vm, packages, commit)
    out.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='bbrguard-source-') as temporary:
        clean = Path(temporary) / ('linux-' + RELEASE)
        clean.mkdir()
        run('tar', '-xJf', str(args.upstream.resolve()), '--strip-components=1', '-C', str(clean))
        run('python3', str(ROOT / 'tools/kernel_patch.py'), str(clean))
        wan_recovery.apply_kernel_tree(clean)
        changed = {line[6:] for line in (ROOT / 'tools/google-bbr3.patch').read_text().splitlines()
                   if line.startswith('+++ b/')}
        changed.update('net/ipv4/' + name for name in ('Kconfig', 'Makefile',
                       'tcp_bbr_guard.c', 'tcp_bbr_guard_policy.h', 'tcp_bbr_guard_legacy.h'))
        for relative in sorted(changed):
            if digest(clean / relative) != digest(src / relative):
                raise SystemExit('Source differs from build: ' + relative)
        shutil.copyfile(src / '.config', clean / '.config')
        shutil.copyfile(ROOT / 'docs/recovery-build.md', clean / 'BBR-BUILD.md')
        # Only the clean, regenerated source is archived; no build signing key.
        run('tar', '-I', 'xz -T4 -1', '-cf', str(out / (clean.name + '-source.tar.xz')),
            '-C', temporary, clean.name)
    for package in packages:
        shutil.copyfile(package, out / package.name)
    shutil.copyfile(src / '.config', out / 'config-amd64')
    shutil.copyfile(ROOT / 'docs/recovery-build.md', out / 'BUILD.md')
    shutil.copyfile(ROOT / 'bbr.sh', out / 'bbr.sh')
    shutil.copyfile(ROOT / 'dd.sh', out / 'dd.sh')
    shutil.copyfile(build / 'smoke/boot.log', out / 'boot.log')
    shutil.copyfile(build / 'vm-evidence/report.json', out / 'validation.json')
    with tarfile.open(out / 'vm-validation.tar.gz', 'w:gz') as archive:
        for path in sorted((build / 'vm-evidence').iterdir()):
            if path.is_file() and path.suffix in ('.json', '.log'):
                archive.add(path, arcname=path.name)
    manifest = dict(kernel_release=RELEASE, package_version=VERSION, architecture='amd64',
                    status='experimental; see README.md and release validation evidence for limits',
                    source_base_sha256=UPSTREAM_SHA, config_sha256=digest(src / '.config'),
                    compiler=subprocess.check_output(['gcc', '--version'], text=True).splitlines()[0],
                    algorithms=['bbrguard'], removed_modules=['tcp_bbr', 'tcp_bbr3', 'tcp_bbr_wan'],
                    package_inspections=inspections, packaged_boot_smoke=smoke['packaged_image'],
                    installation_validation=vm,
                    source_sha256={name: digest(src / name) for name in sorted(changed)},
                    tooling_sha256={name: digest(ROOT / 'tools' / name) for name in
                                    ('kernel_patch.py', 'wan_recovery.py', 'package_recovery.py')},
                    assets=[dict(name=p.name, bytes=p.stat().st_size, sha256=digest(p)) for p in sorted(out.iterdir())])
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (out / 'SHA256SUMS').write_text(''.join(digest(p) + '  ' + p.name + '\n' for p in sorted(out.iterdir())
                                         if p.name != 'SHA256SUMS'))
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
