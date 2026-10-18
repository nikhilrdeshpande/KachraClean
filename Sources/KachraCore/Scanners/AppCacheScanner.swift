import AppKit
import Foundation

/// Per-app caches under `~/Library/Caches` (and `~/.cache` for command-line tools),
/// excluding anything a rule already claims.
///
/// Only folders are reported. `~/.cache` is a convention, not a guarantee: tools also keep login
/// tokens and state there, so unclaimed folders in it are `review` and loose files are skipped.
struct AppCacheScanner {
    let home: URL
    let claimed: Set<String>
    var avoidProtected = false

    func scan() async -> [Finding] {
        let roots: [(URL, Category)] = [
            (home.appendingPathComponent("Library/Caches"), .appCaches),
            (home.appendingPathComponent(".cache"), .toolCaches),
        ]
        var candidates: [(url: URL, category: Category)] = []
        for (root, category) in roots {
            for child in children(of: root) {
                // Skip claimed paths, and folders that contain a claimed path (sized separately).
                if claimed.contains(child.path) { continue }
                if avoidProtected, child.lastPathComponent.hasPrefix("com.apple.") { continue }
                if claimed.contains(where: { $0.hasPrefix(child.path + "/") }) {
                    candidates += children(of: child)
                        .filter { !claimed.contains($0.path) }
                        .map { ($0, category) }
                    continue
                }
                candidates.append((child, category))
            }
        }

        let sizes = await DiskUsage.allocatedSizes(of: candidates.map(\.url))
        var findings: [Finding] = []
        for (index, candidate) in candidates.enumerated() where sizes[index] > 0 {
            let name = candidate.url.lastPathComponent
            let owner = Self.ownerName(forCacheFolder: name)
            let (safety, reason) = Self.judge(name: name, category: candidate.category)
            findings.append(Finding(
                category: candidate.category,
                title: owner ?? name,
                owner: owner,
                paths: [candidate.url.path],
                bytes: sizes[index],
                safety: safety,
                reason: reason,
                lastActivity: DiskUsage.lastModified(candidate.url),
                details: ["folder": name]
            ))
        }
        return findings
    }

    static func judge(name: String, category: Category) -> (Safety, String) {
        if category == .toolCaches {
            return (.review, "Folder in ~/.cache, where command-line tools keep caches. Usually re-created on demand, but some tools also keep settings or downloads here.")
        }
        if name.hasPrefix("com.apple.") {
            return (.review, "Cache for a macOS component. macOS rebuilds it in the background, which can cost CPU time and battery for a while.")
        }
        return (.safe, "Cache data. The app recreates what it needs; it may start a little slower the first time.")
    }

    /// Real subfolders only: no files (tokens, settings) and no symbolic links.
    private func children(of url: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let items = (try? FileManager().contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: []
        )) ?? []
        return items.filter {
            guard let v = try? $0.resourceValues(forKeys: keys) else { return false }
            return v.isDirectory == true && v.isSymbolicLink != true
        }
    }

    /// Resolves a cache folder named after a bundle identifier to the app's display name.
    static func ownerName(forCacheFolder name: String) -> String? {
        guard name.contains("."), !name.hasPrefix(".") else { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) else { return nil }
        return FileManager().displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
