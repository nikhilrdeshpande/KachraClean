import AppKit
import CoreServices
import Foundation

/// Installed apps with their total footprint and honest usage evidence (see docs/spec/05).
///
/// Improves on the reference behavior: an app with no recorded usage is reported as
/// "no usage data", never as "unused since its install date".
public struct AppScanner: Sendable {
    public enum Usage: Sendable, Equatable {
        case spotlight(Date)
        case runningNow
        case noData(installed: Date?)
    }

    public var home: URL
    public var unusedDays: Int
    public var avoidProtected: Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, unusedDays: Int = 180,
                avoidProtected: Bool = false) {
        self.home = home
        self.unusedDays = unusedDays
        self.avoidProtected = avoidProtected
    }

    struct AppInfo: Sendable {
        var url: URL
        var name: String
        var bundleID: String?
        var isApple: Bool
        var usage: Usage
    }

    public func scan() async -> [Finding] {
        let running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        let apps = appBundles().map { inspect($0, running: running) }.filter { !$0.isApple }
        let related = apps.map { relatedData(for: $0) }
        let bundleSizes = await DiskUsage.allocatedSizes(of: apps.map(\.url))
        let relatedSizes = await DiskUsage.allocatedSizes(of: related.flatMap { $0 })

        var findings: [Finding] = []
        var cursor = 0
        for (index, app) in apps.enumerated() {
            let paths = related[index]
            let relatedBytes = relatedSizes[cursor..<(cursor + paths.count)].reduce(0, +)
            cursor += paths.count
            findings.append(finding(for: app, bundleBytes: bundleSizes[index],
                                    relatedPaths: paths, relatedBytes: relatedBytes))
        }
        return findings
    }

    func finding(for app: AppInfo, bundleBytes: Int64, relatedPaths: [URL], relatedBytes: Int64) -> Finding {
        let df = DateFormatter()
        df.dateStyle = .medium
        let (evidence, lastActivity, unused): (String, Date?, Bool) = {
            switch app.usage {
            case .spotlight(let date):
                return ("Last opened \(df.string(from: date)) (Spotlight).", date, Activity.days(since: date) >= unusedDays)
            case .runningNow:
                return ("Running right now.", Date(), false)
            case .noData(let installed):
                let when = installed.map { " · updated \(df.string(from: $0))" } ?? ""
                return ("No usage data from macOS\(when)", nil, false)
            }
        }()
        var details = ["bundle": PathUtil.display(app.url, home: home),
                       "appBytes": String(bundleBytes), "relatedBytes": String(relatedBytes),
                       "usage": evidence, "unused": unused ? "yes" : "no"]
        if let id = app.bundleID { details["bundleID"] = id }
        return Finding(
            category: .apps,
            title: app.name,
            owner: app.name,
            paths: [app.url.path] + relatedPaths.map(\.path),
            bytes: bundleBytes + relatedBytes,
            safety: .risky,
            reason: unused
                ? "Not opened in over \(unusedDays) days. \(evidence) Removing it also removes its settings and data."
                : (lastActivity == nil ? evidence + ". macOS only records some ways of opening apps, so this doesn't mean it's unused." : evidence),
            lastActivity: lastActivity,
            details: details
        )
    }

    // MARK: - Discovery

    func appBundles() -> [URL] {
        let fm = FileManager()
        var result: [URL] = []
        for dir in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
            for item in items {
                if item.pathExtension == "app" {
                    result.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // One level of folders, e.g. /Applications/Utilities or vendor folders.
                    let nested = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [])) ?? []
                    result += nested.filter { $0.pathExtension == "app" }
                }
            }
        }
        return result
    }

    func inspect(_ url: URL, running: Set<String>) -> AppInfo {
        let bundle = Bundle(url: url)
        let id = bundle?.bundleIdentifier
        let name = FileManager().displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let usage: Usage
        if let id, running.contains(id) {
            usage = .runningNow
        } else if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            usage = .spotlight(date)
        } else {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Some bundles carry a placeholder 1980 timestamp; treat it as unknown.
            usage = .noData(installed: modified.flatMap { $0.timeIntervalSince1970 > 400_000_000 ? $0 : nil })
        }
        return AppInfo(url: url, name: name, bundleID: id,
                       isApple: id?.hasPrefix("com.apple.") == true, usage: usage)
    }

    /// Data an app leaves outside its bundle, matched by bundle identifier (and name for
    /// Application Support, where many apps use their display name).
    func relatedData(for app: AppInfo) -> [URL] {
        // Both values come from the app itself (Info.plist, file name), so they're only used as
        // a single path component, never as a path.
        guard let id = app.bundleID, Self.isPlainBundleID(id) else { return [] }
        let lib = home.appendingPathComponent("Library")
        var candidates = [
            lib.appendingPathComponent("Containers/\(id)"),
            lib.appendingPathComponent("Application Support/\(id)"),
            lib.appendingPathComponent("Caches/\(id)"),
            lib.appendingPathComponent("HTTPStorages/\(id)"),
            lib.appendingPathComponent("WebKit/\(id)"),
            lib.appendingPathComponent("Saved Application State/\(id).savedState"),
            lib.appendingPathComponent("Preferences/\(id).plist"),
        ]
        if Self.isOwnFolderName(app.name) {
            candidates += [lib.appendingPathComponent("Application Support/\(app.name)"),
                           lib.appendingPathComponent("Logs/\(app.name)")]
        }
        // Group containers are prefixed with a team ID: <TEAMID>.<id> or <TEAMID>.group.<id>.
        let groups = avoidProtected ? [] : (try? FileManager().contentsOfDirectory(atPath: lib.appendingPathComponent("Group Containers").path)) ?? []
        candidates += groups.filter { $0.hasSuffix(".\(id)") }
            .map { lib.appendingPathComponent("Group Containers/\($0)") }
        if avoidProtected { candidates.removeAll { PathUtil.isProtected($0, home: home) } }
        return Array(Set(candidates.filter(PathUtil.exists)))
    }

    /// Reverse-DNS identifiers only: letters, digits, dots and dashes, with no empty or `..` parts.
    static func isPlainBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && id.count <= 255
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    }

    /// An app name usable as a folder name that belongs to that app alone. Vendor folders shared
    /// by several apps (Application Support/Google, .../Microsoft) are never claimed by name.
    static func isOwnFolderName(_ name: String) -> Bool {
        let shared: Set<String> = ["google", "microsoft", "adobe", "apple", "jetbrains", "autodesk", "mozilla",
                                   "oracle", "logitech", "unity", "epic games", "crashreporter"]
        return !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && !shared.contains(name.lowercased())
    }
}
