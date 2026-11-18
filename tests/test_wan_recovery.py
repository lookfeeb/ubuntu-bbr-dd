import hashlib
import importlib.util
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
FIXTURES = Path(__file__).with_name('fixtures')


def pinned_source():
    patch = (TOOLS / 'google-bbr3.patch').read_text()
    section = patch.split('diff --git a/net/ipv4/tcp_bbr3.c b/net/ipv4/tcp_bbr3.c\n', 1)[1]
    lines = section.split('@@ -0,0 +1,2271 @@\n', 1)[1].splitlines()[:2271]
    return ('\n'.join(x[1:] for x in lines) + '\n').encode()


def c_function(source, declaration):
    match = re.search(re.escape(declaration) + r'[^;]+?\n\{', source)
    if match is None:
        raise ValueError('Missing C function definition: ' + declaration)
    start = match.start()
    return source[start:source.index('\n}\n', start) + 3]


def module(name):
    sys.path.insert(0, str(TOOLS))
    try:
        spec = importlib.util.spec_from_file_location(name, TOOLS / (name + '.py'))
        obj = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(obj)
        return obj
    finally:
        sys.path.pop(0)


class TestRecoveryPolicy(unittest.TestCase):
    def test_round_filter_queue_budget_counter_rollover_and_memory_budget(self):
        policy = module('wan_recovery').POLICY
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'policy.h').write_text(policy)
            (root/'check.c').write_text(r'''
#include <assert.h>
#include "policy.h"
int main(void) {
 struct bbrguard_gate g = {0}; unsigned int good = 0;
 _Static_assert(sizeof(g) == 12, "Keep connection state within the existing CA budget");
 good=bbrguard_finish_round(&g,31,1,good,1); assert(!good);
 good=bbrguard_finish_round(&g,62,2,good,1); assert(!good);
 good=bbrguard_finish_round(&g,93,3,good,1); assert(!good);
 assert(!g.delivered_stamp && !g.lost_stamp); /* accumulate >=128 packets */
 good=bbrguard_finish_round(&g,124,4,good,1); assert(good==3);
 good=bbrguard_finish_round(&g,252,4,good,1); assert(good==3); /* clean keeps evidence */
 good=bbrguard_finish_round(&g,281,7,good,1); assert(good==3); /* short overlap is pending */
 assert(g.delivered_stamp==252 && g.lost_stamp==4);
 good=bbrguard_finish_round(&g,300,7,3,0); assert(!good); /* queue/ECN/RTO discards pending */
 assert(g.delivered_stamp==300 && g.lost_stamp==7);
 g=(struct bbrguard_gate){0};
 assert(bbrguard_finish_round(&g,192,8,0,1)==3); /* exactly 4% */
 g=(struct bbrguard_gate){0};
 assert(!bbrguard_finish_round(&g,191,9,0,1)); /* 4.5% cannot enter */
 g=(struct bbrguard_gate){0};
 assert(bbrguard_finish_round(&g,191,9,3,1)==3); /* 4.5% retains qualification */
 g=(struct bbrguard_gate){0};
 assert(bbrguard_finish_round(&g,185,15,3,1)==3); /* 7.5% retains */
 g=(struct bbrguard_gate){0};
 assert(!bbrguard_finish_round(&g,184,16,3,1)); /* exactly 8% revokes */
 g=(struct bbrguard_gate){0};
 assert(bbrguard_finish_round(&g,30,2,3,1)==3); /* 6.25% needs more evidence */
 assert(!g.delivered_stamp && !g.lost_stamp);
 g=(struct bbrguard_gate){0};
 assert(bbrguard_finish_round(&g,28,4,3,1)==3); /* qualified: pending until 128 */
 assert(!g.delivered_stamp && !g.lost_stamp);
 assert(bbrguard_finish_round(&g,116,11,3,1)==3); /* 127 still pending */
 assert(!bbrguard_finish_round(&g,117,11,3,1)); /* 128/8% revocation */
 assert(g.delivered_stamp==117 && g.lost_stamp==11);
 g=(struct bbrguard_gate){0};
 assert(!bbrguard_finish_round(&g,28,4,0,1)); /* unqualified early exit preserved */
 assert(g.delivered_stamp==28 && g.lost_stamp==4);
 g=(struct bbrguard_gate){0};
 assert(!bbrguard_finish_round(&g,128,0,0,1)); /* don't infer lossy-path eligibility from no loss */
 assert(bbrguard_finish_round(&g,252,4,0,1)==3);
 g=(struct bbrguard_gate){.delivered_stamp=~0U-99,.lost_stamp=~0U-1};
 good=bbrguard_finish_round(&g,24,2,0,1); assert(good==3); /* 124 delivered, 4 lost across wrap */
 g=(struct bbrguard_gate){0};
 assert(!bbrguard_finish_round(&g,~0U,~0U,2,1)); /* wide denominator */
 assert(bbrguard_queue_ok(200000,202000,32,2000));
 assert(!bbrguard_queue_ok(200000,202001,32,2000));
 assert(bbrguard_queue_ok(50000,51562,32,2000));
 assert(!bbrguard_queue_ok(50000,51563,32,2000));
 assert(!bbrguard_queue_ok(49999,49999,32,2000));
 assert(!bbrguard_queue_ok(100000,99999,32,2000));
 assert(!bbrguard_queue_ok(~0U,~0U,32,2000));
 return 0;
}
''')
            subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(root/'check.c'),'-o',str(root/'check')],check=True)
            subprocess.run([str(root/'check')],check=True)

    def test_generator_pins_input_and_keeps_rto_and_severe_loss_paths(self):
        raw = pinned_source()
        recovery=module('wan_recovery')
        self.assertEqual(hashlib.sha256(raw).hexdigest(),recovery.SOURCE_SHA256)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); source=root/'source.c'; source.write_bytes(raw)
            recovery.generate(source,root/'module')
            text=(root/'module/tcp_bbr_guard.c').read_text()
            # R3 stabilizes qualified loss evidence with bounded hysteresis.
            # Frozen callback comparison permits only the declared short-sample change.
            expected = {
                'tcp_bbr_guard.c': '7de65dffbaeb7dfcbc0d21d2b820227efb1232747f64abbbacff0f84d17f7d42',
                'tcp_bbr_guard_policy.h': '06b6b3cb2be6ccfbf08025009a84e1152a9598fbd9b815b01adaf1cb2a3fd8e4',
                'tcp_bbr_wan_policy.h': '6f9f395de068084ffe76481c88f57530db996b803dcc295657b2e46f28fa39ad',
            }
            for name, digest in expected.items():
                self.assertEqual(hashlib.sha256((root/'module'/name).read_bytes()).hexdigest(), digest)
            self.assertIn('MODULE_VERSION("3-guard7-r2-experimental")', text)
            self.assertIn('BUILD_BUG_ON(sizeof(struct bbrguard) > ICSK_CA_PRIV_SIZE)',text)
            self.assertRegex(text, r'if \(new_state == TCP_CA_Loss\) \{[^}]+bbr->guard_good_rounds = 0;')
            self.assertIn('const u32 beta = bbrguard_param(sk, beta);',text)
            self.assertIn('rs->tx_in_flight * 8',text)
            self.assertNotIn('kzalloc',text)
            self.assertIn('before(tcp_jiffies32, bbr->min_rtt_stamp + 5 * HZ)',text)
            kernel=root/'linux'; ipv4=kernel/'net/ipv4'; ipv4.mkdir(parents=True)
            (kernel/'Makefile').write_text('VERSION = 7\nPATCHLEVEL = 3\nSUBLEVEL = 5\n')
            (ipv4/'tcp_bbr3.c').write_bytes(raw)
            (ipv4/'Kconfig').write_text('config TCP_CONG_BBR3\n')
            (ipv4/'Makefile').write_text('obj-$(CONFIG_TCP_CONG_BBR_WAN) += tcp_bbr_wan.o\n')
            (ipv4/'tcp_bbr_wan_policy.h').write_text('existing WAN header\n')
            recovery.apply_kernel_tree(kernel)
            # The delivered single script must generate exactly the same Guard
            # sources without a tools/ directory next to it.
            import shutil
            embedded_tree = root / 'standalone-linux'
            embedded_ipv4 = embedded_tree / 'net/ipv4'
            embedded_ipv4.mkdir(parents=True)
            (embedded_tree / 'Makefile').write_bytes((kernel / 'Makefile').read_bytes())
            (embedded_ipv4 / 'tcp_bbr3.c').write_bytes(raw)
            (embedded_ipv4 / 'Kconfig').write_text('config TCP_CONG_BBR3\n')
            (embedded_ipv4 / 'Makefile').write_text('')
            standalone = root / 'bbr.sh'
            shutil.copyfile(TOOLS.parent / 'bbr.sh', standalone)
            subprocess.run(['bash', '-c', 'source "$1"; apply_recovery_patch "$2"',
                            'test', str(standalone), str(embedded_tree)], check=True, capture_output=True)
            for name in ('tcp_bbr_guard.c', 'tcp_bbr_guard_policy.h', 'tcp_bbr_guard_legacy.h'):
                self.assertEqual((embedded_ipv4 / name).read_bytes(), (ipv4 / name).read_bytes())
            self.assertEqual((ipv4/'tcp_bbr_wan_policy.h').read_text(),'existing WAN header\n')
            self.assertIn('"tcp_bbr_guard_legacy.h"',(ipv4/'tcp_bbr_guard.c').read_text())
            before=(ipv4/'Kconfig').read_bytes()
            with self.assertRaisesRegex(ValueError,'already present'):
                recovery.apply_kernel_tree(kernel)
            self.assertEqual((ipv4/'Kconfig').read_bytes(),before)
            with self.assertRaises(FileExistsError):
                recovery.generate(source,root/'module')
            source.write_bytes(raw+b'\n')
            with self.assertRaisesRegex(ValueError,'pinned'):
                recovery.generate(source,root/'bad')

    def test_loss_hotpath_only_changes_qualified_short_samples(self):
        self.run_compiled_case('guard_hotpath_cases.c', reference=True)

    def test_recovery_gate_after_sparse_loss_and_delayed_acks(self):
        self.run_compiled_case('guard_recovery_cases.c')

    def test_queue_permission_does_not_erase_loss_evidence(self):
        self.run_compiled_case('guard_queue_permission_cases.c')

    def run_compiled_case(self, fixture, reference=False):
        recovery = module('wan_recovery')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source.c'
            source.write_bytes(pinned_source())
            recovery.generate(source, root / 'module')
            generated = (root / 'module/tcp_bbr_guard.c').read_text()
            functions = '\n'.join(c_function(generated, declaration) for declaration in (
                'static bool bbrguard_recovery_allowed(',
                'static void bbrguard_update_gate(',
                'static bool bbrguard_relaxed_loss(',
                'static u32 bbrguard_loss_limit(',
                'static bool bbrguard_tiny_single_loss(',
                'static bool bbrguard_recovery_context(',
                'static bool bbrguard_cc_is_inflight_too_high(',
            ))
            stubs = (FIXTURES / 'guard_socket_stubs.h').read_text()
            oracle = c_function((FIXTURES / 'guard6_hotpath_reference.h').read_text(),
                                'static bool reference_bbrguard_cc_is_inflight_too_high(') if reference else ''
            code = stubs + functions + oracle + (FIXTURES / fixture).read_text()
            (root / 'module/check.c').write_text(code)
            # Exercise different tick rates and both ordinary and UBSan builds.
            for hz, flags in ((250, ['-O2']), (1000, ['-O2', '-fsanitize=undefined', '-fno-sanitize-recover=all'])):
                with self.subTest(hz=hz):
                    # Match the kernel's signed/unsigned comparison policy for
                    # the unchanged upstream loss_thresh comparison.
                    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-sign-compare', *flags,
                                    f'-DHZ={hz}', str(root/'module/check.c'), '-o', str(root/'check')], check=True)
                    subprocess.run([str(root/'check')], check=True)


