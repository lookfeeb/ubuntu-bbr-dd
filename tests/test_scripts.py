"""No host kernel, network configuration, bootloader or disks are modified."""
import hashlib
import http.server
import importlib.util
from pathlib import Path
import shlex
import subprocess
import socket
import re
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Harness(unittest.TestCase):
    script = 'bbr.sh'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vps-scripts-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.config = self.root / 'config'
        self.config.mkdir()
        self.sys = self.root / 'sys'
        self.sys.mkdir()
        self.prefix = f'''
source {shlex.quote(str(ROOT / self.script))}
STATE={shlex.quote(str(self.state))}
SYS_ROOT={shlex.quote(str(self.sys))}
SYSCTL_FILE={shlex.quote(str(self.config / 'sysctl.conf'))}
MODULES_FILE={shlex.quote(str(self.config / 'modules.conf'))}
export STATE
'''

    def shell(self, code, success=True):
        r = subprocess.run(['bash', '-c', self.prefix + code], capture_output=True, text=True, timeout=20)
        if success:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        return r

    def cli(self, *args):
        return subprocess.run(['bash', str(ROOT / self.script), *args], capture_output=True, text=True, timeout=15)

    def nic(self, name, module):
        device = self.sys / 'class/net' / name / 'device/driver'
        device.mkdir(parents=True)
        target = self.sys / 'module' / module
        target.mkdir(parents=True, exist_ok=True)
        (device / 'module').symlink_to(target)


class SharedTests:
    def test_status_summarizes_global_addresses_and_keeps_gvnic_identity(self):
        self.nic('ens4', 'gve')
        result = self.shell(r'''
inspect_cloud() { echo UNEXPECTED_INSTALL_CHECK; exit 99; }
ip() {
    case "$*" in
        '-o -4 address show scope global')
            echo '2: ens4 inet 10.170.0.3/32 brd 10.170.0.3 scope global ens4' ;;
        '-o -6 address show scope global')
            echo '2: ens4 inet6 2600:1900:41a0:37::/128 scope global dynamic' ;;
        *) echo UNEXPECTED_IP_QUERY; exit 99 ;;
    esac
}
cloud_status
''')
        self.assertIn('平台：GCP /', result.stdout)
        self.assertIn('网卡：ens4 / gve（gVNIC）', result.stdout)
        self.assertIn('网卡 IPv4：10.170.0.3/32 (ens4)', result.stdout)
        self.assertIn('网卡 IPv6：2600:1900:41a0:37::/128 (ens4)', result.stdout)
        self.assertNotIn('UNEXPECTED', result.stdout)
        self.assertNotIn('Guest Agent', result.stdout)
        self.assertFalse(list(self.state.iterdir()))

    def test_source_is_inert(self):
        self.shell('true')
        self.assertEqual(list(self.state.iterdir()), [])

    def test_gvnic_recognition_does_not_depend_on_interface_name(self):
        self.nic('customwan9', 'gve')
        self.nic('ens4', 'virtio_net')
        result = self.shell('detect_nics; detect_cloud; echo "$CLOUD $HAS_GVNIC ${NIC_DRIVERS[*]}"')
        self.assertIn('gcp 1', result.stdout)
        self.assertIn('virtio_net', result.stdout)

    def test_virtio_is_not_gvnic(self):
        self.nic('gve0', 'virtio_net')
        result = self.shell('detect_nics; detect_cloud; echo "$CLOUD $HAS_GVNIC"')
        self.assertEqual(result.stdout.strip(), 'generic 0')

    def test_aws_detection_does_not_guess_lightsail(self):
        dmi = self.sys / 'class/dmi/id'
        dmi.mkdir(parents=True)
        (dmi / 'sys_vendor').write_text('Amazon EC2')
        self.assertEqual(self.shell('detect_cloud; echo "$CLOUD"').stdout.strip(), 'aws')
        self.assertEqual(self.shell('CLOUD=lightsail; detect_cloud; echo "$CLOUD"').stdout.strip(), 'lightsail')

    def test_cloud_mismatch_refused(self):
        self.nic('eth0', 'gve')
        self.shell('CLOUD=oci; detect_nics; detect_cloud', success=False)

    def test_corrupt_cache_is_refused(self):
        (self.state / 'payload').write_text('untrusted')
        self.shell('download_verified https://example.invalid "$STATE/payload" ' + 'a' * 64, success=False)

    def test_download_verified_then_cache_used(self):
        sha = hashlib.sha256(b'trusted\n').hexdigest()
        self.shell(r'''
curl() {
  while (( $# )); do
    if [[ $1 == --output ]]; then printf 'trusted\n' > "$2"; return; fi
    shift
  done
  return 1
}
''' + f'\ndownload_verified https://example.invalid "$STATE/payload" {sha}\n'
                   + 'curl() { exit 90; }\n'
                   + f'download_verified https://example.invalid "$STATE/payload" {sha}')
        self.assertEqual((self.state / 'payload').read_bytes(), b'trusted\n')

    def test_embedded_cloud_functions_match_source(self):
        script = (ROOT / self.script).read_text()
        expected = (ROOT / 'tools/cloud_helpers.inc').read_text().strip()
        self.assertIn(expected, script)

    def test_embedded_host_helpers_match_source(self):
        self.assertIn((ROOT / 'tools/host_helpers.inc').read_text().strip(),
                      (ROOT / self.script).read_text())

    def test_download_refuses_symlink_directory_and_invalid_hash(self):
        target = self.state / 'owned'
        target.write_bytes(b'keep')
        output = self.state / 'payload'
        output.symlink_to(target)
        digest = hashlib.sha256(b'keep').hexdigest()
        self.shell(f'download_verified https://example.invalid "$STATE/payload" {digest}', success=False)
        self.assertEqual(target.read_bytes(), b'keep')
        output.unlink()
        output.mkdir()
        self.shell(f'download_verified https://example.invalid "$STATE/payload" {digest}', success=False)
        self.shell('curl() { touch "$STATE/network"; }; download_verified https://example.invalid "$STATE/new" bad', success=False)
        self.assertFalse((self.state / 'network').exists())


