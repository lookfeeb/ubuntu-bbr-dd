"""Synchronize development sources embedded in the two standalone scripts."""
from pathlib import Path
import re
import base64
import json
import gzip
import io

root = Path(__file__).resolve().parents[1]
cloud = (root / 'tools/cloud_helpers.inc').read_text(encoding='utf-8').strip()
menu = (root / 'tools/menu_helpers.inc').read_text(encoding='utf-8').strip()
host = (root / 'tools/host_helpers.inc').read_text(encoding='utf-8').strip()
release = (root / 'tools/release_helpers.inc').read_text(encoding='utf-8').strip()
for name in ['bbr.sh', 'dd.sh']:
    path = root / name
    text = path.read_text(encoding='utf-8')
    text = re.sub(r'# BEGIN MENU HELPERS\n.*?# END MENU HELPERS', lambda _: menu, text, flags=re.S)
    text = re.sub(r'# BEGIN HOST HELPERS\n.*?# END HOST HELPERS', lambda _: host, text, flags=re.S)
    text = re.sub(r'# BEGIN RELEASE HELPERS\n.*?# END RELEASE HELPERS', lambda _: release, text, flags=re.S)
    if '# BEGIN CLOUD HELPERS' in text:
        text = re.sub(r'# BEGIN CLOUD HELPERS\n.*?# END CLOUD HELPERS', lambda _: cloud, text, flags=re.S)
    else:
        text += '\n' + cloud + '\n'
    if name == 'bbr.sh':
        apps = (root / 'tools/app_helpers.inc').read_text(encoding='utf-8').strip()
        payload = (root / 'tools/app_payload.py').read_text(encoding='utf-8').strip()
        payload_block = "# BEGIN APP PAYLOAD\napp_payload() {\n    python3 -B - \"$@\" <<'PY_APP_PAYLOAD'\n" + payload + '\nPY_APP_PAYLOAD\n}\n# END APP PAYLOAD'
        for marker, block in [('APP PAYLOAD', payload_block), ('APP HELPERS', apps)]:
            if '# BEGIN ' + marker in text:
                text = re.sub('# BEGIN ' + marker + r'\n.*?# END ' + marker, lambda _: block, text, flags=re.S)
            else:
                text = text.replace('\nbbr_menu_action() {', '\n' + block + '\n\nbbr_menu_action() {', 1)
        build = (root / 'tools/nginx_build.inc').read_text(encoding='utf-8').strip()
        package = (root / 'tools/nginx_package.py').read_text(encoding='utf-8').strip()
        package_block = "# BEGIN NGINX PACKAGE\nnginx_package_tool() {\n    python3 -B - \"$@\" <<'PY_NGINX_PACKAGE'\n" + package + '\nPY_NGINX_PACKAGE\n}\n# END NGINX PACKAGE'
        for marker, block in [('NGINX BUILD', build), ('NGINX PACKAGE', package_block)]:
            if '# BEGIN ' + marker in text:
                text = re.sub('# BEGIN ' + marker + r'\n.*?# END ' + marker, lambda _: block, text, flags=re.S)
            else:
                text = text.replace('# BEGIN NGINX HELPERS', block + '\n\n# BEGIN NGINX HELPERS', 1)
        nginx = (root / 'tools/nginx_helpers.inc').read_text(encoding='utf-8').strip()
        text = re.sub(r'# BEGIN NGINX HELPERS\n.*?# END NGINX HELPERS', lambda _: nginx, text, flags=re.S)
        kernel_patch = (root / 'tools/kernel_patch.py').read_text(encoding='utf-8').strip()
        buffer = io.BytesIO()
        with gzip.GzipFile(fileobj=buffer, mode='wb', filename='', mtime=0) as compressed:
            compressed.write((root / 'tools/google-bbr3.patch').read_bytes())
        data = base64.b64encode(buffer.getvalue()).decode()
        kernel_patch = kernel_patch.replace("PATCH_DATA = ''  # Filled by sync_embedded.py.", 'PATCH_DATA = ' + repr(data))
        kernel_block = '# BEGIN GOOGLE PATCH\napply_google_patch() {\n    python3 - "$1" <<\'PY_GOOGLE\'\n' + kernel_patch + '\nPY_GOOGLE\n}\n# END GOOGLE PATCH'
        text = re.sub(r'# BEGIN GOOGLE PATCH\n.*?# END GOOGLE PATCH', lambda _: kernel_block, text, flags=re.S)
        recovery = (root / 'tools/wan_recovery.py').read_text(encoding='utf-8').split("if __name__ == '__main__':", 1)[0].strip()
        block = "# BEGIN RECOVERY PATCH\napply_recovery_patch() {\n    python3 - \"$1\" <<'PY_RECOVERY'\n" + recovery + '\napply_kernel_tree(Path(sys.argv[1]))\nPY_RECOVERY\n}\n# END RECOVERY PATCH'
        text = re.sub(r'# BEGIN RECOVERY PATCH\n.*?# END RECOVERY PATCH', lambda _: block, text, flags=re.S)
    if name == 'dd.sh':
        disk = (root / 'tools/dd_disk.sh').read_text(encoding='utf-8').split('# BEGIN DD DISK HELPERS', 1)[1]
        disk = '# BEGIN DD DISK HELPERS\n' + disk.strip('\n')
        text = re.sub(r'# BEGIN DD DISK HELPERS\n.*?# END DD DISK HELPERS', lambda _: disk.strip(), text, flags=re.S)
        patch = (root / 'tools/dd_patch.py').read_text(encoding='utf-8').strip()
        assets = {name: base64.b64encode((root / 'tools' / name).read_bytes()).decode()
                  for name in ['dd_resources.sh', 'dd_disk.sh', 'dd_runtime.sh', 'dd_packages.sh', 'ubuntu-cloudimage-keyring.gpg']}
        patch = patch.replace('ASSETS = {}  # Replaced by sync_embedded.py in the standalone release.',
                              'ASSETS = ' + json.dumps(assets, sort_keys=True))
        block = '# BEGIN DD ENGINE\nengine_tools() {\n    python3 - "$@" <<\'PY_DD\'\n' + patch + '\nPY_DD\n}\n# END DD ENGINE'
        text = re.sub(r'# BEGIN DD ENGINE\n.*?# END DD ENGINE', lambda _: block, text, flags=re.S)
    path.write_text(text, encoding='utf-8', newline='\n')
