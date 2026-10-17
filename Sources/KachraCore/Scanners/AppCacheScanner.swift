import AppKit
import Foundation

/// Per-app caches under `~/Library/Caches` (and `~/.cache` for command-line tools),
/// excluding anything a rule already claims.
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
            let isApple = name.hasPrefix("com.apple.")
            findings.append(Finding(
                category: candidate.category,
                title: owner ?? name,
                owner: owner,
                paths: [candidate.url.path],
                bytes: sizes[index],
                safety: isApple ? .review : .safe,
                reason: isApple
                    ? "Cache for a macOS component. macOS rebuilds it in the background, which can cost CPU time and battery for a while."
                    : "Cache data. The app recreates what it needs; it may start a little slower the first time.",
                lastActivity: DiskUsage.lastModified(candidate.url),
                details: ["folder": name]
            ))
        }
        return findings
    }

    private func children(of url: URL) -> [URL] {
        let items = (try? FileManager().contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        )) ?? []
        return items.filter {
            $0.lastPathComponent != ".DS_Store"
                && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
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
