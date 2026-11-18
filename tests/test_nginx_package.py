"""Untrusted payload validation; no package install or live service changes."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tarfile

from test_scripts import Harness, ROOT

spec = importlib.util.spec_from_file_location('nginx_package', ROOT / 'tools/nginx_package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class TestNginxPackage(Harness):
    def setUp(self):
        super().setUp()
        self.stage = self.root / 'stage'
        for name in package.FILES:
            p = self.stage / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(b'\x7fELF\x02\x01' + b'\0' * 12 + struct.pack('<H', 62) + b'fixture')
        package.seal(self.stage, 'ubuntu', '24.04', 'amd64', '1.30.6', 'a' * 64)
        self.archive = self.root / 'nginx.tar.gz'
        package.package(self.stage, self.archive)

    def extract(self, **changes):
        values = dict(archive=self.archive, destination=self.root / 'out', system='ubuntu', version='24.04', arch='amd64')
        values.update(changes)
        return package.extract_package(**values)

    def test_roundtrip_and_embedded_verifier_match(self):
        meta = self.extract()
        self.assertEqual(meta['nginx_version'], '1.30.6')
        self.shell(f'nginx_package_tool verify "{self.root}/out" ubuntu 24.04 amd64')
        for name in package.FILES:
            self.assertEqual((self.root / 'out' / name).read_bytes(), (self.stage / name).read_bytes())

    def test_rejects_wrong_platform_arch_or_reused_destination(self):
        for changes in ({'system': 'debian'}, {'version': '26.04'}, {'arch': 'arm64'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.extract(**changes)
        (self.root / 'out').mkdir()
        with self.assertRaises(FileExistsError):
            self.extract()

    def test_rejects_cache_with_wrong_build_identity(self):
        with self.assertRaises(ValueError):
            self.extract(recipe='b' * 64)
        self.assertFalse((self.root / 'out').exists())

    def malformed(self, name, kind=tarfile.REGTYPE, duplicate=False, size=1):
        with tarfile.open(self.archive, 'w:gz') as tar:
            for item in (*package.FILES, 'nginx-build.json'):
                tar.add(self.stage / item, arcname=item)
            info = tarfile.TarInfo(name)
            info.type, info.linkname, info.size = kind, '../../escaped', size
            tar.addfile(info, io.BytesIO(b'x' * size) if kind == tarfile.REGTYPE else None)

    def test_rejects_traversal_links_duplicates_extra_files(self):
        for name, kind in [('../escaped', tarfile.REGTYPE), ('/tmp/escaped', tarfile.REGTYPE),
                           ('nginx-build.json', tarfile.REGTYPE), ('usr/sbin/nginx', tarfile.SYMTYPE),
                           ('usr/sbin/nginx', tarfile.LNKTYPE), ('postinst', tarfile.REGTYPE)]:
            self.malformed(name, kind)
            with self.subTest(name=name, kind=kind), self.assertRaises(ValueError):
                self.extract()
            self.assertFalse((self.root / 'out').exists())

    def test_rejects_missing_and_modified_content(self):
        (self.stage / 'usr/sbin/nginx').write_bytes(b'changed')
        package.package(self.stage, self.archive)
        with self.assertRaises(ValueError):
            self.extract()
        with tarfile.open(self.archive, 'w:gz') as tar:
            tar.add(self.stage / 'nginx-build.json', arcname='nginx-build.json')
        with self.assertRaises(ValueError):
            self.extract()

    def test_rejects_elf_arch_even_when_hash_is_updated(self):
        binary = self.stage / 'usr/sbin/nginx'
        binary.write_bytes(b'\x7fELF\x02\x01' + b'\0' * 12 + struct.pack('<H', 183))
        meta = json.loads((self.stage / 'nginx-build.json').read_text())
        meta['files']['usr/sbin/nginx'] = dict(size=binary.stat().st_size, sha256=package.digest(binary))
        (self.stage / 'nginx-build.json').write_text(json.dumps(meta))
        package.package(self.stage, self.archive)
        with self.assertRaises(ValueError):
            self.extract()

    def test_download_checksum_failure_stops_before_extraction(self):
        name = 'nginx-ubuntu-24.04-amd64.tar.gz'
        (self.state / name).write_bytes(self.archive.read_bytes())
        (self.state / 'NGINX_SHA256SUMS').write_text('0' * 64 + '  ' + name + '\n')
        result = self.shell(f'''
NGINX_PACKAGE_DIR=$STATE
NGX_ASSET={name}
mkdir "$STATE/work"
nginx_download_package "$STATE/work"
touch "$STATE/unsafe"
''', success=False)
        self.assertIn('SHA-256', result.stderr)
        self.assertFalse((self.state / 'unsafe').exists())
        self.assertFalse((self.state / 'work/stage').exists())

    def test_remote_download_is_bound_to_script_tag(self):
        name = 'nginx-ubuntu-24.04-amd64.tar.gz'
        (self.state / name).write_bytes(self.archive.read_bytes())
        sha = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.state / 'NGINX_SHA256SUMS').write_text(f'{sha}  {name}\n')
        self.shell(f'''
TOOL_VERSION=9.8.7; NGX_ASSET={name}; ID=ubuntu; VERSION_ID=24.04; NGX_ARCH=amd64
curl() {{
    [[ ${{!#}} == https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/v9.8.7/NGINX_SHA256SUMS ]] || return 91
    while (( $# )); do if [[ $1 == --output ]]; then cp "$STATE/NGINX_SHA256SUMS" "$2"; return; fi; shift; done
}}
download_verified() {{
    [[ $1 == https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/v9.8.7/{name} && $3 == {sha} ]] || return 92
    cp "$STATE/{name}" "$2"
}}
mkdir "$STATE/work"
nginx_download_package "$STATE/work"
[[ $NGX_VERSION == 1.30.6 ]]
''')

    def test_platform_rejects_before_any_download(self):
        for os_id, version, arch in [('ubuntu', '26.04', 'amd64'), ('debian', '12', 'amd64'), ('ubuntu', '24.04', 'arm64')]:
            self.shell(f'''read_os() {{ ID={os_id}; VERSION_ID={version}; }}
dpkg() {{ echo {arch}; }}
nginx_prebuilt_platform
touch "$STATE/unsafe"
''', success=False)
        self.assertFalse((self.state / 'unsafe').exists())
