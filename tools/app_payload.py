"""Validate official application archives and handle private installation records."""
import ipaddress
import http.cookiejar
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import socket
import sqlite3
import ssl
import struct
import sys
import tarfile
import urllib.parse
import urllib.request


def write_json(path, value):
    path = Path(path)
    with path.open('x', encoding='utf-8') as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def select_release(app, arch, release):
    repo = {'x-ui': 'MHSanaei/3x-ui', 'openlist': 'OpenListTeam/OpenList'}[app]
    if arch not in ('amd64', 'arm64'):
        raise ValueError('应用发布包架构不受支持')
    if not isinstance(release, dict):
        raise ValueError('官方 Release 元数据格式异常')
    tag = release.get('tag_name', '')
    if (release.get('draft') is not False or release.get('prerelease') is not False or
            not isinstance(tag, str) or not re.fullmatch(r'v?\d+\.\d+\.\d+(?:\.\d+)?', tag, flags=re.ASCII) or
            release.get('html_url') != f'https://github.com/{repo}/releases/tag/{tag}'):
        raise ValueError('官方最新 Release 不是有效稳定版，未安装')
    name = f'{app}-linux-{arch}.tar.gz'
    assets = release.get('assets')
    if not isinstance(assets, list) or not all(isinstance(asset, dict) for asset in assets):
        raise ValueError('官方 Release 资产清单异常')
    matching = [asset for asset in assets if asset.get('name') == name]
    if len(matching) != 1:
        raise ValueError('官方最新稳定版缺少唯一匹配的架构发布包：' + name)
    asset = matching[0]
    digest = asset.get('digest')
    url = f'https://github.com/{repo}/releases/download/{tag}/{name}'
    if (asset.get('state') != 'uploaded' or asset.get('browser_download_url') != url or
            type(asset.get('size')) is not int or not 0 < asset['size'] <= 1024**3 or
            not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest)):
        raise ValueError('官方发布包的上传状态、下载来源、大小或 SHA-256 异常，未安装')
    return dict(repo=repo, version=tag, name=name, url=url, size=asset['size'], sha256=digest[7:])


def resolve_release(app, arch, filename, destination):
    if Path(filename).stat().st_size > 2097152:
        raise ValueError('官方 Release 元数据过大')
    write_json(destination, select_release(app, arch, json.loads(Path(filename).read_text())))


def extract(app, archive, destination, arch):
    destination = Path(destination)
    destination.mkdir(mode=0o700)
    seen, total = set(), 0
    with tarfile.open(archive, 'r:gz') as bundle:
        for item in bundle:
            name = item.name.removeprefix('./').rstrip('/')
            path = PurePosixPath(name)
            if not name and item.isdir():
                continue
            total += item.size
            if (path.is_absolute() or '..' in path.parts or '\\' in name or
                    any(ord(c) < 32 for c in name) or name in seen or
                    len(seen) >= 2000 or total > 1024**3 or item.size < 0 or
                    item.issparse() or not (item.isdir() or item.isreg()) or
                    (app == 'x-ui' and path.parts[0] != 'x-ui')):
                raise ValueError('发布包包含异常路径、链接、重复文件或超大内容')
            seen.add(name)
            target = destination / path
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(item) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                target.chmod(0o755 if item.mode & 0o111 else 0o644)
    required = ['openlist'] if app == 'openlist' else ['x-ui/x-ui', f'x-ui/bin/xray-linux-{arch}']
    for name in required:
        path = destination / name
        with path.open('rb') as stream:
            header = stream.read(20)
        if (len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or
                struct.unpack('<H', header[18:20])[0] != {'amd64': 62, 'arm64': 183}[arch]):
            raise ValueError('发布包缺少正确架构的可执行文件：' + name)
        path.chmod(0o755)


