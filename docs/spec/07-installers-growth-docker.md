# Old installers, growth since last time, Docker breakdown

Three additions for 0.1.3. Only the installer check has a counterpart we observed in the reference
app; the rest is our own design.

## 1. Old installers

**Observed (spec 01, phase 2:20):** the reference app reads `.dmg`/`.pkg` files in Downloads during
a scan ("installer junk"). How it decides is unknown; we did not inspect it further.

**Our behavior**
- Look in Downloads (two levels deep) and on the Desktop for `.dmg`, `.pkg`, `.mpkg` and `.xip` files.
- Match each one to an installed app by name. Nothing is mounted or opened.
  - Installed apps are the top-level bundles in `/Applications`, `/Applications/Utilities` and
    `~/Applications`.
  - Names are compared lowercased, letters and digits only. Leading "install", "installer" and
    "setup" are ignored.
  - An installer matches when its name starts with the app's name, or with the last part of the
    app's bundle ID ("vscode" for `com.microsoft.VSCode`), and that name is at least 4 characters.
- Evidence: the matched app, and where the file was downloaded from (`kMDItemWhereFroms`, host only).
- Safety:
  - matched to an installed app → **safe**: the app is installed, and the installer can be downloaded again;
  - not matched → **review**: it may be something not installed yet, or installed under another name.
- A file that is also in a duplicate group is left to the duplicate finding, so no path is in two findings.
- The cleaner accepts only files with those extensions in this category.

## 2. Growth since last time

Space problems are usually something that grew: a cache, a model folder, a project's build output.

- After every full scan, a compact summary is kept in `history.json` next to the report (`0600`):
  - date;
  - total per category;
  - every finding of at least 10 MB (ID, title, category, bytes).
  - The last 30 scans are kept.
- **Overview, "What grew since <date>":** up to five lines, each one a category or finding that
  grew by at least 100 MB.
  - The baseline is the newest summary at least 20 hours older than the current scan. If there is
    none, the oldest summary older than the current scan is used.
  - Findings are only called "new" if their category existed in the baseline. A category added by an
    update is not news.
  - Apps and the Trash are left out. Shrinking is not shown here, since it is usually our own cleaning.
- **Disk Explorer:** when a folder in the first two columns of the home folder finishes measuring,
  its children's sizes are recorded, at most one sample per folder per day and six samples per folder.
  - Rows that changed by at least 500 MB since a sample from an earlier day say so: "+18 GB since 12 Oct".

## 3. Docker breakdown

The Docker Desktop disk image is reported as one risky item, because deleting it removes every
image, container and volume. Docker can free most of that space itself.

- If a `docker` CLI is installed, run `docker system df --format '{{json .}}'` during the scan.
  - It is read-only, has a 10 s timeout, and never starts Docker.
  - If the daemon isn't running, nothing changes.
- From its per-type totals (images, containers, local volumes, build cache), the Docker finding
  gets a breakdown and, for each type with reclaimable space, Docker's own command with a Copy button:
  - `docker image prune -a`: images no container uses;
  - `docker builder prune`: build cache;
  - `docker container prune`: stopped containers;
  - `docker volume prune`: flagged as deleting data, because volumes hold databases.
- KachraClean never runs these commands. Its only removal action is Move to Trash.
- When Docker reports reclaimable space but there is no Docker Desktop disk image (OrbStack,
  colima), a "Docker data" finding with no paths is shown. It cannot be selected, only explained.
