# Native Mac updates

Hermex uses [Sparkle 2.10.0](https://sparkle-project.org/), not a shell-based
self-replacement mechanism. The updater is created once at app startup,
independently of server connection or authentication. **Hermex → Check for
Updates…** and **Settings → App Updates** work before connecting to a server.

## Behavior and security

- Automatic daily checking and automatic download/install are enabled by default.
  Settings uses Sparkle's own persistent preferences; starting the app does not
  overwrite a user's opt-out. Disabling checks also disables the installation
  toggle in the UI, without erasing that separate preference.
- Sparkle downloads and stages automatic updates; installation completes on quit.
  A requested update restart is postponed while `MacStore` is busy, streaming,
  or still owns a stream ID (including a disconnected active stream). It resumes
  after those states become idle. If new work starts after postponement resumes,
  AppKit keeps the termination request pending (`terminateLater`) and completes
  it exactly once when idle; a canceled update resolves it without quitting.
  Updating is not permission to stop a server run.
- The feed is the public repository's latest **stable** release asset:
  `https://github.com/KenMercusLai/hermex-mac/releases/latest/download/appcast.xml`.
  Prereleases do not become GitHub's stable latest release. An unavailable feed
  is an update-check error, not permission to install unsigned content.
- The public Ed25519 key and HTTPS feed are in `macOS/Updates.json`. Packaging
  refuses absent/malformed values. The key is public, not a credential.
- Both the appcast and archive require Ed25519 authentication. Archive verification
  is required **before extraction**; signed-feed validation never expires into an
  unsigned fallback (`SUSignedFeedFailureExpirationInterval = 0`). HTTPS uses
  normal platform trust. No server credentials or custom headers enter this path.
- The pinned SDK is the official `Sparkle-2.10.0.tar.xz`, SHA-256
  `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`.
  `sparkle_sdk.py` rehashes the cached archive and restores its contents on every
  invocation. It embeds the framework and its license, not the SDK tools/test app.
- Versions through 0.1.2 contain no updater. Their users must install the first
  updater-enabled version manually; a feed cannot retrofit Sparkle into them.

## Important signing decision

**Ad-hoc Hardened Runtime cannot load the dynamic Sparkle framework with library
validation enabled.** A real disposable probe failed with dyld's diagnostic:
`mapping process and mapped file (non-platform) have different Team IDs`.
Signing the executable and framework ad-hoc does not supply a Team ID.

Packaging therefore **fails closed by default** for an ad-hoc updater build.
Choose one explicitly:

1. Prefer a matching **Developer ID Application** identity for the app and nested
   framework/helpers. This retains library validation. Supply its exact identity
   with `--signing-identity`. Developer ID and notarization are separate from
   Sparkle's Ed25519 archive/feed signing; this script does not notarize.
2. For an intentionally ad-hoc community build, approve
   `--allow-adhoc-library-validation`. This adds precisely
   `com.apple.security.cs.disable-library-validation = true` to the host app.
   Hardened Runtime remains enabled, but its library-validation protection is
   explicitly relaxed. It does not disable Gatekeeper, TLS or Sparkle signatures.
   Do not claim this is equivalent to retaining library validation.

The implementation does not automatically select option 2. The maintainer/user
must accept that trade-off before distributing or launching such a package.

```sh
# CLT-only tests; downloads and verifies the pinned SDK first
bash macOS/scripts/test.sh
python3 -m unittest discover -s macOS/Tests -p test_updates.py
python3 macOS/Tests/run_smoke.py

# Signed identity path (replace with an identity you actually control)
python3 macOS/scripts/build.py --version 0.1.3 --arch universal \
  --signing-identity 'Developer ID Application: YOUR IDENTITY'

# Alternative ONLY after explicit acceptance of the trade-off above
python3 macOS/scripts/build.py --version 0.1.3 --arch universal \
  --allow-adhoc-library-validation
```

Direct `swift build` requires running `python3 macOS/scripts/sparkle_sdk.py`
first. `Package.swift` links the verified framework with CLT-compatible `-F` flags
and embeds only `@executable_path/../Frameworks` as its app runtime search path.
`test.sh` adds the SDK's absolute runpath only for test/debug executables; release
packaging must be rebuilt without that test-only linker option.

## Sign and publish an appcast (release maintainer only)

The release key was generated using Sparkle's `generate_keys` in a dedicated
Keychain account. Keep it there. Do not print/export it, put it in a repository,
pass it on a command line, or add it to an archive. Losing the private key while
requiring signed feeds can require a manually installed recovery release.

After final review, build the final version and do not modify its app or ZIP
again. Stage **only the ZIP update archive** in a clean directory (not the DMG,
which would duplicate the same version in the feed). For example:

```sh
mkdir -p dist/update-feed
cp dist/Hermex-Mac-0.1.3-universal.zip dist/update-feed/
.build/sparkle/bin/generate_appcast --account hermex-mac-release \
  --download-url-prefix https://github.com/KenMercusLai/hermex-mac/releases/download/v0.1.3/ \
  --maximum-deltas 0 dist/update-feed
.build/sparkle/bin/sign_update --account hermex-mac-release --verify \
  dist/update-feed/appcast.xml
```

`generate_appcast` signs the archive enclosure and signs the feed because the
archived app requires it. If the Keychain account is absent, stop; never accept
unsigned output or generate a replacement production key silently. To inspect
an individual ZIP signature, use `sign_update --account hermex-mac-release ZIP`;
its output is a public signature and length, never the private key.

Before publication verify the feed's version, minimum OS 14, enclosure HTTPS URL,
archive length and signature, and that the archived public key matches
`macOS/Updates.json`. Do not edit a signed feed without running `generate_appcast`
again. Publish the ZIP, DMG, checksums and **`appcast.xml`** together in the stable
v0.1.3 Release. Read back the public latest URL, download the assets independently,
and compare hashes. Building and feed generation do not publish anything.

## Real installation evidence and limits

`python3 macOS/Tests/update_install_smoke.py` builds the official Sparkle CLI user
driver from checksum-pinned upstream 2.10.0 sources using CLT. It creates isolated,
random-bundle-ID copies of the real Universal Hermex release executable in
scratch and a loopback-only signed feed. The older 0.1.2 bundle version is a
synthetic baseline containing the new updater-enabled executable, not the
published updater-free v0.1.2 app. A newly generated **test-only** signing
seed exists only in scratch with mode 0600 and is deleted immediately after
signing. Production Keychain keys and installed apps are never accessed.

The smoke checks that a tampered feed is rejected with Sparkle error 1000, a
same-length tampered archive is rejected with error 4005, both leave version
0.1.2 in place, then the official installer replaces it with version 0.1.3.
It reads back the version and executable SHA-256, verifies the installed code
signature and checks both architecture slices. A failed-archive install can leave
one stale-resume error (1004); the isolated test clears that once before retrying
the valid archive. It never treats that unrelated error as signature proof.

This proves actual download/authentication/extraction/application replacement,
**not** the production signing identity, Hardened Runtime loading, standard GUI
interaction, or quit/relaunch of a running app. Disposable smoke apps use normal
ad-hoc signing and are not launched. Unit tests additionally cover Sparkle-backed
preferences and the actual Objective-C delegate selector for busy-run deferral.
Intel execution, macOS 14 hardware and production server use are not claimed.
