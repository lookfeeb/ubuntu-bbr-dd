"""Exercise cache failure gates without mounting or touching block devices."""
import hashlib
from pathlib import Path
import shlex
from test_dd_hardening import RuntimeHarness


class PackageCacheTests(RuntimeHarness):
    def cache(self):
        cache = self.root / 'cache/packages'
        (cache / 'archives').mkdir(parents=True)
        (cache / 'lists').mkdir()
        (cache / 'plan').write_text('linux-image-gcp\n')
        (cache / 'archives/kernel.deb').write_bytes(b'authenticated package fixture')
        (cache / 'lists/release').write_bytes(b'authenticated index fixture')
        files = [cache / 'plan', cache / 'archives/kernel.deb', cache / 'lists/release']
        (cache / 'SHA256SUMS').write_text(''.join(
            f'{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.relative_to(cache)}\n' for f in files))
        return cache

    def test_missing_cache_blocks_erasure(self):
        (self.root / 'cache').mkdir()
        (self.root / 'cache/image.img').touch()
        self.run_shell('DD_IMAGE_VERIFIED=1; dd_require_verified; touch "$DD_BUNDLE/erased"', ok=False)
        self.assertFalse((self.bundle / 'erased').exists())

    def test_tampered_plan_package_or_index_blocks_erasure(self):
        cache = self.cache()
        (self.root / 'cache/image.img').touch()
        for name in ['plan', 'archives/kernel.deb', 'lists/release']:
            original = (cache / name).read_bytes()
            (cache / name).write_bytes(original + b'changed')
            self.run_shell('DD_IMAGE_VERIFIED=1; dd_require_verified; touch "$DD_BUNDLE/erased"', ok=False)
            self.assertFalse((self.bundle / 'erased').exists())
            (cache / name).write_bytes(original)

    def test_valid_cache_allows_gate(self):
        self.cache()
        (self.root / 'cache/image.img').touch()
        self.run_shell('DD_IMAGE_VERIFIED=1; dd_require_verified')

    def test_unseeded_apt_refuses_transaction(self):
        self.run_shell('chroot() { touch "$DD_BUNDLE/apt-ran"; }; dd_install_packages "$DD_BUNDLE"', ok=False)
        self.assertFalse((self.bundle / 'apt-ran').exists())

    def test_seeded_apt_transaction_disallows_download(self):
        target = self.root / 'target/var/lib/ubuntu-dd'
        target.mkdir(parents=True)
        (target / 'packages-ready').touch()
        (target / 'package-plan').write_text('linux-image-gcp\nopenssh-server\n')
        r = self.run_shell('chroot() { printf "%s\\n" "$@"; }; dd_install_packages ' + shlex.quote(str(self.root / 'target')))
        args = r.stdout.splitlines()
        self.assertIn('--no-download', args)
        self.assertNotIn('--reinstall', args)
        self.assertEqual(args[-2:], ['linux-image-gcp', 'openssh-server'])

    def test_package_plan_matches_platform_and_boot_mode(self):
        for cloud, kernel in [('gcp', 'gcp'), ('lightsail', 'aws'), ('oci', 'oracle')]:
            (self.bundle / 'cloud').write_text(cloud)
            r = self.run_shell('is_efi() { return 0; }; uname() { echo aarch64; }; get_ucode_firmware_pkgs() { :; }; dd_package_plan')
            self.assertIn('linux-image-' + kernel, r.stdout)
            self.assertIn('grub-efi-arm64-signed', r.stdout)
            self.assertNotIn('grub-pc', r.stdout)

    def test_prefetch_download_and_selected_driver_fail_before_gate(self):
        (self.bundle / 'cloud').write_text('gcp')
        (self.bundle / 'drivers').write_text('gve\n')
        for mode in ['download', 'driver', 'success']:
            with self.subTest(mode=mode):
                script = 'MODE=' + mode + '\n' + r'''
is_efi() { return 0; }
get_ucode_firmware_pkgs() { :; }
modprobe() { :; }
mount() { :; }
umount() { :; }
mkdir -p "$DD_CACHE/package-stage/etc" "$DD_CACHE/package-stage/var/cache/apt/archives"
mkdir -p "$DD_CACHE/package-stage/var/lib/apt/lists" "$DD_CACHE/package-stage/lib/modules/7.0.0-gcp"
chroot() {
  shift
  case "$1" in
    apt-get)
      case "$*" in
        *--download-only*)
          [ "$MODE" != download ] || return 9
          echo package > "$DD_CACHE/package-stage/var/cache/apt/archives/kernel.deb" ;;
      esac ;;
    dpkg-deb) [ "$2" != -f ] || echo linux-image-7.0.0-gcp ;;
    modinfo) [ "$MODE" != driver ] || return 8; echo '/lib/modules/7.0.0-gcp/gve.ko' ;;
    depmod) : ;;
    *) return 99 ;;
  esac
}
dd_cache_packages /read-only-fixture
dd_verify_package_cache "$DD_CACHE/packages"
touch "$DD_BUNDLE/erased"
'''
                self.run_shell(script, ok=mode == 'success')
                self.assertEqual((self.bundle / 'erased').exists(), mode == 'success')
