import base64
import gzip
import hashlib
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('kernel_patch', ROOT / 'tools/kernel_patch.py')
kernel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kernel)


class KernelPatchTests(unittest.TestCase):
    def tree(self, version='7', sublevel='5'):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / 'Makefile').write_text(f'VERSION = {version}\nPATCHLEVEL = 3\nSUBLEVEL = {sublevel}\nEXTRAVERSION =\n')
        (root / 'net/ipv4').mkdir(parents=True)
        return root

    def test_patch_source_and_embedded_payload_are_exact(self):
        data = (ROOT / 'tools/google-bbr3.patch').read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), kernel.PATCH_SHA256)
        encoded = re.search(r"^PATCH_DATA = '([^']+)'$", (ROOT / 'bbr.sh').read_text(), re.M)[1]
        self.assertEqual(gzip.decompress(base64.b64decode(encoded)), data)

    def test_wrong_baseline_is_rejected_before_patch(self):
        with patch.object(kernel.subprocess, 'run') as run:
            for major, sublevel in [('6', '5'), ('7', '4'), ('7', '6')]:
                with self.subTest(major=major, sublevel=sublevel):
                    with self.assertRaisesRegex(ValueError, 'pristine Linux 7.3.5'):
                        kernel.apply(self.tree(major, sublevel))
            run.assert_not_called()

    def test_duplicate_patch_is_rejected(self):
        root = self.tree()
        (root / 'net/ipv4/tcp_bbr3.c').touch()
        with self.assertRaisesRegex(ValueError, 'already present'):
            kernel.apply(root)

    def test_modified_patch_payload_is_rejected(self):
        with patch.object(kernel, 'PATCH_DATA', base64.b64encode(gzip.compress(b'tampered')).decode()):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                kernel.apply(self.tree())
