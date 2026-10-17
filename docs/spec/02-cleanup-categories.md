# Cleanup categories and defaults (observed from the results screen)

Source: the reference app's cleanup review screen, read through its accessibility tree and a window
screenshot (REA native-UI helper), after one full scan on a real Mac. Full Disk Access granted, root
helper not installed. Category names below are our own descriptive labels; sizes are what that Mac showed.

## Summary screen (observed)
Five result groups: cleanup (17.6 GB), malware (none), performance (2 tasks), applications
(1 update), clutter (53 duplicate downloads). Cleanup is subdivided into **system junk**, **mail
attachments** and **trash bins**.

## System-junk categories (observed) and default selection
Pre-selected categories carry a size badge; their sizes add up to the "selected" total (17.6 GB).

| Category (our label) | Size seen | Pre-selected? | Our safety level |
|---|---|---|---|
| Per-user app caches (`~/Library/Caches/*`) | 17.1 GB | yes | safe (regenerable), but see notes |
| Unneeded CPU architectures inside app binaries | 1.8 GB | **no** | risky: breaks code signatures; v1 = report only |
| Per-user logs | 252 MB | yes | safe |
| System logs | 181 MB | yes | safe (needs helper for root-owned files) |
| Unused app localizations | 55 MB | yes | review: modifies app bundles; v1 = report only |
| System caches | 11.9 MB | yes | safe (needs helper) |
| Old document revisions | 862 KB | **no** | review |
| Login items pointing to missing apps | 8.2 KB | yes | safe |
| iOS device backups / deleted-user data / broken preference files | 0 here | — | review |

**Takeaway:** the reference app pre-selects only regenerable data and leaves anything that alters
apps or user history unticked. KachraClean adopts the same principle, expressed per rule as
`safety: safe | review | risky` (only `safe` is pre-selected).

## How the cache list is presented (observed)
- Grouped **by owning app**, not by path: a third-party browser's cache, a Python distribution,
  pip, Homebrew, pnpm, app auto-updaters (Electron "ShipIt"/updater caches), Apple daemons (media
  analysis, text understanding, Siri voices, Metal shader caches), node-gyp, clang/ccache, etc.
- Every listed item was pre-ticked, including Apple system-daemon caches.
- Sorted by size; per-item drill-down available.
- 1,044 items selected in total.

→ KachraClean: group by owner (resolve bundle IDs to app names/icons), sort by size, allow drill-down,
and show *why* each item is safe (e.g. "re-downloaded on demand").

## The gap: what the cleanup list did NOT contain (our own measurement on the same Mac)
Measured read-only with `find`/`du` over the home folder (excluding `~/Library`):

| Developer data | Size | In reference cleanup list? |
|---|---|---|
| Project dependency/build folders (`node_modules`, `.venv`/`venv`, `.next`, `__pycache__`, `target`) | **~37.7 GB** across ~11.4k folders (node_modules ~15 GB in 66 projects; Python envs ~16 GB) | no |
| `~/.cache` (XDG cache: ML model hub ~35 GB, uv ~1.1 GB, headless-browser downloads ~0.6 GB, …) | **~39 GB** | no |
| `~/.npm` | 1.2 GB | no |

Caveats: the reference app's clutter / large-files and disk-map views were not examined yet and may
surface some of these as "large files"; nor are all of these junk (an active project's environment
or a downloaded model is wanted data). That is exactly why KachraClean needs project-awareness:
last-modified time of the project, git status, and "re-creatable from lockfile" as safety signals.

## Open questions
- Content of the mail-attachments and trash groups; clutter (duplicates, large/old files) logic.
- Performance tasks (likely login/background items and maintenance scripts).
- Whether the root helper changes system-cache/log totals.
