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
- **Unused apps**, with the evidence behind each verdict ("last opened 12 Mar" vs. "no usage data").

Safety comes first:

- Scanning is read-only.
- Every rule carries a safety level (`safe` / `review` / `risky`) and a reason.
- Nothing is deleted without a preview.
- Removal moves items to the Trash.

> Status: early development. The research phase is complete (see `docs/spec/`). Implementation has
> just started.

## Try the app

```bash
./scripts/build-app.sh      # builds build/KachraClean.app (no Xcode needed)
open build/KachraClean.app
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
