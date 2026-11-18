"""Actual generated control path: window budget, pacing cap and revocation."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_wan_recovery import FIXTURES, module, pinned_source


class WindowPacingTests(unittest.TestCase):
    def test_window_budget_and_revocation_on_every_ack(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'source.c').write_bytes(pinned_source())
            module('wan_recovery').generate(root / 'source.c', root / 'module')
            source = (root / 'module/tcp_bbr_guard.c').read_text()
            code = (FIXTURES / 'guard_pacing_stubs.h').read_text()
            for name in ('bbrguard_pace_window', 'bbrguard_update_drain', 'bbrguard_apply_drain', 'bbrguard_cc_main'):
                match = re.search(r'^(?:__bpf_kfunc )?static [^\n]+ ' + name + r'\([^;]+?\n\{', source, re.M)
                self.assertIsNotNone(match, name)
                code += source[match.start():source.index('\n}\n', match.start()) + 3]
            code += (FIXTURES / 'guard_pacing_cases.c').read_text()
            (root / 'module/cases.c').write_text(code)
            for hz in (250, 1000):
                subprocess.run(['cc', '-O2', '-Wall', '-Wextra', '-Werror',
                                '-Wno-unused-parameter', '-Wno-unused-but-set-variable',
                                '-fsanitize=undefined', '-fno-sanitize-recover=all',
                                f'-DHZ={hz}', str(root / 'module/cases.c'), '-o', str(root / 'check')], check=True)
                subprocess.run([str(root / 'check')], check=True)