class TestBBR(SharedTests, Harness):
    script = 'bbr.sh'

    def test_preview_has_no_mutations(self):
        self.shell(r'''
require_host() { exit 81; }
apt-get() { exit 82; }
curl() { exit 83; }
systemctl() { exit 84; }
prebuilt_arch_check() { return 0; }
for ACTION in install build enable restore cleanup; do DRY_RUN=1; dispatch; done
''')
        self.assertEqual(list(self.state.iterdir()), [])

    def test_invalid_parameters(self):
        for args in [('reinstall',), ('install', '--jobs', '0'), ('install', '--profile', 'fast'),
                     ('install', '--version', '22.04'), ('install', '--jobs', '2;reboot'),
                     ('benchmark',), ('benchmark', '--server', ';id'), ('install', '--cloud', 'invalid')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.cli(*args, '--dry-run').returncode, 0)

    def test_install_downloads_and_build_is_explicit(self):
        result = self.shell(r'''
require_host() { return 0; }
install_prebuilt_kernel() { echo prebuilt; }
build_kernel() { echo source; }
ACTION=install; dispatch
ACTION=build; JOBS=2; dispatch
''')
        self.assertEqual(result.stdout.splitlines(), ['prebuilt', 'source'])
        self.assertNotEqual(self.cli('install', '--jobs', '2', '--dry-run').returncode, 0)

    def test_arm64_prebuilt_refused_before_mutation(self):
        result = self.shell(r'''
uname() { echo aarch64; }
kernel_preflight() { touch "$STATE/mutated"; }
build_kernel() { touch "$STATE/compiled"; }
install_prebuilt_kernel
''', success=False)
        self.assertIn('仅支持 amd64', result.stderr)
        self.assertFalse((self.state / 'mutated').exists())
        self.assertFalse((self.state / 'compiled').exists())

    def test_mixed_userspace_architecture_refused(self):
        self.shell('uname() { echo x86_64; }; dpkg() { echo i386; }; prebuilt_arch_check', success=False)

    def prebuilt_download_stubs(self, bad_field=''):
        return 'BAD_FIELD=' + shlex.quote(bad_field) + r'''
PREBUILT_IMAGE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PREBUILT_HEADERS_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
download_verified() {
    printf '%s\n' "$1 $3" >> "$STATE/downloads"
    touch "$2"
}
dpkg-deb() {
    [[ $3 != "$BAD_FIELD" ]] || { echo invalid; return; }
    case "$3" in
        Package)
            case "$2" in *linux-image-*) echo "linux-image-$PREBUILT_RELEASE";;
                *linux-headers-*) echo "linux-headers-$PREBUILT_RELEASE";; esac ;;
        Version) echo "$PREBUILT_VERSION" ;;
        Architecture) echo "$PREBUILT_ARCH" ;;
    esac
}
'''

    def test_prebuilt_downloads_pinned_pair_and_checks_metadata(self):
        self.shell(self.prebuilt_download_stubs() + '\nfetch_prebuilt_packages "$STATE"')
        downloads = (self.state / 'downloads').read_text().splitlines()
        self.assertEqual(len(downloads), 2)
        version = self.shell('printf "%s" "$TOOL_VERSION"').stdout
        self.assertTrue(all(f'/releases/download/v{version}/' in s for s in downloads))
        self.assertFalse(any('libc-dev' in s for s in downloads))
        self.assertEqual((self.state / 'kernel-release').read_text().strip(), '7.3.5-bbrguard7r2only-674859761ded')

    def test_prebuilt_wrong_metadata_never_marks_ready(self):
        for field in ['Package', 'Version', 'Architecture']:
            with self.subTest(field=field):
                self.shell(self.prebuilt_download_stubs(field) + '\nfetch_prebuilt_packages "$STATE"', success=False)
                self.assertFalse((self.state / 'kernel-release').exists())

    def test_prebuilt_failed_download_does_not_call_apt(self):
        self.shell(r'''
prebuilt_arch_check() { return 0; }
kernel_preflight() { return 0; }
prebuilt_resources() { return 0; }
load_prebuilt_checksums() { return 17; }
download_verified() { return 17; }
apt-get() { touch "$STATE/apt-called"; }
install_built_kernel() { touch "$STATE/installed"; }
install_prebuilt_kernel
''', success=False)
        self.assertFalse((self.state / 'apt-called').exists())
        self.assertFalse((self.state / 'installed').exists())

    def test_prebuilt_missing_active_driver_prevents_install(self):
        self.nic('custom9', 'missing_nic')
        result = self.shell(r'''
detect_nics
dpkg-deb() { return 0; }
modinfo() { [[ ${@: -1} != missing_nic ]]; }
verify_prebuilt_drivers "$STATE"
touch "$STATE/installed"
''', success=False)
        self.assertIn('missing_nic', result.stderr)
        self.assertFalse((self.state / 'installed').exists())
        self.assertEqual(list(self.state.glob('check.*')), [])

    def test_prebuilt_extract_failure_and_termination_remove_only_staging(self):
        package = self.state / 'saved.deb'
        package.write_bytes(b'preserved')
        for failure in ('return 19', 'kill -TERM "$BASHPID"'):
            with self.subTest(failure=failure):
                self.shell('dpkg-deb() { ' + failure + '; }; modinfo() { :; };\n'
                           'verify_prebuilt_drivers "$STATE"', success=False)
                self.assertEqual(list(self.state.glob('check.*')), [])
                self.assertEqual(package.read_bytes(), b'preserved')

    def test_prebuilt_retries_reuse_verified_pair_and_stop_before_apt(self):
        digest = hashlib.sha256(b'package').hexdigest()
        setup = f'PREBUILT_IMAGE_SHA256={digest}; PREBUILT_HEADERS_SHA256={digest}\n' + r'''
load_prebuilt_checksums() { :; }
prebuilt_arch_check() { :; }
kernel_preflight() { :; }
prebuilt_resources() { :; }
verify_prebuilt_metadata() { :; }
curl() {
    echo download >> "$STATE/download-count"
    while (( $# )); do
        if [[ $1 == --output ]]; then printf package > "$2"; return; fi
        shift
    done
    return 1
}
dpkg-deb() { :; }
modinfo() { return 1; }
apt-get() { touch "$STATE/apt-called"; }
install_built_kernel() { touch "$STATE/installed"; }
install_prebuilt_kernel
'''
        self.shell(setup, success=False)
        self.shell(setup, success=False)
        self.assertEqual(len((self.state / 'download-count').read_text().splitlines()), 2)
        self.assertEqual(len(list(self.state.rglob('*.deb'))), 2)
        self.assertEqual(list(self.state.rglob('check.*')), [])
        self.assertFalse((self.state / 'apt-called').exists())
        self.assertFalse((self.state / 'installed').exists())

        self.shell(setup.replace('modinfo() { return 1; }', 'modinfo() { return 0; }'))
        self.assertTrue((self.state / 'installed').exists())
        self.assertEqual(len((self.state / 'download-count').read_text().splitlines()), 2)
        self.assertEqual(list(self.state.rglob('check.*')), [])

    def test_prebuilt_checks_active_storage_driver(self):
        device = self.sys / 'bus/virtio/devices/virtio0'
        device.mkdir(parents=True)
        driver = self.sys / 'bus/virtio/drivers/virtio_blk'
        driver.mkdir(parents=True)
        module = self.sys / 'module/virtio_blk'
        module.mkdir(parents=True)
        (driver / 'module').symlink_to(module)
        (device / 'driver').symlink_to(driver)
        result = self.shell(r'''
dpkg-deb() { return 0; }
modinfo() { [[ ${@: -1} != virtio_blk ]]; }
verify_prebuilt_drivers "$STATE"
''', success=False)
        self.assertIn('virtio_blk', result.stderr)

    def sysctl_stub(self, failure=False):
        (self.state / 'cc').write_text('cubic\n')
        (self.state / 'qdisc').write_text('fq_codel\n')
        return f'FAIL_BBR={int(failure)}\nPROFILE=recovery; select_profile\n' + r'''
modprobe() { return 0; }
sysctl() {
  if [[ $1 == -n ]]; then
    case "$2" in
      net.ipv4.tcp_available_congestion_control) echo 'reno cubic bbrguard' ;;
      net.ipv4.tcp_congestion_control) cat "$STATE/cc" ;;
      net.core.default_qdisc) cat "$STATE/qdisc" ;;
    esac
  elif [[ $1 == -w ]]; then
    shift
    local item
    for item in "$@"; do
      case "$item" in
        net.ipv4.tcp_congestion_control=bbrguard)
          [[ $FAIL_BBR == 0 ]] || return 1
          echo bbrguard > "$STATE/cc" ;;
        net.ipv4.tcp_congestion_control=*) echo "${item#*=}" > "$STATE/cc" ;;
        net.core.default_qdisc=*) echo "${item#*=}" > "$STATE/qdisc" ;;
        *) return 1 ;;
      esac
    done
  fi
}
'''

    def test_guard_enable_repeat_restore(self):
        (self.config / 'sysctl.conf').write_text('# original\n')
        self.shell(self.sysctl_stub() + '\nenable_bbr; enable_bbr; restore_bbr')
        self.assertEqual((self.config / 'sysctl.conf').read_text(), '# original\n')
        self.assertFalse((self.config / 'modules.conf').exists())
        self.assertEqual((self.state / 'cc').read_text().strip(), 'cubic')

    def test_failed_enable_restores_runtime_and_files(self):
        self.shell(self.sysctl_stub(True) + '\nenable_bbr', success=False)
        self.assertFalse((self.config / 'sysctl.conf').exists())
        self.assertEqual((self.state / 'qdisc').read_text().strip(), 'fq_codel')
        self.assertEqual(list(self.state.glob('bbr-transaction.*')), [])

    def test_readback_failure_rolls_back_and_cleans_transaction(self):
        (self.config / 'sysctl.conf').write_text('# before\n')
        stub = self.sysctl_stub().replace('echo bbrguard > "$STATE/cc"', ': # simulate write accepted but not applied')
        self.shell(stub + '\nenable_bbr', success=False)
        self.assertEqual((self.config / 'sysctl.conf').read_text(), '# before\n')
        self.assertEqual((self.state / 'cc').read_text().strip(), 'cubic')
        self.assertEqual((self.state / 'qdisc').read_text().strip(), 'fq_codel')
        self.assertFalse((self.config / 'modules.conf').exists())
        self.assertEqual(list(self.state.glob('bbr-transaction.*')), [])

    def test_second_config_rename_failure_rolls_back_and_cleans_files(self):
        (self.config / 'sysctl.conf').write_text('# before\n')
        code = self.sysctl_stub() + r'''
mv() {
    if [[ ${!#} == "$MODULES_FILE" ]]; then return 8; fi
    command mv "$@"
}
enable_bbr
'''
        self.shell(code, success=False)
        self.assertEqual((self.config / 'sysctl.conf').read_text(), '# before\n')
        self.assertFalse((self.config / 'modules.conf').exists())
        self.assertEqual(list(self.config.glob('.bbr-kernel.*')), [])
        self.assertEqual(list(self.state.glob('bbr-transaction.*')), [])

    def test_old_profiles_rejected_without_configuration_changes(self):
        for profile in ('upstream', 'wan'):
            self.shell(self.sysctl_stub() + f'\nPROFILE={profile}; select_profile; enable_bbr', success=False)
            self.assertEqual((self.state / 'cc').read_text().strip(), 'cubic')
            self.assertFalse((self.config / 'modules.conf').exists())

    def test_recovery_profile_enables_matching_module_and_restores(self):
        stub = self.sysctl_stub()
        self.shell(stub + '\nPROFILE=recovery; select_profile; enable_bbr')
        self.assertEqual((self.state / 'cc').read_text().strip(), 'bbrguard')
        self.assertIn('tcp_bbr_guard', (self.config / 'modules.conf').read_text())
        self.shell(stub + '\nrestore_bbr')
        self.assertEqual((self.state / 'cc').read_text().strip(), 'cubic')

    def test_recovery_installs_matching_prebuilt_and_supports_source_build(self):
        result = self.shell(r'''
PROFILE=recovery; select_profile; ACTION=install
require_host() { :; }
install_prebuilt_kernel() { echo "$ALGORITHM $BBR_MODULE $PREBUILT_RELEASE"; }
dispatch
''')
        self.assertEqual(result.stdout.strip(), 'bbrguard tcp_bbr_guard 7.3.5-bbrguard7r2only-674859761ded')
        result = self.shell(r'''
PROFILE=recovery; select_profile; ACTION=build
require_host() { :; }
build_kernel() { echo "$ALGORITHM $BBR_MODULE"; }
dispatch
''')
        self.assertEqual(result.stdout.strip(), 'bbrguard tcp_bbr_guard')

    def test_prebuilt_guard_module_required_before_installation(self):
        result = self.shell(r'''
dpkg-deb() { return 0; }
modinfo() { [[ ${@: -1} != tcp_bbr_guard ]]; }
verify_prebuilt_drivers "$STATE"
touch "$STATE/installed"
''', success=False)
        self.assertIn('tcp_bbr_guard', result.stderr)
        self.assertFalse((self.state / 'installed').exists())

    def test_recovery_missing_module_does_not_write_configuration(self):
        result = self.shell(self.sysctl_stub() + r'''
PROFILE=recovery; select_profile
modprobe() { [[ $1 != tcp_bbr_guard ]]; }
enable_bbr
''', success=False)
        self.assertIn('tcp_bbr_guard', result.stderr)
        self.assertFalse((self.config / 'sysctl.conf').exists())

    def test_missing_guard_module_refuses_boot_setup(self):
        result = self.shell(r'''
modinfo() { [[ ${@: -1} != tcp_bbr_guard ]]; }
install() { exit 99; }
verify_new_drivers 7.3.5-fixture
''', success=False)
        self.assertIn('tcp_bbr_guard', result.stderr)

    def test_prebuilt_does_not_require_original_algorithms(self):
        self.shell(r'''
dpkg-deb() { :; }
modinfo() { [[ ${@: -1} == tcp_bbr_guard || ${@: -1} == sch_fq ]]; }
verify_prebuilt_drivers "$STATE"
''')

    def test_cleanup_never_runs_on_old_kernel(self):
        (self.state / 'kernel-release').write_text('6.13.7-never-running\n')
        (self.state / 'cleanup-pending').touch()
        r = self.shell('apt-get() { touch "$STATE/purged"; }; cleanup_old_kernels', success=False)
        self.assertIn('尚未成功启动', r.stderr)
        self.assertFalse((self.state / 'purged').exists())

    def purge_stubs(self, simulation=None):
        if simulation is None:
            simulation = 'Purg linux-image-6.8.0-99-gcp [1]\nPurg linux-gcp [1]\nPurg linux-tools-6.8.0-99-gcp [1]\n'
        return r'''
dpkg-query() {
  printf 'linux-image-6.13.7-bbrwan1\tinstalled\nlinux-headers-6.13.7-bbrwan1\tinstalled\nlinux-image-6.8.0-99-gcp\tinstalled\nlinux-gcp\tinstalled\nlinux-tools-6.8.0-99-gcp\tinstalled\nlinux-tools-common\tinstalled\nlinux-libc-dev\tinstalled\n'
}
apt-mark() { return 0; }
''' + f'SIMULATION={shlex.quote(simulation)}\n' + r'''
apt-get() {
  if [[ $1 == --simulate ]]; then echo "$SIMULATION";
  else printf '%s\n' "$@" > "$STATE/purged"; fi
}
'''

    def test_cleanup_only_removes_old_kernel_packages(self):
        self.shell(self.purge_stubs() + '\npurge_old_kernel_packages 6.13.7-bbrwan1')
        args = (self.state / 'purged').read_text()
        self.assertIn('linux-image-6.8.0-99-gcp', args)
        self.assertIn('linux-gcp', args)
        self.assertIn('linux-tools-6.8.0-99-gcp', args)
        self.assertNotIn('linux-tools-common', args)
        self.assertNotIn('6.13.7-bbrwan1', args)
        self.assertNotIn('linux-libc-dev', args)

    def test_purge_simulation_rejects_new_kernel_and_other_packages(self):
        for package in ['linux-image-6.13.7-bbrwan1', 'linux-tools-common', 'systemd', 'openssh-server']:
            with self.subTest(package=package):
                self.shell(self.purge_stubs('Remv ' + package + ' [1]') + '\npurge_old_kernel_packages 6.13.7-bbrwan1', success=False)
                self.assertFalse((self.state / 'purged').exists())

    def test_cleanup_removes_previous_kernel_and_protects_only_current(self):
        self.shell(self.purge_stubs('Purg linux-gcp [1]') + r'''
apt-mark() { printf '%s\n' "$@" > "$STATE/protected"; }
purge_old_kernel_packages 6.13.7-bbrwan1
for package in linux-image-6.8.0-99-gcp linux-image-unsigned-6.8.0-99-gcp linux-modules-6.8.0-99-gcp linux-modules-extra-6.8.0-99-gcp linux-headers-6.8.0-99 linux-headers-6.8.0-99-gcp linux-tools-6.8.0-99-gcp; do
    kernel_package_for_release "$package:amd64" 6.8.0-99-gcp || exit 92
done
''')
        args = (self.state / 'purged').read_text()
        self.assertIn('linux-gcp', args)
        self.assertIn('6.8.0-99', args)
        self.assertNotIn('6.8.0-99', (self.state / 'protected').read_text())
        self.assertIn('linux-headers-6.13.7-bbrwan1', (self.state / 'protected').read_text())

    def test_purge_dependency_cannot_remove_current_components(self):
        for package in ['linux-image-6.13.7-bbrwan1', 'linux-image-unsigned-6.13.7-bbrwan1',
                        'linux-modules-6.13.7-bbrwan1', 'linux-headers-6.13.7-bbrwan1',
                        'linux-headers-6.13.7', 'linux-modules-extra-6.13.7-bbrwan1']:
            with self.subTest(package=package):
                self.shell(self.purge_stubs('Remv ' + package + ' [1]') +
                           '\npurge_old_kernel_packages 6.13.7-bbrwan1', success=False)
                self.assertFalse((self.state / 'purged').exists())

    def test_gcp_source_flavored_dependencies_survive_cleanup(self):
        self.shell(r'''
dpkg-query() {
    printf '%s\tinstalled\n' linux-image-7.3.5-test linux-headers-7.3.5-test \
        linux-image-7.0.0-1017-gcp linux-headers-7.0.0-1017-gcp \
        linux-gcp-7.0-headers-7.0.0-1017 linux-gcp-7.0-tools-7.0.0-1017 \
        linux-gcp-7.0-headers-7.0.0-1016 linux-gcp-7.0-tools-7.0.0-1016 linux-gcp
}
apt-mark() { printf '%s\n' "$@" > "$STATE/protected"; }
apt-get() {
    if [[ $1 == --simulate ]]; then
        for package in "$@"; do
            # Model the real GCP dependency: removing shared headers removes
            # the current kernel's architecture-specific headers as well.
            if [[ $package == linux-gcp-7.0-headers-7.0.0-1017 ]]; then
                echo 'Remv linux-headers-7.0.0-1017-gcp [1]'
            fi
        done
        echo 'Purg linux-gcp [1]'
    else
        printf '%s\n' "$@" > "$STATE/purged"
    fi
}
purge_old_kernel_packages 7.0.0-1017-gcp
''')
        protected = (self.state / 'protected').read_text().splitlines()
        purged = (self.state / 'purged').read_text().splitlines()
        for kind in ('headers', 'tools'):
            shared = f'linux-gcp-7.0-{kind}-7.0.0-1017'
            self.assertIn(shared, protected)
            self.assertNotIn(shared, purged)
            self.assertIn(f'linux-gcp-7.0-{kind}-7.0.0-1016', purged)
        self.assertIn('linux-gcp', purged)

    def test_shared_kernel_packages_match_exact_abi_with_multiarch_flavors(self):
        self.shell(r'''
kernel_package_for_release linux-gcp-7.0-headers-7.0.0-1017:arm64 7.0.0-1017-gcp-64k
kernel_package_for_release linux-gcp-7.0-tools-7.0.0-1017 7.0.0-1017-gcp
if kernel_package_for_release linux-gcp-7.0-headers-7.0.0-10170 7.0.0-1017-gcp; then exit 91; fi
if kernel_package_for_release linux-gcp-7.0-tools-7.0.0-1016 7.0.0-1017-gcp; then exit 92; fi
''')

    def test_purge_rejects_unexpected_replacement_installation(self):
        self.shell(self.purge_stubs('Inst linux-image-6.8.0-100-gcp (1)') +
                   '\npurge_old_kernel_packages 6.13.7-bbrwan1', success=False)
        self.assertFalse((self.state / 'purged').exists())

    def test_grub_uses_version_id_not_menu_position(self):
        grub = self.root / 'grub.cfg'
        grub.write_text("submenu 'Advanced' $menuentry_id_option 'gnulinux-advanced-1234' {\n"
                        "menuentry 'Ubuntu, Linux 6.13.7-bbrwan1' $menuentry_id_option 'gnulinux-6.13.7-bbrwan1-advanced-1234' {\n}")
        r = self.shell(f'grub_entry_for 6.13.7-bbrwan1 {shlex.quote(str(grub))}')
        self.assertEqual(r.stdout.strip(), 'gnulinux-advanced-1234>gnulinux-6.13.7-bbrwan1-advanced-1234')

    def test_grub_fragment_disables_cloud_initrdless_boot(self):
        result = self.shell(r'''
GRUB_FORCE_PARTUUID=cloud-root-partition
write_grub_default_config 'submenu>new-kernel' "$STATE/grub.cfg"
source "$STATE/grub.cfg"
[[ -z $GRUB_FORCE_PARTUUID ]]
printf '%s\n' "$GRUB_DEFAULT"
''')
        self.assertEqual(result.stdout.strip(), 'submenu>new-kernel')

    def test_embedded_patch_matches_source(self):
        embedded = (ROOT / 'bbr.sh').read_text()
        generator = (ROOT / 'tools/wan_recovery.py').read_text().split("if __name__ == '__main__':", 1)[0].strip()
        self.assertEqual(embedded.count(generator), 1)
        self.assertNotIn('types.ModuleType', embedded)

    def test_compile_failure_is_not_swallowed_by_tee(self):
        source = self.state / 'linux'
        (source / 'scripts').mkdir(parents=True)
        config = source / 'scripts/config'
        config.write_text('#!/bin/bash\nexit 0\n'); config.chmod(0o755)
        (source / '.config').write_text('CONFIG_TCP_CONG_BBR_GUARD=m\nCONFIG_NET_SCH_FQ=m\nCONFIG_DEBUG_INFO_NONE=y\nCONFIG_GVE=m\n')
        self.shell(r'''
JOBS=1
make() {
  case "$*" in olddefconfig) return 0 ;; '-s kernelrelease') echo 6.13.7-bbrwan1 ;; *) return 9 ;; esac
}
compile_kernel_source "$STATE/linux" "$STATE" "$STATE/build.log"
touch "$STATE/installed"
''', success=False)
        self.assertFalse((self.state / 'installed').exists())
        self.assertFalse((self.state / 'kernel-release').exists())

    def test_source_build_uses_distinct_hotpath_release_and_package_version(self):
        source = self.state / 'linux'
        (source / 'scripts').mkdir(parents=True)
        config = source / 'scripts/config'
        config.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > config-args\n')
        config.chmod(0o755)
        (source / '.config').write_text('CONFIG_TCP_CONG_BBR_GUARD=m\nCONFIG_NET_SCH_FQ=m\nCONFIG_DEBUG_INFO_NONE=y\nCONFIG_GVE=m\n')
        self.shell(r'''
JOBS=1
make() {
  case "$*" in
    olddefconfig) return 0 ;;
    '-s kernelrelease')
      if [[ -f build-args ]]; then
        echo 7.3.5-bbrguard7r2only-674859761ded
      else
        echo 7.3.5-bbrguard6r4only-674859761ded
      fi ;;
    *) printf '%s\n' "$@" > build-args ;;
  esac
}
compile_kernel_source "$STATE/linux" "$STATE" "$STATE/build.log"
''')
        self.assertIn('-bbrguard7r2only-674859761ded', (source / 'config-args').read_text().splitlines())
        self.assertIn('KDEB_PKGVERSION=7.3.5-guard7r2.1', (source / 'build-args').read_text().splitlines())
        self.assertEqual((self.state / 'kernel-release').read_text().strip(),
                         '7.3.5-bbrguard7r2only-674859761ded')


