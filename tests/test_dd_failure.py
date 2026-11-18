"""Same-boot installer failure recovery, using files and no block devices."""
import shlex
import subprocess
import re
import tarfile

from test_dd_hardening import ROOT, RuntimeHarness, patch


class FailureJournalTests(RuntimeHarness):
    def setUp(self):
        super().setUp()
        self.journal = self.root / 'journal'
        self.prefix += f'DD_INSTALL_STATE={shlex.quote(str(self.journal))}\n'

    def test_prepartition_failure_can_retry_without_erasing(self):
        r = self.run_shell('dd_install_begin; dd_fail "bad signature"', ok=False)
        self.assertIn('Partitioning has not started', r.stderr)
        self.assertFalse((self.journal / 'destructive').exists())
        self.assertEqual((self.journal / 'exit-status').read_text(), '1\n')
        self.run_shell('dd_install_begin; test ! -e "$DD_INSTALL_STATE/exit-status"; dd_install_stage complete')
        self.assertEqual((self.journal / 'exit-status').read_text(), '0\n')
        self.assertIn('phase=complete\n', (self.journal / 'status').read_text())

    def test_failed_disk_download_blocks_repartition_on_retry(self):
        r = self.run_shell('''
dd_install_begin
DD_CACHE_MODE=disk; DD_PARTITION_READY=1; xda=disposable
dd_require_partition
dd_install_stage image-download
mountpoint() { return 1; }
dd_fail 'transport exhausted'
''', ok=False)
        self.assertIn('stage image-download', r.stderr)
        self.assertIn('Disk writes have started', r.stderr)
        self.assertEqual((self.journal / 'destructive').read_text(), 'disposable\n')
        self.assertEqual((self.journal / 'exit-status').read_text(), '1\n')
        r = self.run_shell('dd_install_begin; touch "$DD_BUNDLE/erased-again"', ok=False)
        self.assertIn('Automatic restart is refused', r.stderr)
        self.assertFalse((self.bundle / 'erased-again').exists())

    def test_partition_package_and_boot_failures_preserve_original_status(self):
        for phase in ('partitioning', 'package-install', 'target-validation'):
            with self.subTest(phase=phase):
                # Independent attempt directories; do not discard failed evidence.
                self.prefix += f'DD_INSTALL_STATE={shlex.quote(str(self.root / phase))}\n'
                r = self.run_shell(f'''
dd_install_begin
DD_CACHE_MODE=disk; DD_PARTITION_READY=1
dd_require_partition
dd_install_stage {phase}
mountpoint() {{ return 1; }}
(exit 42)
touch "$DD_BUNDLE/rebooted"
''', ok=False)
                self.assertEqual(r.returncode, 42, r.stderr)
                self.assertIn('stage ' + phase, r.stderr)
                self.assertFalse((self.bundle / 'rebooted').exists())

    def test_only_one_installer_can_enter_preflight(self):
        self.run_shell('mkdir -p "$DD_INSTALL_STATE/lock"; dd_install_begin', ok=False)

    def test_boundary_is_checked_after_lock_acquisition(self):
        r = self.run_shell('''
mkdir() {
    command mkdir "$@" || return
    case "$*" in
        */lock) printf 'previous-disk\\n' > "$DD_INSTALL_STATE/destructive" ;;
    esac
}
dd_install_begin
touch "$DD_BUNDLE/entered-preflight"
''', ok=False)
        self.assertIn('Automatic restart is refused', r.stderr)
        self.assertFalse((self.bundle / 'entered-preflight').exists())
        self.assertFalse((self.journal / 'lock').exists())
        self.assertFalse((self.journal / 'status').exists())

    def test_failure_evidence_keeps_lock_until_recorded(self):
        self.run_shell('''
dd_install_begin
dd_disk_cache() {
    test -d "$DD_INSTALL_STATE/lock" && touch "$DD_BUNDLE/lock-held"
    test "$(cat "$DD_INSTALL_STATE/exit-status")" = 42 && touch "$DD_BUNDLE/status-recorded"
    return 1
}
exit 42
''', ok=False)
        self.assertTrue((self.bundle / 'lock-held').exists())
        self.assertTrue((self.bundle / 'status-recorded').exists())
        self.assertFalse((self.journal / 'lock').exists())

    def test_signals_preserve_failure_status_and_unlock_in_supported_shells(self):
        for shell in (['bash'], ['dash'], ['busybox', 'ash']):
            for signal, status in (('HUP', 129), ('INT', 130), ('TERM', 143)):
                with self.subTest(shell=shell, signal=signal):
                    journal = self.root / ('-'.join(shell) + '-' + signal)
                    script = self.prefix + (
                        f'DD_INSTALL_STATE={shlex.quote(str(journal))}\n'
                        f'dd_install_begin; kill -{signal} $$\n')
                    r = subprocess.run(shell + ['-c', script], capture_output=True,
                                       text=True, timeout=10)
                    self.assertEqual(r.returncode, status, r.stderr)
                    self.assertEqual((journal / 'exit-status').read_text(), f'{status}\n')
                    self.assertFalse((journal / 'lock').exists())

    def test_busybox_ash_uses_same_exit_and_write_boundary(self):
        script = self.prefix + '''
dd_install_begin
DD_CACHE_MODE=disk; DD_PARTITION_READY=1
dd_require_partition
mountpoint() { return 1; }
exit 17
'''
        r = subprocess.run(['busybox', 'ash', '-c', script], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 17, r.stderr)
        self.assertIn('Disk writes have started', r.stderr)

    def test_patched_upstream_error_trap_preserves_command_exit_status(self):
        with tarfile.open(ROOT / '.cache/reinstall-8ac9db68.tar.gz') as archive:
            text = archive.extractfile(next(m for m in archive.getmembers()
                                            if m.name.endswith('/trans.sh'))).read().decode()
        patched = patch.patch_trans(text)
        function = re.search(r'trap_err\(\) \{\n.*?\n\}', patched, re.S).group()
        script = self.prefix + function + '''
set -eE
dd_install_begin
trap 'trap_err $LINENO $?' ERR
fail_command() { return 42; }
fail_command
'''
        r = subprocess.run(['busybox', 'ash', '-c', script], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 42, r.stderr)
        self.assertEqual((self.journal / 'exit-status').read_text(), '42\n')
        self.assertIn('(exit 42)', r.stderr)
