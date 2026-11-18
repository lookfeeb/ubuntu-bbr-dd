"""Guard7 hotpath must exactly preserve R5 decisions and socket state."""
import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_wan_recovery import FIXTURES, c_function, module, pinned_source


# The oracle calls these unchanged helpers. Pin them so changing a shared
# dependency cannot silently change both sides of the differential test.
R5_HELPERS = {
    'static bool bbrguard_recovery_allowed(': 'c81685c2a437e288c74a293f4de707498fb7a9cfe38b55d9e0cf69d936e80db9',
    'static void bbrguard_update_gate(': 'a3189859276fac330780b1e92bb33214a8fb7fb1288947d6fdca40e7e5c1e128',
    'static bool bbrguard_relaxed_loss(': 'd01b0edf8647d75a6d72d2dc731888f17e370c6503322c2f707d775ac7e0085d',
    'static u32 bbrguard_loss_limit(': '5efd4e7f22cbb2f7f78131adf183cb3d4990760361c595304788c00d489e76b2',
    'static bool bbrguard_tiny_single_loss(': 'b31a964f96475d0d3538ecff64bd6da93b72a8081b7c046c17c57fca294e60b1',
}


class HotpathEquivalenceTests(unittest.TestCase):
    def run_case(self, clock=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'source.c').write_bytes(pinned_source())
            module('wan_recovery').generate(root / 'source.c', root / 'module')
            generated = (root / 'module/tcp_bbr_guard.c').read_text()
            stubs = (FIXTURES / 'guard_socket_stubs.h').read_text()
            if clock:
                stubs = stubs.replace('static volatile u32 tcp_jiffies32;',
                    'static u32 tick, step; static unsigned reads;\n'
                    'static u32 moving_tick(void) { return tick + step * reads++; }\n'
                    '#define tcp_jiffies32 moving_tick()\n')
            code = '#include <stdio.h>\n#include <string.h>\n#include <assert.h>\n#include <limits.h>\n' + stubs
            for declaration in (
                'static bool bbrguard_recovery_allowed(',
                'static void bbrguard_update_gate(',
                'static bool bbrguard_relaxed_loss(',
                'static u32 bbrguard_loss_limit(',
                'static bool bbrguard_tiny_single_loss(',
                'static bool bbrguard_recovery_context(',
                'static bool bbrguard_cc_is_inflight_too_high(',
            ):
                function = c_function(generated, declaration)
                if declaration in R5_HELPERS:
                    self.assertEqual(hashlib.sha256(function.encode()).hexdigest(), R5_HELPERS[declaration])
                code += function
            oracle = (FIXTURES / 'guard_r5_hotpath_reference.h').read_text()
            self.assertEqual(hashlib.sha256(oracle.encode()).hexdigest(),
                             '744a72d61bbb15510e5f71b785760a72ae23fce8708b7edc9f0670ca8c562898')
            code += oracle
            if clock:
                code += (FIXTURES / 'guard_hotpath_clock_cases.c').read_text()
            else:
                # Reuse the frozen input sequences without modifying an input
                # shared by archived studies. R5 permits no declared exception.
                fixture = (FIXTURES / 'guard_hotpath_cases.c').read_text()
                start = fixture.index('    if (bbrguard_recovery_allowed(sk) &&')
                end = fixture.index('    assert(memcmp(', start)
                fixture = fixture[:start] + '    assert(a == b && old_loss == hot_loss);\n' + fixture[end:]
                fixture = fixture.replace(
                    'assert(changed > 0); /* The exception itself must actually be exercised. */',
                    'assert(changed == 0); /* Exact R5 equivalence. */')
                code += fixture.replace('reference_bbrguard_cc_is_inflight_too_high(', 'r5_reference_loss(')
            (root / 'module/check.c').write_text(code)
            for hz in (250, 1000):
                with self.subTest(hz=hz):
                    subprocess.run(['cc', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-Wno-sign-compare', '-Wno-unused-parameter', '-Wno-unused-function',
                        '-fsanitize=undefined', '-fno-sanitize-recover=all', f'-DHZ={hz}',
                        str(root / 'module/check.c'), '-o', str(root / 'check')], check=True)
                    subprocess.run([str(root / 'check')], check=True)

    def test_r5_decisions_and_socket_state_are_identical(self):
        self.run_case()

    def test_r5_decisions_with_advancing_and_wrapping_clock(self):
        self.run_case(clock=True)
