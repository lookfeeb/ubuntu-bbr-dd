"""Create and validate the small, platform-specific Nginx payload (no install hooks)."""
import hashlib
import json
from pathlib import Path
import re
import struct
import tarfile

MODULES = ('ngx_http_geoip2_module', 'ngx_stream_geoip2_module',
           'ngx_http_brotli_filter_module', 'ngx_http_brotli_static_module')
FILES = ('usr/sbin/nginx', 'etc/nginx/mime.types',
         *(f'usr/local/nginx/modules/{name}.so' for name in MODULES))
LIMIT = 128 * 1024 * 1024


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def validate_metadata(meta, system, version, arch):
    if (meta.get('format') != 1 or meta.get('system') != system or
            meta.get('system_version') != version or meta.get('architecture') != arch or
            arch not in ('amd64', 'arm64') or
            not re.fullmatch(r'\d+\.\d+\.\d+', meta.get('nginx_version', '')) or
            not re.fullmatch(r'[a-f0-9]{64}', meta.get('recipe', '')) or
            set(meta.get('files', {})) != set(FILES)):
        raise ValueError('Nginx 包平台、格式或文件清单不匹配')
    for info in meta['files'].values():
        if (not isinstance(info, dict) or not isinstance(info.get('size'), int) or
                not 0 < info['size'] <= LIMIT or
                not re.fullmatch(r'[a-f0-9]{64}', info.get('sha256', ''))):
            raise ValueError('Nginx 文件大小或 SHA-256 无效')


def check_elf(path, arch):
    with path.open('rb') as stream:
        header = stream.read(20)
    if (len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or
            struct.unpack('<H', header[18:20])[0] != {'amd64': 62, 'arm64': 183}[arch]):
        raise ValueError('Nginx ELF 架构不匹配: ' + str(path))


def verify_tree(stage, system, version, arch):
    stage = Path(stage)
    meta = json.loads((stage / 'nginx-build.json').read_text())
    validate_metadata(meta, system, version, arch)
    for name in FILES:
        path = stage / name
        info = meta['files'][name]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != info['size'] or digest(path) != info['sha256']:
            raise ValueError('Nginx 文件校验失败: ' + name)
        if name != 'etc/nginx/mime.types':
            check_elf(path, arch)
    return meta


def extract_package(archive, destination, system, version, arch, recipe=None):
    archive, destination = Path(archive), Path(destination)
    if archive.is_symlink() or archive.stat().st_size > LIMIT:
        raise ValueError('Nginx 包类型或大小异常')
    # Read only the finite payload; do not use extractall on downloaded archives.
    allowed = set(FILES) | {'nginx-build.json'}
    data = {}
    total = 0
    with tarfile.open(archive, 'r:gz') as bundle:
        for item in bundle:
            total += item.size
            if (item.name not in allowed or item.name in data or not item.isreg() or
                    item.issparse() or not 0 < item.size <= LIMIT or total > LIMIT or
                    (item.name == 'nginx-build.json' and item.size > 65536)):
                raise ValueError('Nginx 压缩包含异常、重复或越界文件')
            data[item.name] = bundle.extractfile(item).read()
            if len(data[item.name]) != item.size:
                raise ValueError('Nginx 压缩包不完整')
    if set(data) != allowed:
        raise ValueError('Nginx 压缩包缺少必需文件')
    meta = json.loads(data['nginx-build.json'])
    validate_metadata(meta, system, version, arch)
    if recipe is not None and meta['recipe'] != recipe:
        raise ValueError('Nginx 缓存与当前构建身份不匹配')
    for name in FILES:
        if (len(data[name]) != meta['files'][name]['size'] or
                hashlib.sha256(data[name]).hexdigest() != meta['files'][name]['sha256']):
            raise ValueError('Nginx 压缩包内部校验失败: ' + name)
    # New staging directory, never overlay existing files or follow links.
    destination.mkdir(mode=0o700)
    for name, content in data.items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        path.chmod(0o644 if name in ('nginx-build.json', 'etc/nginx/mime.types') else 0o755)
    verify_tree(destination, system, version, arch)
    return meta


def seal(stage, system, version, arch, nginx_version, recipe):
    stage = Path(stage)
    meta = dict(format=1, system=system, system_version=version, architecture=arch,
                nginx_version=nginx_version, recipe=recipe,
                files={name: dict(size=(stage / name).stat().st_size, sha256=digest(stage / name)) for name in FILES})
    (stage / 'nginx-build.json').write_text(json.dumps(meta, indent=2, sort_keys=True) + '\n')
    verify_tree(stage, system, version, arch)


def package(stage, output):
    with tarfile.open(output, 'w:gz', compresslevel=6) as bundle:
        for name in (*FILES, 'nginx-build.json'):
            bundle.add(Path(stage) / name, arcname=name, recursive=False)


def main():
    import sys
    command, *args = sys.argv[1:]
    if command == 'extract':
        print(extract_package(*args)['nginx_version'])
    elif command == 'verify':
        print(verify_tree(*args)['nginx_version'])
    elif command == 'seal':
        seal(*args)
    elif command == 'pack':
        package(*args)
    else:
        raise ValueError('Unknown Nginx package operation')


if __name__ == '__main__':
    main()
