"""Application installation boundaries; no packages or host services are changed."""
import contextlib
import copy
import importlib.util
import io
import http.server
import json
from pathlib import Path
import shlex
import socket
import sqlite3
import ssl
import subprocess
import tarfile
import threading
import unittest
from unittest.mock import patch

from test_scripts import Harness, ROOT

spec = importlib.util.spec_from_file_location('app_payload', ROOT / 'tools/app_payload.py')
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


def release_fixture(app='openlist', arch='amd64', tag='v9.8.7'):
    repo = {'x-ui': 'MHSanaei/3x-ui', 'openlist': 'OpenListTeam/OpenList'}[app]
    name = f'{app}-linux-{arch}.tar.gz'
    return dict(tag_name=tag, draft=False, prerelease=False,
                html_url=f'https://github.com/{repo}/releases/tag/{tag}',
                assets=[dict(name=name, state='uploaded', size=1234, digest='sha256:' + 'a' * 64,
                             browser_download_url=f'https://github.com/{repo}/releases/download/{tag}/{name}')])


class AppReleaseTests(Harness):
    def test_latest_version_selected_for_both_apps_and_architectures(self):
        for app in ['x-ui', 'openlist']:
            for arch in ['amd64', 'arm64']:
                for tag in ['v9.8.7', 'v10.1.0']:
                    with self.subTest(app=app, arch=arch, tag=tag):
                        result = payload.select_release(app, arch, release_fixture(app, arch, tag))
                        self.assertEqual(result['version'], tag)
                        self.assertEqual(result['sha256'], 'a' * 64)
                        self.assertTrue(result['url'].endswith(f'/{tag}/{app}-linux-{arch}.tar.gz'))

    def test_draft_prerelease_wrong_repo_and_unsafe_tags_rejected(self):
        for field, value in [('draft', True), ('prerelease', True), ('draft', 'false'),
                             ('tag_name', 'v9.8.7-rc1'), ('tag_name', 'dev'),
                             ('tag_name', 'v9.8.7/../../evil'),
                             ('html_url', 'https://github.com/untrusted/project/releases/tag/v9.8.7')]:
            metadata = release_fixture()
            metadata[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                payload.select_release('openlist', 'amd64', metadata)

    def test_missing_duplicate_and_unverified_assets_rejected(self):
        original = release_fixture()
        variants = []
        for field, value in [('digest', None), ('digest', ''), ('digest', 'sha256:123'),
                             ('size', 0), ('size', True), ('state', 'new'),
                             ('browser_download_url', 'https://example.invalid/package'),
                             ('browser_download_url', original['assets'][0]['browser_download_url'].replace('v9.8.7', 'v9.8.6'))]:
            metadata = copy.deepcopy(original)
            metadata['assets'][0][field] = value
            variants.append(metadata)
        for assets in [[], original['assets'] * 2, release_fixture(arch='arm64')['assets']]:
            variants.append(dict(original, assets=assets))
        for metadata in variants:
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                payload.select_release('openlist', 'amd64', metadata)

    def test_resolved_release_is_preserved_with_install_record(self):
        metadata, selected, record = [self.root / name for name in ['latest.json', 'selected.json', 'record.json']]
        metadata.write_text(json.dumps(release_fixture()))
        payload.resolve_release('openlist', 'amd64', metadata, selected)
        metadata.write_text(json.dumps(release_fixture(tag='v10.0.0')))
        payload.record('openlist', record, 'v9.8.7', str(self.root), str(self.state), '5244', selected)
        self.assertEqual(json.loads(record.read_text())['release']['version'], 'v9.8.7')
        self.assertEqual(json.loads(record.read_text())['release']['sha256'], 'a' * 64)
        with self.assertRaises(ValueError):
            payload.record('openlist', self.root / 'wrong.json', 'v10.0.0', str(self.root), str(self.state), '5244', selected)


class AppPayloadTests(Harness):
    def archive(self, entries):
        path = self.root / 'package.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            for name, kind, content in entries:
                item = tarfile.TarInfo(name)
                item.type = kind
                item.size = len(content) if kind == tarfile.REGTYPE else 0
                item.linkname = '/etc/passwd' if kind == tarfile.SYMTYPE else ''
                archive.addfile(item, io.BytesIO(content) if item.isreg() else None)
        return path

    def test_archive_escape_links_and_wrong_arch_rejected(self):
        for name, kind, content in [('../escape', tarfile.REGTYPE, b'x'),
                                    ('openlist', tarfile.SYMTYPE, b''),
                                    ('openlist', tarfile.REGTYPE, b'wrong architecture')]:
            with self.subTest(name=name, kind=kind):
                archive = self.archive([(name, kind, content)])
                stage = self.root / ('stage-' + str(kind) + '-' + str(len(content)))
                with self.assertRaises(ValueError):
                    payload.extract('openlist', archive, stage, 'amd64')
        self.assertFalse((self.root / 'escape').exists())

    def test_valid_native_payload_extracted_and_marked_executable(self):
        header = b'\x7fELF\x02\x01' + b'\0' * 12 + b'\x3e\0'
        archive = self.archive([('openlist', tarfile.REGTYPE, header)])
        stage = self.root / 'stage'
        payload.extract('openlist', archive, stage, 'amd64')
        self.assertEqual((stage / 'openlist').read_bytes(), header)
        self.assertEqual((stage / 'openlist').stat().st_mode & 0o777, 0o755)

    def test_occupied_port_is_not_reused(self):
        with socket.socket() as occupied:
            occupied.bind(('0.0.0.0', 0))
            port = occupied.getsockname()[1]
            self.assertNotEqual(payload.free_port(port), port)

    def create_state(self):
        record = self.root / 'record.json'
        payload.record('openlist', record, 'v4.2.9', str(self.root), str(self.state), '5244')
        payload.openlist_config(record)
        with sqlite3.connect(self.state / 'data.db') as db:
            db.execute('create table x_users(id integer, username text, role integer)')
            db.execute("insert into x_users values (1, 'renamed-admin', 2)")
        return record

    def test_private_random_credentials_and_actual_configuration(self):
        record = self.create_state()
        state = json.loads(record.read_text())
        self.assertGreaterEqual(len(state['password']), 32)
        self.assertEqual(record.stat().st_mode & 0o777, 0o600)
        config = json.loads((self.state / 'config.json').read_text())
        self.assertEqual(config['scheme']['http_port'], -1)
        self.assertEqual(config['scheme']['https_port'], 5244)
        self.assertEqual(payload.current_state(record)['username'], 'renamed-admin')
        with self.assertRaises(FileExistsError):
            payload.record('openlist', record, 'new', str(self.root), str(self.state), '1234')
        self.assertEqual(json.loads(record.read_text())['password'], state['password'])

    def test_report_never_presents_stale_password_as_valid(self):
        record = self.create_state()
        password = json.loads(record.read_text())['password']
        output = io.StringIO()
        with patch.object(payload, 'addresses', return_value=['2001:db8::7']), \
                patch.object(payload, 'authenticate', side_effect=ValueError('changed')), \
                contextlib.redirect_stdout(output):
            payload.report(record)
        self.assertNotIn(password, output.getvalue())
        self.assertIn('https://[2001:db8::7]:5244/', output.getvalue())
        self.assertIn('用户名：renamed-admin', output.getvalue())
        self.assertIn('密码：未显示', output.getvalue())

    def test_xui_current_settings_and_initial_subscription_disable(self):
        record = self.root / 'record.json'
        payload.record('x-ui', record, 'v3.11.0', str(self.root), str(self.state), '2053')
        with sqlite3.connect(self.state / 'x-ui.db') as db:
            db.executescript('create table users(id integer, username text); create table settings(key text, value text);')
            db.execute("insert into users values (1, 'real-admin')")
            db.executemany('insert into settings values (?, ?)',
                           [('webPort', '2077'), ('webBasePath', '/secret/'),
                            ('webCertFile', '/cert.pem'), ('subEnable', 'true')])
        payload.x_ui_config(record)
        current = payload.current_state(record)
        self.assertEqual((current['port'], current['base'], current['username']), (2077, '/secret/', 'real-admin'))
        with sqlite3.connect(self.state / 'x-ui.db') as db:
            self.assertEqual(db.execute("select value from settings where key='subEnable'").fetchone()[0], 'false')

    def test_https_login_handles_xui_csrf_cookie_and_openlist_json(self):
        cert, key = self.root / 'cert.pem', self.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        observed = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                observed.append(self.path)
                self.send_response(200)
                self.send_header('Set-Cookie', 'session=fixture; Path=/; Secure')
                self.end_headers()
                self.wfile.write(b'{"success": true, "obj": "test-csrf"}')

            def do_POST(self):
                body = self.rfile.read(int(self.headers['Content-Length']))
                observed.append(self.path)
                if self.path == '/secret/login':
                    valid = (self.headers.get('Cookie') == 'session=fixture' and
                             self.headers.get('X-CSRF-Token') == 'test-csrf' and b'password=fixture' in body)
                    response = {'success': valid}
                else:
                    response = {'code': 200 if json.loads(body)['password'] == 'fixture' else 400}
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(response).encode())

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for app, base in [('x-ui', '/secret/'), ('openlist', '/')]:
                state = dict(app=app, base=base, port=server.server_port, cert=str(cert),
                             username='admin', password='fixture')
                payload.authenticate(state)
                state['password'] = 'wrong'
                with self.assertRaises(ValueError):
                    payload.authenticate(state)
            self.assertEqual(observed[0:2], ['/secret/csrf-token', '/secret/login'])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


