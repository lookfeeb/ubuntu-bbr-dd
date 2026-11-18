"""Exercise single-kernel cleanup with real files and isolated package/boot stubs."""
from pathlib import Path
import shlex

from test_scripts import Harness, ROOT

KEEP = '7.3.5-bbrguard7r2only-test'
OLD = '7.0.0-1017-gcp'


class KernelCleanupTests(Harness):
    def setUp(self):
        super().setUp()
        self.machine = self.root / 'machine'
        self.boot = self.machine / 'boot'
        self.modules = self.machine / 'lib/modules'
        for path in ['boot/grub', 'etc/default/grub.d', 'var/lib/ubuntu-dd',
                     f'lib/modules/{KEEP}', f'lib/modules/{OLD}']:
            (self.machine / path).mkdir(parents=True, exist_ok=True)
        for release in (KEEP, OLD):
            for name in ('vmlinuz-', 'initrd.img-'):
                (self.boot / (name + release)).write_text('bootable-' + release)
        for name in ('vmlinuz', 'initrd.img'):
            for suffix in ('', '.old'):
                (self.boot / (name + suffix)).symlink_to(name + '-' + OLD)
        self.grub = self.boot / 'grub/grub.cfg'
        self.grub.write_text(f"submenu 'Advanced' 'gnulinux-advanced-id' {{\n"
                             f"menuentry 'Guard' 'gnulinux-{KEEP}-advanced-id' {{ }}\n}}\n")
        (self.state / 'kernel-release').write_text(KEEP + '\n')
        (self.state / 'profile').write_text('recovery\n')
        (self.state / 'rollback-release').write_text(OLD + '\n')
        (self.state / 'cleanup-pending').touch()
        self.inventory = self.state / 'inventory'
        self.inventory.write_text(''.join(package + '\tinstalled\n' for package in [
            f'linux-image-{KEEP}', f'linux-headers-{KEEP}',
            f'linux-image-{OLD}', f'linux-modules-{OLD}', f'linux-headers-{OLD}',
            'linux-gcp-7.0-headers-7.0.0-1017', 'linux-gcp', 'linux-image-gcp',
            'linux-tools-common', 'linux-libc-dev']))
        script = (ROOT / 'bbr.sh').read_text()
        # Redirect the Python boot-link helper as well as all Bash file paths.
        for path in ['/boot/', '/lib/modules/', '/etc/default/grub.d', '/var/lib/ubuntu-dd']:
            script = script.replace(path, str(self.machine) + path)
        script = script.replace("Path('/boot')", f'Path({str(self.boot)!r})')
        script = script.replace("Path('/')", f'Path({str(self.machine)!r})')
        copy = self.root / 'bbr-cleanup-test.sh'
        copy.write_text(script)
        self.prefix = self.prefix.replace(str(ROOT / 'bbr.sh'), str(copy))
        self.prefix += f'MACHINE={shlex.quote(str(self.machine))}\nKEEP={KEEP}\nOLD={OLD}\n' + r'''
MODE=success
uname() { echo "${RUNNING:-$KEEP}"; }
dpkg-query() {
    if [[ ${@: -1} == 'linux-*' ]]; then cat "$STATE/inventory"; return; fi
    awk -F '\t' -v package="${@: -1}" '$1 == package { print $2; found=1 } END { if (!found) exit 1 }' "$STATE/inventory"
}
apt-mark() { printf '%s\n' "$@" > "$STATE/protected"; }
apt-get() {
    if [[ $1 == --simulate ]]; then
        if [[ $MODE == unsafe ]]; then echo "Remv linux-image-$KEEP [1]"; return; fi
        for package in "$@"; do
            [[ $package != linux-* ]] || printf 'Purg %s [1]\n' "$package"
        done
        return 0
    fi
    printf '%s\n' "$@" >> "$STATE/purge-calls"
    [[ $MODE != apt ]] || return 81
    [[ $MODE != no-op ]] || return 0
    for package in "$@"; do
        [[ $package == linux-* ]] || continue
        [[ $package != *"$KEEP"* && $package != linux-tools-common && $package != linux-libc-dev ]] || return 99
        awk -F '\t' -v package="$package" '$1 != package' "$STATE/inventory" > "$STATE/inventory.new"
        mv "$STATE/inventory.new" "$STATE/inventory"
    done
    rm -f -- "$MACHINE/boot/vmlinuz-$OLD" "$MACHINE/boot/initrd.img-$OLD"
    rm -rf -- "$MACHINE/lib/modules/$OLD"
    [[ $MODE != lost-initrd ]] || rm -f -- "$MACHINE/boot/initrd.img-$KEEP"
}
modprobe() { [[ $MODE != modprobe ]]; }
modinfo() {
    if [[ $1 == -F ]]; then
        if [[ $MODE == wrong-guard ]]; then echo 3-guard6-r5-experimental; else echo 3-guard7-r2-experimental; fi
    else
        [[ $MODE != driver || ${@: -1} != gve ]]
    fi
}
sysctl() { if [[ $MODE == algorithm ]]; then echo cubic; else echo bbrguard; fi; }
detect_nics() { NIC_NAMES=(ens4); NIC_DRIVERS=(gve); }
ip() { [[ $MODE == route ]] || echo default via 192.0.2.1; }
systemctl() {
    if [[ $1 == is-active ]]; then [[ $MODE != ssh ]]; return; fi
    echo "$*" >> "$STATE/systemctl-calls"
    [[ $MODE != timer ]]
}
grub-script-check() { [[ $MODE != invalid-grub ]]; }
update-grub() {
    if [[ $MODE == post-grub && -e $STATE/purge-calls ]]; then return 84; fi
    local GRUB_DEFAULT=0 file release
    source "$MACHINE/etc/default/grub.d/99-bbr-kernel.cfg"
    {
        printf 'set default="%s"\n' "$GRUB_DEFAULT"
        echo "submenu 'Advanced' 'gnulinux-advanced-id' {"
        for file in "$MACHINE"/boot/vmlinuz-*; do
            release=${file##*/vmlinuz-}
            printf "menuentry 'kernel' 'gnulinux-%s-advanced-id' { }\n" "$release"
        done
        echo '}'
    } > "$MACHINE/boot/grub/grub.cfg"
}
'''

    def assert_completed(self):
        for marker in ('cleanup-pending', 'cleanup-incomplete', 'rollback-release'):
            self.assertFalse((self.state / marker).exists(), marker)
        self.assertEqual(sorted(p.name for p in self.boot.glob('vmlinuz-*')), ['vmlinuz-' + KEEP])
        self.assertEqual(sorted(p.name for p in self.modules.iterdir()), [KEEP])
        self.assertNotIn(OLD, self.inventory.read_text())
        self.assertIn('linux-tools-common', self.inventory.read_text())
        self.assertIn(f'linux-headers-{KEEP}', self.inventory.read_text())
        for name in ('vmlinuz', 'initrd.img'):
            for suffix in ('', '.old'):
                self.assertEqual((self.boot / (name + suffix)).resolve(), self.boot / (name + '-' + KEEP))
        self.assertIn(f'set default="gnulinux-advanced-id>gnulinux-{KEEP}-advanced-id"', self.grub.read_text())
        self.assertIn('disable --now bbr-kernel-cleanup.timer', (self.state / 'systemctl-calls').read_text())

    def test_previous_kernel_is_removed_after_successful_health_checks(self):
        result = self.shell('cleanup_old_kernels')
        self.assert_completed()
        self.assertIn('仅保留当前 BBR 内核', result.stdout)
        self.assertIn('linux-image-gcp', (self.state / 'purge-calls').read_text())

    def test_manual_cleanup_without_pending_or_rollback_and_repeat(self):
        (self.state / 'cleanup-pending').unlink()
        (self.state / 'rollback-release').unlink()
        self.shell('cleanup_old_kernels')
        before = (self.state / 'purge-calls').read_bytes()
        result = self.shell('cleanup_old_kernels')
        self.assert_completed()
        self.assertEqual((self.state / 'purge-calls').read_bytes(), before)
        self.assertIn('没有其他内核包需要卸载', result.stdout)

    def test_stale_rollback_record_does_not_block_cleanup(self):
        (self.state / 'rollback-release').write_text('already-removed-kernel\n')
        self.shell('cleanup_old_kernels')
        self.assert_completed()

    def test_health_failures_never_start_a_purge(self):
        for mode in ('modprobe', 'wrong-guard', 'algorithm', 'driver', 'ssh', 'route', 'invalid-grub'):
            with self.subTest(mode=mode):
                self.shell(f'MODE={mode}; cleanup_old_kernels', success=False)
                self.assertFalse((self.state / 'purge-calls').exists())
                self.assertTrue((self.boot / ('vmlinuz-' + OLD)).exists())

    def test_missing_current_boot_files_or_headers_stops_cleanup(self):
        for name in ('vmlinuz-', 'initrd.img-'):
            path = self.boot / (name + KEEP)
            original = path.read_bytes()
            path.write_bytes(b'')
            self.shell('cleanup_old_kernels', success=False)
            path.write_bytes(original)
        self.inventory.write_text(self.inventory.read_text().replace(f'linux-headers-{KEEP}\tinstalled\n', ''))
        self.shell('cleanup_old_kernels', success=False)
        self.assertFalse((self.state / 'purge-calls').exists())

    def test_install_or_dd_pending_stops_cleanup(self):
        for path in (self.state / 'install-pending', self.machine / 'var/lib/ubuntu-dd/reinstall-pending'):
            path.touch()
            self.shell('cleanup_old_kernels', success=False)
            self.assertFalse((self.state / 'purge-calls').exists())
            path.unlink()

    def test_running_kernel_must_match_record(self):
        self.shell('RUNNING=$OLD; cleanup_old_kernels', success=False)
        self.assertFalse((self.state / 'purge-calls').exists())

    def test_failed_apt_keeps_markers_blocks_reboot_and_allows_retry(self):
        self.shell('MODE=apt; cleanup_old_kernels', success=False)
        for marker in ('cleanup-pending', 'cleanup-incomplete', 'rollback-release'):
            self.assertTrue((self.state / marker).exists())
        result = self.shell('require_host() { :; }; reboot_host() { echo UNEXPECTED_REBOOT; }; ACTION=reboot; dispatch', success=False)
        self.assertNotIn('UNEXPECTED_REBOOT', result.stdout)
        self.shell('cleanup_old_kernels')
        self.assert_completed()

    def test_post_purge_grub_failure_retries_without_old_kernel(self):
        self.shell('MODE=post-grub; cleanup_old_kernels', success=False)
        self.assertFalse((self.boot / ('vmlinuz-' + OLD)).exists())
        self.assertTrue((self.state / 'cleanup-incomplete').exists())
        self.shell('cleanup_old_kernels')
        self.assert_completed()

    def test_successful_apt_exit_without_removal_is_not_success(self):
        result = self.shell('MODE=no-op; cleanup_old_kernels', success=False)
        self.assertIn('仍有其他内核包', result.stderr)
        self.assertTrue((self.state / 'cleanup-incomplete').exists())

    def test_current_initrd_must_survive_package_hooks(self):
        self.shell('MODE=lost-initrd; cleanup_old_kernels', success=False)
        self.assertTrue((self.state / 'cleanup-incomplete').exists())

    def test_unmanaged_kernel_is_reported_and_not_silently_deleted(self):
        unmanaged = self.boot / 'vmlinuz-6.1-manual'
        unmanaged.write_text('manual-image')
        result = self.shell('cleanup_old_kernels', success=False)
        self.assertIn(str(unmanaged), result.stderr)
        self.assertEqual(unmanaged.read_text(), 'manual-image')
        self.assertTrue((self.state / 'cleanup-incomplete').exists())

    def test_unsafe_plan_never_runs_purge(self):
        self.shell('MODE=unsafe; cleanup_old_kernels', success=False)
        self.assertFalse((self.state / 'purge-calls').exists())
        self.assertTrue((self.state / 'cleanup-incomplete').exists())

    def test_symlinked_pending_marker_does_not_modify_its_target(self):
        marker = self.state / 'cleanup-pending'
        marker.unlink()
        outside = self.root / 'outside'
        outside.write_text('keep')
        marker.symlink_to(outside)
        self.shell('cleanup_old_kernels', success=False)
        self.assertEqual(outside.read_text(), 'keep')
        self.assertFalse((self.state / 'purge-calls').exists())

    def test_preview_changes_no_files(self):
        result = self.shell('DRY_RUN=1; cleanup_old_kernels')
        self.assertIn('包括原回退内核', result.stdout)
        self.assertFalse((self.state / 'purge-calls').exists())
        self.assertFalse((self.state / 'cleanup-incomplete').exists())
