"""Nginx version selection and failure handling without modifying the host."""
from test_scripts import Harness, ROOT


class TestNginx(Harness):
    def test_stable_version_excludes_mainline_and_legacy(self):
        (self.state / 'page').write_text('''<h4>Mainline version</h4>
<a href="/download/nginx-9.9.9.tar.gz">mainline</a>
<h4>Stable version</h4><a href="/download/nginx-1.30.9.tar.gz">old</a>
<a href="/download/nginx-1.30.10.tar.gz">current</a>
<h4>Legacy versions</h4><a href="/download/nginx-8.8.8.tar.gz">legacy</a>''')
        self.assertEqual(self.shell('nginx_stable_version "$STATE/page"').stdout.strip(), '1.30.10')

    def test_missing_or_external_stable_fails_closed(self):
        for content in ('<h4>Mainline version</h4>',
                        '<h4>Stable version</h4><a href="https://evil/nginx-1.30.6.tar.gz">x</a>'):
            (self.state / 'page').write_text(content)
            self.shell('nginx_stable_version "$STATE/page"', success=False)

    def test_source_signature_failure_prevents_extraction(self):
        self.shell('''
nginx_fetch() { touch "$2"; }
nginx_stable_version() { echo 1.30.6; }
gpg() { [[ "$*" != *--verify* ]]; }
tar() { touch "$STATE/extracted"; }
nginx_source "$STATE"
''', success=False)
        self.assertFalse((self.state / 'extracted').exists())

    def test_unapproved_signer_prevents_extraction(self):
        self.shell('''
nginx_fetch() { touch "$2"; }
nginx_stable_version() { echo 1.30.6; }
gpg() { echo '[GNUPG:] VALIDSIG 0000000000000000000000000000000000000000 2026'; }
tar() { touch "$STATE/extracted"; }
nginx_source "$STATE"
''', success=False)
        self.assertFalse((self.state / 'extracted').exists())

    def test_existing_swap_file_or_symlink_is_never_overwritten(self):
        swap = self.state / 'swapfile'
        for symlink in (False, True):
            if symlink:
                swap.symlink_to(self.state / 'missing')
            else:
                swap.write_text('existing')
            self.shell('dd() { touch "$STATE/overwritten"; }; nginx_prepare_swap "$STATE"', success=False)
            self.assertFalse((self.state / 'overwritten').exists())
            swap.unlink()

    def swap_fixture(self):
        (self.state / 'swapfile').write_text('swap')
        (self.state / 'swap.uuid').write_text('test-uuid')
        (self.state / 'fstab').write_text('# existing fstab\n/other none swap sw 0 0\n')
        return '''
stat() { echo 0:600:2147483648; }
blkid() { if [[ "$*" == *UUID* ]]; then echo test-uuid; else echo swap; fi; }
systemctl() { :; }
swapon() { if [[ "$*" == *--show* ]]; then echo /other; else echo ACTIVATED; fi; }
dd() { exit 93; }
'''

    def test_permanent_swap_reuse_and_single_fstab_entry(self):
        self.shell(self.swap_fixture() + '''
nginx_prepare_swap "$STATE" "$STATE/fstab"
nginx_prepare_swap "$STATE" "$STATE/fstab"
''')
        content = (self.state / 'fstab').read_text()
        self.assertEqual(content.count('# bbr-nginx'), 1)
        self.assertIn('/other none swap sw 0 0', content)
        self.assertIn('swap sw,nofail 0 0', content)
        self.assertTrue((self.state / 'swapfile').exists())

    def test_fstab_conflict_stops_before_activation(self):
        setup = self.swap_fixture()
        (self.state / 'fstab').write_text(f'{self.state}/swapfile none swap noauto 0 0\n')
        result = self.shell(setup + 'nginx_prepare_swap "$STATE" "$STATE/fstab"', success=False)
        self.assertNotIn('ACTIVATED', result.stdout)

    def test_exit_failure_rolls_back_only_after_install_changed(self):
        for changed in (0, 1):
            result = self.shell(f'''
NGX_CHANGED={changed}; NGX_BACKUP=$STATE; NGX_WORK=$STATE/build
mkdir -p "$NGX_WORK"
nginx_restore_install() {{ echo RESTORED; }}
nginx_finish 19
''', success=False)
            self.assertEqual(result.returncode, 19)
            self.assertEqual('RESTORED' in result.stdout, bool(changed))

    def test_helpers_embedded(self):
        self.assertIn((ROOT / 'tools/nginx_helpers.inc').read_text().strip(), (ROOT / 'bbr.sh').read_text())

    def creation_fixture(self):
        (self.state / 'fstab').write_text('# fixture\n/other none swap sw 0 0\n')
        return r'''
stat() {
    case "$2" in
        %u:%a) echo 0:600 ;;
        %u:%a:%s) echo 0:600:2147483648 ;;
        *) command stat "$@" ;;
    esac
}
dd() {
    local argument
    SWAP_CREATOR_PID=$BASHPID
    echo allocate >> "$STATE/allocations"
    for argument in "$@"; do
        case "$argument" in of=*) printf fake-swap > "${argument#of=}" ;; esac
    done
}
mkswap() { :; }
blkid() { if [[ "$*" == *UUID* ]]; then echo test-uuid; else echo swap; fi; }
systemctl() { :; }
swapon() {
    if [[ "$*" == *--show* ]]; then
        [[ ! -f $STATE/active ]] || cat "$STATE/active"
    else printf '%s\n' "$1" >> "$STATE/active"; fi
}
'''

    def prepare(self, setup, success=True):
        return self.shell(setup + '\nnginx_prepare_swap "$STATE" "$STATE/fstab"', success=success)

    def test_creation_failures_leave_retryable_state(self):
        setup = self.creation_fixture()
        for failure in ('dd() { return 74; }', 'mkswap() { return 75; }',
                        'dd() { kill -TERM "$BASHPID"; }'):
            with self.subTest(failure=failure):
                self.prepare(setup + failure, success=False)
                self.assertFalse((self.state / 'swapfile').exists())
                self.assertFalse((self.state / 'swap.uuid').exists())
                self.assertFalse((self.state / 'swap.pending').exists())
                self.assertEqual(list(self.state.glob('.swap*')), [])
        self.prepare(setup)
        self.assertEqual((self.state / 'swap.uuid').read_text(), 'test-uuid\n')
        self.assertEqual((self.state / 'fstab').read_text().count('# bbr-nginx'), 1)

    def test_sigkill_during_allocation_recovers_on_retry(self):
        setup = self.creation_fixture()
        self.prepare(setup + 'dd() { kill -KILL "$BASHPID"; }', success=False)
        self.assertTrue((self.state / 'swap.pending').exists())
        self.prepare(setup)
        self.assertEqual((self.state / 'swapfile').read_bytes(), b'fake-swap')
        self.assertFalse((self.state / 'swap.pending').exists())
        self.assertEqual(list(self.state.glob('.swap*')), [])

    def test_sigkill_between_file_and_marker_recovers_without_reallocation(self):
        setup = self.creation_fixture()
        self.prepare(setup + r'''
mv() {
    command mv "$@"
    if [[ ${@: -1} == "$STATE/swapfile" ]]; then kill -KILL "$SWAP_CREATOR_PID" "$BASHPID"; fi
}
''', success=False)
        self.assertTrue((self.state / 'swapfile').exists())
        self.assertFalse((self.state / 'swap.uuid').exists())
        self.prepare(setup + 'dd() { exit 93; }')
        self.assertEqual((self.state / 'allocations').read_text().splitlines(), ['allocate'])
        self.assertFalse((self.state / 'swap.pending').exists())

    def test_ready_journal_survives_failed_marker_publication(self):
        setup = self.creation_fixture()
        self.prepare(setup + r'''
mv() {
    [[ ${@: -1} != "$STATE/swap.uuid" ]] || return 76
    command mv "$@"
}
''', success=False)
        self.assertTrue((self.state / 'swap.pending').exists())
        self.assertTrue((self.state / 'swapfile').exists())
        self.prepare(setup + 'dd() { exit 93; }')
        self.assertEqual((self.state / 'swap.uuid').read_text(), 'test-uuid\n')

    def test_fstab_failure_preserves_active_swap_and_original_fstab(self):
        setup = self.creation_fixture()
        original = (self.state / 'fstab').read_bytes()
        self.prepare(setup + r'''
mv() {
    [[ ${@: -1} != "$STATE/fstab" ]] || return 77
    command mv "$@"
}
''', success=False)
        self.assertEqual((self.state / 'fstab').read_bytes(), original)
        self.assertTrue((self.state / 'swapfile').exists())
        self.assertEqual(list(self.state.glob('fstab.bbr-nginx.*')), [])
        self.prepare(setup + 'dd() { exit 93; }')
        self.assertEqual((self.state / 'active').read_text().splitlines(), [str(self.state / 'swapfile')])
        self.assertEqual((self.state / 'fstab').read_text().count('# bbr-nginx'), 1)

    def test_recovery_refuses_replaced_inode_and_active_partial(self):
        setup = self.creation_fixture()
        self.prepare(setup + 'dd() { kill -KILL "$BASHPID"; }', success=False)
        pending = self.state / 'swap.pending'
        identity, name, uuid = pending.read_text().split()
        staged = self.state / name
        pending.write_text(f'0:0 {name} {uuid}\n')
        self.prepare(setup, success=False)
        self.assertTrue(staged.exists())
        pending.write_text(f'{identity} {name} {uuid}\n')
        (self.state / 'active').write_text(str(staged) + '\n')
        self.prepare(setup, success=False)
        self.assertTrue(staged.exists())
        self.assertTrue(pending.exists())

    def test_recovery_refuses_symlink_and_unreadable_active_swap_state(self):
        setup = self.creation_fixture()
        pending = self.state / 'swap.pending'
        pending.symlink_to(self.state / 'missing-journal')
        self.prepare(setup, success=False)
        self.assertTrue(pending.is_symlink())
        pending.unlink()
        self.prepare(setup + 'dd() { kill -KILL "$BASHPID"; }', success=False)
        staged = self.state / pending.read_text().split()[1]
        self.prepare(setup + 'swapon() { return 79; }', success=False)
        self.assertTrue(staged.exists())
        self.assertTrue(pending.exists())
