"""Boot the full recovery kernel without disks or external network interfaces."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

# Kept here so the current Guard6 check is independent of the retired lab runner.
SMOKE_C = r'''
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/reboot.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <unistd.h>
static void stop(const char *step) {
    perror(step); printf("DD_KERNEL_SMOKE_FAIL: %s\n", step); fflush(stdout);
    sync(); reboot(LINUX_REBOOT_CMD_POWER_OFF); for (;;) pause();
}
int main(void) {
    struct utsname u;
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    int console = open("/dev/console", O_RDWR);
    if (console >= 0) { for (int i = 0; i < 3; i++) dup2(console, i); if (console > 2) close(console); }
    if (uname(&u)) stop("uname");
    printf("DD_KERNEL_RELEASE=%s ARCH=%s\n", u.release, u.machine);
    const char *modules[] = {"/tcp_bbr_guard.ko"};
    const char *names[] = {"bbrguard"};
    for (int i = 0; i < 1; i++) {
        int fd = open(modules[i], O_RDONLY);
        if (fd < 0 || syscall(SYS_finit_module, fd, "", 0)) stop(modules[i]);
        close(fd);
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0 || setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, names[i], strlen(names[i]))) stop(names[i]);
        char actual[32] = {0}; socklen_t len = sizeof(actual);
        if (getsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, actual, &len) || strcmp(actual, names[i])) stop("algorithm mismatch");
        printf("DD_ALGORITHM_OK=%s\n", actual); close(fd);
    }
    const char *removed[] = {"bbr", "bbr3", "bbrwan"};
    for (int i = 0; i < 3; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) stop("guard-only socket");
        if (!setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION, removed[i], strlen(removed[i]))) stop("old algorithm unexpectedly available");
        close(fd);
    }
    printf("DD_GUARD_INDEPENDENT=1\n");
    printf("DD_KERNEL_SMOKE_PASS\n"); fflush(stdout);
    sync(); reboot(LINUX_REBOOT_CMD_POWER_OFF); for (;;) pause();
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    # Compatibility with existing build jobs; Guard is now the only mode.
    parser.add_argument('--guard-only', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--output', type=Path, help='New output directory; existing evidence is never overwritten')
    parser.add_argument('--image-package', type=Path, help='Boot the actual Debian image and its packaged Guard module')
    args = parser.parse_args()
    build = args.build.resolve()
    src, out = build / 'linux', args.output.resolve() if args.output else build / 'smoke'
    out.mkdir(exist_ok=False)
    root = out / 'root'
    for directory in ('dev', 'proc', 'sys'):
        (root / directory).mkdir(parents=True)
    program = SMOKE_C
    algorithms, modules = ['bbrguard'], ['tcp_bbr_guard.ko']
    (out / 'init.c').write_text(program)
    subprocess.run(['gcc', '-static', '-O2', '-Wall', '-Wextra', str(out / 'init.c'), '-o', str(root / 'init')], check=True)
    artifacts = [src / 'arch/x86/boot/bzImage', src / '.config']
    for name in modules:
        path = src / 'net/ipv4' / name
        artifacts.append(path)
        shutil.copyfile(path, root / name)
    kernel = artifacts[0]
    package_report = None
    if args.image_package:
        release = (build / 'kernel-release').read_text().strip()
        package = args.image_package.resolve()
        with tempfile.TemporaryDirectory(prefix='guard6-smoke-package-') as temporary:
            extracted = Path(temporary)
            subprocess.run(['dpkg-deb', '-x', str(package), temporary], check=True)
            packaged_kernel = extracted / 'boot' / ('vmlinuz-' + release)
            if packaged_kernel.read_bytes() != kernel.read_bytes():
                raise ValueError('Packaged kernel does not match build')
            packaged_config = extracted / 'boot' / ('config-' + release)
            if packaged_config.read_bytes() != (src / '.config').read_bytes():
                raise ValueError('Packaged config does not match build')
            candidates = list((extracted / 'lib/modules' / release).rglob('tcp_bbr_guard.ko*'))
            if len(candidates) != 1:
                raise ValueError('Expected exactly one packaged Guard module')
            module = candidates[0]
            destination = root / 'tcp_bbr_guard.ko'
            if module.suffix == '.ko':
                shutil.copyfile(module, destination)
            else:
                decompressors = {'.xz': 'xz', '.gz': 'gzip', '.zst': 'zstd'}
                with destination.open('wb') as stream:
                    subprocess.run([decompressors[module.suffix], '-dc', str(module)], stdout=stream, check=True)
            kernel = out / 'packaged-vmlinuz'
            shutil.copyfile(packaged_kernel, kernel)
            package_report = {'name': package.name, 'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
                              'module_sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
                              'kernel_matches_build': True, 'config_matches_build': True}
    with (out / 'init.cpio').open('wb') as stream:
        files = ['.'] + sorted(str(p.relative_to(root)) for p in root.rglob('*'))
        subprocess.run(['cpio', '-o', '-H', 'newc', '--quiet', '--owner=0:0'], cwd=root,
                       input=('\n'.join(files) + '\n').encode(), stdout=stream, check=True)
    command = ['qemu-system-x86_64', '-machine', 'q35', '-accel', 'kvm', '-accel', 'tcg', '-cpu', 'max',
               '-m', '1024', '-smp', '2', '-nodefaults', '-display', 'none', '-serial', 'stdio',
               '-monitor', 'none', '-nic', 'none', '-no-reboot', '-kernel', str(kernel),
               '-initrd', str(out / 'init.cpio'), '-append', 'console=ttyS0 rdinit=/init panic=-1 quiet loglevel=3']
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    log = result.stdout + result.stderr
    (out / 'boot.log').write_text(log)
    print(log)
    if result.returncode or 'DD_KERNEL_SMOKE_PASS' not in log or 'DD_KERNEL_SMOKE_FAIL' in log:
        raise RuntimeError('Recovery kernel smoke test failed')
    report = dict(diskless=True, external_nics=False, algorithms=algorithms,
                  sha256={str(p.relative_to(src)): hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts})
    if package_report:
        report['packaged_image'] = package_report
        report['removed_algorithms_unavailable'] = ['bbr', 'bbr3', 'bbrwan']
    (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
