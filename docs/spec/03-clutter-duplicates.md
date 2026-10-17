# Clutter: duplicate downloads (observed from the results screen)

Source: the reference app's clutter review screen (accessibility tree + screenshot), same scan as
`01`/`02`. Personal file names are omitted.

## Observed
- Scope of this check: the **Downloads folder tree** (all listed copies lived under `~/Downloads`,
  including copies inside extracted-archive subfolders).
- Result: 53 files pre-selected for removal, 157 MB total, in ~37 groups.
- Groups are byte-identical copies (same size; typical pattern: `name.ext`, `name (1).ext`, re-extracted
  archive folders `folder (1)`, `folder (2)`). Each group shows "selected / total copies" (e.g. 3 / 4).
- The default selection mode ("smart") leaves exactly **one copy per group unticked**.
- Per copy it shows: name, folder breadcrumb, a date, and size; groups are sorted by total size.
- Filter by file kind is available ("all files" by default).

## Which copy is kept? (inferred, low confidence)
In the one group examined, the kept copy was **not** the oldest (by birth time or Spotlight
"date added"); it was the copy whose full path sorts first lexicographically. One group is not enough
to establish the rule. → KachraClean defines its own rule rather than guessing theirs:
keep the copy that (1) is outside `~/Downloads` if any, else (2) has no " (n)" suffix, else
(3) was added first; always show the kept copy explicitly and let the user change it.

## KachraClean design notes
- Detect duplicates in stages: group by size → partial hash (first/last 64 KB) → full hash
  (BLAKE3/SHA-256) only for remaining candidates. Never hash files that have a unique size.
- Treat APFS clones as "not wasting space" (shared blocks); report only the real reclaimable bytes.
- Duplicates are `review` safety level: never pre-delete without showing the kept copy.
