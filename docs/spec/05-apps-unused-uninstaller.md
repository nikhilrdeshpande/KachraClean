# Applications: uninstaller list and "unused" detection

Source: the reference app's applications review screen (accessibility tree + screenshot), a filesystem
trace of the applications scan (28 s, ~161k operations), and our own Spotlight metadata queries on
the same apps.

## Observed (reference app)
- Applications scan results: app updates available, "consider removing some applications", and
  installer files found (460 MB).
- Uninstaller list: 38 apps; filters All / Unused (4) / Suspicious / Selected; grouped by store
  (App Store vs other) and vendor (Apple, Google, Microsoft, …), plus a plug-ins section.
- Each row: icon, name, a date, total size (bundle **plus related data** — e.g. a browser at 15.3 GB and
  an AI desktop app at 14.6 GB, far above their bundle sizes), drill-down to related files.
- **Nothing is pre-selected.** Uninstall stays disabled until the user ticks apps.
- During the scan, the app walked app bundles extensively but opened no usage databases; Spotlight's
  `mds`/`mds_stores` were active at the same time.

## Where the date comes from (inferred, high confidence)
Compared against `mdls` for 12 apps:
- When Spotlight has `kMDItemLastUsedDate`, the displayed date equals it (2/2 apps).
- When it doesn't, the displayed date equals the **bundle's modification date** (10/10 apps).

## What "unused" means (prediction confirmed)
We predicted, from the dates alone, that "unused" = displayed date older than ~6 months, and named the
4 apps in advance. The Unused filter then listed exactly those 4 apps (the next-oldest app, 1 day inside
the 6-month line, was not included). The exact cutoff (180 days vs 6 calendar months) is not pinned down.

## Weakness we can fix
Spotlight's last-used date is only set for some launch paths; many daily-used apps on this Mac had
none, so their "last used" silently fell back to install/modify time. An app used every day could be
labelled unused.

## KachraClean design
- Usage signal precedence: (1) Spotlight `kMDItemLastUsedDate`; (2) **currently running** or seen running
  (sample `NSWorkspace.runningApplications` while KachraClean is open and remember first/last seen);
  (3) recent-documents lists' modification dates as a hint; (4) bundle mtime — shown explicitly as
  "never seen used (installed …)" rather than presented as a usage date.
- Show the evidence per app ("last opened 12 Mar via Spotlight" vs "no usage data; installed 25 Feb").
- Unused threshold user-configurable (default 180 days); never pre-select uninstalls.
- App size = bundle + related data (containers, Application Support, caches, preferences matched by
  bundle ID and name), with the related-files list visible before removal; removal goes to Trash.