class AppInstallTests(Harness):
    def setUp(self):
        super().setUp()
        self.prefix += f'''
APP_STATE={shlex.quote(str(self.root / 'records'))}
eval "$(declare -f app_paths | sed '1s/app_paths/original_app_paths/')"
app_paths() {{
    original_app_paths "$1"
    APP_DIR={self.root}/application
    APP_DATA={self.root}/data
    APP_RECORD={self.root}/records/$1.json
    APP_UNIT={self.root}/application.service
}}
apt-get() {{ echo APT_CALLED; }}
systemctl() {{
    echo "$*" >> "$STATE/systemctl"
    case "$1" in show) echo not-found ;; esac
}}
download_verified() {{ echo DOWNLOAD_CALLED; printf fixture > "$2"; }}
eval "$(declare -f app_asset | sed '1s/app_asset/real_app_asset/')"
app_asset() {{
    APP_ARCH=amd64; APP_VERSION=v9.8.7; APP_SHA=fixture; APP_URL=https://example.invalid/fixture
    printf '%s\\n' '{{"version":"v9.8.7"}}' > "$APP_WORK/selected-release.json"
}}
'''

    def fake_payload(self):
        return '''
eval "$(declare -f app_payload | sed '1s/app_payload/original_app_payload/')"
app_payload() {
    case "$1" in
        extract) mkdir -p "$4"; printf fixture > "$4/openlist" ;;
        verify) : ;;
        report) echo APP_REPORT ;;
        *) original_app_payload "$@" ;;
    esac
}
app_initialize() { :; }
'''

    def test_existing_install_is_never_overwritten(self):
        (self.root / 'application').mkdir()
        marker = self.root / 'application' / 'data.db'
        marker.write_bytes(b'precious')
        result = self.shell('install_panel_app openlist', success=False)
        self.assertNotIn('APT_CALLED', result.stdout)
        self.assertEqual(marker.read_bytes(), b'precious')

    def test_managed_install_only_reports_and_does_not_reset_credentials(self):
        (self.root / 'records').mkdir()
        record = self.root / 'records/openlist.json'
        record.write_text('unchanged')
        result = self.shell('curl() { echo UNEXPECTED_LOOKUP; return 93; }; app_payload() { echo EXISTING_REPORT; }; install_panel_app openlist')
        self.assertIn('EXISTING_REPORT', result.stdout)
        self.assertNotIn('APT_CALLED', result.stdout)
        self.assertNotIn('UNEXPECTED_LOOKUP', result.stdout)
        self.assertEqual(record.read_text(), 'unchanged')

    def test_corrupt_download_fails_before_service_or_database_creation(self):
        result = self.shell("download_verified() { die 'SHA-256 校验失败'; }; install_panel_app openlist", success=False)
        self.assertFalse((self.root / 'application').exists())
        self.assertFalse((self.root / 'data').exists())
        self.assertNotIn('enable', (self.state / 'systemctl').read_text())
        self.assertIn('撤回', result.stdout)

    def test_initialization_failure_rolls_back_fresh_files(self):
        self.shell(self.fake_payload() + "app_initialize() { false; }; install_panel_app openlist", success=False)
        for name in ['application', 'data', 'application.service', 'records/openlist.json']:
            self.assertFalse((self.root / name).exists(), name)

    def test_service_failure_removes_only_fresh_service_and_data(self):
        self.shell(self.fake_payload() + '''
systemctl() { case "$1" in show) echo not-found ;; enable) return 1 ;; esac; }
install_panel_app openlist
''', success=False)
        for name in ['application', 'data', 'application.service', 'records/openlist.json']:
            self.assertFalse((self.root / name).exists(), name)

    def test_login_failure_never_claims_success_and_removes_fresh_service(self):
        result = self.shell(self.fake_payload() + '''
eval "$(declare -f app_payload | sed '1s/app_payload/fake_app_payload/')"
app_payload() { if [[ $1 == verify ]]; then return 1; fi; fake_app_payload "$@"; }
sleep() { :; }
install_panel_app openlist
''', success=False)
        self.assertNotIn('安装完成，已启用开机启动', result.stdout)
        self.assertNotIn('APP_REPORT', result.stdout)
        self.assertIn('disable --now openlist.service', (self.state / 'systemctl').read_text())
        self.assertFalse((self.root / 'data').exists())

    def test_successful_install_keeps_record_and_prints_info(self):
        result = self.shell(self.fake_payload() + 'install_panel_app openlist')
        self.assertIn('APP_REPORT', result.stdout)
        self.assertIn('enable --now openlist.service', (self.state / 'systemctl').read_text())
        self.assertEqual((self.root / 'records/openlist.json').stat().st_mode & 0o777, 0o600)
        self.assertTrue((self.root / 'application/openlist').exists())
        self.assertEqual(list((self.root / 'records').glob('install.*')), [])

    def use_latest(self, metadata):
        fixture = self.root / 'latest.json'
        fixture.write_text(json.dumps(metadata))
        return self.fake_payload() + f'''
app_asset() {{ real_app_asset; }}
curl() {{
    local output=''
    printf '%s\\n' "${{!#}}" >> "$STATE/lookups"
    while (( $# )); do
        if [[ $1 == --output ]]; then output=$2; shift; fi
        shift
    done
    cp {shlex.quote(str(fixture))} "$output"
}}
'''

    def test_latest_lookup_once_and_versioned_verified_download(self):
        result = self.shell(self.use_latest(release_fixture()) + '''
download_verified() { printf '%s\\n' "$1" "$3" > "$STATE/download"; printf fixture > "$2"; }
install_panel_app openlist
''')
        self.assertIn('APP_REPORT', result.stdout)
        self.assertEqual((self.state / 'lookups').read_text().splitlines(),
                         ['https://api.github.com/repos/OpenListTeam/OpenList/releases/latest'])
        self.assertEqual((self.state / 'download').read_text().splitlines(),
                         ['https://github.com/OpenListTeam/OpenList/releases/download/v9.8.7/openlist-linux-amd64.tar.gz', 'a' * 64])
        self.assertEqual(json.loads((self.root / 'records/openlist.json').read_text())['version'], 'v9.8.7')

    def test_latest_api_failure_does_not_download_or_fall_back(self):
        result = self.shell(self.use_latest(release_fixture()) + '''
curl() { return 22; }
install_panel_app openlist
''', success=False)
        self.assertNotIn('DOWNLOAD_CALLED', result.stdout)
        self.assertFalse((self.root / 'application').exists())
        self.assertIn('查询官方最新稳定版失败', result.stderr)

    def test_bad_latest_metadata_never_reaches_download(self):
        metadata = release_fixture()
        metadata['assets'][0]['digest'] = None
        result = self.shell(self.use_latest(metadata) + 'install_panel_app openlist', success=False)
        self.assertNotIn('DOWNLOAD_CALLED', result.stdout)
        self.assertFalse((self.root / 'application').exists())

    def test_embedded_application_sources_match(self):
        text = (ROOT / 'bbr.sh').read_text()
        for name in ['app_helpers.inc', 'app_payload.py']:
            self.assertIn((ROOT / 'tools' / name).read_text().strip(), text)
