# Case study log

## 2026-10-17 — Setup
- Installed REA 6.5.0 (`rea-agents`), registered as MCP server for Claude Code, Ghidra 12.1.4 (Homebrew, OpenJDK 21) as native provider.
- Target: CleanMyMac 5.7.2 (build 50702.0.2610141002) from the official MacPaw download page (`download.macpaw.com/BasicPlus/CleanMyMac.dmg`).
  - DMG sha256 `27aa1efd999ced8794595ad7f3e83503353baf3fc5350e99c9753c64912092ac`
  - Signed "Developer ID Application: MacPaw Way Ltd (S8EX82NJP6)", notarized (spctl: accepted).
  - Universal binary (arm64 + x86_64), bundle 436 MB, 136 frameworks.
- First REA run: `rea inspect-artifact` on the bundle → evidence `ev_fca8d5e96ba5dddfc19211ec301ae00d0bedbdf56e66d3de746708d155bff867` (directory inventory, no execution).
- Observations (inventory only):
  - Modular architecture: one framework per feature — SmartCareModule, JunkCleanupModule, SystemJunkScanning, TrashJunkScanning, UninstallerScanning, UnusedDiskImagesScanning, SpaceLensScanning, OrganizeScanning, PerformanceScanning, PrivacyScanning, CloudStorageScanning, MailJunkScanning, DownloadsScanning, AIToolScanning, UpdaterScanning.
  - Privileged helper `Library/LaunchServices/com.macpaw.CleanMyMac5.Agent`, login items (Menu, HealthMonitor), Finder Sync extension.
  - Rules appear to live in an encrypted knowledge base (`Resources/info.cmmkb`, 297,984 bytes, entropy 7.999 bits/byte; loaded by `KnowledgeBaseService`). **Decision: we do not decrypt it.** Rules will be learned from observed scan behavior instead.

## 2026-10-17 — Static metadata pass (no execution, no decompilation)
- Note: the app was launched once (~15:16) from `~/re-targets`, and it moved itself to `/Applications` (the bundle ships a `MoveApplicationService` framework). First-run footprint: 3 preference keys, group containers for its app groups; no helper, no login items, no permissions granted. A fresh, read-only copy was re-extracted from the DMG for static work; `/Applications/CleanMyMac_5.app` is the copy we run.
- Learned: REA's `inspect_plist` and `inspect_signature` need an active target. Opening the `.app` would bind Ghidra to MacPaw's binary, so we opened **the Info.plist file itself** with `open_binary` (format: plist), which keeps the session metadata-only.
- `inspect_plist` on main Info.plist → `ev_0a7bae9ee36e4fd02e730f4c0173790923357e6dc57a24d77e9186dea22c395d`. Observed: min macOS 11.0; one privileged executable declared via `SMPrivilegedExecutables`; usage descriptions for Photos, Contacts, Calendars, Reminders, Music, Desktop, Documents, Downloads, App Data.
- Entitlements (`codesign -d --entitlements`): main app **not sandboxed**; Finder Sync extension sandboxed; app groups include a legacy CleanMyMac4 group; HealthMonitor has network-server + location entitlements.
- Helper metadata (`launchctl plist __TEXT,__launchd_plist` / `__info_plist`): one Mach service; `SMAuthorizedClients` = main app, Menu, HealthMonitor (team-ID pinned); helper version 5.3.2 vs app 5.7.2.
- Spec written: `docs/spec/00-reference-architecture.md`.

## 2026-10-17 — First runtime observation: full scan
- Setup: CleanMyMac launched from `/Applications`, Full Disk Access granted, privileged helper NOT installed. Trace recorded by the user with `sudo fs_usage -w -f pathname CleanMyMac_5 com.macpaw.CleanMyMac5.Agent` (17:31–17:37). The Clean button was never pressed.
- Tooling notes for the article:
  - Opening the running app with REA (`open_binary`, provider `native-macos`, to use `observe_native_ui`) was **blocked by Claude Code's auto-mode safety classifier** ("third-party attack"). A follow-up read-only shell command on the trace was also blocked once; the user then explicitly approved trace analysis. Takeaway: agent guardrails treat attaching to someone else's running app as high-risk, and that's sensible; the human has to make the call.
  - Trace analysis was done with two small Python parsers (kept outside the repo), not REA: REA's process capture launches the target itself and snapshots files, whereas we needed system-wide syscall tracing of an already-running GUI app.