class TestRecoveryPackage(unittest.TestCase):
    def test_guard_only_config_rejects_original_algorithms(self):
        package = module('package_recovery')
        config = 'CONFIG_TCP_CONG_BBR_GUARD=m\n# CONFIG_TCP_CONG_BBR3 is not set\n'
        package.verify_guard_config(config)
        for name in ('BBR', 'BBR3', 'BBR_WAN'):
            for state in ('m', 'y'):
                with self.assertRaisesRegex(ValueError, 'still enabled'):
                    package.verify_guard_config(config + f'CONFIG_TCP_CONG_{name}={state}\n')
        with self.assertRaisesRegex(ValueError, 'not enabled'):
            package.verify_guard_config('CONFIG_TCP_CONG_BBR_GUARD=n\n')

    def test_package_contents_reject_old_compressed_modules_and_missing_guard(self):
        package = module('package_recovery')
        guard = './lib/modules/test/kernel/net/ipv4/tcp_bbr_guard.ko.zst'
        package.verify_module_names([guard, './boot/vmlinuz-test'], True)
        for name in ('tcp_bbr', 'tcp_bbr3', 'tcp_bbr_wan'):
            for suffix in ('.ko', '.ko.xz', '.ko.gz', '.ko.zst'):
                with self.assertRaisesRegex(ValueError, 'original'):
                    package.verify_module_names([guard, './lib/modules/test/' + name + suffix], True)
        for names in ([], [guard, guard.replace('.zst', '')]):
            with self.assertRaisesRegex(ValueError, 'exactly one'):
                package.verify_module_names(names, True)


if __name__ == '__main__':
    unittest.main()
