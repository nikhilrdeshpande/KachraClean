# KachraClean

Open-source macOS storage cleaner (caches, junk, dev artifacts like node_modules, unused apps, large files, app leftovers). Also a public case study of using REA (https://github.com/morluto/rea) to study how a commercial cleaner behaves.

## Clean-room rules (non-negotiable — this project is published)

The reference app is CleanMyMac 5 (MacPaw). Its bundle lives OUTSIDE this repo at `~/re-targets/cleanmymac/` and must never be copied in.

1. **Observe behavior, don't decompile MacPaw code.** Allowed on CleanMyMac: bundle inventory (file layout, framework/module names, Info.plists, entitlements), and runtime observation of what it reads/flags during scans. Not allowed: Ghidra/Hopper decompilation of MacPaw binaries.
2. **Never circumvent protection.** Do not decrypt `info.cmmkb` / `userInfo.cmmkb` (encrypted knowledge base), do not bypass trial/licensing, do not patch or inject into the app.
3. **Deep binary RE is for macOS itself** (e.g. how System Data / purgeable space / CacheDelete work) — findings go into the spec, not code.
4. **Nothing of theirs enters this repo**: no decompiled code, no strings/UI copy, no icons/artwork, no rule lists copied verbatim.
5. **Spec, then code.** Findings → `docs/spec/` (behavior described in our own words + evidence ID). Implementation is written only from `docs/spec/` and public Apple docs / open-source references with compatible licenses.
6. Every investigation step gets a dated entry in `docs/case-study/log.md` (what we asked REA, what it returned, what we concluded) — this becomes the website article.

## Safety rules for the app itself
- Preview before delete; default action is Move to Trash, never `rm`.
- Every cleanup rule carries a safety level (safe / review / risky) and a reason.
