"""Release manifests gate all package downloads and cache identity."""
import shlex

from test_scripts import Harness


class PrebuiltManifestTests(Harness):
    def manifest(self, content, fail=False):
        path = self.root / 'release-sums'
        path.write_text(content)
        return 'FIXTURE=' + shlex.quote(str(path)) + '\n' + r'''
curl() {
    printf '%s\n' "$*" > "$STATE/manifest-url"
    while (( $# )); do
        if [[ $1 == --output ]]; then cp "$FIXTURE" "$2"; return; fi
        shift
    done
    return 1
}
''' + ('curl() { return 22; }\n' if fail else '')

    def entries(self):
        release = '7.3.5-bbrguard7r2only-674859761ded_7.3.5-guard7r2.1_amd64.deb'
        return ''.join(digest * 64 + '  linux-' + kind + '-' + release + '\n'
                       for digest, kind in [('a', 'image'), ('b', 'headers')])

    def test_resolves_same_script_release_and_cleans_temporary_file(self):
        result = self.shell(self.manifest(self.entries()) +
                            'load_prebuilt_checksums\necho "$PREBUILT_IMAGE_SHA256 $PREBUILT_HEADERS_SHA256"')
        self.assertEqual(result.stdout.strip(), 'a' * 64 + ' ' + 'b' * 64)
        version = self.shell('printf "%s" "$TOOL_VERSION"').stdout
        self.assertIn(f'/releases/download/v{version}/SHA256SUMS', (self.state / 'manifest-url').read_text())
        self.assertEqual(list(self.state.glob('release-checksums.*')), [])

    def test_invalid_manifest_or_download_never_reaches_package_install(self):
        valid = self.entries()
        for content, fail in [(valid, True), ('', False), (valid.splitlines()[0] + '\n', False),
                              (valid + valid, False), (valid.replace('a' * 64, 'x' * 64), False),
                              (valid.replace('linux-image', 'other-image'), False)]:
            with self.subTest(content=content, fail=fail):
                self.shell(self.manifest(content, fail) + '''
prebuilt_arch_check() { :; }
kernel_preflight() { :; }
prebuilt_resources() { :; }
fetch_prebuilt_packages() { touch "$STATE/packages-requested"; }
apt-get() { touch "$STATE/apt-called"; }
install_prebuilt_kernel
''', success=False)
                self.assertFalse((self.state / 'packages-requested').exists())
                self.assertFalse((self.state / 'apt-called').exists())
                self.assertEqual(list(self.state.glob('release-checksums.*')), [])

    def test_missing_checksums_cannot_download(self):
        self.shell('download_verified() { touch "$STATE/downloaded"; }; fetch_prebuilt_packages "$STATE"', success=False)
        self.assertFalse((self.state / 'downloaded').exists())
