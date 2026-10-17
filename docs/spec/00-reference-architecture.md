# Reference architecture (observed from bundle metadata only)

Source: CleanMyMac 5.7.2 bundle inventory, Info.plists, entitlements, helper launchd metadata.
No code was decompiled. Evidence IDs refer to REA records listed in `docs/case-study/log.md`.

## What a full-featured Mac cleaner needs (lessons for KachraClean)

1. **Not sandboxed + Full Disk Access.** The main app ships without the App Sandbox entitlement; only its
   Finder extension is sandboxed. A sandboxed (App Store) build cannot reach other apps' caches and
   containers, which is why App Store cleaners are reduced editions.
   → KachraClean: distribute outside the App Store (Developer ID + notarization); onboarding must walk the
   user through granting Full Disk Access and must work in a degraded mode without it.

2. **A root helper for system-level paths.** The app declares one privileged helper via the legacy
   `SMPrivilegedExecutables` / `SMJobBless` mechanism. The helper exposes a single Mach service, and its
   allowed clients are restricted by code-signing requirement (same team ID) to the main app, the
   menu-bar app and the health monitor. The helper's version (5.3.2) lags the app (5.7.2) — the helper
   is a small, stable surface; logic stays in the app.
   → KachraClean: use the modern `SMAppService` daemon API (macOS 13+), keep the helper tiny (delete /
   measure paths the user can't), validate the caller's code signature on every XPC connection.

3. **Per-app-data privacy prompts.** It declares usage descriptions for Photos, Contacts, Calendars,
   Reminders, Music, and Desktop/Documents/Downloads. Cache cleanup for Apple apps triggers TCC prompts
   unless Full Disk Access is granted.
   → KachraClean: request FDA once rather than triggering a stream of per-folder prompts.

4. **One module per cleanup domain** (from framework names): system junk, trash, uninstaller /
   app leftovers, unused disk images, large & old files ("organize"), space visualization, downloads,
   mail attachments, cloud storage, privacy traces, app updater, performance (login items etc.), and
   AI-tool data. → this is our feature checklist; see `01-feature-map.md` (to write).

5. **Rules ship as data, not code.** Cleanup knowledge is stored in an encrypted knowledge-base file
   loaded by a dedicated service. We do not read it. → KachraClean keeps rules as a readable, versioned,
   community-editable data file (each rule: paths/globs, safety level, reason, owning app).

6. **Always-on companions.** A menu-bar app and a health monitor run as login items and talk to the
   helper. → optional for KachraClean; not part of v1.

## Unknowns (to resolve by runtime observation)
- Which concrete paths each scan module reads and flags.
- How "unused apps" are determined (last-used date source).
- How it sizes things (allocated vs logical size, APFS clones, purgeable space).
