# Scan behavior (observed from a filesystem trace)

Source: one full scan by the reference app (v5.7.2) on a real Mac, recorded with
`sudo fs_usage -w -f pathname` (filtered to the main app process and helper names).
Full Disk Access granted, privileged helper **not** installed. 1,343,066 events, 17:31–17:37.
Raw trace stays outside the repo (it contains personal file names); summaries below are in our
own words with personal paths generalized.

Legend: **Observed** = seen in the trace. **Inferred** = our interpretation of a pattern. **Unknown** = open question.

## Headline numbers (observed)
| Metric | Value |
|---|---|
| Active scan time | ~2.5 min (bulk of events 17:32:00–17:33:50) |
| Filesystem operations | 1.34 M |
| Threads used | 107 |
| Top operations | `getattrlist` 381k, `lstat` 341k, `open` 196k, `stat` 175k, `fstatat` 53k, `listxattr`/`getxattr` 17k |
| Files opened for reading (not just stat'ed) | ~97k distinct, overwhelmingly inside app bundles |
| Deletes/renames outside its own data/temp dirs | **0** |

## Phases (observed timeline → inferred purpose)
| Window | What it touched | Inferred purpose |
|---|---|---|
| 0:00–0:40 | own frameworks, system volumes | startup, volume discovery |
| 0:50 | `/Library/Logs`, `~/Library/Logs/*`, `~/Library/Caches/*` | **system junk**: logs + user caches, every cache folder walked to size it |
| 1:00–1:30 | every `/Applications/*.app`, fully (Resources, `*.lproj`, frameworks, plug-ins); the system code-signature store | **app inventory**: per-app size, localizations, signature/integrity; feeds uninstaller, updater and malware checks |
| 1:30–2:00 | `/System/Library/LaunchAgents`, `/Library/LaunchDaemons`, `/Library/LaunchAgents`, `/usr/libexec` | **background items / persistence** check |
| 2:10 | `/Library/Application Support`, `/Library/Preferences` | **leftovers** of apps no longer installed |
| 2:20 | `.dmg`/`.pkg` files in Downloads and in an updater cache; one installer package was expanded into the app's own temp dir and then deleted | **installer junk** + package inspection |
| 2:30–2:50 | Documents, Desktop, Downloads trees (photos, project folders) | **large & old files / clutter** |
| 3:00+ | idle | results shown |

## What this means for KachraClean
1. **Scanning is metadata-heavy and parallel.** A good scan does `stat`/`getattrlist`-class calls on
   millions of entries across many threads and opens few files. → Use `getattrlistbulk`-style bulk
   enumeration (or `FileManager` enumerators with prefetched resource keys) on a bounded worker pool;
   never read file contents just to size them.
2. **The scan is strictly read-only.** All writes and deletes during the scan went to the app's own
   support/cache/temp dirs. → KachraClean's scan phase must never mutate user files; cleanup is a
   separate, explicit step.
3. **Caches are walked generically.** Developer caches under `~/Library/Caches` (pip, Homebrew downloads
   and bootsnap, node-gyp, pnpm, ccache, headless Chrome) were visited during the generic cache walk.
4. **No dedicated developer-project scanner was visible.** `node_modules`, `venv`/`.venv`, `build`, `dist`,
   `__pycache__` were only touched incidentally while walking Documents/Desktop (a few hundred events each).
   Xcode `DerivedData` and `CoreSimulator` were checked (4 events each; likely absent on this Mac).
   → This is the gap KachraClean targets: project-aware cleanup (find projects, size their build
   artifacts, respect "recently active" projects).
5. **Installers in Downloads are a category.** `.dmg`/`.pkg` files were enumerated; at least one package
   was expanded for inspection.

## Unknowns (next observation runs)
- **What was actually flagged** vs merely visited. A filesystem trace can't tell; needs the results screen.
- **How "unused apps" are decided.** Usage databases (`knowledgeC.db`, Biome streams, recent-documents
  lists, Screen Time container) were only stat'ed, never opened for reading. Inferred: usage comes from
  Spotlight metadata (e.g. last-used date) via the metadata daemon, which a per-process filesystem trace
  can't see. Test with a dedicated run of the applications module.
- **What the root helper adds** (system-level caches, other users, `/private/var`). Needs a run with the
  helper installed.
- Trace limitations: `fs_usage` truncates long paths from the front; the menu-bar and health-monitor
  processes were not captured (name filter).

## Side effects of installing/running the reference app (observed; useful for our own uninstall docs)
- Login items: a menu-bar app and a health monitor; a Finder Sync extension.
- A user LaunchAgent for its updater in `~/Library/LaunchAgents/`.
- Data in `~/Library/Application Support/<app>`, a group container, `/Users/Shared/<app>`, its cache dir,
  crash-reporter state, a feature-flag cache, and preference keys.
