"""Actual generated C: bounded exploration, history gates and R3 equivalence."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_wan_recovery import FIXTURES, module, pinned_source


class TestHistoryRecovery(unittest.TestCase):
    def test_actual_callbacks_and_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'source.c').write_bytes(pinned_source())
            module('wan_recovery').generate(root / 'source.c', root / 'module')
            source = (root / 'module/tcp_bbr_guard.c').read_text()
            reference = (FIXTURES / 'guard_history_reference.h').read_text()
            def fn(s, n):
                match = re.search(r'^(?:__bpf_kfunc )?static [^\n]+ ' + n + r'\([^;]+?\n\{', s, re.M)
                self.assertIsNotNone(match, n)
                return s[match.start():s.index('\n}\n', match.start()) + 3]
            socket_stub = ('#include <assert.h>\n#include <limits.h>\n#include <stdio.h>\n'
                           '#include <string.h>\n' + (FIXTURES / 'guard_socket_stubs.h').read_text())
            for kind in ('growth', 'loss', 'state', 'layout'):
                with self.subTest(kind=kind):
                    if kind == 'growth':
                        code = (FIXTURES / 'guard_history_growth_stubs.h').read_text()
                        for name in ('bbrguard_recovery_allowed', 'bbrguard_early_probe',
                                     'bbrguard_tiny_single_loss',
                                     'bbrguard_cc_raise_inflight_hi_slope',
                                     'bbrguard_cc_probe_inflight_hi_upward',
                                     'bbrguard_cc_has_elapsed_in_phase',
                                     'bbrguard_cc_check_time_to_probe_bw'):
                            code += fn(source, name)
                        for name in ('original_probe', 'original_time'):
                            code += fn(reference, name)
                        for s, name in ((source, 'new_stop'), (reference, 'old_stop')):
                            body = fn(s, 'bbrguard_cc_update_cycle_phase')
                            expression = re.search(r'if \((bbr->prev_probe_too_high &&.*?)\) \{', body, re.S)[1]
                            code += ('static bool ' + name + '(struct sock *sk, const struct rate_sample *rs, u32 inflight) {\n'
                                     'const struct bbrguard *bbr=inet_csk_ca(sk);const struct tcp_sock *tp=tcp_sk(sk);(void)tp;(void)rs;return ' + expression + ';\n}\n')
                    elif kind == 'loss':
                        code = socket_stub
                        for name in ('bbrguard_recovery_allowed', 'bbrguard_relaxed_loss',
                                     'bbrguard_loss_limit', 'bbrguard_tiny_single_loss',
                                     'bbrguard_recovery_context',
                                     'bbrguard_cc_is_inflight_too_high'):
                            code += fn(source, name)
                        code += fn(reference, 'original_loss')
                    elif kind == 'state':
                        code = socket_stub + fn(source, 'bbrguard_update_gate') + fn(reference, 'original_gate')
                        init = fn(source, 'bbrguard_cc_init')
                        self.assertIn('bbr->guard_large_sample = 0;', init)
                        self.assertIn('(bbr->guard_large_sample << 4)', source)
                    else:
                        code = ('#include <stdint.h>\n#include <stddef.h>\n'
                                'typedef uint32_t u32;typedef uint64_t u64;typedef uint16_t u16;\n'
                                '#include "tcp_bbr_guard_policy.h"\n')
                        old = (FIXTURES / 'guard_history_layout_reference.h').read_text()
                        start = source.index('struct bbrguard {')
                        new = source[start:source.index('\n};', start) + 4]
                        code += old.replace('struct bbrguard {', 'struct old_bbr {')
                        code += new.replace('struct bbrguard {', 'struct new_bbr {')
                        code += '\n_Static_assert(sizeof(struct old_bbr)+8==sizeof(struct new_bbr),"layout");\n'
                        code += '_Static_assert(sizeof(struct new_bbr)<=144,"CA budget");\n'
                        code += '_Static_assert(offsetof(struct new_bbr,guard_stamp)==sizeof(struct old_bbr),"append only");\n'
                        members = re.findall(r'^\s*u(?:16|32|64)\s+(\w+)(?:\[\d+\])?;', old, re.M) + ['loss_gate']
                        for name in members:
                            code += ('_Static_assert(offsetof(struct old_bbr,' + name + ')==offsetof(struct new_bbr,' + name + '),"offset");\n')
                        code += 'int main(void){return 0;}\n'
                    if kind != 'layout':
                        code += (FIXTURES / ('guard_history_' + kind + '_cases.c')).read_text()
                    (root / 'module/check.c').write_text(code)
                    for hz in (250, 1000):
                        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                                        '-Wno-sign-compare', '-O2', '-fsanitize=undefined',
                                        '-fno-sanitize-recover=all', f'-DHZ={hz}',
                                        str(root / 'module/check.c'), '-o', str(root / 'check')], check=True)
                        subprocess.run([str(root / 'check')], check=True)
