"""Real installer functions with redirected files and inert package/boot tools."""
from pathlib import Path
import shlex

from test_scripts import Harness, ROOT

OLD = '6.8.0-147-generic'
NEW = '7.3.5-bbrguard6r5only-test'


class KernelInstallTests(Harness):
    def setUp(self):
        super().setUp()
        self.machine = self.root / 'machine'
        self.boot = self.machine / 'boot'
        for path in ['boot/grub', 'etc/default/grub.d', 'etc/initramfs-tools/hooks',
                     'etc/systemd/system', 'usr/local/libexec', f'lib/modules/{OLD}']:
            (self.machine / path).mkdir(parents=True, exist_ok=True)
        for name in [f'vmlinuz-{OLD}', f'initrd.img-{OLD}']:
            (self.boot / name).write_text('bootable')
        self.grub = self.boot / 'grub/grub.cfg'
        self.grub.write_text(f'''set default="gnulinux-advanced-id>gnulinux-{OLD}-advanced-id"
submenu 'Advanced' 'gnulinux-advanced-id' {{
menuentry 'old' 'gnulinux-{OLD}-advanced-id' {{ }}
}}
''')
        self.build = self.state / 'build'
        self.build.mkdir()
        (self.build / 'kernel-release').write_text(NEW + '\n')
        for kind in ['image', 'headers']:
            (self.build / f'linux-{kind}-{NEW}.deb').write_text('fixture')
        # Redirect every absolute path touched by installation. APT, sysctl,
        # systemd and initramfs commands below never delegate to the host.
        script = (ROOT / 'bbr.sh').read_text()
        for path in ['/boot/', '/lib/modules/', '/etc/default/grub.d', '/etc/initramfs-tools',
                     '/etc/systemd/system', '/usr/local/libexec', '/var/lib/ubuntu-dd']:
            script = script.replace(path, str(self.machine) + path)
        copy = self.root / 'bbr-test.sh'
        copy.write_text(script)
        self.prefix = self.prefix.replace(str(ROOT / 'bbr.sh'), str(copy))
        self.prefix += f'MACHINE={shlex.quote(str(self.machine))}\nOLD={OLD}\nNEW={NEW}\n' + r'''
MODE=success
uname() { if [[ $1 == -r ]]; then echo "${RUNNING:-$OLD}"; else echo x86_64; fi; }
dpkg-query() { echo installed; }
dpkg-deb() {
    case "$3" in
        Package) basename "$2" .deb ;;
        Version) echo 7.3.5-test.1 ;;
        Architecture) echo amd64 ;;
        *) return 96 ;;
    esac
}
apt-get() {
    printf '%s\n' "$*" >> "$STATE/apt-calls"
    if [[ $MODE == removal && " $* " != *' --no-remove '* ]]; then
        echo removed > "$STATE/old-kernel-removed"
        return 82
    fi
    printf installed > "$MACHINE/boot/vmlinuz-$NEW"
    mkdir -p "$MACHINE/lib/modules/$NEW"
    update-grub
    cp "$MACHINE/boot/grub/grub.cfg" "$STATE/grub-during-apt"
    case "$MODE" in
        apt) return 81 ;;
        signal) kill -TERM "$BASHPID" ;;
        kill) kill -KILL "$BASHPID" ;;
        empty-image) : > "$MACHINE/boot/vmlinuz-$NEW" ;;
    esac
}
modinfo() { [[ $MODE != driver || " $* " != *" $NEW "* ]]; }
update-initramfs() {
    [[ $MODE != initramfs ]] || return 83
    printf initrd > "$MACHINE/boot/initrd.img-$NEW"
    [[ $MODE != empty-initrd ]] || : > "$MACHINE/boot/initrd.img-$NEW"
}
update-grub() {
    local GRUB_DEFAULT="gnulinux-advanced-id>gnulinux-$NEW-advanced-id"
    local fragment=$MACHINE/etc/default/grub.d/99-bbr-kernel.cfg
    [[ ! -f $fragment ]] || source "$fragment"
    [[ $MODE != fallback ]] || return 86
    [[ $MODE != grub || $GRUB_DEFAULT != *"$NEW"* ]] || return 84
    {
        printf 'set default="%s"\n' "$GRUB_DEFAULT"
        echo "submenu 'Advanced' 'gnulinux-advanced-id' {"
        printf "menuentry 'old' 'gnulinux-%s-advanced-id' { }\n" "$OLD"
        [[ ! -f $MACHINE/boot/vmlinuz-$NEW ]] || printf "menuentry 'new' 'gnulinux-%s-advanced-id' { }\n" "$NEW"
        echo '}'
    } > "$MACHINE/boot/grub/grub.cfg"
}
sysctl() {
    case "${2:-}" in
        net.ipv4.tcp_congestion_control) echo cubic ;;
        net.core.default_qdisc) echo fq_codel ;;
        *) return 97 ;;
    esac
}
systemctl() {
    echo "$*" >> "$STATE/systemctl-calls"
    [[ $MODE != kill-after-boot || $1 != daemon-reload ]] || kill -KILL "$BASHPID"
    [[ $MODE != service || $1 != daemon-reload ]] || return 85
}
'''

    def run_install(self, mode='success', success=True, extra=''):
        return self.shell(f'MODE={mode}\n{extra}\ninstall_built_kernel "$STATE/build"', success=success)

    def assert_old_default(self):
        self.assertIn(f'set default="gnulinux-advanced-id>gnulinux-{OLD}-advanced-id"', self.grub.read_text())

    def test_failed_install_keeps_a_verified_old_default(self):
        for mode in ['apt', 'driver', 'initramfs', 'grub', 'service']:
            with self.subTest(mode=mode):
                self.run_install(mode, success=False)
                self.assert_old_default()
                self.assertFalse((self.state / 'cleanup-pending').exists())

    def test_failed_finalization_restores_configuration(self):
        (self.config / 'sysctl.conf').write_text('# old sysctl\n')
        (self.config / 'modules.conf').write_text('# old modules\n')
        (self.state / 'profile').write_text('previous\n')
        self.run_install('service', success=False)
        self.assertEqual((self.config / 'sysctl.conf').read_text(), '# old sysctl\n')
        self.assertEqual((self.config / 'modules.conf').read_text(), '# old modules\n')
        self.assertEqual((self.state / 'profile').read_text(), 'previous\n')
        self.assertFalse((self.state / 'kernel-release').exists())

    def test_package_install_forbids_dependency_removals(self):
        self.run_install('removal')
        self.assertFalse((self.state / 'old-kernel-removed').exists())
        self.assertIn('--no-remove', (self.state / 'apt-calls').read_text())

    def test_relative_package_directory_is_resolved_before_apt(self):
        self.shell('cd "$STATE"\ninstall_built_kernel build')
        command = (self.state / 'apt-calls').read_text()
        for kind in ('image', 'headers'):
            self.assertIn(str(self.build / f'linux-{kind}-{NEW}.deb'), command)
        self.assertNotIn(' build/linux-', command)

    def test_same_release_reinstall_requires_distinct_rollback(self):
        self.run_install(success=False, extra='RUNNING=$NEW')
        self.assertFalse((self.state / 'apt-calls').exists())

    def test_success_pins_fallback_during_apt_and_commits_new_default(self):
        self.run_install()
        self.assertIn(f'gnulinux-{OLD}-advanced-id"', (self.state / 'grub-during-apt').read_text())
        self.assertIn(f'set default="gnulinux-advanced-id>gnulinux-{NEW}-advanced-id"', self.grub.read_text())
        self.assertEqual((self.state / 'rollback-release').read_text(), OLD + '\n')
        self.assertEqual((self.state / 'kernel-release').read_text(), NEW + '\n')
        self.assertTrue((self.state / 'cleanup-pending').exists())
        self.assertFalse((self.state / 'install-pending').exists())
        transactions = list(self.state.glob('install.*'))
        self.assertEqual(len(transactions), 1)
        self.assertEqual((transactions[0] / 'phase').read_text(), 'complete\n')

    def test_same_release_reinstall_with_valid_fallback_succeeds(self):
        self.run_install()
        (self.state / 'cleanup-pending').unlink()
        self.run_install(extra='RUNNING=$NEW')
        self.assertEqual((self.state / 'rollback-release').read_text(), OLD + '\n')
        self.assertTrue((self.state / 'cleanup-pending').exists())

    def test_invalid_or_missing_fallback_stops_before_apt(self):
        for record in [NEW, 'invalid/path', '6.8.0-missing']:
            (self.state / 'rollback-release').write_text(record + '\n')
            self.run_install(success=False, extra='RUNNING=$NEW')
            self.assertFalse((self.state / 'apt-calls').exists())

    def test_fallback_pin_failure_never_installs_packages(self):
        before = self.grub.read_bytes()
        self.run_install('fallback', success=False)
        self.assertEqual(self.grub.read_bytes(), before)
        self.assertFalse((self.state / 'apt-calls').exists())
        self.assertFalse((self.state / 'install-pending').exists())

    def test_empty_image_or_initrd_never_commits(self):
        for mode in ['empty-image', 'empty-initrd']:
            self.run_install(mode, success=False)
            self.assert_old_default()
            self.assertFalse((self.state / 'cleanup-pending').exists())

    def test_signal_restores_boot_and_configuration(self):
        result = self.run_install('signal', success=False)
        self.assertEqual(result.returncode, 143)
        self.assert_old_default()
        self.assertFalse((self.state / 'install-pending').exists())

    def test_forced_termination_recovers_before_retry(self):
        for mode in ['kill', 'kill-after-boot']:
            with self.subTest(mode=mode):
                self.run_install(mode, success=False)
                self.assertTrue((self.state / 'install-pending').exists())
                self.shell('recover_kernel_install')
                self.assert_old_default()
                self.assertFalse((self.state / 'install-pending').exists())
                self.assertFalse((self.state / 'cleanup-pending').exists())
        self.run_install()
        self.assertTrue((self.state / 'cleanup-pending').exists())

    def test_completed_transaction_recovery_does_not_undo_success(self):
        self.run_install(success=False, extra='finish_kernel_install() { kill -KILL "$BASHPID"; }')
        self.assertTrue((self.state / 'install-pending').exists())
        self.shell('recover_kernel_install')
        self.assertFalse((self.state / 'install-pending').exists())
        self.assertTrue((self.state / 'cleanup-pending').exists())
        self.assertIn(f'set default="gnulinux-advanced-id>gnulinux-{NEW}-advanced-id"', self.grub.read_text())

    def test_failed_restoration_preserves_marker_and_next_run_recovers(self):
        (self.config / 'sysctl.conf').write_text('# original\n')
        self.run_install('service', success=False, extra='kernel_restore_file() { return 87; }')
        self.assertTrue((self.state / 'install-pending').exists())
        self.shell('recover_kernel_install')
        self.assert_old_default()
        self.assertEqual((self.config / 'sysctl.conf').read_text(), '# original\n')
        self.assertFalse((self.state / 'cleanup-pending').exists())
        self.assertFalse((self.state / 'install-pending').exists())

    def test_interrupted_install_blocks_reboot_and_cleanup(self):
        (self.state / 'install-pending').write_text('unfinished')
        for action in ['reboot', 'cleanup']:
            result = self.shell(f'''require_host() {{ :; }}
reboot_host() {{ echo UNEXPECTED_REBOOT; }}
ACTION={action}; dispatch
''', success=False)
            self.assertIn('安装', result.stderr)
            self.assertNotIn('UNEXPECTED_REBOOT', result.stdout)
            self.assertFalse((self.state / 'apt-calls').exists())

    def test_recovery_refuses_paths_outside_transaction_directory(self):
        (self.state / 'install-pending').write_text(str(self.root) + '\n')
        self.shell('recover_kernel_install', success=False)
        self.assertTrue((self.state / 'install-pending').exists())

    def test_symlinked_configuration_is_restored_without_touching_target(self):
        original = self.root / 'original.conf'
        original.write_text('# external original\n')
        (self.config / 'sysctl.conf').symlink_to(original)
        hook = self.machine / 'etc/initramfs-tools/hooks/bbr-cloud-nic'
        hook.write_text('# original hook\n')
        self.run_install('service', success=False)
        self.assertTrue((self.config / 'sysctl.conf').is_symlink())
        self.assertEqual(original.read_text(), '# external original\n')
        self.assertEqual(hook.read_text(), '# original hook\n')

    def test_missing_backup_does_not_erase_configuration_or_clear_marker(self):
        (self.config / 'sysctl.conf').write_text('# original\n')
        self.run_install('kill-after-boot', success=False)
        transaction = Path((self.state / 'install-pending').read_text().strip())
        (transaction / 'before/sysctl.conf').unlink()
        current = (self.config / 'sysctl.conf').read_bytes()
        self.shell('recover_kernel_install', success=False)
        self.assertEqual((self.config / 'sysctl.conf').read_bytes(), current)
        self.assertTrue((self.state / 'install-pending').exists())

    def test_dd_plan_blocks_recovery_before_boot_changes(self):
        self.run_install('kill-after-boot', success=False)
        dd = self.machine / 'var/lib/ubuntu-dd'
        dd.mkdir(parents=True)
        (dd / 'reinstall-pending').touch()
        before = self.grub.read_bytes()
        self.shell('recover_kernel_install', success=False)
        self.assertEqual(self.grub.read_bytes(), before)
        self.assertTrue((self.state / 'install-pending').exists())
