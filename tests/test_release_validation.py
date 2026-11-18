"""Reject package publication unless the exact packages completed guest validation."""
import copy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from package_recovery import RELEASE, VERSION, digest, verify_vm_report


class ValidationTests(unittest.TestCase):
    def test_publication_binds_both_packages_boots_and_all_phases(self):
        with tempfile.TemporaryDirectory() as tmp:
            packages = [Path(tmp) / name for name in ('image.deb', 'headers.deb')]
            for path in packages:
                path.write_bytes(path.name.encode())
            report = dict(status='pass', kernel_release=RELEASE, package_version=VERSION,
                          phases=['setup', 'install', 'new', 'rollback', 'old', 'return', 'clean'],
                          packages={p.name: digest(p) for p in packages}, original_kernel='6.8.0-generic',
                          boots=[dict(id=str(i) * 8 + '-0000-0000-0000-000000000000', ssh=True) for i in (1, 2, 3, 4)],
                          commit='tested')
            verify_vm_report(report, packages, 'tested')
            variants = [dict(status='running'), dict(kernel_release='old'), dict(package_version='old'),
                        dict(phases=report['phases'][:-1]), dict(packages={}), dict(commit='different'),
                        dict(original_kernel=RELEASE), dict(boots=report['boots'][:3]),
                        dict(boots=[report['boots'][0]] * 4)]
            for change in variants:
                candidate = copy.deepcopy(report)
                candidate.update(change)
                with self.subTest(change=change), self.assertRaises(ValueError):
                    verify_vm_report(candidate, packages, 'tested')
            packages[1].write_bytes(b'changed after test')
            with self.assertRaises(ValueError):
                verify_vm_report(report, packages, 'tested')