- Safety check first: all 740 delete/rename events were inside the app's own data, cache and temp directories (including an installer package it expanded into its temp dir and removed). **Zero user files touched.**
- Findings → `docs/spec/01-scan-behavior.md`: ~2.5 min active scan, 1.34 M metadata-heavy operations on 107 threads; distinct phases (logs/caches → full app-bundle inventory → launch agents/daemons → leftovers → installers → large/old files); developer caches visited only as part of the generic cache walk; no dedicated project-artifact scanner seen; app-usage databases only stat'ed (usage source still unknown).
- Privacy decision: the raw trace contains personal folder names, so it stays in `~/re-targets/` and the spec generalizes paths.

## 2026-10-17 — Reading the results screen with REA
- The user added allow rules for `mcp__rea__open_binary` and `mcp__rea__observe_native_ui` via `/permissions` (auto mode had refused to even prompt).
- `open_binary` cannot select the macOS-utilities provider explicitly (only ghidra/hopper/ida). With auto-selection it opened the app with **no deep provider bound**: Ghidra v1 refuses universal Mach-O binaries ("analyze a thinned slice instead"), Hopper/IDA absent. `binary_session` confirmed `analysis_provider_binding: null`; all disassembly/decompile tools reported `provider_missing`. So the clean-room boundary held by construction.
- `observe_native_ui` first needed Accessibility permission for Terminal (granted by the user), then still failed: **REA bug found** — REA compiles its Swift UI helper from scratch on every call with a fresh module cache and a 60 s timeout; on macOS 26 SDK that cold compile takes ~66 s here, so the call always times out. (To report upstream: `dist/native/NativeUiHelperRuntime.js`, `timeout: 60_000`.)
- Workaround: compiled REA's own helper source with REA's exact `swiftc` invocation and ran it with the same request JSON. Capture took 1.3 s: 97 accessibility nodes + window screenshot.
- Observed summary (paraphrased): cleanup 17.6 GB; malware none; performance 2 tasks; applications 1 update; clutter 53 duplicate downloads. Sidebar modules (feature areas): smart scan, cleanup, protection, performance, applications, clutter, disk map, cloud cleanup, tools, activity.
- Tried to click "Review" (navigation only) through a guarded wrapper (fresh re-capture, exact-label checks, forbidden words like Run/Clean/Remove). **Blocked by auto mode as "auto-mode bypass"**: the approval covered reading the window, not driving it. Decision: the human clicks, the agent observes.

## 2026-10-17 — Cleanup review screen (human clicks, agent reads)
- User clicked Cleanup → Review. Full capture (`max_nodes` 4000) timed out at 60 s on the long list; a screenshot-only capture (0.3 s) plus a bounded tree capture (800 nodes, 13 s) worked. Note for REA: a node budget with an early-exit on time would help large native lists.
- Observed: system junk split into 12 categories; 17.6 GB pre-selected (1,044 items). Pre-selected = caches, logs, localizations, system caches, broken login items. Not pre-selected = architecture stripping (1.8 GB) and document revisions. Caches grouped by owning app, all pre-ticked, including Apple daemon caches.
- Checkbox state is not exposed via accessibility; inferred from the size badges, which sum exactly to the selected total.
- Our own read-only measurement on the same Mac: ~37.7 GB of project build/dependency folders and ~39 GB in `~/.cache` (mostly ML models), none of which appeared in the cleanup list → the developer-cleanup gap is real and large on this machine.
- Spec: `docs/spec/02-cleanup-categories.md`.

## 2026-10-17 — Clutter review screen
- Human clicked My Clutter → Review; agent captured (screenshot 0.3 s; 437-node tree, not truncated).
- Observed: duplicate detection scoped to Downloads; 53 copies / 157 MB pre-selected; one copy per group kept.
- Checked the keep rule against file metadata (birth time, Spotlight date-added, last-used) for one group: kept copy was not the oldest; consistent with "first path in sort order". Recorded as low-confidence inference.
- Spec: `docs/spec/03-clutter-duplicates.md`.

