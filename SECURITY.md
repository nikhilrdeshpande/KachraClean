# Security

KachraClean moves files to the Trash and usually runs with Full Disk Access, so bugs that could
remove the wrong thing are treated as security issues.

## Reporting

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/nikhilrdeshpande/KachraClean/security/advisories/new),
not in a public issue. Include the macOS version, the KachraClean version, and steps to reproduce.

Examples of what counts:

- A scan that lists personal files, credentials or another app's data as removable.
- A way to make the cleaner move anything outside the locations described below.
- A crafted file, folder name, app bundle or cache layout that changes what gets cleaned.

## How cleaning is constrained

- Scanning only reads. Nothing on disk changes until you press Clean.
- Cleaning only moves items to the Trash. Nothing is deleted outright, and the last clean can be undone.
- The cleaner re-checks every path itself and does not trust the scan report, which is stored on disk.
  It refuses:
  - anything outside your home folder, except whole `.app` bundles in `/Applications`;
  - top-level home and Library folders;
  - keychains, mail, messages, iCloud Drive and other cloud folders;
  - SSH, GPG and cloud-provider credential folders, and token or key files;
  - items that don't match their category. For example, an "app cache" must be inside
    `Library/Caches`, and a "large file" must be a single file.
- Values that come from other software are never used as paths. App bundle IDs, app names and
  model manifests are validated first, and symbolic links that lead outside a model cache are ignored.
- The app is built with the hardened runtime, which blocks code injection into a process that holds
  Full Disk Access.
