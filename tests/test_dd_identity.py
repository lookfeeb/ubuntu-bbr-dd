"""Disk identity regression: real selectors/gates, file-backed hardware stubs."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

from test_dd_hardening import patch

ROOT = Path(__file__).resolve().parents[1]
SHELLS = [('bash',), ('dash',), ('busybox', 'ash')]


class DiskIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        archive = Path(os.environ.get('DD_UPSTREAM_ARCHIVE', str(ROOT / '.cache/reinstall-8ac9db68.tar.gz')))
        if not archive.is_file():
            raise unittest.SkipTest('Pinned upstream fixture missing')
        with tempfile.TemporaryDirectory() as tmp:
            patch.build(archive, Path(tmp))
            trans = (Path(tmp) / 'trans.sh').read_text()
        cls.selector = re.search(r'^find_xda\(\) \{\n.*?^\}', trans, re.M | re.S)[0]
        # Use the actual patched create_part, so failure must precede all of
        # upstream's partitioning commands (including its first apk call).
        cls.partition = re.search(r'^create_part\(\) \{\n.*?^\}', trans, re.M | re.S)[0]

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='dd-identity-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.hardware = self.root / 'hardware'
        self.hardware.mkdir()
        self.disk('vda')
        (self.hardware / 'names').write_text('vda disk\n')
        self.prefix = f'''set -eu
. {shlex.quote(str(ROOT / 'tools/dd_runtime.sh'))}
. {shlex.quote(str(ROOT / 'tools/dd_disk.sh'))}
DD_BUNDLE={shlex.quote(str(self.bundle))}
HW={shlex.quote(str(self.hardware))}
DD_INSTALL_STATE={shlex.quote(str(self.root / 'journal'))}
lsblk() {{
    [ "$1 $2 $3 $4" = '--nodeps --noheadings --raw --output' ] || exit 91
    if [ "$5" = NAME,TYPE ]; then cat "$HW/names"; else cat "$HW/${{6##*/}}/$5"; fi
}}
blockdev() {{ [ "$1" = --getsize64 ] || exit 92; cat "$HW/${{2##*/}}/bytes"; }}
dd_scsi_properties() {{ return 1; }}
apk() {{ :; }}
get_config() {{ echo STALE_CACHE_READ >&2; exit 93; }}
set_config() {{ printf '%s\\n' "$2" > "$HW/cache"; }}
main_disk=1234abcd
{self.selector}
{self.partition}
'''

    def disk(self, name, identity='1234abcd', serial='serial-1', wwn='wwn-1', size='17179869184'):
        directory = self.hardware / name
        directory.mkdir(exist_ok=True)
        for field, value in [('PTUUID', identity), ('SERIAL', serial), ('WWN', wwn), ('bytes', size)]:
            (directory / field).write_text(value + '\n')

    def run_shell(self, body, ok=True, shell=('bash',)):
        if not shutil.which(shell[0]):
            self.skipTest(f'{shell[0]} unavailable')
        result = subprocess.run([*shell, '-c', self.prefix + body], text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_unique_record_and_find_in_all_shells(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                result = self.run_shell('dd_record_disk_identity /dev/vda; find_xda; echo "$xda"', shell=shell)
                self.assertEqual(result.stdout.strip(), 'vda')
                self.assertEqual((self.bundle / 'disk-identity-version').read_text(), '1\n')

    def test_selector_installs_real_alpine_disk_utility_packages(self):
        # Alpine 3.24 supplies /sbin/blockdev through util-linux-misc; asking
        # APK for the command name aborts before the real identity selector.
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.run_shell('''
dd_record_disk_identity /dev/vda
apk() {
    [ "$1" = add ] || return 91
    shift
    for package in "$@"; do
        case "$package" in lsblk|util-linux-misc|eudev) ;; *) return 92 ;; esac
    done
    printf '%s\\n' "$@" > "$HW/apk-packages"
}
find_xda
[ "$xda" = vda ]
''', shell=shell)
                self.assertEqual((self.hardware / 'apk-packages').read_text().splitlines(),
                                 ['lsblk', 'util-linux-misc', 'eudev'])

    def test_scsi_inquiry_preserves_identifiers_without_udev_lsblk(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.disk('vda')
                self.run_shell('''
dd_record_disk_identity /dev/vda
: > "$HW/vda/SERIAL"
: > "$HW/vda/WWN"
dd_scsi_properties() {
    [ "$1" = /dev/vda ] || exit 94
    printf 'ID_SERIAL_SHORT=serial-1\\nID_WWN=base-wwn\\nID_WWN_WITH_EXTENSION=wwn-1\\n'
}
find_xda
[ "$xda" = vda ]
''', shell=shell)

    def test_scsi_fallback_does_not_accept_changed_missing_or_ambiguous_identity(self):
        for properties in ['ID_SERIAL_SHORT=replaced\n', '',
                           'ID_SERIAL_SHORT=serial-1\nID_SERIAL_SHORT=serial-1\n']:
            with self.subTest(properties=properties):
                self.disk('vda')
                self.run_shell('dd_record_disk_identity /dev/vda')
                (self.hardware / 'vda/SERIAL').write_text('')
                self.run_shell(f'dd_scsi_properties() {{ printf %s {shlex.quote(properties)}; }}\nfind_xda', ok=False)
        self.disk('vda')
        self.run_shell('dd_record_disk_identity /dev/vda')
        (self.hardware / 'vda/SERIAL').write_text('changed\n')
        self.run_shell('''
dd_scsi_properties() { echo ID_SERIAL_SHORT=serial-1; }
find_xda
''', ok=False)

    def test_clone_id_same_capacity_rejected_in_both_orders(self):
        self.disk('vdb', serial='different-serial', wwn='different-wwn')
        for shell in SHELLS:
            for names in ['vda disk\nvdb disk\n', 'vdb disk\nvda disk\n']:
                with self.subTest(shell=shell, names=names):
                    (self.hardware / 'names').write_text(names)
                    result = self.run_shell('dd_record_disk_identity /dev/vda; echo BOOT_CHANGE', ok=False, shell=shell)
                    self.assertIn('found 2', result.stderr)
                    self.assertNotIn('BOOT_CHANGE', result.stdout)

    def test_device_rename_reselected_ignoring_stale_cache(self):
        self.run_shell('dd_record_disk_identity /dev/vda')
        self.disk('vdb')
        self.disk('vda', identity='abcdef12')
        (self.hardware / 'names').write_text('vda disk\nvdb disk\n')
        (self.hardware / 'cache').write_text('vda\n')
        for shell in SHELLS:
            result = self.run_shell('find_xda; echo "$xda"', shell=shell)
            self.assertEqual(result.stdout.strip(), 'vdb')
            self.assertNotIn('STALE_CACHE_READ', result.stderr)
            self.assertEqual((self.hardware / 'cache').read_text(), 'vdb\n')

    def test_mbr_and_gpt_normalization(self):
        for identity in ['0x1234ABCD', '12345678-1234-ABCD-5678-123456789ABC']:
            self.disk('vda', identity=identity)
            self.run_shell(f'dd_record_disk_identity /dev/vda; main_disk={identity}; find_xda')
            self.assertEqual((self.bundle / 'disk-ptuuid').read_text().strip(), identity.lower().removeprefix('0x'))

    def test_no_serial_or_wwn_still_requires_unique_id_and_size(self):
        self.disk('vda', serial='', wwn='')
        self.run_shell('dd_record_disk_identity /dev/vda; find_xda')
        self.disk('vdb', identity='')  # An unrelated, unpartitioned disk is OK.
        (self.hardware / 'names').write_text('vdb disk\nvda disk\n')
        self.run_shell('find_xda')

    def test_recorded_serial_wwn_and_capacity_change_or_disappear(self):
        self.run_shell('dd_record_disk_identity /dev/vda')
        for field in ['SERIAL', 'WWN', 'bytes']:
            for value in ['', 'different', '0']:
                with self.subTest(field=field, value=value):
                    self.disk('vda')
                    (self.hardware / 'vda' / field).write_text(value + '\n')
                    self.run_shell('find_xda', ok=False)

    def test_no_match_and_boot_record_mismatch(self):
        self.run_shell('dd_record_disk_identity /dev/vda')
        self.run_shell('main_disk=abcdef12; find_xda', ok=False)
        self.disk('vda', identity='abcdef12')
        self.run_shell('find_xda', ok=False)

    def test_missing_or_invalid_identity_records(self):
        for field in ['disk-identity-version', 'disk-ptuuid', 'disk-bytes', 'disk-SERIAL', 'disk-WWN']:
            for value in [None, 'bad\n']:
                with self.subTest(field=field, value=value):
                    self.run_shell('dd_record_disk_identity /dev/vda')
                    path = self.bundle / field
                    if value is None:
                        path.unlink()
                    else:
                        path.write_text(value)
                    self.run_shell('find_xda', ok=False)

    def test_probe_failure_and_ambiguous_fields_fail_closed(self):
        for field in ['names', 'vda/PTUUID', 'vda/SERIAL', 'vda/WWN', 'vda/bytes']:
            path = self.hardware / field
            saved = path.read_bytes()
            path.unlink()
            self.run_shell('dd_record_disk_identity /dev/vda', ok=False)
            path.write_bytes(saved)
        for value in ['', 'garbage', '1234abcd\nabcdef12']:
            self.disk('vda', identity=value)
            self.run_shell('dd_record_disk_identity /dev/vda', ok=False)
        self.disk('vda', serial='one\ntwo')
        self.run_shell('dd_record_disk_identity /dev/vda', ok=False)

    def test_unsupported_and_virtual_devices_never_selected(self):
        self.run_shell('dd_record_disk_identity /dev/vda')
        (self.hardware / 'names').write_text('loop0 loop\nnbd0 disk\nsr0 rom\nvda disk\nvda1 part\n')
        self.run_shell('find_xda')
        (self.hardware / 'names').write_text('../escape disk\nvda disk\n')
        self.run_shell('find_xda', ok=False)

    def test_late_clone_or_swap_precedes_actual_partition_gate(self):
        for shell in SHELLS:
            for mode in ['ram', 'disk']:
                for change in ['clone', 'swap']:
                    with self.subTest(shell=shell, mode=mode, change=change):
                        self.disk('vda')
                        (self.hardware / 'names').write_text('vda disk\n')
                        mutation = ('printf "vda disk\\nvdb disk\\n" > "$HW/names"' if change == 'clone'
                                    else 'echo replaced > "$HW/vda/SERIAL"')
                        self.disk('vdb')
                        result = self.run_shell(f'''
dd_record_disk_identity /dev/vda
find_xda
dd_verify_disk_identity /dev/$xda
DD_CACHE_MODE={mode}; DD_PARTITION_READY=1
dd_require_verified() {{ :; }}
dd_install_begin
{mutation}
apk() {{ echo PARTITION_COMMAND; exit 94; }}
create_part
''', ok=False, shell=shell)
                        self.assertNotIn('PARTITION_COMMAND', result.stdout)
                        self.assertFalse((self.root / 'journal/destructive').exists())

    def test_valid_identity_allows_each_cache_mode_gate(self):
        for mode in ['ram', 'disk']:
            self.run_shell(f'''dd_record_disk_identity /dev/vda
find_xda
DD_CACHE_MODE={mode}; DD_PARTITION_READY=1
dd_require_verified() {{ :; }}
dd_require_partition
''')

    def test_embedded_host_helper_matches_source(self):
        pattern = r'# BEGIN DD DISK HELPERS\n.*?# END DD DISK HELPERS'
        self.assertEqual(re.search(pattern, (ROOT / 'dd.sh').read_text(), re.S)[0],
                         re.search(pattern, (ROOT / 'tools/dd_disk.sh').read_text(), re.S)[0])

    def test_host_metadata_or_identity_failure_never_invokes_engine(self):
        engine = self.hardware / 'engine'
        engine.write_text('#!/bin/bash\necho BOOT_CHANGE\n')
        for failure in ['metadata', 'identity']:
            with self.subTest(failure=failure):
                self.disk('vdb')
                (self.hardware / 'names').write_text('vda disk\nvdb disk\n')
                result = self.run_shell(f'''
. {shlex.quote(str(ROOT / 'dd.sh'))}
STATE=$HW
CACHE_MODE=disk
need() {{ :; }}
secure_boot_check() {{ :; }}
inspect_cloud() {{ :; }}
detect_system_disk() {{ SYSTEM_DISK=/dev/vda; }}
show_reinstall_target() {{ :; }}
prepare_engine() {{ ENGINE=$HW/engine; }}
engine_tools() {{
    if [ "$1" = image ]; then
        [ {failure} != metadata ] || return 88
        echo https://example.invalid/release-20261108/image.img > "$DD_BUNDLE/image-url"
        echo 1073741824 > "$DD_BUNDLE/image-bytes"
    fi
}}
reinstall_ubuntu
''', ok=False)
                self.assertNotIn('BOOT_CHANGE', result.stdout)
                self.assertFalse((self.hardware / 'reinstall-pending').exists())


if __name__ == '__main__':
    unittest.main()