class TestDD(SharedTests, Harness):
    script = 'dd.sh'

    def test_low_memory_cache_preview_and_destructive_boundary(self):
        for mode in ('auto', 'ram', 'disk'):
            result = self.shell(f'ACTION=reinstall; CACHE_MODE={mode}; DRY_RUN=1; dispatch')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('512 MiB', result.stdout)
            self.assertIn('磁盘模式', result.stdout)
        for args in [('reinstall', '--cache-mode', 'stream'), ('cancel', '--cache-mode', 'disk')]:
            self.assertNotEqual(self.cli(*args, '--dry-run').returncode, 0)

    def test_ubuntu_2204_and_bbr_options_rejected(self):
        for args in [('reinstall', '--version', '22.04'), ('install',), ('reinstall', '--version', 'debian'),
                     ('reinstall', '--jobs', '2'), ('reinstall', '--ssh-port', '65536'),
                     ('reinstall', '--ssh-port', 'x'), ('reinstall', '--yes'), ('cancel', '--test-network')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.cli(*args, '--dry-run').returncode, 0)

    def test_previews_do_not_mutate(self):
        self.shell(r'''
require_host() { exit 81; }; prepare_engine() { exit 82; }
for ACTION in reinstall cancel; do DRY_RUN=1; dispatch; done
''')
        self.assertEqual(list(self.state.iterdir()), [])

    def test_cancel_does_not_validate_or_download_image(self):
        self.shell(self.engine_stubs() + 'prepare_image_policy() { exit 89; }; cancel_reinstall')
        self.assertEqual((self.state / 'args').read_text().splitlines()[0], 'reset')

    def engine_stubs(self, code=0, target_display=True):
        engine = self.state / 'fake-engine.sh'
        engine.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$STATE/args"\n'
                          'if [[ ${DD_LOGIN_FD:-} == 8 ]]; then printf "%s" "fixture-secret" >&8; fi\n' + f'exit {code}\n')
        return '''
secure_boot_check() { return 0; }
inspect_cloud() { return 0; }
detect_system_disk() { SYSTEM_DISK=/dev/mock; }
prepare_image_policy() { DD_IMAGE_URL=https://example.invalid/verified.img; }
''' + ("show_reinstall_target() { return 0; }\n" if target_display else '') + f'prepare_engine() {{ ENGINE={shlex.quote(str(engine))}; }}\n'

    def test_noninteractive_reinstall_refused(self):
        result = self.shell(self.engine_stubs(target_display=False) + 'reinstall_ubuntu', success=False)
        self.assertIn('交互终端', result.stderr)
        self.assertFalse((self.state / 'args').exists())

    def test_reinstall_passes_disk_version_port_and_network_hold(self):
        self.shell(self.engine_stubs() + 'TEST_NETWORK=1; UBUNTU_VERSION=26.04; SSH_PORT=2222; SSH_KEY=/unused; reinstall_ubuntu')
        args = (self.state / 'args').read_text().splitlines()
        self.assertEqual(args[:6], ['ubuntu', '26.04', '--target-disk', '/dev/mock', '--ssh-port', '22'])
        self.assertEqual(args[args.index('--username') + 1], 'root')
        self.assertNotIn('--ssh-key', args)
        self.assertEqual(args[-2:], ['--hold', '1'])
        self.assertTrue((self.state / 'reinstall-pending').exists())
        self.assertTrue((self.state / 'reinstall-ready').exists())

    def test_failure_keeps_cancel_record(self):
        self.shell(self.engine_stubs(9) + 'reinstall_ubuntu', success=False)
        self.assertTrue((self.state / 'reinstall-pending').exists())
        self.assertFalse((self.state / 'reinstall-ready').exists())
        self.assertFalse((self.state / 'login-password').exists())
        self.shell(self.engine_stubs(9) + 'cancel_reinstall', success=False)
        self.assertTrue((self.state / 'reinstall-pending').exists())
        self.shell(self.engine_stubs() + 'cancel_reinstall')
        self.assertFalse((self.state / 'reinstall-pending').exists())

    def test_multiple_disks_and_partial_read_refused(self):
        for body in ["printf '/dev/sda disk\\n/dev/sdb disk\\n'", "echo '/dev/sda disk'; return 1", 'return 0']:
            self.shell(f'lsblk() {{ {body}; }}\nunique_disk_for /dev/root', success=False)

    def test_duplicate_ancestors_are_one_disk(self):
        r = self.shell("lsblk() { printf '/dev/root lvm\\n/dev/sda disk\\n/dev/sda disk\\n'; }; unique_disk_for /dev/root")
        self.assertEqual(r.stdout.strip(), '/dev/sda')

    def test_cancel_removes_saved_login_only_after_successful_reset(self):
        self.shell(self.engine_stubs() + 'reinstall_ubuntu')
        self.shell(self.engine_stubs(9) + 'cancel_reinstall', success=False)
        self.assertTrue((self.state / 'login-password').exists())
        self.assertTrue((self.state / 'reinstall-ready').exists())
        self.shell(self.engine_stubs() + 'cancel_reinstall')
        for name in ['login-password', 'reinstall-ready', 'reinstall-pending']:
            self.assertFalse((self.state / name).exists())

    def test_engine_without_login_never_marks_preparation_ready(self):
        setup = self.engine_stubs()
        (self.state / 'fake-engine.sh').write_text('#!/bin/bash\nexit 0\n')
        self.shell(setup + 'reinstall_ubuntu', success=False)
        self.assertTrue((self.state / 'reinstall-pending').exists())
        self.assertFalse((self.state / 'reinstall-ready').exists())