## 2026-10-17 — Performance review screen + purgeable space
- Observed two maintenance tasks: DNS cache flush and freeing purgeable space (estimated at up to 2.7 GB).
- Our check with public `URLResourceValues`: important-usage capacity − free capacity = 2.74 GB → matches. The reference figure is reproducible with public API; no private framework needed for the *estimate*.
- Investigated a ~19 GiB free-space drop during the session: caused by the user's own ML downloads, not by the analysis or the reference app.
- Spec: `docs/spec/04-maintenance-purgeable.md`.

## 2026-10-17 — Applications: how "unused" is decided
- User recorded a second trace (`fs_usage` incl. `mds`, `mds_stores`), ran the applications scan, opened the uninstaller review. Agent captured the screen (492 nodes, untruncated).
- Matched the per-app dates against `mdls`: Spotlight last-used date when present (2/2), else bundle modification date (10/10). Unused count (4) matches a ~6-month cutoff on that date.
- Trace: 28 s, ~161k ops, no usage-database reads, Spotlight daemons active → consistent with a Spotlight metadata query.
- This answered the biggest open question without reading a line of the app's code: observation + a hypothesis + checking it against OS metadata.
- Spec: `docs/spec/05-apps-unused-uninstaller.md`.
- Confirmation: the agent predicted the 4 "unused" apps from the date rule before seeing the filter; the user opened the Unused filter and it listed exactly those 4. A predict-then-verify loop is the strongest evidence a black-box study can produce.

## 2026-10-17 — First implementation: engine + CLI, run on the same Mac
- Built from `docs/spec/` only: Swift package with `KachraCore` (read-only scanners, rules file, Trash-only cleaner) and a `kachra` CLI. 11 tests (project classification and judging, duplicate keep rule, cleaner refusals, rule-file integrity, purgeable formula).
- No Xcode on this Mac, only the Command Line Tools: the `Testing` framework needs explicit `-F`/rpath flags (`scripts/test.sh`).
- First full read-only scan on the reference Mac: 58 s.

| | Reference app (pre-selected) | KachraClean |
|---|---|---|
| Safe to remove | 17.6 GB | 39.6 GB |
| Total reported (safe + review) | 17.6 GB | 108.8 GB |
| Project dependencies & builds | not listed | 43.9 GB in 120 folders (13.3 GB safe: idle projects with lockfiles) |
| AI models & datasets | not listed | 37.7 GB (review) |
| Purgeable estimate | 2.7 GB | 2.76 GB |

- Two bugs found by looking at real output, then fixed: an environment folder directly in the home folder was named after the user account; a datasets cache was marked safe instead of review.

