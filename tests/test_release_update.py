"""Exercise release discovery, untrusted downloads and verified child handoff offline."""
import hashlib
import shlex

from test_scripts import Harness, ROOT
from test_menus import MenuHarness

BASE = 'https://github.com/lookfeeb/ubuntu-bbr-dd'


class ReleaseCases:
    def setUp(self):
        super().setUp()
        self.fixture = self.root / 'upstream.sh'
        self.manifest = self.root / 'SHA256SUMS'
        self.requests = self.root / 'requests'
        self.scratch = self.root / 'scratch'
        self.scratch.mkdir()
        self.new_script()
        exports = dict(TEST_PAYLOAD=self.fixture, TEST_MANIFEST=self.manifest,
                       TEST_REQUESTS=self.requests, TEST_LATEST=BASE + '/releases/tag/v9.8.7',
                       TEST_SCRIPT=self.script, TMPDIR=self.scratch)
        self.prefix += '\n' + '\n'.join('export ' + k + '=' + shlex.quote(str(v)) for k, v in exports.items()) + '\n'
        self.prefix += r'''
curl() {
    local url=${!#} output='' argument
    printf '%s\n' "$url" >> "$TEST_REQUESTS"
    while (( $# )); do
        argument=$1; shift
        if [[ $argument == --output ]]; then output=$1; shift; fi
    done
    case "$url" in
        https://github.com/lookfeeb/ubuntu-bbr-dd/releases/latest)
            [[ ${TEST_FAIL:-} != latest ]] || return 22
            printf '%s' "$TEST_LATEST" ;;
        https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/v9.8.7/SHA256SUMS)
            [[ ${TEST_FAIL:-} != manifest ]] || return 22
            cp "$TEST_MANIFEST" "$output" ;;
        https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/v9.8.7/"$TEST_SCRIPT")
            [[ ${TEST_FAIL:-} != script ]] || return 22
            cp "$TEST_PAYLOAD" "$output"
            [[ ${TEST_CORRUPT:-0} != 1 ]] || printf '\n# corrupt\n' >> "$output" ;;
        *) return 92 ;;
    esac
}
export -f curl
'''

    def new_script(self, exit_code=0):
        helper = (ROOT / 'tools/release_helpers.inc').read_text()
        self.fixture.write_text('#!/usr/bin/env bash\nset -Eeuo pipefail\n'
                                'say() { printf "%s\\n" "$*"; }\n'
                                'die() { echo "$*" >&2; exit 1; }\n'
                                'need() { command -v "$1" >/dev/null; }\n' + helper + '\n'
                                f'run_latest_release {self.script} "$0"\n'
                                '[[ -z ${BBR_DD_RELEASE_SHA256:-} ]]\n'
                                'printf "NEW_MENU\\n"\n' + f'exit {exit_code}\n')
        digest = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        self.manifest.write_text(f'{digest}  {self.script}\n')
        return digest

    def launch(self, extra='', current=None, success=True):
        current = current or ROOT / self.script
        return self.shell(extra + '\nrun_latest_release ' + self.script + ' ' + shlex.quote(str(current)) +
                          '\necho OLD_MENU\n', success=success)

    def test_latest_release_is_frozen_and_verified_child_runs_once(self):
        result = self.launch()
        self.assertEqual(result.stdout.count('NEW_MENU'), 1)
        self.assertNotIn('OLD_MENU', result.stdout)
        self.assertEqual(self.requests.read_text().splitlines(), [BASE + '/releases/latest',
                         BASE + '/releases/download/v9.8.7/SHA256SUMS',
                         BASE + '/releases/download/v9.8.7/' + self.script])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_real_main_checks_release_before_entering_menu(self):
        result = MenuHarness.terminal(self, 'BBR_DD_AUTO_UPDATE=1; main', '')
        self.assertIn('NEW_MENU', result)
        self.assertNotIn('===== Guard ', result)
        self.assertNotIn('===== Ubuntu DD', result)
        self.assertEqual(len(self.requests.read_text().splitlines()), 3)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_current_release_reuses_verified_bytes_without_script_download(self):
        result = self.launch(current=self.fixture)
        self.assertIn('NEW_MENU', result.stdout)
        self.assertEqual(len(self.requests.read_text().splitlines()), 2)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_bad_checksum_never_executes_and_leaves_original_unchanged(self):
        before = (ROOT / self.script).read_bytes()
        result = self.launch('export TEST_CORRUPT=1', success=False)
        self.assertNotIn('NEW_MENU', result.stdout)
        self.assertNotIn('OLD_MENU', result.stdout)
        self.assertEqual(before, (ROOT / self.script).read_bytes())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_missing_duplicate_malformed_and_shell_manifest_entries_rejected(self):
        valid = self.manifest.read_text()
        for manifest in ('', valid + valid, valid + valid.rstrip() + ' extra\n',
                         f'{"g" * 64}  {self.script}\n',
                         f'$(touch {self.state}/executed)  {self.script}\n'):
            with self.subTest(manifest=manifest):
                self.manifest.write_text(manifest)
                result = self.launch(success=False)
                self.assertNotIn('NEW_MENU', result.stdout)
                self.assertNotIn('OLD_MENU', result.stdout)
                self.assertFalse((self.state / 'executed').exists())
                self.assertEqual(list(self.scratch.iterdir()), [])

    def test_unexpected_release_location_rejected(self):
        for url in ('https://evil.invalid/releases/tag/v9.8.7', BASE + '/releases/tag/v9.8.7-rc1',
                    BASE + '/releases/tag/v9.8.7/../main', BASE + '/releases/tag/v9.8.7;id'):
            with self.subTest(url=url):
                self.requests.unlink(missing_ok=True)
                result = self.launch('export TEST_LATEST=' + shlex.quote(url), success=False)
                self.assertEqual(len(self.requests.read_text().splitlines()), 1)
                self.assertNotIn('NEW_MENU', result.stdout)
                self.assertEqual(list(self.scratch.iterdir()), [])

    def test_network_failure_never_falls_back_silently(self):
        for stage in ('latest', 'manifest', 'script'):
            with self.subTest(stage=stage):
                result = self.launch('export TEST_FAIL=' + stage, success=False)
                self.assertNotIn('NEW_MENU', result.stdout)
                self.assertNotIn('OLD_MENU', result.stdout)
                self.assertEqual(list(self.scratch.iterdir()), [])

    def test_invalid_bash_is_rejected_even_with_matching_checksum(self):
        self.fixture.write_text('#!/bin/bash\nif then\n')
        digest = hashlib.sha256(self.fixture.read_bytes()).hexdigest()
        self.manifest.write_text(f'{digest}  {self.script}\n')
        result = self.launch(success=False)
        self.assertNotIn('OLD_MENU', result.stdout)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_child_failure_is_preserved_without_returning_to_old_menu(self):
        self.new_script(exit_code=42)
        result = self.launch(success=False)
        self.assertEqual(result.returncode, 42)
        self.assertNotIn('OLD_MENU', result.stdout)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_explicit_offline_mode_never_contacts_network(self):
        result = self.launch('BBR_DD_AUTO_UPDATE=0')
        self.assertIn('OLD_MENU', result.stdout)
        self.assertFalse(self.requests.exists())

    def test_stale_child_digest_cannot_skip_update(self):
        result = self.launch('export BBR_DD_RELEASE_SHA256=' + 'a' * 64)
        self.assertIn('NEW_MENU', result.stdout)
        self.assertNotIn('OLD_MENU', result.stdout)
        self.assertEqual(len(self.requests.read_text().splitlines()), 3)

    def test_binary_checksum_style_and_embedded_source(self):
        self.manifest.write_text(self.manifest.read_text().replace('  ', ' *'))
        self.assertIn('NEW_MENU', self.launch().stdout)
        self.assertIn((ROOT / 'tools/release_helpers.inc').read_text().strip(),
                      (ROOT / self.script).read_text())


class TestBBRRelease(ReleaseCases, Harness):
    script = 'bbr.sh'


class TestDDRelease(ReleaseCases, Harness):
    script = 'dd.sh'
