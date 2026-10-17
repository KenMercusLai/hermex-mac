#!/usr/bin/env python3
"""Fetch a checksum-pinned official Sparkle SDK for CLT-only builds.

No package resolution, credentials, key generation or executable downloads from
unversioned URLs. The cached archive is rehashed on every invocation.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
VERSION = '2.10.0'
SHA256 = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
URL = f'https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-{VERSION}.tar.xz'
SDK = ROOT / '.build/sparkle'


def verify_archive(data):
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Sparkle SDK checksum mismatch; refusing extraction')


def prepare():
    scratch = Path(os.environ.get('HERMEX_SCRATCH', str(Path.home() / '.hermes/cache/scratch')))
    scratch.mkdir(parents=True, exist_ok=True)
    archive = scratch / f'Hermex-Sparkle-{VERSION}.tar.xz'
    if not archive.exists():
        data = urllib.request.urlopen(URL, timeout=120).read()
        verify_archive(data)
        archive.write_bytes(data)
    verify_archive(archive.read_bytes())
    # Always restore SDK contents from the verified archive, not an untrusted
    # sentinel in a previously extracted directory. ditto preserves symlinks.
    if SDK.exists():
        shutil.rmtree(SDK)
    SDK.mkdir(parents=True)
    subprocess.run(['/usr/bin/tar', '-xJf', str(archive), '-C', str(SDK)], check=True,
                   env={'PATH': '/usr/bin:/bin', 'TMPDIR': str(scratch)})
    print(f'Sparkle {VERSION}: pinned SHA-256 verified', flush=True)
    return SDK


if __name__ == '__main__':
    prepare()