class TestWanPolicy(unittest.TestCase):
    def test_policy_c_boundaries(self):
        spec = importlib.util.spec_from_file_location('wan_recovery', ROOT / 'tools/wan_recovery.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'policy.h').write_text(module.BASE_POLICY)
            (folder / 'test.c').write_text(r'''
#include <assert.h>
#include "policy.h"
int main(void) {
  assert(bbrguard_relax_allowed(100000, 112500, 0, 1, 1));
  assert(!bbrguard_relax_allowed(100000, 112501, 0, 1, 1));
  assert(!bbrguard_relax_allowed(49999, 50000, 0, 1, 1));
  assert(!bbrguard_relax_allowed(100000, 99999, 0, 1, 1));
  assert(!bbrguard_relax_allowed(100000, 100000, 1, 1, 1));
  assert(!bbrguard_relax_allowed(100000, 100000, 0, 0, 1));
  assert(!bbrguard_relax_allowed(100000, 100000, 0, 1, 0));
  assert(!bbrguard_relax_allowed(~0U, ~0U, 0, 1, 1));
  assert(!bbrguard_relax_allowed(0, 0, 0, 1, 1));
  assert(bbrguard_relax_allowed(4000000000U, 4200000000U, 0, 1, 1));
  return 0;
}
''')
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(folder / 'test.c'), '-o', str(folder / 'test')], check=True)
            subprocess.run([str(folder / 'test')], check=True)


