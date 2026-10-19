# KachraClean

**An open-source macOS storage cleaner for people who build things.**

*Kachra* (कचरा) means "trash" in Hindi and Marathi.

Commercial Mac cleaners are good at app caches and logs. On a developer's Mac, though, most of the
reclaimable space is somewhere else: `node_modules`, Python virtual environments, build output,
package-manager caches and downloaded ML models. On the Mac we tested, a leading commercial cleaner
found 17.6 GB to clean, and project folders plus model caches added roughly 78 GB more that it
didn't list.

KachraClean aims to cover both:

- **Caches, logs and junk**, grouped by the app that owns them.
- **Developer cleanup** that understands projects: it looks at recent activity, git status, and
  whether a folder can be rebuilt from a lockfile.
- **Model and toolchain caches** such as Hugging Face, Ollama, `~/.cache`, npm/pnpm/pip/uv and Homebrew.
- **Duplicate downloads**, with a stated rule for which copy is kept.
- **Old installers**: disk images and packages for apps that are already installed.
- **What grew since last time**, so a runaway cache shows up before the disk is full.
- **Docker**, broken down by what Docker itself can free, with its own commands to copy.
- **Unused apps**, with the evidence behind each verdict ("last opened 12 Mar" vs. "no usage data").
- **Disk Explorer**: every folder in your home, biggest first, in Finder-style columns. Suggestions
  are marked, and folders that hold them say how much, so space the scan doesn't recognise isn't
  invisible.

Safety comes first:

- Scanning is read-only.
- Every rule carries a safety level (`safe` / `review` / `risky`) and a reason.
- Nothing is deleted without a preview.
- Removal moves items to the Trash.

> Status: early preview (0.1.2). The research phase is complete (see `docs/spec/`).

## Download

Get the latest `KachraClean-<version>.dmg` from
[Releases](https://github.com/nikhilrdeshpande/KachraClean/releases/latest). Open it and drag
**KachraClean** to **Applications**. It runs on macOS 14 or later, on Apple silicon and Intel Macs.

The app is not notarized by Apple yet, so the first launch is blocked with a warning that Apple
could not verify it. To open it anyway:

1. Try to open KachraClean once and dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to
   KachraClean.

Or, from Terminal: `xattr -dr com.apple.quarantine /Applications/KachraClean.app`

## Build the app yourself

```bash
./scripts/build-app.sh      # builds build/KachraClean.app (no Xcode needed)
open build/KachraClean.app

UNIVERSAL=1 ./scripts/build-app.sh && ./scripts/make-dmg.sh   # release disk image
```

Grant **KachraClean** Full Disk Access when the banner asks. Safe items are pre-selected. Nothing
moves until you press **Move to Trash…** and confirm, and you can always restore items from the Trash.

## Try it (command line)

You need macOS 14 or later and Swift 6. The Xcode Command Line Tools are enough.

```bash
swift build -c release
.build/release/kachra scan                       # read-only; saves a report
.build/release/kachra scan --only projectArtifacts,models --top 20
.build/release/kachra clean --category toolCaches # dry run: shows what would move to the Trash
.build/release/kachra clean --id <id> --yes       # actually moves that finding to the Trash
.build/release/kachra explore ~/code              # a folder's contents, biggest first
./scripts/test.sh                                 # run the tests
```

Give your terminal **Full Disk Access** (System Settings → Privacy & Security) so the scan can see
other apps' caches and containers.

## The case study

KachraClean also documents how we used [REA](https://github.com/morluto/rea) and an AI agent to study
how a commercial cleaner behaves, from the outside, under clean-room rules:

- We observed behavior: bundle metadata, filesystem traces and the results screens.
- We never decompiled the reference app's code or decrypted its data files.
- Findings are written in our own words in [`docs/spec/`](docs/spec/). The step-by-step log is in
  [`docs/case-study/log.md`](docs/case-study/log.md).
- The implementation is written only from those specs, public Apple documentation, and
  compatibly licensed open-source references.

## Disclaimer

KachraClean is an independent project. It is not affiliated with, endorsed by, or sponsored by MacPaw
or any other vendor. Product names are trademarks of their respective owners and are used only to
identify the software we studied.

## License

[MIT](LICENSE)
