"""Boot, install and roll back local release packages in a disposable guest.

No package installation, module loading or boot changes occur on the host.
Only the explicitly listed evidence files are published; disk and keys stay private.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time

import dd_patch
from package_recovery import RELEASE, VERSION, digest

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    commit = (build / 'source-commit').read_text().strip()
    current = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != current:
        raise SystemExit('Build belongs to a different source commit')
    run('git', '-C', ROOT, 'diff', '--quiet', 'HEAD', '--', '.')
    work, evidence = build / 'vm-private', build / 'vm-evidence'
    work.mkdir(mode=0o700)
    evidence.mkdir()
    shutil.copyfile(ROOT / 'tools/ubuntu-cloudimage-keyring.gpg', work / 'ubuntu-cloudimage-keyring.gpg')
    dd_patch.image_metadata(work, '24.04', 'amd64')
    url = (work / 'image-url').read_text().strip()
    expected = re.findall(r'^([a-f0-9]{64}) [ *]' + re.escape(url.rsplit('/', 1)[1]) + r'$',
                          (work / 'SHA256SUMS').read_text(), re.M)
    if len(expected) != 1:
        raise ValueError('Missing unique signed image checksum')
    base = work / 'base.img'
    run('curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
        '--retry', '3', '--max-time', '1800', '--output', base, url)
    if digest(base) != expected[0] or base.stat().st_size != int((work / 'image-bytes').read_text()):
        raise ValueError('Cloud image checksum or size mismatch')
    info = json.loads(subprocess.check_output(['qemu-img', 'info', '--output=json', str(base)]))
    if (info['format'] != 'qcow2' or 'backing-filename' in info or 'data-file' in info or
            'data-file' in info.get('format-specific', {}).get('data', {})):
        raise ValueError('Unexpected cloud image backing file')
    run('qemu-img', 'check', '-f', 'qcow2', base)
    disk = work / 'guest.qcow2'
    run('qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', base, disk, '20G')
    key = work / 'id_ed25519'
    run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', key)
    user_data = work / 'user-data'
    user_data.write_text('#cloud-config\nhostname: guard-release-lab\nmanage_etc_hosts: true\n'
                         'disable_root: false\nssh_pwauth: false\nusers:\n  - name: root\n'
                         '    lock_passwd: true\n    ssh_authorized_keys:\n      - ' +
                         key.with_suffix('.pub').read_text().strip() + '\n')
    metadata = work / 'meta-data'
    metadata.write_text('instance-id: guard-release-lab\nlocal-hostname: guard-release-lab\n')
    seed = work / 'seed.img'
    run('cloud-localds', seed, user_data, metadata)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    ssh_options = ['-i', str(key), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                   '-o', 'StrictHostKeyChecking=accept-new', '-o', f'UserKnownHostsFile={work}/known_hosts',
                   '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4']
    ssh_base = ['ssh', *ssh_options, '-p', str(port), 'root@127.0.0.1']
    command = ['qemu-system-x86_64', '-machine', 'q35', '-accel', 'kvm', '-accel', 'tcg',
               '-cpu', 'max', '-smp', '2', '-m', '2048', '-display', 'none', '-monitor', 'none',
               '-serial', f'file:{evidence}/serial.log',
               '-drive', f'file={disk},format=qcow2,if=virtio',
               '-drive', f'file={seed},format=raw,if=virtio,readonly=on',
               '-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22',
               '-device', 'virtio-net-pci,netdev=net0']
    report = dict(status='running', kernel_release=RELEASE, package_version=VERSION,
                  commit=commit, build_environment='local Linux / WSL; isolated QEMU guest',
                  platform='Ubuntu 24.04 amd64, QEMU, 2 GiB, VirtIO, BIOS',
                  cloud_image=dict(url=url, sha256=expected[0]), packages={}, phases=[])
    for kind in ('image', 'headers'):
        package = build / f'linux-{kind}-{RELEASE}_{VERSION}_amd64.deb'
        report['packages'][package.name] = digest(package)

    def ssh(script, timeout=900):
        return run(*ssh_base, 'bash -se', input=script, text=True, capture_output=True, timeout=timeout).stdout

    def wait_boot(previous=None):
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            if vm.poll() is not None:
                raise RuntimeError('QEMU exited before SSH became ready')
            try:
                result = subprocess.run([*ssh_base, 'cat /proc/sys/kernel/random/boot_id'],
                                        text=True, capture_output=True, timeout=15)
            except subprocess.TimeoutExpired:
                continue
            boot = result.stdout.strip()
            if result.returncode == 0 and re.fullmatch(r'[a-f0-9-]{36}', boot) and boot != previous:
                return boot
            time.sleep(5)
        raise TimeoutError('New guest boot did not become SSH-accessible')

    def phase(name):
        # Save failures as well as successes; no credentials are passed in scripts.
        try:
            result = subprocess.run([*ssh_base, 'bash', '/root/guard-release/guest.sh', name],
                                    text=True, capture_output=True, timeout=1500)
        except subprocess.TimeoutExpired as error:
            (evidence / f'{name}.log').write_bytes((error.stdout or b'') + (error.stderr or b'') + b'\nTIMEOUT\n')
            raise
        (evidence / f'{name}.log').write_text(result.stdout + result.stderr)
        print(result.stdout + result.stderr, flush=True)
        result.check_returncode()
        if f'GUARD_RELEASE_PHASE_PASS={name}\n' not in result.stdout:
            raise RuntimeError('Missing guest phase marker: ' + name)
        report['phases'].append(name)

    with (evidence / 'qemu.log').open('w') as log:
        vm = subprocess.Popen(command, stdout=log, stderr=log)
        try:
            boot = wait_boot()
            ssh('cloud-init status --wait\nmkdir -p /root/guard-release/packages\ntouch /root/guard-release/guest-marker\n')
            copies = [(ROOT / 'bbr.sh', 'bbr.sh'), (ROOT / 'tools/release/guest.sh', 'guest.sh')]
            copies += [(build / name, 'packages/' + name) for name in report['packages']]
            for source, target in copies:
                run('scp', *ssh_options, '-P', str(port), source,
                    'root@127.0.0.1:/root/guard-release/' + target, timeout=600)
            sums = ''.join(value + '  packages/' + name + '\n' for name, value in report['packages'].items())
            ssh("cat > /root/guard-release/packages.sha256 <<'SUMS'\n" + sums + 'SUMS\n' +
                "printf '%s\\n' '" + RELEASE + "' > /root/guard-release/packages/kernel-release\n")
            phase('setup')
            report['original_kernel'] = ssh('cat /root/guard-release/original-kernel\n').strip()
            phase('install')
            for phases in [('new', 'rollback'), ('old',), ('return',), ('clean',)]:
                ssh('systemd-run --on-active=2s /usr/sbin/reboot\n')
                new_boot = wait_boot(boot)
                report.setdefault('boots', []).append(dict(id=new_boot, ssh=True))
                boot = new_boot
                for name in phases:
                    phase(name)
            report['status'] = 'pass'
        except Exception:
            report['status'] = 'fail'
            raise
        finally:
            if vm.poll() is None:
                vm.terminate()
                try:
                    vm.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    vm.kill()
                    vm.wait()
            (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            # Keys and disposable guest data are never copied to evidence/assets.
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
