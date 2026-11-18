"""Official snapshot selection with simulated HTTP and actual GPG signatures."""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch as mock_patch
from urllib.error import HTTPError

from test_dd_hardening import patch


class Response(io.BytesIO):
    def __init__(self, url, data=b'', size='1073741824'):
        super().__init__(data)
        self.url = url
        self.headers = {'Content-Length': size}

    def geturl(self):
        return self.url


class SnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix='dd-snapshot-key-')
        cls.home = Path(cls.keys.name)
        os.chmod(cls.home, 0o700)
        subprocess.run(['gpg', '--batch', '--homedir', str(cls.home), '--pinentry-mode', 'loopback',
                        '--passphrase', '', '--quick-generate-key', 'Snapshot Test <test@example.invalid>',
                        'ed25519', 'sign', '0'], check=True, capture_output=True)
        cls.key = subprocess.run(['gpg', '--homedir', str(cls.home), '--export'],
                                 check=True, capture_output=True).stdout

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['gpgconf', '--homedir', str(cls.home), '--kill', 'all'], capture_output=True)
        cls.keys.cleanup()

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='dd-snapshot-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        (self.bundle / 'ubuntu-cloudimage-keyring.gpg').write_bytes(self.key)
        self.calls = []
        self.serial = '20261108'
        self.size = '1073741824'
        self.redirect = None
        self.missing = None
        self.heading = None
        self.sign()

    def sign(self, text=None):
        self.digest = hashlib.sha256(b'fixture snapshot image').hexdigest()
        self.manifest = (text if text is not None else ''.join(
            f'{self.digest} *ubuntu-{version}-server-cloudimg-{arch}.img\n'
            for version in ['24.04', '26.04'] for arch in ['amd64', 'arm64'])).encode()
        manifest = self.root / 'signed'
        manifest.write_bytes(self.manifest)
        subprocess.run(['gpg', '--homedir', str(self.home), '--batch', '--yes', '--detach-sign',
                        '-o', str(self.root / 'sig'), str(manifest)], check=True, capture_output=True)
        self.signature = (self.root / 'sig').read_bytes()

    def open(self, request, timeout):
        self.assertEqual(timeout, 60)
        url = request if isinstance(request, str) else request.full_url
        method = 'GET' if isinstance(request, str) else request.get_method()
        self.calls.append((method, url))
        if self.missing and url.endswith(self.missing):
            raise HTTPError(url, 404, 'Missing snapshot', {}, None)
        final = url
        if self.redirect and url.endswith(self.redirect):
            final = url.replace(f'release-{self.serial}/', 'release/')
        if url.endswith('/release/'):
            version = '24.04' if '/noble/' in url else '26.04'
            data = self.heading if self.heading is not None else f'<h1>Ubuntu {version} LTS (Name) release [{self.serial}]</h1>'.encode()
        elif url.endswith('/SHA256SUMS'):
            data = self.manifest
        elif url.endswith('/SHA256SUMS.gpg'):
            data = self.signature
        else:
            self.assertEqual(method, 'HEAD', 'Tests must never fetch a whole image')
            data = b''
        return Response(final, data, self.size)

    def run_metadata(self, version='24.04', arch='amd64'):
        with mock_patch.object(patch.urllib.request, 'build_opener', return_value=self), contextlib.redirect_stdout(io.StringIO()):
            patch.image_metadata(self.bundle, version, arch)

    def assert_no_policy(self):
        for field in ['image-url', 'image-build', 'image-bytes']:
            self.assertFalse((self.bundle / field).exists(), field)

    def test_versions_architectures_and_build_suffix(self):
        for version, codename in [('24.04', 'noble'), ('26.04', 'resolute')]:
            for arch in ['amd64', 'arm64']:
                for serial in ['20261108', '20261108.1']:
                    with self.subTest(version=version, arch=arch, serial=serial):
                        self.serial = serial
                        self.calls.clear()
                        self.run_metadata(version, arch)
                        base = f'https://cloud-images.ubuntu.com/releases/{codename}/release-{serial}/'
                        self.assertEqual((self.bundle / 'image-url').read_text(), base + f'ubuntu-{version}-server-cloudimg-{arch}.img\n')
                        self.assertEqual((self.bundle / 'image-build').read_text(), serial + '\n')
                        self.assertEqual((self.bundle / 'image-bytes').read_text(), self.size + '\n')
                        self.assertEqual((self.bundle / 'SHA256SUMS').read_bytes(), self.manifest)
                        self.assertEqual(self.calls[1:], [('GET', base + 'SHA256SUMS'), ('GET', base + 'SHA256SUMS.gpg'),
                                                       ('HEAD', base + f'ubuntu-{version}-server-cloudimg-{arch}.img')])

    def test_current_release_switch_does_not_change_prepared_snapshot(self):
        original = self.open

        def rotating(request, timeout):
            response = original(request, timeout)
            if response.url.endswith('/release/'):
                self.serial = '20261109'
                # The dynamic heading would now point at B; the signed A
                # resources remain available at the exact A date directory.
            return response

        with mock_patch.object(self, 'open', side_effect=rotating):
            self.run_metadata()
        self.assertEqual((self.bundle / 'image-build').read_text(), '20261108\n')
        self.assertTrue(all('/release-20261108/' in url for _, url in self.calls[1:]))
        self.run_metadata()
        self.assertEqual((self.bundle / 'image-build').read_text(), '20261109\n')

    def test_missing_snapshot_resources_never_fall_back(self):
        for missing in ['SHA256SUMS', 'SHA256SUMS.gpg', '.img']:
            self.missing = missing
            self.calls.clear()
            with self.assertRaises(HTTPError):
                self.run_metadata()
            self.assert_no_policy()
            self.assertEqual(sum(url.endswith('/release/') for _, url in self.calls), 1)

    def test_redirect_to_mutable_directory_refused(self):
        for redirect in ['SHA256SUMS', 'SHA256SUMS.gpg', '.img']:
            self.redirect = redirect
            with self.assertRaisesRegex(ValueError, 'redirected'):
                self.run_metadata()
            self.assert_no_policy()

    def test_redirect_to_different_snapshot_refused(self):
        original = self.open

        def wrong_build(request, timeout):
            response = original(request, timeout)
            response.url = response.url.replace('release-20261108/', 'release-20261109/')
            return response

        with mock_patch.object(self, 'open', side_effect=wrong_build), self.assertRaisesRegex(ValueError, 'redirected'):
            self.run_metadata()
        self.assert_no_policy()

    def test_missing_ambiguous_wrong_version_and_invalid_date_headings(self):
        for heading in [b'<h1>Unknown</h1>',
                        b'<h1>Ubuntu 26.04 LTS release [20261108]</h1>',
                        b'<h1>Ubuntu 24.04 LTS release [20260230]</h1>',
                        b'<h1>Ubuntu 24.04 LTS release [20261108]</h1>' * 2,
                        b'x' * (2 * 1024 * 1024)]:
            self.heading = heading
            with self.assertRaises(ValueError):
                self.run_metadata()
            self.assert_no_policy()

    def test_bad_signature_stops_before_image_head(self):
        self.manifest += b'tampered\n'
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_metadata()
        self.assert_no_policy()
        self.assertFalse(any(method == 'HEAD' for method, _ in self.calls))

    def test_signed_missing_or_duplicate_entry_refused(self):
        for manifest in [f'{self.digest} *other.img\n',
                         f'{self.digest} *ubuntu-24.04-server-cloudimg-amd64.img\n' * 2]:
            self.sign(manifest)
            with self.assertRaisesRegex(ValueError, 'Missing or ambiguous'):
                self.run_metadata()
            self.assert_no_policy()

    def test_invalid_size_refused_and_old_policy_invalidated(self):
        for size in ['0', str(64 * 1024 * 1024), str(16 * 1024 ** 3), '-1', 'garbage', None]:
            self.size = size
            for field in ['image-url', 'image-build', 'image-bytes']:
                (self.bundle / field).write_text('stale')
            with self.assertRaises((ValueError, TypeError)):
                self.run_metadata()
            self.assert_no_policy()


if __name__ == '__main__':
    unittest.main()
