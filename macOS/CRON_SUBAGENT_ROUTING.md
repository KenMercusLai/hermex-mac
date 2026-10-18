# Cron-delegated sessions in Tasks

This is a client-only presentation change. It does not create, run, update or delete jobs or sessions and adds no backend endpoint. The Tasks pane still reads `/api/crons`, `/api/sessions` and `/api/crons/output`; selecting a worker uses the existing exact-ID session selection/history path and keeps server-reported read-only status.

## Source contract

Read-only inspection of the `hermes-webui` source established:

- `api/route_session_list_cache.py:16–21` documents run session IDs as literal `cron_` + exact job ID + `_` + `YYYYMMDD_HHMMSS`. Its matching code requires the entire suffix to match the timestamp, to prevent `backup` claiming `backup_full`.
- `api/models.py:7718,7806` also identifies `cron` as an actual producer source. Reported cron-source ancestry can prove a worker belongs out of Conversations even if its run ID cannot resolve to a job.
- `SessionSummary` exposes producer metadata (`rawSource`, `sourceTag`, `sessionSource`), exact `parentSessionId`, optional profile and read-only flags, but no explicit scheduled-job ID.
- `CronJob.jobId` is the actual decoded identifier. `CronJob.id` can fall back to a display name and therefore is **not** used to match workers to tasks.

`CronSessionRouting` requires a delegated session according to the existing `SessionHierarchy.isSubagent` predicate. It iteratively follows only delegated parent links, using first-occurrence ID deduplication and cycle detection. A missing parent can itself be a strictly parsed run ID. A present run does not need to be delegated and is not migrated itself. Fork/compression/continuation links are not traversed as delegation.

The parser uses whole-input anchors and ASCII timestamp digits. It never trims, lowercases or repairs IDs. Matching is only against a real catalog job's `jobId`; no prefix, title, name-only, or deleted-job fallback is used. When profiles are reported they must agree along the entire path and with the job. Unknown profiles are not treated as conflicts.

Proven cron workers, including nested descendants, are removed from Conversations whether or not the jobs endpoint is available. Only resolved workers appear beneath a real task; unresolved workers remain in memory/server storage but have no navigation row. Non-cron orphans remain visible. No session is deleted.

## Ownership and search

- `MacStore.sessions` remains the current result set, including search matches.
- `fullSessions` is connection-owned relationship/catalog data and is not overwritten by search responses. Every non-search sidebar refresh requests the archive-inclusive catalog, replaces the snapshot rather than accumulating IDs, and applies the archive toggle only to the sidebar's emitted rows. For conversation routing, current returned records precede the snapshot when the same ID appears in both; only current matches are emitted.
- Tasks reads full catalog sessions, not search matches. Opening/refreshing Tasks fetches an unfiltered session catalog, including archived rows, independently of the current sidebar query.
- Session-list, shared full-snapshot, task-list and task-output request revisions prevent older overlapping responses from installing state. Connection generation and API-client ownership reject A→B→A responses even from transports that survive disconnect. Stale failure responses are guarded too.
- Disconnect clears the full snapshot, job catalog, task/worker disclosures, task preview and task error/loading state.
- Task and worker disclosure controls are separate from selecting a task output or opening a session. Existing interactive conversation disclosure remains unchanged.

## Review P2 remediation

Remote baseline was fetched before editing: `origin/main` and `HEAD` remained `2777d1598cb30c41b2d864a3c327bd13259a6f49`. The finding matrix is scratch `cron-p2-finding-matrix.md`. Only `MacStore.swift`, `OwnershipTests.swift`, and this document were changed by this remediation.

1. **Complete relationship catalog:** an archived delegated intermediate was lost when normal archive-off sidebar results replaced the full snapshot, exposing its nonarchived leaf in Conversations and removing both workers from Tasks. Non-search sidebar requests now include archived rows; only sidebar emission is filtered. Shared snapshot revisions therefore arbitrate complete catalogs, not complete versus partial data. Regression tests cover Tasks → normal refresh, both interleaved Tasks/sidebar completion orders, and deleted-ID eviction on subsequent replacement. Current partial/search record precedence and existing search/snapshot/connection ABA checks remain unchanged.
2. **Output preview ABA:** task refresh failure discarded the jobs/preview but left the output generation and selected job valid. The catch path now advances the preview revision and clears its selected job. Separate success/failure tests hold A output, fail catalog refresh (A → empty), restore the exact equal job A, and release the stale response; neither stale content nor stale failure may install.

