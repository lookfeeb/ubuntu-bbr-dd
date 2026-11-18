"""Apply Google's complete BBRv3 patch series to the pinned stable kernel.

The rate sampling, congestion-control callbacks and UAPI changes are required
as well as tcp_bbr3.c. Embedded in bbr.sh along with the original patch.
"""
import base64
import gzip
import hashlib
from pathlib import Path
import re
import subprocess
import sys

PATCH_SHA256 = 'f4098994236209328cbac66e89e4c216aacdce31098b07532f961eecd789c553'
PATCH_DATA = ''  # Filled by sync_embedded.py.


def apply(root):
    root = Path(root).resolve()
    makefile = (root / 'Makefile').read_text()
    for name, value in [('VERSION', '7'), ('PATCHLEVEL', '3'), ('SUBLEVEL', '5'), ('EXTRAVERSION', '')]:
        match = re.search(r'^' + name + r' =([^\n]*)$', makefile, re.M)
        if not match or match[1].strip() != value:
            raise ValueError('Expected pristine Linux 7.3.5')
    if (root / 'net/ipv4/tcp_bbr3.c').exists():
        raise ValueError('BBRv3 already present; use a clean source tree')
    data = gzip.decompress(base64.b64decode(PATCH_DATA)) if PATCH_DATA else Path(__file__).with_name('google-bbr3.patch').read_bytes()
    if hashlib.sha256(data).hexdigest() != PATCH_SHA256:
        raise ValueError('Google BBRv3 patch checksum mismatch')
    patches = [p for p in re.split(r'(?=^From [a-f0-9]{40} Mon Sep 17)', data.decode(), flags=re.M) if p.strip()]
    if len(patches) != 13:
        raise ValueError('Expected 13 Google BBRv3 patches')
    for number, patch in enumerate(patches, 1):
        print(f'Applying Google BBRv3 patch {number}/13', flush=True)
        subprocess.run(['patch', '--dry-run', '--batch', '--forward', '--fuzz=0', '-p1'], cwd=root, input=patch, text=True, check=True)
        subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1'], cwd=root, input=patch, text=True, check=True)


if __name__ == '__main__':
    apply(sys.argv[1])
