"""Low-memory gates and ordering; never repartitions a host block device."""
import re
import shlex
import shutil
import subprocess
import tarfile

from test_dd_hardening import ROOT, RuntimeHarness, patch


class LowMemoryTests(RuntimeHarness):
    def test_nominal_512_memory_floor_and_reservations(self):
        self.run_shell('dd_check_minimum_ram 469762048')
        self.run_shell('dd_check_minimum_ram 469762047', ok=False)

    def test_disk_reserve_includes_swap_overlay_and_image(self):
        small = int(self.run_shell('dd_disk_cache_bytes 621284352').stdout)
        large = int(self.run_shell('dd_disk_cache_bytes 3221225472').stdout)
        self.assertEqual(small, 6 * 1024**3)
        self.assertEqual(large, 7 * 1024**3)

    def test_disk_partition_gate_is_one_shot_and_distinct_from_image_gate(self):
        self.run_shell('DD_CACHE_MODE=disk; dd_require_partition', ok=False)
        self.run_shell('DD_CACHE_MODE=disk; DD_PARTITION_READY=1; dd_require_partition; '
                       'test "$DD_PARTITION_READY" = 0; dd_require_partition', ok=False)
        self.run_shell('DD_CACHE_MODE=disk; DD_PARTITION_READY=1; dd_require_partition; dd_require_verified', ok=False)

    def test_bad_manifest_or_endpoint_never_allows_partitioning(self):
        for mode in ('signature', 'https', 'capacity', 'memory'):
            script = 'MODE=' + mode + '\n' + r'''
DD_CACHE_MODE=disk; xda=fake; img=https://example.invalid/image.img
blockdev() { if [ "$MODE" = capacity ]; then echo 10737418240; else echo 64424509440; fi; }
dd_verify_manifest() { [ "$MODE" != signature ]; }
dd_https() { [ "$MODE" != https ]; }
create_part() { touch "$DD_BUNDLE/partitioned"; exit 99; }
total=536870912
[ "$MODE" != memory ] || total=268435456
dd_prepare_disk_cache 621284352 "$total"
'''
            self.run_shell(script, ok=False)
            self.assertFalse((self.bundle / 'partitioned').exists())

    def test_disk_install_never_partitions_again_after_payload_verification(self):
        result = self.run_shell(r'''
DD_CACHE_MODE=disk
dd_preflight() { echo 'partition+verify'; }
create_part() { echo 'unexpected-repartition'; return 1; }
download_qcow() { echo 'use-verified-image'; }
dd_prepare_install
''')
        self.assertEqual(result.stdout.splitlines(), ['partition+verify', 'use-verified-image'])

    def test_ram_install_keeps_verification_before_partition(self):
        result = self.run_shell(r'''
DD_CACHE_MODE=ram
dd_preflight() { echo verify; }
create_part() { echo partition; }
download_qcow() { echo copy; }
dd_prepare_install
''')
        self.assertEqual(result.stdout.splitlines(), ['verify', 'partition', 'copy'])

    def test_active_disk_swap_partition_is_not_removed_or_unmounted(self):
        self.run_shell(r'''
DD_CACHE_MODE=disk
sync() { :; }
parted() { touch "$DD_BUNDLE/damaged"; return 1; }
umount() { touch "$DD_BUNDLE/damaged"; return 1; }
resize_after_install_cloud_image() { touch "$DD_BUNDLE/damaged"; return 1; }
dd_release_installer
dd_finish_partition_layout
''')
        self.assertFalse((self.bundle / 'damaged').exists())

    def test_failed_payload_preflight_does_not_start_copy(self):
        self.run_shell(r'''
DD_CACHE_MODE=disk
dd_preflight() { return 8; }
create_part() { touch "$DD_BUNDLE/copied"; }
download_qcow() { touch "$DD_BUNDLE/copied"; }
dd_prepare_install
''', ok=False)
        self.assertFalse((self.bundle / 'copied').exists())

    def test_qcow_detach_ignores_other_open_files_but_bounds_image_wait(self):
        if not shutil.which('fuser'):
            self.skipTest('fuser is required for real file-handle checks')
        with tarfile.open(ROOT / '.cache/reinstall-8ac9db68.tar.gz') as archive:
            source = archive.extractfile(next(member for member in archive.getmembers()
                                             if member.name.endswith('/trans.sh'))).read().decode()
        function = re.search(r'disconnect_qcow\(\) \{\n.*?\n\}', patch.patch_trans(source), re.S).group()
        pidfile = self.root / 'nbd-pid'
        pidfile.touch()
        image = self.root / 'image.img'
        image.touch()
        # Substitute only the hardware probe and wait duration. Real fuser
        # fuser must distinguish two open files on the same filesystem.
        function = function.replace('/sys/block/nbd0/pid', str(pidfile)).replace('sleep 5', 'sleep 0.01')
        script = self.prefix + function + '\n' + (
            'qemu-nbd() { :; }\n'
            f'qcow_file={shlex.quote(str(image))}\ndisconnect_qcow\n')
        with (self.root / 'memory.log').open('w'):
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        with image.open('rb'):
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('nbd detach timed out', result.stderr)
