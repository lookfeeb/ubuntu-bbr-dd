"""Local kernel bundles use the same checksum/metadata gates as remote packages."""
import hashlib
import shlex
from test_scripts import Harness


class LocalPrebuiltTests(Harness):
    def bundle(self):
        bundle = self.root / 'local bundle'
        bundle.mkdir()
        identity = self.shell('printf "%s_%s_%s" "$PREBUILT_RELEASE" "$PREBUILT_VERSION" "$PREBUILT_ARCH"').stdout
        files = [bundle / f'linux-{kind}-{identity}.deb' for kind in ('image','headers')]
        for p in files:
            p.write_bytes(('fixture '+p.name).encode())
        (bundle/'SHA256SUMS').write_text(''.join(
            hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in files))
        return bundle, files

    def setup_code(self, bundle):
        return 'BBR_PACKAGE_DIR='+shlex.quote(str(bundle))+'\n'+r'''
curl() { touch "$STATE/unexpected-network"; return 94; }
verify_prebuilt_metadata() { touch "$STATE/metadata-checked"; }
'''

    def test_valid_local_bundle_and_cache_without_network_or_source_writes(self):
        bundle, files = self.bundle()
        before = {p.name:p.read_bytes() for p in bundle.iterdir()}
        self.shell(self.setup_code(bundle)+'''
load_prebuilt_checksums
mkdir "$STATE/cache"
fetch_prebuilt_packages "$STATE/cache"
fetch_prebuilt_packages "$STATE/cache"
''')
        self.assertTrue((self.state/'metadata-checked').exists())
        self.assertFalse((self.state/'unexpected-network').exists())
        self.assertEqual(before, {p.name:p.read_bytes() for p in bundle.iterdir()})
        for p in files:
            self.assertEqual(p.read_bytes(), (self.state/'cache'/p.name).read_bytes())

    def test_corrupt_local_package_stops_before_metadata_and_apt(self):
        bundle, files = self.bundle()
        files[0].write_bytes(b'changed')
        self.shell(self.setup_code(bundle)+r'''
prebuilt_arch_check() { :; }
kernel_preflight() { :; }
prebuilt_resources() { :; }
apt-get() { touch "$STATE/apt-called"; }
install_prebuilt_kernel
''',success=False)
        for name in ('metadata-checked','apt-called','unexpected-network'):
            self.assertFalse((self.state/name).exists())
        self.assertFalse(list(self.state.rglob('*.local.*')))

    def test_missing_local_manifest_does_not_fall_back_to_release(self):
        bundle, _ = self.bundle()
        (bundle/'SHA256SUMS').unlink()
        self.shell(self.setup_code(bundle)+'load_prebuilt_checksums',success=False)
        self.assertFalse((self.state/'unexpected-network').exists())
        self.assertFalse(list(self.state.glob('release-checksums.*')))

    def test_duplicate_local_manifest_entry_is_rejected(self):
        bundle, _ = self.bundle()
        sums=bundle/'SHA256SUMS'
        sums.write_text(sums.read_text()*2)
        self.shell(self.setup_code(bundle)+'load_prebuilt_checksums',success=False)
        self.assertFalse((self.state/'unexpected-network').exists())

    def test_corrupt_cache_is_not_silently_reused(self):
        bundle, files = self.bundle()
        cache=self.state/'cache';cache.mkdir()
        (cache/files[0].name).write_bytes(b'corrupt')
        self.shell(self.setup_code(bundle)+'''
load_prebuilt_checksums
fetch_prebuilt_packages "$STATE/cache"
''',success=False)
        self.assertFalse((self.state/'metadata-checked').exists())

    def test_symlink_package_is_rejected(self):
        bundle, files = self.bundle()
        actual=self.root/'actual.deb';actual.write_bytes(files[0].read_bytes())
        files[0].unlink();files[0].symlink_to(actual)
        self.shell(self.setup_code(bundle)+'''
load_prebuilt_checksums
mkdir "$STATE/cache"
fetch_prebuilt_packages "$STATE/cache"
''',success=False)
        self.assertFalse((self.state/'metadata-checked').exists())
