import Foundation

/// How confident we are that removing an item is harmless. Only `safe` items are pre-selected.
public enum Safety: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerated automatically or on demand; no user data.
    case safe
    /// Probably reclaimable, but the user should look first (active project, large re-download, ...).
    case review
    /// Can break something or lose data; reported for information, never pre-selected.
    case risky

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .risky: 2
        }
    }

    public static func < (lhs: Safety, rhs: Safety) -> Bool { lhs.rank < rhs.rank }
}

public enum Category: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    case appCaches
    case logs
    case toolCaches
    case models
    case largeFiles
    case projectArtifacts
    case duplicates
    case installers
    case apps
    case trash

    public var title: String {
        switch self {
        case .appCaches: "App caches"
        case .logs: "Logs"
        case .toolCaches: "Developer tool caches"
        case .models: "AI models"
        case .largeFiles: "Large files"
        case .projectArtifacts: "Project dependencies"
        case .duplicates: "Duplicate downloads"
        case .installers: "Old installers"
        case .apps: "Applications"
        case .trash: "Trash"
        }
    }
}

/// One reclaimable thing, as shown to the user: a cache folder, a project's `node_modules`,
/// a group of duplicate copies, an app with its related data.
public struct Finding: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var category: Category
    public var title: String
    /// App or tool that owns the data, when known.
    public var owner: String?
    /// Paths that would be moved to the Trash if this finding is cleaned.
    public var paths: [String]
    /// Allocated bytes on disk that cleaning would release.
    public var bytes: Int64
    public var safety: Safety
    /// Why this is (or isn't) safe to remove, in plain language.
    public var reason: String
    public var lastActivity: Date?
    /// Extra facts for the detail view (e.g. "lockfile": "pnpm-lock.yaml").
    public var details: [String: String]

    public init(
        category: Category,
        title: String,
        owner: String? = nil,
        paths: [String],
        bytes: Int64,
        safety: Safety,
        reason: String,
        lastActivity: Date? = nil,
        details: [String: String] = [:]
    ) {
        self.id = Finding.makeID(category: category, paths: paths)
        self.category = category
        self.title = title
        self.owner = owner
        self.paths = paths
        self.bytes = bytes
        self.safety = safety
        self.reason = reason
        self.lastActivity = lastActivity
        self.details = details
    }

    /// Stable across scans so a finding can be referenced from the CLI or a saved report.
    static func makeID(category: Category, paths: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
        for byte in (category.rawValue + "|" + paths.sorted().joined(separator: "|")).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}

public struct VolumeInfo: Codable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    /// What macOS would make available for an "important" write, including purgeable space.
    public var availableForImportantUsage: Int64

    /// Space macOS can free on demand (iCloud-evictable files, purgeable caches, snapshots).
    /// Matches what commercial cleaners present as "purgeable" (see docs/spec/04).
    public var purgeableBytes: Int64 { max(0, availableForImportantUsage - freeBytes) }
}

public struct ScanReport: Codable, Sendable {
    public var createdAt: Date
    public var findings: [Finding]
    public var volume: VolumeInfo?
    /// Seconds spent per scanner, for diagnostics.
    public var timings: [String: Double]

    public init(createdAt: Date = Date(), findings: [Finding], volume: VolumeInfo?, timings: [String: Double]) {
        self.createdAt = createdAt
        self.findings = findings
        self.volume = volume
        self.timings = timings
    }

    public func total(_ category: Category? = nil, safety: Safety? = nil) -> Int64 {
        findings
            .filter { category == nil || $0.category == category }
            .filter { safety == nil || $0.safety == safety }
            .reduce(0) { $0 + $1.bytes }
    }
}

/// How findings describe recent activity: "today", "yesterday", "12 days ago".
enum Activity {
    static func days(since date: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    static func describe(days: Int) -> String {
        switch days {
        case 0: "today"
        case 1: "yesterday"
        default: "\(days) days ago"
        }
    }

    static func describe(_ date: Date) -> String { describe(days: days(since: date)) }
}
