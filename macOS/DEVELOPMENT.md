# Native macOS development

The Mac target is independent of the iOS Xcode project. Do not apply iOS simulator/App Store signing instructions to it. There are no network dependencies in `Package.swift`; it compiles selected original portable Swift files in place and keeps the entire iOS project untouched.

## Architecture

- **`MacStore`**: main-actor app state, server/session-scoped drafts, session actions, pending user requests, upload/send/reconnect/stop coordination. Send and reattach are separate paths; reattach cannot call chat start.
- **`APIClient` + `Endpoint`**: original upstream actor, HTTP error handling, cross-origin redirect guard, cookie-auth requests and wire request bodies. Private ephemeral URLSessions are supplied by the Mac store rather than the upstream shared cookie jar.
- **`MacKeychain` / `ConnectionRegistry`**: Security.framework generic-password items in the default macOS scope, service `com.kenmercuslai.hermex-mac`. Password accounts are keyed by the validated server URL. Saved server addresses/last connection use a separate `connections` item. No plaintext credential/connection file, bundled password, shared iOS access group or Apple team is required. Unlock/cancellation/storage failures are visible.
- **`ConnectionHeaders` / `ConnectionHeaderVault`**: original `CustomHeader` model and application policy, with strict Mac editor validation, case-insensitive last-nonblank duplicate policy, transport-managed field rejection and complete Cloudflare pair validation. Headers have a separate `connection-headers|<validated-url>` Keychain item, independent of remember-password. Source-owned editor drafts survive A→B→A in memory; URL changes restore only the destination's scope. No process-wide secret store is used.
- **`ConnectionFailure`**: header-bearing pre-auth health probe, Cloudflare HTML/Access-login diagnostics distinct from JSON origin-permission refusals, response-body suppression and header-value redaction for displayed errors. A Cloudflare denial explains Service Token + Service Auth policy versus the separate WebUI password; no Access bypass or production policy change is performed.
- **`UpstreamSSE`**: unchanged event types/decoder/payload models extracted from upstream `SSEClient.swift`. LDSwiftEventSource is not linked.
- **`MacStream`**: Foundation AsyncBytes transport, SSE blank-line framing, normal TLS validation, private auth session, cursor extraction, content-type/status checks and cancellation. It intentionally parses bytes rather than using `AsyncBytes.lines`, which omitted the empty frame boundaries during the real fixture test on this SDK.
- **`RunProjection`**: replay-cursor de-duplication, text/reasoning/tool/request projection. `done` is not treated as socket end; `stream_end`, cancel and errors are terminal.
- **`MacComposer`**: native NSTextView and a tested marked-text send gate. No send through an active IME composition.
- **`NativeMarkdown`**: selectable native attributed inline Markdown, simple headings and fenced-code blocks with copying. No webview or remote HTML execution. Rich tables/math/media are not claimed.
- **`SessionHierarchy` / `SessionDisclosureState`**: macOS-only, dependency-free projection of producer-marked delegated subagents. Iterative forest construction/traversal removes cyclic parent edges, retains orphan rows, de-duplicates IDs first-row-wins, preserves exact raw IDs and existing root/sibling order, and aggregates reported descendant activity. Disclosure stores IDs only in memory, scoped to the connected server URL; search payloads never prune it.
- **`SidebarSessionRow`**: separate sibling disclosure/selection buttons, nested indentation, descendant/activity/selected-branch labels and exact-row context actions. Indentation caps at eight levels for narrow sidebars; deeper rows retain the full hierarchy and show their nesting level.
- **`MacApplication`, `ConversationView`, `ServerPanels`**: native views. Workspace/skills/memory/tasks/insights are read-only; destructive session deletion always uses a confirmation UI.

Small webui memory and bounded-download excerpts are retained in `UpstreamAdapters.swift` because their upstream files also depend on the unlinked direct-Hermes stack. `Package.swift` explicitly allowlists sources and excludes all unrelated upstream subtrees/resources, avoiding Xcode-only asset and string-catalog compilers.

### Swift 6.4 CLT notes

The current standalone toolchain has SwiftUI/AppKit and Swift Testing, but no XCTest or full Xcode. `test.sh` uses `swift test --disable-xctest` with the framework path returned from `xcode-select -p`.

The SDK also exports a new `State` macro whose Xcode-only macro plugin is absent in standalone CLT. `MacState<Value>` aliases the established `SwiftUI.State<Value>` property-wrapper type, avoiding macro-name lookup without replacing its runtime behavior. Both release architectures compile with this route.