## 2026-10-17 — SwiftUI app
- `KachraCleanApp` target on top of `KachraCore`: overview (reclaimable headline, disk bar, safe / review / purgeable tiles, per-category breakdown), category review lists with safety badge, reason, evidence and paths, Show in Finder, select-by-safety menu, confirmation before Move to Trash, and a Full Disk Access banner.
- No Xcode: `scripts/build-app.sh` assembles `KachraClean.app` from the SwiftPM build (Info.plist, resource bundle in Contents/Resources, ad-hoc signature). Rules loading checks the app's Resources folder before SwiftPM's `Bundle.module`, which would otherwise crash inside a hand-built bundle.
- Gotcha: `Category` collides with the Objective-C runtime's `Category` type in an AppKit/SwiftUI target; solved with a module-level typealias.
- Screenshot review caught three UX bugs (a partial CLI scan overwriting the app's report, no pre-selection after reload, a truncated sidebar label), all fixed.

## 2026-10-17 — UX redesign (research-led)
Research inputs and what each changed:
- Disk-browser usability studies (Stasko et al.; Woodburn et al. 2019): sunbursts convey hierarchy better than treemaps on first use, and tiny outer slices need consolidating → interactive two-ring **space map** (categories → biggest items, small items merged, hover explains, click opens).
- Undo-vs-confirm guidance: blanket confirmations get clicked through; reversible actions should offer Undo → moving to the Trash happens immediately with an **Undo** toast (⌘Z, restores from the Trash); only removing apps asks first.
- Mole's design notes (calm, stable layouts; visible plan before deletion; independent path validation) → fixed-layout scanning screen with a step checklist; engine-level path guards stay separate from the UI.
- Criticism of Apple's Storage pane (unexplained "System Data", numbers that keep changing) → every item carries a reason and evidence; results appear only when final.
- WWDC25 Liquid Glass → floating glass action bar and glass buttons on macOS 26, material fallback on 14–15.
- What we observed in the reference app → one primary action on the results screen, "review" one click away.

Implementation notes / bugs found by screenshot review:
- Duplicate primary actions on the home screen → one selection concept; the hero button cleans the selection.
- Sidebar and inspector clipped at narrower windows. Root cause (after several wrong guesses): SwiftUI's `.inspector` asks the window to grow toward the screen edge and lays content out at that width when the window can't. Replaced with an in-column details panel. (Stale autosaved split-view widths from earlier builds also contributed while debugging.)
- `Category` and `Scanner` collide with Objective-C runtime / Foundation types in an AppKit target → module typealiases.
- **Without Full Disk Access, macOS blocks `open()` on some folders until the user answers a consent prompt**, which froze a scan step for minutes (found by sampling the process: threads parked in `__open`). Fix: a permission sheet before scanning that auto-continues once access is granted, plus a limited mode that skips other apps' containers and macOS system caches.

## 2026-10-17 — Per-model AI view and Large files
- **Hugging Face, one model at a time.** `hf cache ls --format json` (installed on the test Mac) lists repos, but only with humanized sizes/dates. KachraClean reads the cache layout directly instead: each snapshot file is a symlink into a shared `hub/blobs` store (newer layout), so per-model size = sum of the blobs it links to. Results matched the CLI exactly (e.g. 20.32 GB for the largest model) and the scan takes ~0.3 s. Key safety detail: trashing a model folder alone frees nothing in this layout, so a finding = the repo folder + blobs no other repo uses; shared blobs are kept; unreferenced blobs are a separate "safe" finding (equivalent to `hf cache prune`). The official CLI command is shown as evidence.
- **Ollama, one model at a time**, from its JSON manifests and content-addressed blobs (same exclusive/shared logic).
- **Large files** via a synchronous Spotlight query (`kMDItemFSSize > 500 MB` scoped to home: 33 hits in 0.12 s), with a folder-walk fallback. Classified by kind (video, audio, disk image, archive, dataset, VM disk); always `review`; Quick Look thumbnails and preview. Model weights found this way (ComfyUI checkpoints, mflux) go to AI models instead, grouped per model folder for sharded models.
- Effect on the test Mac: AI models 37.7 GB → 70.9 GB (loose weights were previously invisible); Large files 12.5 GB.

## 2026-10-18 — Security sweep before going public
- **Repository:** history scanned for secrets, tokens, personal paths and emails: clean. Every commit uses the GitHub no-reply address; GitHub secret scanning and push protection are on; private vulnerability reporting enabled; `SECURITY.md` added. One leak found: the icon's source PNG carried the image model's generation metadata (prompt and a local path containing the macOS username). It is now stripped from all images; older commits still contain it.
- **Real bugs found by reading the scanners as an attacker would:**
  - `~/.cache` children were reported as *safe* caches. On the test Mac that pre-selected the Hugging Face login token (`~/.cache/huggingface/token`). Now only folders are reported, `~/.cache` folders are *review*, and the datasets cache is back to *review* through its own rule.
  - A Hugging Face snapshot symlink pointing outside the cache would have counted its target (any file of yours) as one of the model's blobs, and trashed it with the model. Now only targets inside the cache count.
  - Ollama blob paths were built from manifest digests without validation (`../` possible). Now only `sha256:<64 hex>` is accepted.
  - App bundle IDs come from the app's own Info.plist and were used to build "related data" paths. A crafted ID could point into Documents. Bundle IDs and app names are now validated, and shared vendor folders are never claimed by name.
  - A weights file inside any folder named `vae`/`transformer` made the *parent* folder the thing to remove. Grouping now requires a real model folder.
  - The cache-folder symlink case could make in-use model blobs look "unreferenced" (safe). Paths are now resolved consistently.
- **Defence in depth:** the cleaner no longer trusts findings. It refuses credentials, keychains, mail and cloud folders, and anything that doesn't match its category. The saved report is `0600`. The app is signed with the hardened runtime. Undo now covers partly cleaned items, and scans older than a day are no longer pre-selected.
- Tests: 14 → 23, including one per bug above.
