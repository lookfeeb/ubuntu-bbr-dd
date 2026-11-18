"""Validate a local Nginx payload in a disposable Ubuntu 24.04 QEMU guest."""
import argparse
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time

from nginx_package import digest

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--base', type=Path, required=True, help='Previously signature-verified Ubuntu 24.04 cloud image')
    parser.add_argument('--base-sha256', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    assets, base, out = args.assets.resolve(), args.base.resolve(), args.out.resolve()
    if not re.fullmatch(r'[a-f0-9]{64}', args.base_sha256) or digest(base) != args.base_sha256:
        raise ValueError('Cloud image SHA-256 mismatch')
    info = json.loads(subprocess.check_output(['qemu-img', 'info', '--output=json', str(base)]))
    if info['format'] != 'qcow2' or 'backing-filename' in info or 'data-file' in info or 'data-file' in info.get('format-specific', {}).get('data', {}):
        raise ValueError('Unexpected backing or data file')
    run('sha256sum', '-c', 'NGINX_SHA256SUMS', cwd=assets)
    out.mkdir(mode=0o700)
    private, evidence = out / 'private', out / 'evidence'
    private.mkdir(mode=0o700)
    evidence.mkdir()
    # Freeze the installer so evidence and guest execution cannot refer to
    # different revisions if the workspace is edited during boot.
    installer = private / 'bbr.sh'
    shutil.copyfile(ROOT / 'bbr.sh', installer)
    disk, seed, key = private / 'guest.qcow2', private / 'seed.img', private / 'id_ed25519'
    run('qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', base, disk, '12G')
    run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', key)
    (private / 'user-data').write_text('#cloud-config\nhostname: nginx-release-lab\nmanage_etc_hosts: true\n'
                                      'disable_root: false\nssh_pwauth: false\nusers:\n  - name: root\n'
                                      '    lock_passwd: true\n    ssh_authorized_keys:\n      - ' + key.with_suffix('.pub').read_text().strip() + '\n')
    (private / 'meta-data').write_text('instance-id: nginx-release-lab\nlocal-hostname: nginx-release-lab\n')
    run('cloud-localds', seed, private / 'user-data', private / 'meta-data')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    options = ['-i', str(key), '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
               '-o', 'StrictHostKeyChecking=accept-new', '-o', f'UserKnownHostsFile={private}/known_hosts',
               '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3']
    ssh_base = ['ssh', *options, '-p', str(port), 'root@127.0.0.1']
    report = dict(status='running', platform='Ubuntu 24.04 amd64, QEMU, 1 GiB, 2 vCPU',
                  base_sha256=args.base_sha256, installer_sha256=digest(installer),
                  payload_sha256=digest(assets / 'nginx-ubuntu-24.04-amd64.tar.gz'), phases=[], seconds={})

    def ssh(script, timeout=900):
        return run(*ssh_base, 'bash -se', input=script, text=True, capture_output=True, timeout=timeout).stdout

    def phase(name, script):
        started = time.monotonic()
        try:
            result = subprocess.run([*ssh_base, 'bash -se'], input=script, text=True, capture_output=True, timeout=900)
        except subprocess.TimeoutExpired as error:
            (evidence / f'{name}.log').write_bytes((error.stdout or b'') + (error.stderr or b'') + b'\nTIMEOUT\n')
            raise
        (evidence / f'{name}.log').write_text(result.stdout + result.stderr)
        report['seconds'][name] = round(time.monotonic() - started, 2)
        result.check_returncode()
        report['phases'].append(name)
        print(f'{name}: PASS ({report["seconds"][name]}s)', flush=True)

    command = ['qemu-system-x86_64', '-machine', 'q35', '-accel', 'kvm', '-accel', 'tcg', '-cpu', 'max',
               '-smp', '2', '-m', '1024', '-display', 'none', '-monitor', 'none', '-serial', f'file:{evidence}/serial.log',
               '-drive', f'file={disk},format=qcow2,if=virtio', '-drive', f'file={seed},format=raw,if=virtio,readonly=on',
               '-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22', '-device', 'virtio-net-pci,netdev=net0']
    with (evidence / 'qemu.log').open('w') as log:
        vm = subprocess.Popen(command, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                if vm.poll() is not None:
                    raise RuntimeError('Guest exited before boot')
                probe = subprocess.run([*ssh_base, 'true'], capture_output=True, timeout=10)
                if probe.returncode == 0:
                    break
                time.sleep(3)
            else:
                raise TimeoutError('Guest SSH did not become ready')
            ssh('cloud-init status --wait\nmkdir -p /root/nginx-test/assets\n')
            for path in (installer, ROOT / 'tools/nginx_probe.py'):
                run('scp', *options, '-P', port, path, 'root@127.0.0.1:/root/nginx-test/', timeout=120)
            for name in ('NGINX_SHA256SUMS', 'nginx-ubuntu-24.04-amd64.tar.gz'):
                run('scp', *options, '-P', port, assets / name, 'root@127.0.0.1:/root/nginx-test/assets/', timeout=120)
            setup = 'cd /root/nginx-test\nexport BBR_DD_AUTO_UPDATE=0 NGINX_PACKAGE_DIR=/root/nginx-test/assets\nsource ./bbr.sh\nrequire_host\n'
            phase('install', setup + 'install_nginx\n'
                  'test ! -e /var/lib/bbr-nginx/swapfile\n'
                  'test -z "$(command -v gcc || true)"\n'
                  'curl -fsS http://127.0.0.1/ | grep -F "Nginx is running."\n')
            phase('protocols', 'cd /root/nginx-test\nexport DEBIAN_FRONTEND=noninteractive\n'
                  'apt-get install -y --no-install-recommends python3-aioquic brotli\n'
                  'python3 -B nginx_probe.py\n')
            phase('reinstall', setup + 'sha256sum /etc/nginx/nginx.conf /etc/nginx/conf.d/probe.conf /usr/share/GeoIP/GeoLite2-City.mmdb > /root/preserved.sha256\n'
                  'install_nginx\nsha256sum -c /root/preserved.sha256\n'
                  'systemctl is-active --quiet nginx\n')
            # Fail the actual new config test once; the previous running service
            # and its files must be restored by the real EXIT trap.
            phase('rollback', setup + r'''
sha256sum /usr/sbin/nginx /usr/local/nginx/modules/*.so /etc/nginx/nginx.conf /var/lib/bbr-nginx/installed.json > /root/before-rollback.sha256
nginx_service() { printf '[Unit]\nDescription=Broken probe\n[Service]\nType=forking\nExecStart=/bin/false\n[Install]\nWantedBy=multi-user.target\n'; }
set +e
(set -e; install_nginx)
result=$?
set -e
test "$result" -ne 0
sha256sum -c /root/before-rollback.sha256
systemctl is-active --quiet nginx
curl -fsS http://127.0.0.1/ | grep -F 'Nginx is running.'
''')
            phase('final', 'cd /root/nginx-test\npython3 -B nginx_probe.py\n'
                  'test ! -e /var/lib/bbr-nginx/swapfile\nnginx -V\n')
            report['status'] = 'pass'
        except Exception:
            report['status'] = 'fail'
            raise
        finally:
            if vm.poll() is None:
                vm.terminate()
                try:
                    vm.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    vm.kill()
                    vm.wait()
            (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
