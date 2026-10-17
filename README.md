# Hermex for Mac

Native **SwiftUI + AppKit** macOS client for your self-hosted [hermes-webui](https://github.com/nesquena/hermes-webui) server. This community fork ports [uzairansaruzi/hermex](https://github.com/uzairansaruzi/hermex) to the desktop. It is not a webview wrapper and does not bundle an agent or model runtime.

**macOS 14+ · Universal (Apple silicon + Intel) · MIT**

[Releases / 下载](https://github.com/KenMercusLai/hermex-mac/releases) · [Development and testing](macOS/DEVELOPMENT.md) · [Original iPhone README](macOS/UPSTREAM_README.md)

## 安装 / Install

1. Download `Hermex-Mac-<version>-universal.dmg` from Releases; ZIP is also available.
2. Open the disk image and drag **Hermex.app** to **Applications**.
3. Open Hermex and enter your existing **hermes-webui** URL, e.g. `http://127.0.0.1:8787`, and its password. For remote access, prefer HTTPS or a trusted private network.
4. **Remember password in macOS Keychain** enables reconnect without re-entering it. The last URL is remembered; reconnect is deliberate, not an automatic background sign-in.

这是独立的 Mac 客户端，不需要 Xcode、Apple 开发者账号或在 Mac 上安装 Hermes 服务端。连接你已有的 `hermes-webui` 即可。下载包同时包含 Apple silicon 与 Intel 架构；实际执行测试在 Apple silicon 上完成。

### Community signing

The app is **ad-hoc signed with hardened runtime**, not Developer ID signed or Apple-notarized. macOS can warn on first opening a downloaded build. Verify the release's SHA-256 and source before approving it. If you trust it, use macOS's per-app **Privacy & Security → Open Anyway** flow. Do not disable Gatekeeper globally or bypass TLS verification. Managed Macs may disallow ad-hoc applications.

## Automatic app updates (0.1.3+)

Sparkle checks the public GitHub Releases feed daily and automatically downloads
and installs updates by default. Installation completes on quit; update restarts
wait for busy work or active streams. Use **Hermex → Check for Updates…** or
**Settings → App Updates**, available before connecting to a server. Both
automatic settings can be changed there. Feeds and archives require Ed25519
signatures, with archive verification before extraction. Older 0.1.2 installations
need one manual upgrade. See [update security and release signing](macOS/AUTOMATIC_UPDATES.md),
including the explicit ad-hoc library-validation decision required for packaging.

## Features

- Native resizable sidebar/conversation layout, light/dark appearance, Settings window, standard menus and selectable text.
- Server health check and upstream password/cookie login; private in-memory cookie jars per connection; passwords in the default macOS Keychain; sign-out/password removal.
- Pre-connect **Connection Headers** in the welcome screen and Settings: Cloudflare Access Service Token pair, generic Add/Remove Header rows and secure values; separate per-server Keychain storage.
- Saved server addresses and connection switching. Unsent text and attachment references are isolated per server/session **in app memory**.
- Session list, server-side search (Return to search), create, rename, pin/unpin, archive/restore and confirmed permanent deletion. Right-click a session for actions. Enable **Archived** to find and restore archived sessions.
- Collapsible **nested subagents** under their owning conversation, collapsed by default. Use the left chevron to reveal workers without selecting the parent; each child opens normally, retaining server-reported read-only restrictions. Parents show descendant counts and reported active workers. Expansion is memory-only and resets on disconnect/server change. Search results stay flat with parent context, so a collapsed matching child is never hidden. Missing owners remain visible with a truthful badge; grouping requires producer subagent metadata, never just a title or parent link.
- Conversation history with earlier-message loading, inline Markdown/headings/fenced code, message/code copying, reasoning and recorded/live tool details.
- Real SSE streaming, **Stop**, visible disconnect errors and **Reattach** using the existing stream ID/journal cursor. Reattach never resends the prompt. **Refresh Run** discovers an active run after reopening a conversation.
- Tool approval **Allow Once / Deny**, clarification choices and free-text answers. Pending requests are checked while a run is active; no automatic or permanent approval grants.
- File/image attachments through the native paperclip file importer, up to 20 MB each, using the upstream multipart/attachment-marker contract.
- Model/provider catalog menus plus editable custom IDs, session workspace selection/application and profile selection for new sessions. Open the conversation's sliders control.
- Read-only server panels: session-scoped workspace file browser/text/image preview; skills/instruction content; memory/user/soul/project context; scheduled tasks/recent output; usage metrics/charts/model breakdown.

### Keyboard

| Action | Shortcut |
|---|---|
| New session | ⌘N |
| Refresh sessions | ⌘R |
| Settings | ⌘, |
| Send from message editor | Return or ⌘Return |
| Newline | Shift-Return |

Return/⌘Return never sends while IME composition is active. Another turn cannot be sent while a run is active; stop it first.

## Cloudflare Access / authenticated reverse proxies

Cloudflare Access and the WebUI password are **two independent authentication layers**. An Access-protected `/health` must first accept your authorized Service Token; Hermex then performs the existing WebUI password/cookie login if enabled. The WebUI password does not satisfy Cloudflare Access.

1. Obtain a Service Token authorized for your Access application from its administrator. The application's Access policy must use the **Service Auth** action and include that token. An email/identity-provider login policy alone is not sufficient for a native service-token client. See [Cloudflare's official Service Token documentation](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/). This app does not create tokens or change Access policies.
2. Enter the exact HTTPS server URL, then fill both **CF-Access-Client-Id** and **CF-Access-Client-Secret** in **Connection Headers**. The two empty rows are supplied by default; **Add Cloudflare Pair** restores missing rows without overwriting values. No specific token format is assumed. Values are secure fields, with surrounding whitespace trimmed according to upstream policy.
3. Enter the separate **Webui password** if your server requires one and choose **Connect**. Generic authenticated proxies can use **Add Header**, for example an administrator-provided `X-Api-Key` or `Authorization` header.

Blank values are ignored, including the default empty Cloudflare pair. A partial pair is rejected with guidance. Header names must be valid HTTP tokens; control characters in names/values and transport-managed fields such as `Host`, `Cookie` and `Content-Length` are rejected. Duplicate names are case-insensitive and the last nonblank row wins. Built-in `Accept` / `Content-Type` values take precedence where those requests require them.

Nonblank headers are saved in **macOS Keychain for that exact validated server URL** when connecting, independently of **Remember password**. Selecting a saved server or re-entering its URL restores its own headers; editing/pasting another address never copies credentials to it. In-progress header drafts stay source-owned in memory, and each connection captures an immutable snapshot for health, login, API, uploads, media, SSE and replay. Disconnect before editing active connection headers. **Clear & Forget Saved Headers** removes that server's saved/editor headers without deleting its WebUI password. **Sign Out & Forget Credentials** removes both; if server logout cannot be confirmed, local credentials are still forgotten and a warning is shown. Disconnect alone preserves saved credentials.

Same-origin redirects retain headers. Cross-origin GET/media/SSE redirects strip configured custom headers, and cross-origin credential-bearing POST redirects are refused. No headers are attached to directly requested third-party media. Use HTTPS: HTTP exposes headers as well as passwords/data. Never post token values in bug reports, screenshots or logs. Browser email/SSO/MFA login is not implemented; use an administrator-authorized Service Token rather than disabling Access.

## Compatibility and limitations

This is a useful **first native Mac release, not full iOS parity**.

- Targets **legacy hermes-webui**, not direct Hermes dashboard/Gateway/Bots. Passwordless servers and authorized proxy custom headers / Cloudflare Service Tokens work; passkeys, browser OIDC/SSO and browser multi-factor sign-in are not implemented.
- Compiles the original `APIClient`, endpoints, tolerant models, multipart and catalog policies directly. Retains the original SSE event decoder; Apple URLSession replaces the third-party iOS EventSource transport. Original iOS source/history remain intact.
- Contract reference: upstream Hermex plus read-only inspection of webui `641878bd88f91950ce9774af1ccf1372ba08ad19`. Automated integration uses an **explicit local protocol fixture**, not production transcripts or a live model. Authenticated production workflows were **not** exercised by the implementation task.
- Files, memory, skills, tasks and insights are **read-only**. Task/memory/skill editing, Kanban, projects, Git mutations, session import/branch/compress/export controls, steering, voice/TTS, media playback, rich math/tables, app intents and server administration are not exposed in this Mac UI.
- No iOS share extension, APNs relay, Live Activities, mobile app lock or App Store integration.
- No disk transcript/offline cache. Loaded history remains visible on network interruption. Drafts do not survive quitting. Disconnecting/switching detaches the client, **not** the server's run. Reopen the session and choose **Refresh Run** to reattach. Reconnection is user-driven rather than an unbounded retry loop.
- Unsupported routes show errors. Missing metrics show “Not reported”, not fabricated values. File permissions and all execution remain the server's security responsibility. Remote HTML is shown as text source, never executed.
- Intel is cross-compiled, not runtime-tested. Execution tests were on Apple silicon, macOS 27, Swift 6.4 CLT; there is no claim of a macOS 14 hardware test.

## Build locally — no Xcode or Apple account

Install Apple's Command Line Tools (`xcode-select --install`). Use Swift 6 with the macOS SDK and Swift Testing. The official Sparkle framework is downloaded from a versioned URL and SHA-256 verified; no Xcode package resolution is required.

```sh
# Prepare the checksum-pinned Sparkle SDK, then build the native release binary
python3 macOS/scripts/sparkle_sdk.py
swift build -c release --build-system native

# Tests, including a real temporary-Keychain round trip
bash macOS/scripts/test.sh

# Actual app state + auth/session/upload + interrupted SSE/replay, fixture only
python3 macOS/Tests/run_smoke.py

# Universal app: choose signing policy first; see macOS/AUTOMATIC_UPDATES.md
python3 macOS/scripts/build.py --version 0.1.3 --arch universal \
  --signing-identity 'Developer ID Application: YOUR IDENTITY'
```

The packaging command fails closed for ad-hoc signing unless the maintainer explicitly accepts `--allow-adhoc-library-validation`; this relaxes that single Hardened Runtime protection for loading Sparkle. It never disables TLS, archive/feed signature validation or Gatekeeper. Artifacts are under `dist/`, ignored by Git. `--arch arm64` builds only Apple silicon. Version is supplied explicitly. Bundle display name: **Hermex for Mac**; identifier: `com.kenmercuslai.hermex-mac`.

The explicit `--build-system native` avoids Xcode-only tools in SwiftPM's latest default backend. Swift 6.4 warns this option is deprecated, but it currently builds correctly with standalone CLT. `test.sh` supplies CLT's Swift Testing framework search path. [Development notes](macOS/DEVELOPMENT.md) cover architecture, fixture UI tests, boundaries and release verification.

## Origin and license

Upstream Hermex is by **Uzair Ansar and contributors**, under the [MIT license](LICENSE). This is an independent macOS fork, not an official upstream Mac release. Original source/assets/notices/history are preserved. Portable code is compiled in place; new UI, Keychain, stream transport, tests and packaging are under `macOS/`. No upstream iOS Swift files were modified.
