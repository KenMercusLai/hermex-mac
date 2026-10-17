#!/usr/bin/env python3
"""Local, account-free native build and ad-hoc signed distribution packaging."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / 'dist'


def run(*args, **kwargs):
    print('+', ' '.join(str(x) for x in args), flush=True)
    return subprocess.run([str(x) for x in args], cwd=ROOT, env=ENV, check=True, **kwargs)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', default='0.1.0')
    parser.add_argument('--arch', choices=['universal', 'arm64'], default='universal')
    parser.add_argument('--configuration', choices=['release', 'debug'], default='release')
    parser.add_argument('--skip-dmg', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('Version must be a numeric major.minor.patch')
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
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
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
    # No sandbox/access group entitlement is needed: default-scope macOS Keychain
    # works with ad-hoc signatures. Hardened runtime is enabled, not disabled.
    run('codesign', '--force', '--sign', '-', '--options', 'runtime', '--timestamp=none', app)
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