Use `--build-system native` to avoid the new SwiftPM default backend's Xcode-only resource tools. Swift 6.4 emits a deprecation warning for this option; that warning is a toolchain limitation, not a test failure. Build/test subprocesses use a minimal environment so tool failures cannot dump inherited host credentials.

## Automated checks

```sh
bash macOS/scripts/test.sh
python3 macOS/Tests/run_smoke.py
```

Verified results for this implementation:

- **45 Swift Testing tests passed**, retaining all 35 v0.1.1 tests (25 original baseline plus 10 header regressions). The retained checks cover required-header health-before-auth, per-server header Keychain restoration/removal/password independence, arbitrary URL edits/paste/selection draft isolation, strict validation/injection/reserved/duplicate policies, Cloudflare-specific non-echoing errors, immutable delayed-connect headers, full origin comparison, case-insensitive redirect stripping, fail-closed credential POST redirects and local forgetting after a refused remote logout. The ownership regressions use deterministic delayed URLProtocol responses, not timing sleeps. The original 17 ownership fixes and new header-required connection/remote-logout regressions were observed RED→GREEN; additional policy/security tests cover their boundaries.
- **Headless fixture smoke passed** using the actual app store and original networking: password login/auth verification, model/provider/profile/workspace catalog decoding, create/rename/pin/archive/restore/update/search, real multipart upload, a deliberately interrupted real HTTP SSE connection, replay without a second chat start, authoritative history readback, workspace text read, skills/content, memory, cron list/output, insights, delete and logout. The runner asserts exactly **one** chat start, one upload was exercised and the fixture session was removed. It also checks a new-session profile cannot leak into an existing conversation's send. Five explicit hierarchy seeds remain; the disposable smoke-created session is removed.
- The temporary Keychain tests use random service names and clean up their own items. They do not read production passwords.
- **Required-header fixture smoke passed**: an optional fake Service Token + generic-header gate protects every route, including `/health` and initial/replay SSE. The actual app connection-configuration/store path persists headers to an isolated random-service Keychain, recreates the store to restore them with remember-password disabled, then runs auth/catalog/session/upload/interrupted-SSE/replay/file-preview/panels/Stop/approval/clarification/logout. Initial and replay SSE both pass the gate, exactly one chat start occurs, and logout removes the headers. The fixture rejects missing headers before exposing its marker. This path was observed failing before header-aware smoke support, then passing.
- **Two-origin real HTTP redirect smoke passed**: separate loopback servers receive actual Foundation JSON, bounded-download, media and native SSE requests. Same-origin redirects preserve headers; second-origin redirects and directly requested external media receive none. A 307 password POST never reaches the second origin. Built-in JSON/SSE Accept and JSON/multipart Content-Type take precedence. Unit tests additionally cover scheme/host/effective-port comparison and mixed-case field removal. The existing upstream redirect delegate is unchanged; its live-edit race is avoided by immutable per-connection providers.

**Hierarchy checks:** 10 additional Swift tests cover actual snake-case wire decoding, metadata-only membership (excluding cron/fork/compression/continuation/title guesses), nested ordering/collapse/activity, hidden-child flat search with parent context, missing owners, cycle/self-parent safety, first-row duplicate policy, literal IDs, a 4,096-row deep chain, refresh/search/server/disconnect disclosure lifecycle, selected-child ownership changes and read-only selection/send guarding through the actual store. Malformed-cycle rendering was observed RED (missing rows/duplicate identity), then GREEN; activity fallback was observed RED (0 instead of 2), then GREEN. Initial feature/API tests also failed before implementation. Both real HTTP auth smoke modes now assert default collapse, nested disclosure, reported active descendant counts, visible orphan, read-only worker history, selected-branch context after explicit collapse, refresh stability and server-side search finding a hidden grandchild. The fixture seeds were first absent (RED), and the runner then rejected the old app without the hierarchy smoke marker (RED), before both modes passed.

The Python server is an **explicit protocol fixture**, not a bundled runtime, live Hermes agent or substitute for production verification. Payload shapes are derived from upstream contracts and the read-only webui source reference. No real model is called and no production session is modified. Authentication/streaming against a user's live authenticated server remain a separate acceptance check.

### Async ownership regressions

