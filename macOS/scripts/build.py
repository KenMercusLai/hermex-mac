#!/usr/bin/env python3
"""Local, account-free native build and ad-hoc signed distribution packaging."""
import argparse
import base64
import json
from urllib.parse import urlparse


def signing_entitlements(identity, allow_adhoc):
    if identity != '-':
        return {}
    if not allow_adhoc:
        raise ValueError('Ad-hoc Hardened Runtime cannot load Sparkle: dyld rejects different Team IDs. '
                         'Use --signing-identity with a matching Developer ID, or explicitly approve '
                         '--allow-adhoc-library-validation to disable library validation only.')
    return {'com.apple.security.cs.disable-library-validation': True}


def update_info(config):
    feed, key = config.get('feedURL', ''), config.get('publicEDKey', '')
    url = urlparse(feed)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError('Updates require an HTTPS feed URL without credentials or fragment')
    try:
        decoded = base64.b64decode(key, validate=True)
    except Exception as error:
        raise ValueError('Updates require a base64 Ed25519 public key') from error
    if len(decoded) != 32 or not any(decoded):
        raise ValueError('Updates require a 32-byte Ed25519 public key')
    return {'SUFeedURL': feed, 'SUPublicEDKey': key,
            'SUEnableAutomaticChecks': True, 'SUAutomaticallyUpdate': True,
            'SUScheduledCheckInterval': 86400, 'SUVerifyUpdateBeforeExtraction': True,
            'SURequireSignedFeed': True, 'SUSignedFeedFailureExpirationInterval': 0,
            'SUSendProfileInfo': False}

import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

from sparkle_sdk import prepare

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / 'dist'