The slices were completed vertically: finding 1 RED (2 tests, 6 expected failed expectations) → GREEN (6 focused tests), then finding 2 RED (2 tests, 2 expected failed expectations) → GREEN (8 focused tests). Logs: scratch `cron-p2-1-red.log`, `cron-p2-1-green.log`, `cron-p2-2-red.log`, `cron-p2-2-green.log`.

## Verification on final remediated candidate

- **99/99 Swift tests passed** (95 original candidate tests plus 4 new regression tests), including all isolated fixture-Keychain tests: `bash macOS/scripts/test.sh`; scratch `cron-p2-full-swift.log`. **4/4 Python tests passed**: `python3 -m unittest discover -s macOS/Tests -p 'test*.py' -v`; `cron-p2-python.log`.
- Complete existing `python3 macOS/Tests/run_smoke.py .build/debug/Hermex` passed legacy and required-header auth, sessions/upload, native SSE interrupt/replay with exactly one chat start, read-only panels/logout and two-origin redirect security: `cron-p2-protocol.log`. Only disposable fixture credentials/Keychain items were used; no production credentials/services.
- `python3 macOS/scripts/build.py --version 0.1.6 --arch universal --allow-adhoc-library-validation` succeeded with a sanitized environment: `cron-p2-universal-build.log`. ARM64 and Intel slices report minimum macOS 14.0. Deep/strict/all-architecture signature verification, ZIP integrity and DMG checksum verification passed.
- Actual official Sparkle CLI installation into a random-ID, non-running disposable scratch app succeeded at 0.1.6. Tampered feed rejected with **error 1000**, tampered archive with **error 4005**; installed version, executable hash and signature were read back. A subsequent stale rejected-install continuation reported 1004 and was cleared by the existing isolated retry before successful installation. Evidence: scratch `hermex-update-smoke-0fak12re/results.json` and `cron-p2-update-install.log`. Only an ephemeral test seed was used and deleted; no production signing key/feed/Keychain was accessed.
- Existing native offscreen worker-rendering test passed in the full suite. Its PNG is scratch `cron-tasks-offscreen.png`; this is programmatic rendering, not interactive GUI or VoiceOver acceptance. Historical implementation RED→GREEN logs remain `cron-red-*.log` / `cron-green-*.log`.
- Additional packaged-release protocol invocation was **invalid**: smoke handling is compiled only under `#if DEBUG` (`Entry.swift`, `ProtocolSmoke.swift`). The release binary ignored `--protocol-smoke`, fell through to normal app startup and was killed by the runner's 45-second timeout (`cron-p2-release-protocol.log`). It left no running Hermex process. This was not a product test failure, but it violated the intended no-GUI/no-production-Keychain execution boundary: normal initialization uses `MacStore()` and can read the production connection registry/headers and start the updater. No saved secret was returned to the agent or inspected; whether those startup reads completed is not established. No further release launch or production-state inspection was attempted. The valid full protocol result above is from the debug-only isolated fixture path.
- `git diff --check` passed. Shared producer/upstream files, package configuration and protocol fixture remain unchanged from `origin/main`. Toolchain emits the existing native-build-system deprecation warning; no required build/test gate remains failing.

Artifacts are under `dist/`: `Hermex.app`, `Hermex-Mac-0.1.6-universal.zip`, `Hermex-Mac-0.1.6-universal.dmg`, and `Hermex-Mac-0.1.6-universal-SHA256SUMS.txt`. These are local ad-hoc Hardened Runtime artifacts with the explicitly authorized library-validation entitlement, not Developer ID/notarized releases. Intel is cross-compiled, not runtime-tested. No installed user app was replaced, no GUI relaunch acceptance was performed, and no publication was attempted; the invalid extra release invocation and its startup-read risk are disclosed above. **Existing `dist/update-feed-0.1.6` content is stale after rebuilding; the parent must regenerate/re-sign it before release.**

Final local artifact SHA-256:

- App executable: `6996a3aa413e4d58ece37fb2245571f4d51898d45f3edc7874f578774c3abef3`
- Universal ZIP: `f6c1a13564df2459ec0c34e073a2acff05c9aa8eb7bf4bf19b969c760e0b45b2`
- Universal DMG: `fc657d7cef973bfdd254c17dc585b6378f0400dc835dbfc8586d60b3efcf804c`