Connection attempts freeze the validated address and header snapshot for credentials and the saved-server registry; the connection form disables editing while busy. Both APIClient's provider/redirect guard and MacStream's initial/replay requests use that same captured snapshot. Later editor changes never change an active client. Disconnect invalidates the connection/selection generations and releases busy state. Older completions, errors and deferred busy cleanup cannot publish into a newer connection. Explicit sign-out forgets only the owned connection's password/header items, even if remote logout fails; failure to confirm remote logout is reported, not silently treated as server-side revocation.

Selection-sensitive operations capture client, connection address/generation, session ID and selection generation before awaiting. Settings, mutations, create/history/upload/send, reattach, Stop and approval/clarification paths reject stale results. Stream attachment receives that captured owner explicitly, rather than reading a newly selected session after a status response. Server catalog lists use connection ownership, while catalog defaults also require selection ownership. Logout forgets only the captured connection's credentials.

`OwnershipTests.swift` gates individual URLProtocol responses with continuations: wait for A's request, finish selecting/connecting B, then release A. It asserts B's history, draft, attachments, settings, run projection, Stop destination and actual send request remain B-owned. Keychain cases exercise remember/forget with random test services only. Logout/catalog and stale-send cleanup tests use an independently injected test transport so disconnect cancellation cannot mask a late-response bug. Delayed malformed JSON also proves obsolete failures cannot replace the current error.

| Review seam | Regression coverage | Observed result |
| --- | --- | --- |
| Address/authentication ownership | `connectionCredentialsStayBoundToValidatedAddress`, `disconnectedAuthenticationCannotPublishOrBlockNextConnection` | RED → GREEN |
| Session settings and mutation readback | `delayedSessionSettingsCannotRetargetAnotherDraft`, `delayedMutationReadbackCannotRetargetAnotherDraft` | RED → GREEN |
| Reattach status/history | `delayedReattachStatusCannotAttachToAnotherSelection`, `delayedReattachStreamStatusCannotClearAnotherRun`, `delayedReattachHistoryCannotInstallAnotherSession` | RED → GREEN |
| Related connection/selection paths | delayed Stop/history, new session, logout, each catalog stage, input responses/pending probes, failures and busy cleanup | RED → GREEN |

### Sidebar hierarchy policy

Only `raw_source`, `source_tag` or `session_source` explicitly identifying `subagent` qualifies a row for nesting. A parent ID or `relationship_type=child_session` alone is insufficient: the producer uses those for other relationships too. Explicit fork/compression/continuation metadata excludes nesting. Existing upstream decoders/models are unchanged. Producer proof is read-only `api/models.py` source overlay (6159–6166) and state-row projection (7752–7778), plus `api/agent_sessions.py` (376–390). Broader browser lineage/fork grouping is deliberately not copied. Only returned rows are used: no parent-fetch requests, lineage resolution or server mutations are added.

Branches start collapsed. Refresh preserves choices for surviving IDs; partial search results do not prune them. Newly discovered/moved ancestors of a selected child open its path so automatic ownership updates do not hide it. An explicit collapse keeps its content selected and labels the containing branch; unchanged refresh does not undo that choice. Search (Return) displays every returned match as a flat row labeled with its available parent title or exact missing-parent ID. Parent-not-in-list means unavailable in the current payload, not necessarily deleted. Missing-parent and cyclic-link subagents stay top-level with truthful context. Counts/activity describe returned descendants and server-reported stream/pending state, not a fabricated live worker tracker. Disconnect clears all disclosure IDs; neither titles nor transcripts are persisted by this feature.

## Independent native UI verification

Start the explicitly labeled fixture in a foreground terminal:

```sh
python3 macOS/Tests/protocol_fixture.py --port 18787
```

Open `dist/Hermex.app`, enter `http://127.0.0.1:18787`, and use the public **fixture-only** password displayed by that server (`hermex-fixture-only`). This credential is not a production secret. The release app has no auto-login, fixture content or auth bypass.

For isolated UI testing without persistent connection/Keychain changes, run the Debug executable after tests:

```sh
./.build/debug/Hermex --isolated
```

`--isolated`, `--protocol-smoke`, `--protocol-smoke-headers` and `--header-redirect-smoke` exist only inside `#if DEBUG`. Isolation disables persistence, not authentication. The headless smoke accepts only loopback servers and requires an explicit fixture marker from `/health` **before** any login/mutation. In required-header mode the public fixture-only headers are applied before that marker probe; real credentials are never read. It refuses a real server, including the normal local service. `run_smoke.py` runs both compatibility modes plus the two-origin redirect check. For manual header-mode fixture testing use `protocol_fixture.py --require-headers`; the obviously fake constants are in that fixture's source, not a real Cloudflare account.

