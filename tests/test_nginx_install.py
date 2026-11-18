"""Exercise installation transactions against temporary paths and fake services."""
from pathlib import Path
import re
import shlex

from test_scripts import Harness, ROOT


class TestNginxInstall(Harness):
    def setUp(self):
        super().setUp()
        # Rewrite only absolute host paths, not $stage/usr/... payload paths.
        helper = (ROOT / 'tools/nginx_helpers.inc').read_text()
        prefixes = ('/etc/nginx', '/etc/systemd', '/usr/sbin/nginx', '/usr/local/nginx',
                    '/usr/share/GeoIP', '/var/lib/bbr-nginx', '/var/lib/ubuntu-dd',
                    '/var/cache/nginx', '/var/log/nginx', '/run/systemd/system')
        for prefix in prefixes:
            helper = re.sub(r'(?<![\w$])' + re.escape(prefix), str(self.root / 'host') + prefix, helper)
        helper = helper.replace('$stage"' + str(self.root / 'host'), '$stage"')
        path = self.root / 'nginx.inc'
        path.write_text(helper)
        self.prefix += '\nsource ' + shlex.quote(str(path)) + '\n'
        self.host = self.root / 'host'
        (self.host / 'run/systemd/system').mkdir(parents=True)
        (self.host / 'etc/systemd/system').mkdir(parents=True)
        (self.host / 'usr/sbin').mkdir(parents=True)
        self.stage = self.root / 'payload'
        (self.stage / 'usr/sbin').mkdir(parents=True)
        executable = self.stage / 'usr/sbin/nginx'
        executable.write_text('#!/bin/bash\n[[ "$*" != *-t* || ! -e "$STATE/fail-config" ]]\n')
        executable.chmod(0o755)
        (self.stage / 'usr/local/nginx/modules').mkdir(parents=True)
        (self.stage / 'usr/local/nginx/modules/test.so').write_text('new module')
        (self.stage / 'etc/nginx').mkdir(parents=True)
        (self.stage / 'etc/nginx/mime.types').write_text('new mime')
        (self.stage / 'nginx-build.json').write_text('new metadata')
        self.prefix += f'''
ID=ubuntu; VERSION_ID=24.04; NGX_ARCH=amd64; NGX_VERSION=1.30.6
nginx_prebuilt_platform() {{ :; }}
nginx_package_tool() {{ :; }}
nginx_download_package() {{ cp -a {shlex.quote(str(self.stage))} "$1/stage"; }}
nginx_fetch() {{ printf database > "$2"; }}
mmdblookup() {{ :; }}
apt-get() {{ printf '%s\\n' "$*" >> "$STATE/apt"; }}
id() {{ return 0; }}
useradd() {{ :; }}
install() {{
    local -a args=()
    while (( $# )); do
        case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    command install "${{args[@]}}"
}}
systemctl() {{
    printf '%s\\n' "$*" >> "$STATE/services"
    case "$1" in
        is-active) [[ -e "$STATE/active" ]] ;;
        is-enabled) if [[ -e "$STATE/enabled" ]]; then echo enabled; else echo disabled; return 1; fi ;;
        start) [[ ! -e "$STATE/fail-start" ]] || {{ rm "$STATE/fail-start"; return 9; }}; touch "$STATE/active" ;;
        stop) rm -f "$STATE/active" ;;
        enable) touch "$STATE/enabled" ;;
        disable) rm -f "$STATE/enabled" ;;
    esac
}}
'''

    def original(self):
        for relative, data in [('etc/nginx/nginx.conf', 'original configuration'),
                               ('etc/nginx/mime.types', 'original mime'),
                               ('usr/sbin/nginx', 'original executable'),
                               ('usr/local/nginx/modules/old.so', 'original module'),
                               ('etc/systemd/system/nginx.service', 'original service'),
                               ('usr/share/GeoIP/GeoLite2-City.mmdb', 'original database'),
                               ('var/lib/bbr-nginx/installed.json', 'original metadata')]:
            path = self.host / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(data)
        (self.state / 'active').touch()
        (self.state / 'enabled').touch()
        return {str(p.relative_to(self.host)): p.read_bytes() for p in self.host.rglob('*') if p.is_file()}

    def test_prebuilt_installs_without_build_tools_or_swap(self):
        self.shell('nginx_prepare_swap() { exit 91; }; nginx_build_stage() { exit 92; }; install_nginx')
        self.assertTrue((self.host / 'usr/sbin/nginx').exists())
        self.assertTrue((self.state / 'active').exists())
        apt = (self.state / 'apt').read_text()
        self.assertIn('--no-remove', apt)
        self.assertNotIn('build-essential', apt)
        self.assertNotIn('cmake', apt)
        self.assertFalse((self.host / 'var/lib/bbr-nginx/swapfile').exists())

    def test_explicit_source_route_builds_then_uses_shared_installer(self):
        self.shell(f'''
nginx_download_package() {{ exit 93; }}
nginx_recover_swap() {{ :; }}
nginx_prepare_swap() {{ touch "$STATE/source-swap"; }}
nginx_build_stage() {{ cp -a {shlex.quote(str(self.stage))} "$3"; touch "$STATE/source-built"; }}
install_nginx source
''')
        self.assertTrue((self.state / 'source-swap').exists())
        self.assertTrue((self.state / 'source-built').exists())
        self.assertTrue((self.state / 'active').exists())
        self.assertIn('build-essential', (self.state / 'apt').read_text())

    def test_existing_configuration_database_and_unrelated_module_are_preserved(self):
        before = self.original()
        self.shell('nginx_fetch() { exit 93; }; install_nginx')
        for relative in ('etc/nginx/nginx.conf', 'etc/nginx/mime.types', 'usr/share/GeoIP/GeoLite2-City.mmdb', 'usr/local/nginx/modules/old.so'):
            self.assertEqual((self.host / relative).read_bytes(), before[relative])

    def test_failed_config_restores_original_files_and_service(self):
        before = self.original()
        (self.state / 'fail-config').touch()
        self.shell('install_nginx', success=False)
        for relative, data in before.items():
            self.assertEqual((self.host / relative).read_bytes(), data, relative)
        self.assertFalse((self.host / 'usr/local/nginx/modules/test.so').exists())
        self.assertTrue((self.state / 'active').exists())
        self.assertTrue((self.state / 'enabled').exists())

    def test_failed_start_restores_original_service(self):
        before = self.original()
        (self.state / 'fail-start').touch()
        self.shell('install_nginx', success=False)
        self.assertEqual((self.host / 'usr/sbin/nginx').read_bytes(), before['usr/sbin/nginx'])
        self.assertTrue((self.state / 'active').exists())

    def test_download_failure_prevents_apt_and_live_changes(self):
        before = self.original()
        self.shell('nginx_download_package() { return 94; }; install_nginx', success=False)
        self.assertFalse((self.state / 'apt').exists())
        self.assertFalse((self.state / 'services').exists())
        for relative, data in before.items():
            self.assertEqual((self.host / relative).read_bytes(), data)

    def test_fresh_failed_install_removes_new_live_payload(self):
        (self.state / 'fail-config').touch()
        self.shell('install_nginx', success=False)
        for relative in ('etc/nginx', 'usr/sbin/nginx', 'usr/local/nginx', 'usr/share/GeoIP/GeoLite2-City.mmdb'):
            self.assertFalse((self.host / relative).exists())
        self.assertFalse((self.state / 'active').exists())
