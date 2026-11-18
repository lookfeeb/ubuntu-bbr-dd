"""Generated probe-stop decision must preserve an accepted single loss only."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_wan_recovery import FIXTURES, c_function, module, pinned_source


class ProbeConsistencyTests(unittest.TestCase):
    def test_single_loss_continuation_and_all_exclusion_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'source.c').write_bytes(pinned_source())
            module('wan_recovery').generate(root / 'source.c', root / 'module')
            source = (root / 'module/tcp_bbr_guard.c').read_text()
            stub = (FIXTURES / 'guard_socket_stubs.h').read_text()
            stub = stub.replace('u32 guard_large_sample,', 'u32 prev_probe_too_high, guard_large_sample,')
            stub = stub.replace('bool ecn;', 'bool ecn, is_cwnd_limited;')
            stub = stub.replace('u32 tx_in_flight;', 'u32 tx_in_flight, acked_sacked; int losses;')
            code = '#include <assert.h>\n#include <stdio.h>\n#include <string.h>\n' + stub
            for name in ('bbrguard_recovery_allowed', 'bbrguard_early_probe', 'bbrguard_tiny_single_loss'):
                code += c_function(source, 'static bool ' + name + '(')
            body = c_function(source, 'static void bbrguard_cc_update_cycle_phase(')
            expression = re.search(r'if \((bbr->prev_probe_too_high &&.*?)\) \{', body, re.S)[1]
            code += ('static bool stop_probe(struct sock *sk, const struct rate_sample *rs, u32 inflight) {\n'
                     'const struct bbrguard *bbr=inet_csk_ca(sk);const struct tcp_sock *tp=tcp_sk(sk);\n'
                     'return ' + expression + ';\n}\n')
            code += (FIXTURES / 'guard_probe_consistency_cases.c').read_text()
            (root / 'module/check.c').write_text(code)
            for hz in (250, 1000):
                subprocess.run(['cc', '-O2', '-Wall', '-Wextra', '-Werror',
                                '-fsanitize=undefined', '-fno-sanitize-recover=all',
                                f'-DHZ={hz}', str(root / 'module/check.c'), '-o', str(root / 'check')], check=True)
                subprocess.run([str(root / 'check')], check=True)
