"""Fault injection uses temporary files and stubs, never block devices."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('dd_patch', ROOT / 'tools/dd_patch.py')
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class RuntimeHarness(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dd-hardening-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        (self.bundle / 'cache-mode').write_text('ram\n')
        self.prefix = ('set -eu\n'
                       f'. {shlex.quote(str(ROOT / "tools/dd_resources.sh"))}\n'
                       f'. {shlex.quote(str(ROOT / "tools/dd_runtime.sh"))}\n'
                       f'. {shlex.quote(str(ROOT / "tools/dd_packages.sh"))}\n'
                       f'DD_BUNDLE={shlex.quote(str(self.bundle))}\n'
                       f'DD_CACHE={shlex.quote(str(self.root / "cache"))}\n'
                       f'confhome=https://raw.githubusercontent.com/bin456789/reinstall/{patch.COMMIT}\n')
        # These cases isolate image/journal/package gates; disk identity has a
        # separate hardware-free suite exercising the real shared checker.
        self.prefix += 'dd_verify_disk_identity() { :; }\nxda=mock\n'

    def run_shell(self, body, ok=True):
        result = subprocess.run(['bash', '-c', self.prefix + body], capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

class DownloadTests(RuntimeHarness):
    setup_download = '''
calls=0
sleep() { :; }
dd_https() {
    calls=$((calls + 1))
    case "$*" in *'--retry 0 --continue-at -'*) ;; *) exit 95 ;; esac
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --output ]; then out=$2; break; fi
        shift
    done
    transfer
}
'''

    def test_interruption_resumes_without_discarding_prefix(self):
        r = self.run_shell(self.setup_download + '''
transfer() {
    if [ "$calls" = 1 ]; then printf abc > "$out"; return 18; fi
    [ "$(cat "$out")" = abc ] || exit 96
    printf def >> "$out"
}
dd_download_image https://example.invalid/image "$DD_BUNDLE/part" 6
echo calls=$calls
''')
        self.assertIn('calls=2', r.stdout)
        self.assertEqual((self.bundle / 'part').read_text(), 'abcdef')

    def test_unsupported_resume_falls_back_to_fresh_download(self):
        (self.bundle / 'part').write_text('abc')
        self.run_shell(self.setup_download + '''
transfer() {
    if [ "$calls" = 1 ]; then return 33; fi
    [ ! -e "$out" ] || exit 96
    printf abcdef > "$out"
}
dd_download_image https://example.invalid/image "$DD_BUNDLE/part" 6
''')
        self.assertEqual((self.bundle / 'part').read_text(), 'abcdef')

    def test_retries_are_bounded_and_tls_failure_is_immediate(self):
        for status, count in [(56, 4), (60, 1)]:
            result = self.run_shell(self.setup_download + f'''
transfer() {{ echo REQUEST; return {status}; }}
dd_download_image https://example.invalid/image "$DD_BUNDLE/part" 6
''', ok=False)
            self.assertEqual(result.stdout.count('REQUEST'), count)

    def test_oversized_or_symlink_cache_is_refused(self):
        part = self.bundle / 'part'
        for linked in (False, True):
            if linked:
                part.symlink_to(self.bundle / 'missing')
            else:
                part.write_text('oversized')
            self.run_shell('dd_https() { exit 93; }; dd_download_image https://example.invalid/image "$DD_BUNDLE/part" 6', ok=False)
            part.unlink()


class RuntimeTests(RuntimeHarness):
    def resource(self):
        (self.bundle / 'ttys.sh').write_text('trusted helper\n')
        patch.seal(self.bundle)

    def test_resource_curl_wget_download_are_local_and_identical(self):
        self.resource()
        for call in ['dd_resource curl -Lo "$DD_BUNDLE/out" "$confhome/ttys.sh"',
                     'dd_resource wget "$confhome/ttys.sh" -O "$DD_BUNDLE/out"',
                     'dd_resource download "$confhome/ttys.sh" "$DD_BUNDLE/out"']:
            self.run_shell(call)
            self.assertEqual((self.bundle / 'out').read_text(), 'trusted helper\n')
        self.assertEqual(self.run_shell('dd_resource wget "$confhome/ttys.sh" -O-').stdout, 'trusted helper\n')

    def test_corrupt_resource_never_reaches_output(self):
        self.resource()
        (self.bundle / 'ttys.sh').write_text('modified script')
        self.run_shell('dd_resource curl -Lo "$DD_BUNDLE/out" "$confhome/ttys.sh"', ok=False)
        self.assertFalse((self.bundle / 'out').exists())

    def test_missing_resource_and_main_branch_refused(self):
        self.resource()
        self.run_shell('dd_resource wget "$confhome/unknown.sh" -O-', ok=False)
        self.run_shell('dd_resource wget https://raw.githubusercontent.com/bin456789/reinstall/main/ttys.sh -O-', ok=False)

    def test_non_bundle_request_is_explicit_fallback(self):
        r = self.run_shell('dd_resource curl -Lo /unused https://example.invalid/image', ok=False)
        self.assertEqual(r.returncode, 125)

    def test_no_verified_gate_means_no_disk_write(self):
        self.run_shell('dd_require_verified; echo destroyed > "$DD_BUNDLE/erased"', ok=False)
        self.assertFalse((self.bundle / 'erased').exists())
        self.run_shell('DD_IMAGE_VERIFIED=1; dd_require_verified; echo destroyed > "$DD_BUNDLE/erased"', ok=False)
        self.assertFalse((self.bundle / 'erased').exists())

    def test_low_memory_stops(self):
        self.run_shell('dd_check_memory 500000000 2647483647', ok=False)
        self.run_shell('dd_check_memory 500000000 2647483648')

    def test_http_and_certificate_bypass_refused(self):
        for args in ['http://example.invalid/image', '--no-check-certificate https://example.invalid/image']:
            self.run_shell('dd_wget ' + args, ok=False)

    def test_cloud_init_keeps_credentials_and_network(self):
        target = self.root / 'target'
        (target / 'etc/cloud').mkdir(parents=True)
        (target / 'etc/cloud/cloud-init.disabled').touch()
        for cloud, datasource in [('gcp', 'GCE'), ('lightsail', 'Ec2'), ('aws', 'Ec2'), ('oci', 'Oracle')]:
            (self.bundle / 'cloud').write_text(cloud)
            self.run_shell(f'dd_cloud_init_policy {shlex.quote(str(target))}')
            cfg = (target / 'etc/cloud/cloud.cfg.d/99-zz-ubuntu-dd.cfg').read_text()
            self.assertIn(f'datasource_list: [ {datasource}, None ]', cfg)
            self.assertIn('network: {config: disabled}', cfg)
            self.assertIn('allow_userdata: false', cfg)
            self.assertIn('cloud_config_modules: []', cfg)
            self.assertIn('cloud_final_modules: []', cfg)
            self.assertNotIn('set_passwords', cfg)
            self.assertEqual('metadata_url: http://169.254.169.254/computeMetadata/v1/' in cfg,
                             cloud == 'gcp')
            self.assertFalse((target / 'etc/cloud/cloud-init.disabled').exists())

    def test_missing_target_gve_fails(self):
        (self.bundle / 'drivers').write_text('gve\n')
        r = self.run_shell('chroot() { return 1; }; dd_check_kernel_drivers /mock 6.17.0-gcp', ok=False)
        self.assertIn('missing gve', r.stderr)

    def test_built_in_target_gve_allowed(self):
        (self.bundle / 'drivers').write_text('gve\n')
        self.run_shell("chroot() { echo '(builtin)'; }; dd_check_kernel_drivers /mock 6.17.0-gcp")

    def test_generic_image_can_defer_gve_only_with_cloud_kernel_plan(self):
        (self.bundle / 'drivers').write_text('gve\n')
        (self.bundle / 'cloud').write_text('gcp\n')
        result = self.run_shell('chroot() { return 1; }; dd_check_image_drivers /mock 6.8.0-generic')
        self.assertIn('selected cloud kernel', result.stderr)
        self.run_shell('chroot() { return 1; }; dd_check_kernel_drivers /mock 6.8.0-gcp', ok=False)
        (self.bundle / 'cloud').write_text('generic\n')
        self.run_shell('chroot() { return 1; }; dd_check_image_drivers /mock 6.8.0-generic', ok=False)

    def test_selected_platform_controls_kernel_flavor(self):
        for cloud, flavor in [('gcp', 'gcp'), ('aws', 'aws'), ('lightsail', 'aws'), ('oci', 'oracle')]:
            (self.bundle / 'cloud').write_text(cloud + '\n')
            self.assertEqual(self.run_shell('get_ubuntu_kernel_flavor').stdout.strip(), flavor)

    def test_https_redirect_handler_rejects_downgrade(self):
        with self.assertRaisesRegex(ValueError, 'Non-HTTPS'):
            patch.HTTPSOnly().redirect_request(None, None, 302, '', {}, 'http://example.invalid')

    def target_stubs(self, mode):
        target = self.root / 'target'
        # Supply valid fixture paths on both BIOS hosts (WSL) and EFI CI
        # runners. Production checks must retain their real firmware probe.
        for name in ['boot/vmlinuz-test', 'boot/initrd.img-test', 'boot/grub/grub.cfg',
                     'boot/efi/EFI/ubuntu/shimx64.efi']:
            f = target / name
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text('fixture')
        (target / 'etc').mkdir(exist_ok=True)
        (target / 'etc/shadow').write_text('root:$6$fixture:0:0:99999:7:::\n')
        (self.bundle / 'drivers').write_text('gve\n')
        (self.bundle / 'cloud').write_text('gcp\n')
        (self.bundle / 'nics').write_text('00:11:22:33:44:55 gve\n')
        return f'MODE={shlex.quote(mode)}\nTARGET={shlex.quote(str(target))}\n' + r'''
ssh_port=2222
chroot() {
  shift
  case "$1" in
    modinfo) echo '/lib/modules/test/kernel/drivers/net/gve.ko.zst' ;;
    lsinitramfs)
      if [ "$MODE" != missing_initrd_gve ]; then echo 'usr/lib/modules/test/kernel/drivers/net/gve.ko.zst'; fi ;;
    netplan) [ "$MODE" != bad_netplan ] ;;
    /usr/sbin/sshd)
      if [ "$MODE" = bad_sshd ]; then return 1; fi
      if [ "$2" = -T ]; then
        printf 'port 2222\npasswordauthentication yes\npermitrootlogin yes\n'
      fi ;;
  esac
}
dd_finalize_target "$TARGET"
echo checked > "$DD_BUNDLE/finalized"
'''

    def test_target_initramfs_netplan_and_ssh_failures_stop_finalization(self):
        for mode in ['missing_initrd_gve', 'bad_netplan', 'bad_sshd']:
            with self.subTest(mode=mode):
                self.run_shell(self.target_stubs(mode), ok=False)
                self.assertFalse((self.bundle / 'finalized').exists())

    def test_target_checks_add_gve_and_record_policy(self):
        self.run_shell(self.target_stubs('success'))
        self.assertTrue((self.bundle / 'finalized').exists())
        self.assertEqual((self.root / 'target/etc/initramfs-tools/modules').read_text(), 'gve\n')


class SignatureTests(RuntimeHarness):
    @classmethod
    def setUpClass(cls):
        cls.keytemp = tempfile.TemporaryDirectory(prefix='dd-test-key-')
        cls.home = Path(cls.keytemp.name)
        os.chmod(cls.home, 0o700)
        subprocess.run(['gpg', '--batch', '--homedir', str(cls.home), '--pinentry-mode', 'loopback',
                        '--passphrase', '', '--quick-generate-key', 'DD Test <test@example.invalid>',
                        'ed25519', 'sign', '0'], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['gpgconf', '--homedir', str(cls.home), '--kill', 'all'], capture_output=True)
        cls.keytemp.cleanup()

    def signed_manifest(self, text=None):
        self.payload = b'signed test image content\n'
        self.digest = hashlib.sha256(self.payload).hexdigest()
        (self.bundle / 'SHA256SUMS').write_text(text or f'{self.digest} *image.img\n')
        key = subprocess.run(['gpg', '--homedir', str(self.home), '--export'], check=True, capture_output=True).stdout
        (self.bundle / 'ubuntu-cloudimage-keyring.gpg').write_bytes(key)
        subprocess.run(['gpg', '--homedir', str(self.home), '--batch', '--yes', '--detach-sign',
                        '-o', str(self.bundle / 'SHA256SUMS.gpg'), str(self.bundle / 'SHA256SUMS')],
                       check=True, capture_output=True)

    def test_valid_signature_exact_entry(self):
        self.signed_manifest()
        r = self.run_shell('dd_verify_manifest "$DD_BUNDLE" image.img')
        self.assertEqual(r.stdout.strip(), self.digest)

    def test_altered_manifest_bad_signature(self):
        self.signed_manifest()
        with (self.bundle / 'SHA256SUMS').open('a') as f:
            f.write('tampered\n')
        self.run_shell('dd_verify_manifest "$DD_BUNDLE" image.img', ok=False)

    def test_wrong_trust_anchor_refused(self):
        self.signed_manifest()
        shutil.copy(ROOT / 'tools/ubuntu-cloudimage-keyring.gpg', self.bundle / 'ubuntu-cloudimage-keyring.gpg')
        self.run_shell('dd_verify_manifest "$DD_BUNDLE" image.img', ok=False)

    def test_missing_and_duplicate_image_entry_refused(self):
        self.signed_manifest()
        self.run_shell('dd_verify_manifest "$DD_BUNDLE" other.img', ok=False)
        self.signed_manifest(f'{self.digest} *image.img\n{self.digest} *image.img\n')
        self.run_shell('dd_verify_manifest "$DD_BUNDLE" image.img', ok=False)

    def preflight_stubs(self, mode):
        self.signed_manifest()
        (self.bundle / 'image-url').write_text('https://example.invalid/image.img\n')
        (self.bundle / 'image-bytes').write_text(str(len(self.payload)))
        (self.bundle / 'disk-bytes').write_text('2000000000\n')
        (self.bundle / 'download').write_bytes(self.payload if mode != 'corrupt' else b'x' * len(self.payload))
        return f'MODE={shlex.quote(mode)}\n' + r'''
distro=ubuntu; releasever=24.04; img_type=qemu; xda=mock
img=https://example.invalid/image.img
apk() { :; }; swapoff() { :; }; mount() { :; }; umount() { :; }
mountpoint() { return 1; }
blockdev() { echo 2000000000; }
dd_check_live_nics() { :; }
dd_check_memory() { if [ "$MODE" = memory ]; then dd_fail 'no memory'; fi; }
dd_https() {
  [ "$MODE" != download ] || return 9
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then cp "$DD_BUNDLE/download" "$2"; return; fi
    shift
  done
  return 1
}
qemu-img() {
  if [ "$1" = info ]; then echo '{}'; fi
}
jq() {
  if [ "$1" = -er ]; then echo 100000000; fi
}
dd_preflight_image() {
  [ "$MODE" != driver ] || dd_fail 'gve missing'
  [ "$MODE" != packages ] || dd_fail 'package download failed'
  mkdir -p "$DD_CACHE/packages/archives" "$DD_CACHE/packages/lists"
  echo linux-image-gcp > "$DD_CACHE/packages/plan"
  (cd "$DD_CACHE/packages" && sha256sum plan > SHA256SUMS)
}
dd_preflight
dd_require_verified
echo destroyed > "$DD_BUNDLE/erased"
'''

    def test_download_hash_memory_and_driver_failures_precede_erasure(self):
        for mode in ['download', 'corrupt', 'memory', 'driver', 'packages']:
            with self.subTest(mode=mode):
                self.run_shell(self.preflight_stubs(mode), ok=False)
                self.assertFalse((self.bundle / 'erased').exists())

    def test_complete_preflight_opens_gate(self):
        self.run_shell(self.preflight_stubs('success'))
        self.assertTrue((self.bundle / 'erased').exists())


class UpstreamIntegration(unittest.TestCase):
    @unittest.skipUnless(shutil.which('systemd-analyze'), 'systemd-analyze required')
    def test_first_boot_network_unit_has_no_cloud_init_ordering_cycle(self):
        # An isolated unit graph reproduces cloud-init-local's early ordering.
        # No units are loaded into the running system manager.
        with tempfile.TemporaryDirectory(prefix='dd-unit-graph-') as temp:
            units = Path(temp)
            fixtures = {
                'sysinit.target': '[Unit]\nDefaultDependencies=no\n',
                'basic.target': '[Unit]\nRequires=sysinit.target\nAfter=sysinit.target\n',
                'shutdown.target': '[Unit]\nDefaultDependencies=no\n',
                'cloud-init-local.service': '[Unit]\nDefaultDependencies=no\nBefore=sysinit.target\n[Service]\nExecStart=/bin/true\n',
                'dbus.service': '[Service]\nExecStart=/bin/true\n',
                'systemd-remount-fs.service': '[Unit]\nDefaultDependencies=no\nBefore=sysinit.target\n[Service]\nExecStart=/bin/true\n',
                'systemd-udev-settle.service': '[Unit]\nDefaultDependencies=no\nBefore=sysinit.target\n[Service]\nExecStart=/bin/true\n',
                'default.target': '[Unit]\nWants=fix-eth-name.service cloud-init-local.service basic.target dbus.service\n',
            }
            for name, text in fixtures.items():
                (units / name).write_text(text)
            original = ('[Unit]\nAfter=dbus.service\nBefore=cloud-init-local.service\n'
                        '[Service]\nType=oneshot\nExecStart=/bin/true\n')
            for text, cycle in [(original, True), (patch.patch_network_unit(original), False)]:
                (units / 'fix-eth-name.service').write_text(text)
                result = subprocess.run(['systemd-analyze', 'verify', '--man=no', str(units / 'default.target')],
                                        env={**os.environ, 'SYSTEMD_UNIT_PATH': str(units)},
                                        capture_output=True, text=True, timeout=20)
                if cycle:
                    # systemd may resolve a Wants cycle by dropping a job and
                    # still return zero: the diagnostic is the failure signal.
                    self.assertIn('cycle', result.stderr.lower())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn('cycle', result.stderr.lower())

    def test_pinned_archive_patch_and_entry_gates(self):
        archive = Path(os.environ.get('DD_UPSTREAM_ARCHIVE', str(ROOT / '.cache/reinstall-8ac9db68.tar.gz')))
        if not archive.is_file():
            self.skipTest('Set DD_UPSTREAM_ARCHIVE to the SHA-256 verified upstream tar.gz')
        with tempfile.TemporaryDirectory(prefix='dd-upstream-') as temp:
            target = Path(temp) / 'bundle'
            patch.build(archive, target)
            host = (target / 'reinstall.sh').read_text()
            trans = (target / 'trans.sh').read_text()
            self.assertNotIn('command curl --insecure', host)
            self.assertIn('cp -a "$DD_BUNDLE/." "$initrd_dir/configs/dd/"', host)
            self.assertIn('cp /etc/ssl/certs/ca-certificates.crt', host)
            self.assertIn('busybox date -u -s @', host)
            self.assertIn('read -r -s -p "请输入 root 登录密码', host)
            password_function = 'prompt_password() {' + host.split('prompt_password() {', 1)[1].split('\nsave_password()', 1)[0]
            password_test = ('set -e\nwarn() { :; }; info() { :; }; error() { :; }; '
                             'error_and_exit() { exit 71; }\n' + password_function +
                             '\nprompt_password\n[[ $password == "fixture-secret" ]]\n')
            result = subprocess.run(['bash', '-c', password_test], input='wrong\nno-match\nfixture-secret\nfixture-secret\n',
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('fixture-secret', result.stdout + result.stderr)
            eof = subprocess.run(['bash', '-c', password_test], input='', capture_output=True, text=True, timeout=10)
            self.assertEqual(eof.returncode, 71)
            report_function = 'dd_report_login() {' + host.split('dd_report_login() {', 1)[1].split('\nprompt_password()', 1)[0]
            record = Path(temp) / 'login-password'
            report_test = ('set -e\numask 077\nwarn() { :; }; info() { :; }; error() { :; }; '
                           'error_and_exit() { exit 71; }\n' + report_function + password_function +
                           '\nDD_LOGIN_FD=8; distro=ubuntu; username=root; ssh_port=22; ssh_keys=\n' +
                           'exec 8>' + shlex.quote(str(record)) + '\nprompt_password\ndd_report_login\n')
            for secret in ['fixture-$literal-%s', '']:
                result = subprocess.run(['bash', '-c', report_test],
                                        input=secret + '\n' + (secret + '\n' if secret else ''),
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                saved = record.read_text()
                if secret:
                    self.assertEqual(saved, secret)
                else:
                    self.assertEqual(len(saved), 16)
                self.assertNotIn(saved, result.stdout + result.stderr)
                self.assertEqual(record.stat().st_mode & 0o777, 0o600)
                self.assertFalse((target / 'login-password').exists())
            for invalid in ['username=admin', 'ssh_port=2222', 'ssh_keys=fixture-key']:
                result = subprocess.run(['bash', '-c', 'error_and_exit() { exit 71; }\n' + report_function +
                                         '\nDD_LOGIN_FD=8; distro=ubuntu; username=root; ssh_port=22; ssh_keys=; password=fixture\n' +
                                         invalid + '\ndd_report_login 8>' + shlex.quote(str(record))], capture_output=True)
                self.assertEqual(result.returncode, 71)
                self.assertEqual(record.read_bytes(), b'')
            self.assertIn('qemu)\n            dd_prepare_install', trans)
            self.assertIn('create_part() {\n    dd_require_partition', trans)
            self.assertIn('dd_finish_partition_layout', trans)
            self.assertIn('dd_release_installer', trans)
            self.assertNotIn('wget -O /trans.sh "$confhome/trans.sh"', trans)
            self.assertIn('dd_finalize_target /os', trans)
            self.assertIn('dd_upstream_kernel_flavor() {', trans)
            self.assertIn('dd_seed_packages /os', trans)
            self.assertIn('dd_install_packages "$os_dir"', trans)
            self.assertNotIn('chroot $os_dir apt-get update', trans)
            self.assertNotIn('--allow-remove-essential', trans)
            for line in trans.splitlines():
                if 'chroot $os_dir apt-get ' in line:
                    self.assertIn('--no-download', line)
            for script in ['reinstall.sh', 'trans.sh']:
                subprocess.run(['bash', '-n', str(target / script)], check=True)
            if shutil.which('busybox'):
                subprocess.run(['busybox', 'ash', '-n', str(target / 'trans.sh')], check=True)
            # Evaluate function definitions only. The real create_part gate
            # must stop before its first apk/wipefs/partition command.
            definitions = trans[:trans.index('# 脚本入口')]
            test = definitions + '\n. ' + shlex.quote(str(ROOT / 'tools/dd_runtime.sh')) + '\ndd_verify_disk_identity() { :; }; create_part\n'
            r = subprocess.run(['bash'], input=test, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('image not verified', r.stderr)
            # Also build using the independent delivered script, with no
            # external tools/ assets available beside it.
            standalone = Path(temp) / 'dd.sh'
            shutil.copy(ROOT / 'dd.sh', standalone)
            out = Path(temp) / 'standalone-bundle'
            cmd = '. ' + shlex.quote(str(standalone)) + '\nengine_tools build ' + shlex.quote(str(archive)) + ' ' + shlex.quote(str(out))
            subprocess.run(['bash', '-c', cmd], check=True, capture_output=True)
            self.assertEqual((out / 'trans.sh').read_bytes(), (target / 'trans.sh').read_bytes())
            self.assertEqual((out / 'fix-eth-name.service').read_bytes(),
                             (target / 'fix-eth-name.service').read_bytes())

    def test_patch_anchor_drift_refused(self):
        with self.assertRaisesRegex(ValueError, 'anchor mismatch'):
            patch.patch_host('changed upstream')

    def test_corrupt_archive_refused_before_extract(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / 'bad.tgz'
            archive.write_bytes(b'bad')
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                patch.build(archive, Path(temp) / 'out')
            self.assertFalse((Path(temp) / 'out').exists())

    def test_standalone_embeds_exact_assets(self):
        # Source the public single file without accessing tools/ on target.
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'dd.sh'
            shutil.copy(ROOT / 'dd.sh', target)
            result = subprocess.run(['bash', '-c', 'source "$1"; ACTION=reinstall; DRY_RUN=1; dispatch', 'test', str(target)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            script = target.read_text()
            import base64
            for name in ['dd_resources.sh', 'dd_disk.sh', 'dd_runtime.sh', 'dd_packages.sh', 'ubuntu-cloudimage-keyring.gpg']:
                self.assertIn(base64.b64encode((ROOT / 'tools' / name).read_bytes()).decode(), script)


if __name__ == '__main__':
    unittest.main()
