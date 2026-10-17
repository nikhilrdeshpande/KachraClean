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
- Observed Smart Care summary: Cleanup "17.6 GB of junk"; Protection "No threats"; Performance "2 tasks"; Applications "1 vital update"; My Clutter "53 duplicate downloads". Sidebar modules: Smart Care, Cleanup, Protection, Performance, Applications, My Clutter, Space Lens, Cloud Cleanup, My Tools, My Activity.
- Tried to click "Review" (navigation only) through a guarded wrapper (fresh re-capture, exact-label checks, forbidden words like Run/Clean/Remove). **Blocked by auto mode as "auto-mode bypass"**: the approval covered reading the window, not driving it. Decision: the human clicks, the agent observes.

## 2026-10-17 — Cleanup review screen (human clicks, agent reads)
- User clicked Cleanup → Review. Full capture (`max_nodes` 4000) timed out at 60 s on the long list; a screenshot-only capture (0.3 s) plus a bounded tree capture (800 nodes, 13 s) worked. Note for REA: a node budget with an early-exit on time would help large native lists.
- Observed: system junk split into 12 categories; 17.6 GB pre-selected (1,044 items). Pre-selected = caches, logs, localizations, system caches, broken login items. Not pre-selected = architecture stripping (1.8 GB) and document revisions. Caches grouped by owning app, all pre-ticked, including Apple daemon caches.
- Checkbox state is not exposed via accessibility; inferred from the size badges, which sum exactly to the selected total.
- Our own read-only measurement on the same Mac: ~37.7 GB of project build/dependency folders and ~39 GB in `~/.cache` (mostly ML models), none of which appeared in the cleanup list → the developer-cleanup gap is real and large on this machine.
- Spec: `docs/spec/02-cleanup-categories.md`.