Manual acceptance checklist (parent/release maintainer owns screenshots):

1. Invalid URL/wrong password/offline endpoint show errors; correct fixture login shows the native sidebar.
2. Open seeded conversation; select/copy Markdown/code; resize columns, switch light/dark, test Settings and ⌘N/⌘R.
3. New session; send with Return and ⌘Return; Shift-Return inserts a newline. With Chinese/Japanese IME, Return commits composition without sending.
4. Attach a small file and image through the paperclip importer. Send, observe reasoning/tools/response, try Stop; disconnect and reattach without duplicated user turns.
5. Right-click rename/pin/archive; show archived and restore. Delete dialog Cancel does nothing; confirm deletes only the chosen fixture session.
6. Open Workspace and text preview; Skills/content; Memory; Tasks/recent output; Insights. These routes must remain reads.
7. Switch servers/conversations with identical IDs; draft/auth/history must not cross scopes. Quit/relaunch: URL/password persistence works; drafts are intentionally memory-only.
8. Expand Connection Headers in welcome and disconnected Settings; add/remove generic rows and restore the Cloudflare pair. At 920×620 and in Settings, scroll to all fields/actions. Switch A→B→A by typing/paste/Saved servers; values must remain source-owned. Sign Out removes only the selected server's saved password/headers and clears displayed data. Dedicated Clear forgets headers independently of password. Disconnect alone must not stop server execution.

9. The seeded sidebar starts with the welcome owner and orphan only. Expand welcome to see research/validation workers, then research to see citations. Check descendant counts, the active nested worker indicator, distinct chevron-versus-selection clicks and read-only child history. Collapse while citations is selected: content stays selected and the owner labels the branch. Search `citations` with Return: its flat match must be visible with missing-parent context. Clear search, refresh, test right-click actions on the exact worker (not its parent), and disconnect/reconnect to verify default collapse. Test narrow widths, deep indentation and VoiceOver/button labels.

The implementation subagent did not launch a competing GUI session; independent packaged-app UI verification is delegated to the parent as requested.

## Packaging and release

```sh
python3 macOS/scripts/build.py --version 0.1.2 --arch universal
```

This builds arm64 and cross-compiles x86_64 with a macOS 14 deployment target, combines them with `lipo`, generates `.icns` from upstream's light icon, embeds version/license/notices, ad-hoc signs with hardened runtime, verifies the signature, makes a `ditto` ZIP, creates/verifies a compressed DMG with an Applications symlink, and writes SHA-256 sums. `--arch arm64` omits the Intel slice. `--skip-dmg` is available if disk-image creation is unavailable. No GitHub Actions or Apple account is required.

Expected paths:

- `dist/Hermex.app`
- `dist/Hermex-Mac-0.1.2-universal.zip`
- `dist/Hermex-Mac-0.1.2-universal.dmg`
- `dist/Hermex-Mac-0.1.2-universal-SHA256SUMS.txt`

Real verification performed: `codesign --verify --deep --strict` passed; `lipo -archs` reported `x86_64 arm64`; `vtool -show-build` reported minimum OS 14.0 for both slices; `unzip -t` reported no errors; `hdiutil verify` reported a valid checksum. Neither Apple notarization nor an Intel runtime test is claimed. Test execution is Apple silicon on macOS 27.

The parent handles commits, pushes, tag/version choice and Release publication. Building does not commit, push, publish, alter Git identity, restart services or touch production state. Rebuild after any code/version change; do not upload stale packages.

## Security and compatibility boundaries

Normal Foundation TLS trust validation is retained. The bundle permits explicitly configured HTTP endpoints for self-hosted/private-network compatibility; this is not a certificate-trust bypass. Remote HTTP login displays a warning. Prefer HTTPS. No untrusted remote HTML is loaded, no shell/tool code is executed locally, and server paths are not treated as local file URLs.

Saved credentials and addresses are Keychain-only. Cookies/drafts/transcripts are in memory. Generic-password Keychain access on an ad-hoc app can prompt again after an app update because its signature changes; do not solve this by making passwords world-readable or adding shared iOS access-group entitlements.

Contract provenance: original Hermex sources retained from the fork point; live webui checkout `641878bd88f91950ce9774af1ccf1372ba08ad19` was a read-only source reference. Existing upstream compatibility-pin files continue to describe the iOS project; they are not silently advanced by this Mac fork. APIs can drift and optional panels may be unavailable. See README for the explicit unported feature list.
