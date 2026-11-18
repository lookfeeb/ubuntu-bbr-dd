"""Cache identity and corruption tests using real tar, manifest and ELF validation."""
import struct
import tarfile

from test_scripts import Harness
from test_nginx_package import package


class TestNginxCache(Harness):
    def setUp(self):
        super().setUp()
        template = self.state / 'template'
        for name in package.FILES:
            path = template / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'\x7fELF\x02\x01' + b'\0' * 12 + struct.pack('<H', 62) + b'fixture')
        with tarfile.open(self.state / 'upstream.tar.gz', 'w:gz'):
            pass
        (self.state / 'compiler').write_text('gcc fixture 1')
        self.prefix += r'''
read_os() { ID=ubuntu; VERSION_ID=24.04; }
dpkg() { echo amd64; }
dpkg-query() { echo 'fixture-lib=1'; }
gcc() { cat "$STATE/compiler"; }
ld() { echo ld-fixture; }
nginx_source() {
    NGX_VERSION=1.30.6
    cp "$STATE/upstream.tar.gz" "$1/nginx.tar.gz"
    touch "$1/nginx.tar.gz.asc" "$1/signature.status" "$1/nginx.sha256"
}
download_verified() { cp "$STATE/upstream.tar.gz" "$2"; }
nginx_module_source() { mkdir -p "$2"; }
git() { :; }
nginx_build_jobs() { echo 1; }
nginx_compile_stage() {
    echo compiled >> "$STATE/compiles"
    mkdir "$2"
    cp -a "$STATE/template/." "$2/"
}
'''

    def build(self, name, success=True):
        return self.shell(f'mkdir "$STATE/{name}"\nnginx_build_stage "$STATE/{name}" "$STATE/cache" "$STATE/{name}/stage"', success=success)

    def test_matching_inputs_reuse_verified_payload_without_compilation(self):
        self.build('one')
        output = self.build('two').stdout
        self.assertIn('复用已校验', output)
        self.assertEqual((self.state / 'compiles').read_text().splitlines(), ['compiled'])
        self.assertEqual((self.state / 'one/stage/nginx-build.json').read_bytes(), (self.state / 'two/stage/nginx-build.json').read_bytes())

    def test_compiler_change_forces_new_payload(self):
        self.build('one')
        (self.state / 'compiler').write_text('gcc fixture 2')
        self.build('two')
        self.assertEqual((self.state / 'compiles').read_text().splitlines(), ['compiled', 'compiled'])
        self.assertNotEqual((self.state / 'one/stage/nginx-build.json').read_bytes(), (self.state / 'two/stage/nginx-build.json').read_bytes())

    def test_corrupt_completed_cache_fails_closed(self):
        self.build('one')
        cached = next(p for p in (self.state / 'cache').glob('*.tar.gz') if len(p.name) == 71)
        cached.write_bytes(b'broken')
        self.build('two', success=False)
        self.assertFalse((self.state / 'two/stage').exists())
        self.assertEqual((self.state / 'compiles').read_text().splitlines(), ['compiled'])
