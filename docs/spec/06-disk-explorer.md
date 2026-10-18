# Disk Explorer

The scan answers "what can I safely remove?" and only lists things it recognises. Space it doesn't
recognise stays invisible. The Disk Explorer answers the other question, "where is my space?", by
showing every file and folder, biggest first, with what the scan knows laid on top.

Sources: public descriptions of disk browsers (OmniDiskSweeper reviews and release notes on
Macworld, Engadget and Michael Tsai's blog; DaisyDisk's product pages), plus our own scanner.
We did not observe or inspect any disk browser's binary or runtime for this; nothing here is
evidence-backed behavior of another product, only a design.

## What the user sees
- **Columns, like Finder's column view.** The first column is the home folder. Selecting a folder
  opens its contents in the next column. Every column is sorted by size, largest first.
- **Sizes fill in live.** Files show their size immediately. Folders show a spinner until measured,
  then move into place. Items not yet measured sort last.
- **Honest sizes.** When macOS refuses to list part of a folder (permissions, or a location we
  deliberately skip without Full Disk Access), its size is shown with a `+` ("12 GB+"): the real
  size is at least that much.
- **Proportion bars.** Each row shows its share of the folder it sits in.
- **What KachraClean knows.**
  - A row that *is* a suggestion shows its category and safety level.
  - A folder that *contains* suggestions shows how many and how much ("3 suggestions · 4.2 GB").
  - Unknown folders are shown plainly. Nothing is hidden because we don't recognise it.
- **Details panel** for the selected item: size, item count, last modified, location, the
  suggestion's reason when there is one, and which categories its contents fall into.
- **Rest of the disk.** Once the home folder is measured, the header shows how much of the used
  space lies outside it (macOS, apps, other users), so "System Data" is not a mystery.

## Measuring (read-only)
- Metadata only. Sizes are allocated blocks (`totalFileAllocatedSize`), the same measure the scan
  uses; no file is opened. Symbolic links are not followed and count as zero.
- Hidden files and folders are included (`~/.cache`, `~/.ollama` are often the biggest).
  Packages (`.app`, `.photoslibrary`) are measured as folders.
- One walk of a folder records the sizes of the folders below it, three levels deep, so moving
  down after the first measurement is instant. Deeper folders are measured when opened.
- Several folders are measured at a time. Leaving a folder cancels its unfinished measurements;
  a cancelled measurement is never cached.
- Without Full Disk Access, other apps' containers (`Library/Containers`, `Library/Group Containers`)
  are not entered, because macOS can pause the process on a consent prompt there (see the
  2026-10-17 log). Their size is shown with `+` and the column explains why it is empty.
- Reload forgets every cached size.

## Removing from the explorer
- Move to Trash only, behind a confirmation that names the item and its size, and says whether
  KachraClean recognises it. Undo puts it back, like any other clean.
- The cleaner checks the path itself, as for scan findings, with the same location guards:
  - nothing outside the home folder;
  - no top-level home folder (Documents, Library, ...) and no `Library/<area>` folder;
  - no keychains, mail, messages, iCloud Drive or cloud-storage folders;
  - no credential folders or key files.
- There is no category check, because the user picked the item.
- Suggestions that were inside a removed folder leave the scan results and come back on Undo.
- Sizes of the folders above update without re-measuring.

## Entry points
- "Disk Explorer" in the sidebar, available before any scan.
- "Show in Disk Explorer" on a suggestion's details panel opens the explorer at that path.
- Choose Folder... browses any other folder; removal outside the home folder is still refused.
