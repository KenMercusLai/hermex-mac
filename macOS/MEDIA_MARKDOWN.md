# MEDIA downloads and Markdown (0.1.4)

## User-visible behavior

- History and live reply text share `MessageContent`. **Settings → Messages → Render Markdown** defaults on and persists through `AppStorage` / UserDefaults (`renderMarkdown`). Switching it off immediately selects raw text for existing and streaming replies; MEDIA controls remain available in either mode.
- Markdown uses native SwiftUI block views for ATX headings, unordered/ordered lists with indentation, blockquotes, horizontal rules, fenced code with Copy, and pipe tables. Foundation parses bold, italic, inline code and links. There is no HTML renderer, JavaScript or automatic remote-image loading. Only HTTP(S)/mailto links may open externally, with credential-bearing URLs rejected.
- Each MEDIA control opens NSSavePanel. Only confirming **Download** starts a request. Cancel performs no app download/network/file operation. The chooser cannot create directories; choose an existing destination folder. Normal overwrite confirmation belongs to NSSavePanel. Downloads never open automatically.
- Local-looking paths are **server paths**, not files on the client Mac. `MEDIA:file://…`, arbitrary schemes, protocol-relative URLs and HTTP(S) URLs containing credentials are rejected and remain text.

Supported forms (synthetic examples):

```text
MEDIA:/srv/reports/性能 100% 'quoted'.zip
MEDIA:"/srv/reports/path with spaces.md"
MEDIA:</srv/reports/report.md>
[report](MEDIA:/srv/reports/report(1).md)
<MEDIA:https://files.example.invalid/report.zip>
```

Bare MEDIA consumes the rest of its line because server filenames can contain spaces; use quotes, angle wrappers or a Markdown link destination when appending prose. Tokens inside backtick inline code and backtick/tilde fenced code (including unfinished streaming fences) stay literal. Wrapped tokens are replaced as a whole, not rendered with dangling Markdown delimiters. A safe last-component filename is suggested; remote response filenames do not override the user's selection.

## Security and ownership

- `MediaDownloadPlan` reuses upstream `Endpoint.media(sessionID:path)` (`GET /api/media`), preserving exact path and session query values. It escapes literal `+` in the encoded endpoint query because the Python server uses form-style `parse_qs`; percent sequences in an opaque server filename are not decoded.
- `MacStore.saveMedia` captures the client, immutable connection-header snapshot, connection generation, exact session ID and selection generation **before** awaiting the panel. Ownership is checked before the request and after the download, including A→B→A navigation. Navigation/disconnect cancels active transfers; late completions cannot save a file or overwrite the new selection's error.
- Same-origin media uses the existing authenticated per-connection URLSession and captured headers (including authorized Cloudflare headers). External HTTP(S) media uses that client's separate ephemeral session with no cookie or credential storage and no connection headers.
- The Mac-only download delegate fails closed on **all cross-origin redirects**, including the same host on another port. Allowed same-origin redirects retain the existing immutable `CrossOriginHeaderStripper`. This is intentionally stricter than upstream preview downloads; a CDN redirect must be replaced by an explicit direct public MEDIA URL.
- URLSession download tasks spool to temporary files rather than loading archives into Data. Only a successful 2xx result, current ownership and a confirmed local destination allow saving. A destination-volume staging copy plus atomic POSIX rename preserves pre-existing files on HTTP/network/cancellation/copy/rename errors. Temporary and staging files are cleaned up. Displayed errors never include server response bodies, URLs, remote paths or secret values.
- Sparkle's restart and termination gates include pending save panels and transfers, and observe the active count returning to zero. Upstream iOS/networking files and release feed/signing configuration are unchanged.

## Automated evidence and limitations

`bash macOS/scripts/test.sh` covers deterministic parser/settings/save-first/cancel/atomic-write behavior, immutable headers and pre-/post-await ownership races (A→B→A, disconnect, and switching servers). Injectable panel/fetch boundaries isolate those tests; they are not native chooser/visual acceptance.

`MediaWireTests` starts explicit disposable Python loopback fixtures, never the app GUI or a live Hermes server. One test runs the actual MacStore connect/password-cookie → session → cancel (zero `/api/media` requests, no output files) → confirmed default downloader → atomic save pipeline. Another checks exact Unicode/space/quote/percent/plus query round trips, authenticated cookies + CF headers, 401/403/404, truncated connections, same-origin redirects, refused cross-origin redirects, and a direct cookie-less public-origin download. Saved archives are SHA-256 checked using bounded file reads against the fixture's independently computed digest. The fixture ZIP is 16,777,336 bytes with SHA-256 `0557f748b5b7e91d8e3ff476e28231900f74917d5419b2311b011177fde93105`.

The existing legacy/header-required protocol and two-origin redirect smoke suites remain applicable. Packaging tests also ensure the disposable Sparkle install smoke uses the built app's actual version rather than relabeling it as an older hard-coded target.

Manual acceptance remains with the parent/release maintainer: NSSavePanel permissions, overwrite/cancel interactions, light/dark/narrow-window Markdown layout, VoiceOver, immediate Settings changes during streaming, and GUI persistence after relaunch. No production server, user conversation, release signing key, published feed, installed user app or GUI session is touched by the implementation subagent. Native blocks are a practical subset, **not full CommonMark/GFM**: math, HTML, reference links, complex nested blocks and table alignment directives are not claimed. Tables render as native grids; list continuation layout and complex nesting remain limited. Intel is cross-compiled, not runtime-tested; ad-hoc signing is not Developer ID signing or notarization.

Build the candidate explicitly:

```sh
python3 macOS/scripts/build.py --version 0.1.4 --arch universal --allow-adhoc-library-validation
python3 -m unittest discover -s macOS/Tests -p 'test_*.py' -v
python3 macOS/Tests/run_smoke.py
python3 macOS/Tests/update_install_smoke.py
```

The last command signs only disposable scratch copies with a generated **test-only** key, verifies rejection of tampered feed/archive data, installs via the official Sparkle CLI and reads back version/hash/signature. It does not launch Hermex or claim hardened GUI relaunch or production signing verification. Parent review, final rebuild/signing, feed generation and publication are separate.
