import Foundation

/// Compact record of past scans and folder sizes, for "what grew since last time" (docs/spec/07).
public struct History: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var title: String
        public var category: Category
        public var bytes: Int64
    }

    public struct Scan: Codable, Sendable {
        public var date: Date
        public var categories: [Category: Int64]
        /// Findings of at least `itemMinimum`, by ID (IDs are stable across scans).
        public var items: [String: Item]
    }

    public struct Sample: Codable, Sendable {
        public var date: Date
        public var bytes: Int64
    }

    public struct Change: Sendable, Identifiable {
        public var id: String
        public var title: String
        public var category: Category
        public var delta: Int64
        /// A finding that wasn't there before (as opposed to a category total that grew).
        public var isNew: Bool
        public var isCategory: Bool
    }

    public struct Growth: Sendable {
        public var since: Date
        public var changes: [Change]
    }

    public var scans: [Scan] = []
    /// Sizes of folders measured in the Disk Explorer, oldest first.
    public var folders: [String: [Sample]] = [:]

    static let itemMinimum: Int64 = 10_000_000
    static let maxScans = 30
    static let maxSamples = 6
    /// A baseline must be at least this old to be "last time" rather than a moment ago.
    static let baselineAge: TimeInterval = 20 * 3_600

    public init() {}

    // MARK: Scans

    public mutating func record(_ report: ScanReport) {
        let counted = report.findings.filter { $0.category.countsTowardGrowth }
        var categories: [Category: Int64] = [:]
        for f in counted { categories[f.category, default: 0] += f.bytes }
        let items = Dictionary(counted.filter { $0.bytes >= Self.itemMinimum }.map {
            ($0.id, Item(title: $0.title, category: $0.category, bytes: $0.bytes))
        }) { first, _ in first }
        scans.removeAll { $0.date == report.createdAt }
        scans.append(Scan(date: report.createdAt, categories: categories, items: items))
        scans.sort { $0.date < $1.date }
        if scans.count > Self.maxScans { scans.removeFirst(scans.count - Self.maxScans) }
    }

    /// The scan to compare against: the newest one from at least 20 hours earlier, else the oldest
    /// one before this report.
    func baseline(before date: Date) -> Scan? {
        let earlier = scans.filter { $0.date < date }
        return earlier.last { $0.date <= date.addingTimeInterval(-Self.baselineAge) } ?? earlier.first
    }

    /// Categories and findings that grew by at least `minimum` since the baseline, biggest first.
    public func growth(of report: ScanReport, minimum: Int64 = 100_000_000, limit: Int = 5) -> Growth? {
        guard let base = baseline(before: report.createdAt) else { return nil }
        let counted = report.findings.filter { $0.category.countsTowardGrowth }
        var totals: [Category: Int64] = [:]
        for f in counted { totals[f.category, default: 0] += f.bytes }
        var changes: [Change] = []
        for (category, bytes) in totals {
            guard let old = base.categories[category] else { continue }  // category added by an update
            if bytes - old >= minimum {
                changes.append(Change(id: "cat-" + category.rawValue, title: category.title, category: category,
                                      delta: bytes - old, isNew: false, isCategory: true))
            }
        }
        for f in counted where base.categories[f.category] != nil {
            let delta = f.bytes - (base.items[f.id]?.bytes ?? 0)
            if delta >= minimum {
                changes.append(Change(id: f.id, title: f.title, category: f.category, delta: delta,
                                      isNew: base.items[f.id] == nil, isCategory: false))
            }
        }
        changes.sort { $0.delta > $1.delta }
        return Growth(since: base.date, changes: Array(changes.prefix(limit)))
    }

    // MARK: Folders

    /// Records a folder's size; one sample per folder per day.
    public mutating func record(folder path: String, bytes: Int64, at date: Date = Date()) {
        var samples = folders[path] ?? []
        if let last = samples.last, Calendar.current.isDate(last.date, inSameDayAs: date) { samples.removeLast() }
        samples.append(Sample(date: date, bytes: bytes))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        folders[path] = samples
    }

    /// How much a folder changed since a sample from at least 20 hours ago.
    public func change(of path: String, now bytes: Int64, at date: Date = Date()) -> (delta: Int64, since: Date)? {
        guard let base = folders[path]?.last(where: { $0.date <= date.addingTimeInterval(-Self.baselineAge) }) else {
            return nil
        }
        return (bytes - base.bytes, base.date)
    }

    // MARK: Storage

    public static var defaultLocation: URL {
        ScanReport.defaultLocation.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    public static func load(from url: URL = defaultLocation) -> History {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(History.self, from: $0) } ?? History()
    }

    public func save(to url: URL = defaultLocation) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fm = FileManager()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Also for a folder made by an older version with default permissions.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try encoder.encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension Category {
    /// Apps and the Trash change for reasons that aren't news ("an app updated", "you deleted things").
    var countsTowardGrowth: Bool { self != .apps && self != .trash }
}
