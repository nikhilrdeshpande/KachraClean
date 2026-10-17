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
