#!/usr/bin/env python3
"""Real disposable Sparkle install + rejection tests, never launches Hermex.

Uses Sparkle's own command-line user driver, built with CLT from checksum-pinned
upstream test-tool sources. No production Keychain access: ephemeral test-only
Ed25519 seed is generated in scratch, chmod 0600, and deleted after signing.
Only uniquely identified scratch app copies are updated. Not GUI acceptance.
Run after compiling release arm64 and x86_64 binaries.
"""
import functools
import atexit
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'macOS/scripts'))
from sparkle_sdk import SDK, prepare

SOURCES = ['main.m', 'SPUCommandLineDriver.h', 'SPUCommandLineDriver.m',
           'SPUCommandLineUserDriver.h', 'SPUCommandLineUserDriver.m']
SOURCE_SHA = 'f0df48d2e7878dbe505a3e4c8349e484c3fafc71df4e58f1e83daa6071021723'
SCRATCH = Path(os.environ.get('HERMEX_SCRATCH', str(Path.home() / '.hermes/cache/scratch')))


def main():
    prepare()
    SCRATCH.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='hermex-update-smoke-', dir=SCRATCH))
    env = {'HOME': str(work / 'home'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': str(SCRATCH)}
    Path(env['HOME']).mkdir()

    def run(*args, **kwargs):
        result = subprocess.run([str(x) for x in args], check=True, env=env,
                                text=True, capture_output=True, timeout=120, **kwargs)
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.stderr.strip():
            print(result.stderr.strip())
        return result

    source = work / 'cli'
    source.mkdir()
    data = [urllib.request.urlopen('https://raw.githubusercontent.com/sparkle-project/Sparkle/2.10.0/sparkle-cli/' + name,
                                   timeout=45).read() for name in SOURCES]
    if hashlib.sha256(b''.join(data)).hexdigest() != SOURCE_SHA:
        raise RuntimeError('Official Sparkle CLI source checksum mismatch')
    for name, content in zip(SOURCES, data):
        (source / name).write_bytes(content)
    cli = source / 'sparkle-cli'
    run('clang', '-fobjc-arc', '-DSPU_OBJC_DIRECT_MEMBERS=', '-DSPU_OBJC_DIRECT=',
        '-F', SDK, '-framework', 'Sparkle', '-framework', 'Foundation', '-framework', 'AppKit',
        '-Xlinker', '-rpath', '-Xlinker', SDK, *(source / n for n in SOURCES if n.endswith('.m')),
        '-o', cli)
    # No Hardened Runtime on this external test driver. Production app signing is
    # tested separately; this never pretends to prove hardened GUI relaunch.
    private = work / 'TEST-ONLY-seed'
    atexit.register(lambda: private.unlink(missing_ok=True))
    public = work / 'TEST-ONLY-public'
    helper = work / 'TestKey.swift'
    helper.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let args = CommandLine.arguments
try key.rawRepresentation.base64EncodedString().write(toFile: args[1], atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(toFile: args[2], atomically: true, encoding: .utf8)
''')
    # umask protects the ephemeral seed from its first write, not just afterwards.
    previous_mask = os.umask(0o077)
    try:
        run('swift', helper, private, public)
    finally:
        os.umask(previous_mask)
    key = public.read_text().strip()
    appid = 'com.kenmercuslai.hermex-mac.smoke.' + uuid.uuid4().hex
    archive_dir = work / 'feed'
    archive_dir.mkdir()
    new = work / 'new/Hermex.app'
    old = work / 'installed/Hermex.app'
    run('ditto', ROOT / 'dist/Hermex.app', new)
    run('lipo', '-create', ROOT / '.build/arm64-apple-macosx/release/Hermex',
        ROOT / '.build/intel/x86_64-apple-macosx/release/Hermex',
        '-output', new / 'Contents/MacOS/Hermex')
    framework = new / 'Contents/Frameworks/Sparkle.framework'
    framework.parent.mkdir(exist_ok=True)
    if framework.exists():
        shutil.rmtree(framework)
    run('ditto', SDK / 'Sparkle.framework', framework)
    info_path = new / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier=appid, CFBundleVersion='0.1.3', CFBundleShortVersionString='0.1.3',
                SUPublicEDKey=key, SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                SUSignedFeedFailureExpirationInterval=0, SUEnableAutomaticChecks=False)
    handler = functools.partial(SimpleHTTPRequestHandler, directory=str(archive_dir))
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    url = f'http://127.0.0.1:{server.server_port}/'
    info['SUFeedURL'] = url + 'appcast.xml'
    info_path.write_bytes(plistlib.dumps(info))
    # Disposable copy uses normal ad-hoc code signing, not hardened signing.
    # No production entitlement is added, and the app is never launched.
    run('codesign', '--force', '--sign', '-', '--timestamp=none', new)
    run('ditto', new, old)
    old_info_path = old / 'Contents/Info.plist'
    old_info = dict(info, CFBundleVersion='0.1.2', CFBundleShortVersionString='0.1.2')
    old_info_path.write_bytes(plistlib.dumps(old_info))
    run('codesign', '--force', '--sign', '-', '--timestamp=none', old)
    archive = archive_dir / 'Hermex-Mac-0.1.3-universal.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', new, archive)
    try:
        run(SDK / 'bin/generate_appcast', '--ed-key-file', private,
            '--download-url-prefix', url, '--maximum-deltas', '0', archive_dir)
    finally:
        private.unlink(missing_ok=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    feed = archive_dir / 'appcast.xml'
    original_feed = feed.read_bytes()
    original_archive = archive.read_bytes()
    results = {}

    def update():
        return subprocess.run([str(cli), '--check-immediately', '--verbose', '--user-agent-name',
                               'Hermex-disposable-install-smoke', str(old)], env=env,
                              text=True, capture_output=True, timeout=120)

    def installed_version():
        return plistlib.loads(old_info_path.read_bytes())['CFBundleVersion']

    try:
        # Exercise feed authentication before any installer has run, so a stale
        # failed-install resume cannot masquerade as a signature rejection.
        feed.write_bytes(original_feed.replace(b'<title>', b'<title>tampered ', 1))
        bad_feed = update()
        print('TAMPERED FEED:', bad_feed.returncode, bad_feed.stderr)
        assert bad_feed.returncode != 0 and installed_version() == '0.1.2'
        assert 'feed is improperly signed' in bad_feed.stderr
        results['tamperedFeedRejected'] = True
        feed.write_bytes(original_feed)
        # Archive mutation, without changing its size, must fail authentication.
        mutated = bytearray(original_archive)
        mutated[len(mutated) // 2] ^= 1
        archive.write_bytes(mutated)
        bad_archive = update()
        print('TAMPERED ARCHIVE:', bad_archive.returncode, bad_archive.stderr)
        assert bad_archive.returncode != 0 and installed_version() == '0.1.2'
        assert 'update is improperly signed' in bad_archive.stderr
        results['tamperedArchiveRejected'] = True
        archive.write_bytes(original_archive)
        good = update()
        if good.returncode != 0 and 'Failed to resume installing update' in good.stderr:
            # Sparkle first clears the prior rejected install's continuation.
            # This is an isolated negative-test artifact, not an app retry loop.
            print('Cleared previous rejected-install resume:', good.stderr)
            good = update()
        print('SIGNED UPDATE:', good.returncode, good.stdout, good.stderr)
        assert good.returncode == 0, 'Sparkle installer did not report success'
        assert installed_version() == '0.1.3', 'Installed app version was not replaced'
        before = hashlib.sha256((new / 'Contents/MacOS/Hermex').read_bytes()).hexdigest()
        after = hashlib.sha256((old / 'Contents/MacOS/Hermex').read_bytes()).hexdigest()
        assert before == after
        run('codesign', '--verify', '--deep', '--strict', '--all-architectures', old)
        run('lipo', '-archs', old / 'Contents/MacOS/Hermex')
        results.update(installedVersion='0.1.3', installedExecutableSHA256=after,
                       officialSparkleInstaller=True, guiRelaunchTested=False, productionSigningTested=False)
    finally:
        server.shutdown()
        server.server_close()
        # Uniquely scoped domains only. Never alter real Hermex preferences.
        subprocess.run(['/usr/bin/defaults', 'delete', appid], capture_output=True, env=env)
        private.unlink(missing_ok=True)
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('Disposable evidence:', work)
    print('SPARKLE INSTALL SMOKE PASSED')


if __name__ == '__main__':
    main()