def run(*args, **kwargs):
    print('+', ' '.join(str(x) for x in args), flush=True)
    return subprocess.run([str(x) for x in args], cwd=ROOT, env=ENV, check=True, **kwargs)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', default='0.1.3')
    parser.add_argument('--signing-identity', default='-', help='Use a Developer ID identity to retain library validation')
    parser.add_argument('--allow-adhoc-library-validation', action='store_true',
                        help='Explicit opt-in: disables library validation ONLY for ad-hoc builds')
    parser.add_argument('--updates-config', type=Path, default=ROOT / 'macOS/Updates.json')
    parser.add_argument('--arch', choices=['universal', 'arm64'], default='universal')
    parser.add_argument('--configuration', choices=['release', 'debug'], default='release')
    parser.add_argument('--skip-dmg', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('Version must be a numeric major.minor.patch')
    try:
        update_settings = update_info(json.loads(args.updates_config.read_text()))
        entitlements = signing_entitlements(args.signing_identity, args.allow_adhoc_library_validation)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    sdk = prepare()
    scratch = Path(os.environ.get('HERMEX_SCRATCH', str(Path.home() / '.hermes/cache/scratch')))
    scratch.mkdir(parents=True, exist_ok=True)
    # No host environment credentials are inherited by build subprocesses.
    ENV = {k: os.environ[k] for k in ('HOME', 'PATH') if k in os.environ}
    ENV['TMPDIR'] = str(scratch)
    DIST.mkdir(exist_ok=True)
    run('swift', 'build', '-c', args.configuration, '--build-system', 'native', '--triple', 'arm64-apple-macosx14.0')
    binary = ROOT / '.build/arm64-apple-macosx' / args.configuration / 'Hermex'
    intel = None
    if args.arch == 'universal':
        run('swift', 'build', '-c', args.configuration, '--build-system', 'native', '--triple', 'x86_64-apple-macosx14.0', '--scratch-path', '.build/intel')
        intel = ROOT / '.build/intel/x86_64-apple-macosx' / args.configuration / 'Hermex'
    app = DIST / 'Hermex.app'
    if app.exists():
        shutil.rmtree(app)
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    executable = macos / 'Hermex'
    if intel:
        run('lipo', '-create', binary, intel, '-output', executable)
    else:
        shutil.copy2(binary, executable)
    executable.chmod(0o755)
    info = {
        'CFBundleExecutable': 'Hermex',
        'CFBundleIdentifier': 'com.kenmercuslai.hermex-mac',
        'CFBundleName': 'Hermex',
        'CFBundleDisplayName': 'Hermex for Mac',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': args.version,
        'CFBundleVersion': args.version,
        'CFBundleIconFile': 'AppIcon',
        'LSMinimumSystemVersion': '14.0',
        'LSApplicationCategoryType': 'public.app-category.productivity',
        'NSHighResolutionCapable': True,
        'NSSupportsAutomaticTermination': False,
        'NSHumanReadableCopyright': 'Hermex upstream © Uzair Ansar. macOS port © KenMercusLai. MIT License.',
        # Self-hosted users may deliberately configure HTTP. TLS certificate
        # verification is NEVER bypassed. The login UI warns for remote HTTP.
        'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True, 'NSAllowsLocalNetworking': True},
    }
    info.update(update_settings)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    frameworks = app / 'Contents/Frameworks'
    frameworks.mkdir()
    run('ditto', sdk / 'Sparkle.framework', frameworks / 'Sparkle.framework')
    shutil.copy2(sdk / 'LICENSE', resources / 'Sparkle-LICENSE.txt')
    shutil.copy2(ROOT / 'LICENSE', resources / 'LICENSE.txt')
    shutil.copy2(ROOT / 'macOS/Resources/NOTICE.txt', resources / 'NOTICE.txt')
    (resources / 'VERSION.txt').write_text(args.version + '\n' + args.arch + '\n')
    iconset = DIST / 'AppIcon.iconset'
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()
    original = ROOT / 'HermesMobile/Resources/Assets.xcassets/AppIconLight.appiconset/hermes_mobile_light_icon.png'
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            suffix = '@2x' if scale == 2 else ''
            run('sips', '-z', str(size * scale), str(size * scale), original, '--out', iconset / f'icon_{size}x{size}{suffix}.png', stdout=subprocess.DEVNULL)
    run('iconutil', '-c', 'icns', iconset, '-o', resources / 'AppIcon.icns')
    run('plutil', '-lint', app / 'Contents/Info.plist')
    # Sign nested code inside-out; never use codesign --deep to sign.
    framework = frameworks / 'Sparkle.framework'
    for nested in [*framework.rglob('*.xpc'), *framework.rglob('*.app'),
                   framework / 'Versions/B/Autoupdate', framework]:
        run('codesign', '--force', '--sign', args.signing_identity, '--options', 'runtime',
            '--preserve-metadata=entitlements', '--timestamp=none', nested)
    signing_flags = []
    if entitlements:
        print('WARNING: explicit ad-hoc opt-in disables library validation; Hardened Runtime remains enabled.')
        entitlement_path = scratch / 'hermex-adhoc-entitlements.plist'
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        signing_flags = ['--entitlements', entitlement_path]
    run('codesign', '--force', '--sign', args.signing_identity, '--options', 'runtime', '--timestamp=none', *signing_flags, app)
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    run('lipo', '-archs', executable)
    name = f'Hermex-Mac-{args.version}-{args.arch}'
    archive = DIST / (name + '.zip')
    if archive.exists():
        archive.unlink()
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive)
    artifacts = [archive]
    if not args.skip_dmg:
        stage = DIST / 'dmg-stage'
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir()
        run('ditto', app, stage / 'Hermex.app')
        (stage / 'Applications').symlink_to('/Applications')
        shutil.copy2(ROOT / 'LICENSE', stage / 'LICENSE.txt')
        (stage / 'Read Me.txt').write_text('Drag Hermex.app to Applications. Requires macOS 14+.\nCommunity ad-hoc signed build; not Apple-notarized.\nSee the repository README for security and compatibility details.\nNo server runtime is bundled.\n')
        dmg = DIST / (name + '.dmg')
        if dmg.exists():
            dmg.unlink()
        run('hdiutil', 'create', '-volname', 'Hermex for Mac', '-srcfolder', stage, '-ov', '-format', 'UDZO', dmg)
        run('hdiutil', 'verify', dmg)
        artifacts.append(dmg)
        shutil.rmtree(stage)
    checksums = DIST / (name + '-SHA256SUMS.txt')
    checksums.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in artifacts))
    print('\nBuilt and verified:')
    for path in [app, *artifacts, checksums]:
        print(path)