class TestResumableDownloads(Harness):
    def setUp(self):
        super().setUp()
        self.payload = b'cached-kernel-fixture\n' * 65536
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.mode = 'resume'
        self.requests = []
        self.sent_bytes = 0
        case = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requested = self.headers.get('Range')
                case.requests.append(requested)
                start = int(requested.removeprefix('bytes=').removesuffix('-')) if requested else 0
                if requested and start >= len(case.payload):
                    self.send_response(416)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    self.close_connection = True
                    return
                ignored = bool(requested and case.mode == 'no-range')
                if ignored:
                    start = 0
                data = case.payload[start:]
                self.send_response(206 if requested and not ignored else 200)
                self.send_header('Content-Length', str(len(data)))
                if requested and not ignored:
                    self.send_header('Content-Range', f'bytes {start}-{len(case.payload)-1}/{len(case.payload)}')
                self.end_headers()
                truncate = len(case.requests) == 1 or case.mode == 'always-interrupt'
                if truncate:
                    data = data[:max(1, len(data) // 2)]
                if case.mode == 'corrupt':
                    data = b'x' * len(data)
                try:
                    self.wfile.write(data)
                    self.wfile.flush()
                    case.sent_bytes += len(data)
                    if truncate:
                        self.connection.shutdown(socket.SHUT_RDWR)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    pass
                self.close_connection = True

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def download(self, success=True):
        # Loopback fixture only: keep real curl's Range/error behavior while
        # overriding its protocol allowlist. Production retains HTTPS-only flags.
        return self.shell(r'''
curl() { command curl "$@" --proto '=http' --proto-redir '=http'; }
sleep() { :; }
''' + f'download_verified http://127.0.0.1:{self.server.server_port}/kernel '
            + f'"$STATE/package.deb" {self.digest} 1', success=success)

    def test_real_curl_resumes_and_verified_cache_avoids_new_requests(self):
        self.download()
        self.assertEqual(len(self.requests), 2)
        self.assertIsNone(self.requests[0])
        self.assertEqual(self.requests[1], f'bytes={len(self.payload)//2}-')
        self.assertEqual(self.sent_bytes, len(self.payload))
        self.download()
        self.assertEqual(len(self.requests), 2)
        self.assertEqual((self.state / 'package.deb').read_bytes(), self.payload)
        self.assertEqual(list(self.state.glob('*.part.*')), [])

    def test_real_curl_falls_back_when_server_ignores_range(self):
        self.mode = 'no-range'
        self.download()
        self.assertEqual(self.requests, [None, f'bytes={len(self.payload)//2}-', None])
        self.assertEqual((self.state / 'package.deb').read_bytes(), self.payload)

    def test_retry_budget_preserves_partial_for_next_invocation(self):
        self.mode = 'always-interrupt'
        self.download(success=False)
        self.assertEqual(len(self.requests), 4)
        partial = self.state / f'package.deb.part.{self.digest}'
        size = partial.stat().st_size
        self.assertGreater(size, 0)
        self.assertFalse((self.state / 'package.deb').exists())
        self.mode = 'resume'
        self.download()
        self.assertEqual(self.requests[4], f'bytes={size}-')
        self.assertEqual((self.state / 'package.deb').read_bytes(), self.payload)

    def test_bad_hash_is_never_promoted_and_bad_final_cache_is_refused(self):
        self.mode = 'corrupt'
        self.download(success=False)
        self.assertFalse((self.state / 'package.deb').exists())
        self.assertEqual(list(self.state.glob('*.part.*')), [])
        (self.state / 'package.deb').write_bytes(b'bad-cache')
        requests = len(self.requests)
        self.download(success=False)
        self.assertEqual(len(self.requests), requests)
        self.assertEqual((self.state / 'package.deb').read_bytes(), b'bad-cache')

    def test_partial_symlink_is_refused_without_modifying_target(self):
        target = self.state / 'owned-by-user'
        target.write_bytes(b'keep')
        (self.state / f'package.deb.part.{self.digest}').symlink_to(target)
        self.download(success=False)
        self.assertEqual(self.requests, [])
        self.assertEqual(target.read_bytes(), b'keep')

    def test_complete_partial_is_promoted_without_network(self):
        (self.state / f'package.deb.part.{self.digest}').write_bytes(self.payload)
        self.download()
        self.assertEqual(self.requests, [])
        self.assertEqual((self.state / 'package.deb').read_bytes(), self.payload)

    def test_invalid_full_length_partial_restarts_after_http_416(self):
        (self.state / f'package.deb.part.{self.digest}').write_bytes(b'x' * len(self.payload))
        self.download()
        self.assertEqual(self.requests, [f'bytes={len(self.payload)}-', None])
        self.assertEqual((self.state / 'package.deb').read_bytes(), self.payload)


class TestDDResumableDownloads(TestResumableDownloads):
    script = 'dd.sh'


if __name__ == '__main__':
    unittest.main(verbosity=2)