def free_port(preferred):
    for port in [int(preferred)] + [secrets.randbelow(40000) + 20000 for _ in range(64)]:
        sockets = []
        try:
            for family, address in [(socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')]:
                if family == socket.AF_INET6 and not socket.has_ipv6:
                    continue
                sock = socket.socket(family)
                sockets.append(sock)
                if family == socket.AF_INET6:
                    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                try:
                    sock.bind((address, port))
                except OSError as error:
                    if family == socket.AF_INET6 and error.errno == 99:
                        continue
                    raise
            return port
        except OSError:
            continue
        finally:
            for sock in sockets:
                sock.close()
    raise ValueError('找不到可用的管理端口')


def record(app, filename, version, directory, data, port, release_file=None):
    state = dict(format=1, app=app, version=version, directory=directory,
                 data=data, port=int(port), username='admin', password=secrets.token_urlsafe(24),
                 base='/' + secrets.token_hex(12) + '/' if app == 'x-ui' else '/')
    if release_file is not None:
        state['release'] = json.loads(Path(release_file).read_text())
        if state['release']['version'] != version:
            raise ValueError('安装版本与冻结的 Release 信息不一致')
    write_json(filename, state)


def openlist_config(filename):
    state = json.loads(Path(filename).read_text())
    data = Path(state['data'])
    write_json(data / 'config.json', dict(force=True,
               database=dict(type='sqlite3', db_file=str(data / 'data.db'), table_prefix='x_'),
               scheme=dict(address='', http_port=-1, https_port=state['port'],
                           force_https=True, cert_file=str(data / 'tls/cert.pem'),
                           key_file=str(data / 'tls/key.pem'))))


def x_ui_config(filename):
    state = json.loads(Path(filename).read_text())
    # Only invoked for a fresh database before the first service start. Leave
    # subscriptions disabled until the user chooses their inbound/port settings.
    with sqlite3.connect(str(Path(state['data']) / 'x-ui.db')) as db:
        db.execute('delete from settings where key = ?', ('subEnable',))
        db.execute('insert into settings(key, value) values (?, ?)', ('subEnable', 'false'))


def current_state(filename):
    state = json.loads(Path(filename).read_text())
    data = Path(state['data'])
    if state['app'] == 'x-ui':
        with sqlite3.connect((data / 'x-ui.db').as_uri() + '?mode=ro', uri=True) as db:
            settings = dict(db.execute('select key, value from settings'))
            username = db.execute('select username from users order by id limit 1').fetchone()
        state.update(port=int(settings['webPort']), base=settings['webBasePath'],
                     username=username[0], cert=settings['webCertFile'])
    else:
        config = json.loads((data / 'config.json').read_text())
        with sqlite3.connect((data / 'data.db').as_uri() + '?mode=ro', uri=True) as db:
            username = db.execute('select username from x_users where role=2 order by id limit 1').fetchone()
        state.update(port=config['scheme']['https_port'], base='/', username=username[0],
                     cert=config['scheme']['cert_file'])
    if (not 1 <= state['port'] <= 65535 or not state['base'].startswith('/') or
            any(ord(c) < 32 for c in state['base'] + state['username'])):
        raise ValueError('当前应用的管理配置异常')
    return state


def authenticate(state):
    # Trust the installed self-signed certificate, never disable TLS verification.
    context = ssl.create_default_context(cafile=state['cert'])
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                        urllib.request.HTTPSHandler(context=context),
                                        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    base = f'https://127.0.0.1:{state["port"]}' + state['base']
    credentials = dict(username=state['username'], password=state['password'])
    if state['app'] == 'x-ui':
        with opener.open(base + 'csrf-token', timeout=5) as response:
            csrf = json.loads(response.read(65536))
        if csrf.get('success') is not True or not isinstance(csrf.get('obj'), str):
            raise ValueError('无法获取 3X-UI 登录会话')
        request = urllib.request.Request(base + 'login', urllib.parse.urlencode(credentials).encode(),
                                         {'X-CSRF-Token': csrf['obj'], 'X-Requested-With': 'XMLHttpRequest'})
    else:
        request = urllib.request.Request(base + 'api/auth/login', json.dumps(credentials).encode(),
                                         {'Content-Type': 'application/json'})
    with opener.open(request, timeout=5) as response:
        result = json.loads(response.read(1024 * 1024))
    if (result.get('success') is not True if state['app'] == 'x-ui' else result.get('code') != 200):
        raise ValueError('保存的初始凭据未通过登录验证（可能已经修改）')


def addresses():
    result = []
    # Public egress detection is informational; cloud firewalls/NAT are not changed.
    for url in ['https://api.ipify.org', 'https://api6.ipify.org']:
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                address = str(ipaddress.ip_address(response.read(128).decode().strip()))
            if address not in result:
                result.append(address)
        except (OSError, ValueError):
            pass
    connection = os.environ.get('SSH_CONNECTION', '').split()
    if len(connection) == 4:
        try:
            address = str(ipaddress.ip_address(connection[2]))
            if address not in result:
                result.append(address)
        except ValueError:
            pass
    return result


def report(filename):
    state = current_state(filename)
    print('\n===== ' + ('3X-UI' if state['app'] == 'x-ui' else 'OpenList') + ' 安装与登录信息 =====')
    print('安装版本：' + state['version'])
    print('管理端口：' + str(state['port']) + ' / TCP（HTTPS）')
    for host in addresses() or ['服务器公网 IP']:
        host = '[' + host + ']' if ':' in host else host
        print(f'访问地址：https://{host}:{state["port"]}{state["base"]}')
    print('用户名：' + state['username'])
    try:
        authenticate(state)
        print('密码：' + state['password'])
        print('本机 HTTPS 与登录验证：通过')
    except (OSError, ValueError):
        print('密码：未显示；保存的初始密码未通过当前登录验证，请使用已修改的密码或检查服务。')
    print('凭据记录：' + str(filename) + '（仅 root 可读；修改密码后旧记录不会自动更新）')
    print('数据目录：' + state['data'])
    print('服务状态：systemctl status ' + state['app'])
    print('启动命令：systemctl start ' + state['app'])
    print('停止命令：systemctl stop ' + state['app'])
    print('重启命令：systemctl restart ' + state['app'])
    print('日志命令：journalctl -u ' + state['app'] + ' -n 80 --no-pager')
    print('TLS 证书：' + state['cert'])
    print('使用自动生成的自签证书，浏览器会提示证书不受信任；可在应用配置中更换正式证书。')
    print('公网连通性未验证；请在云安全组/防火墙放行上述 TCP 端口，NAT 主机还需端口映射。')
    if state['app'] == 'x-ui':
        print('代理入站与订阅请登录面板后配置；入站端口需要另行放行。')
    else:
        print('网盘/存储请登录后台添加；WebDAV 路径为 /dav。')


def main():
    command, *args = sys.argv[1:]
    if command == 'extract':
        extract(*args)
    elif command == 'release':
        resolve_release(*args)
    elif command == 'port':
        print(free_port(*args))
    elif command == 'record':
        record(*args)
    elif command == 'field':
        print(json.loads(Path(args[0]).read_text())[args[1]])
    elif command == 'openlist-config':
        openlist_config(*args)
    elif command == 'x-ui-config':
        x_ui_config(*args)
    elif command == 'verify':
        authenticate(current_state(*args))
    elif command == 'report':
        report(*args)
    else:
        raise ValueError('未知应用操作')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('应用处理失败：' + str(error), file=sys.stderr)
        sys.exit(1)
