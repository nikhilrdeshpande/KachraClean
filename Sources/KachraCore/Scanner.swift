import Foundation

/// Runs all scanners and assembles a report. Read-only: nothing on disk is modified.
public struct Scanner: Sendable {
    public struct Options: Sendable {
        public var categories: Set<Category>
        /// Where to look for code projects. Defaults to the home folder.
        public var projectRoots: [URL]
        public var downloads: URL
        public var idleDays: Int
        public var unusedAppDays: Int

        public init(
            categories: Set<Category> = Set(Category.allCases),
            projectRoots: [URL]? = nil,
            downloads: URL? = nil,
            idleDays: Int = 30,
            unusedAppDays: Int = 180,
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) {
            self.categories = categories
            self.projectRoots = projectRoots ?? [home]
            self.downloads = downloads ?? home.appendingPathComponent("Downloads")
            self.idleDays = idleDays
            self.unusedAppDays = unusedAppDays
        }
    }

    public var options: Options
    public var home: URL

    public init(options: Options = Options(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.options = options
        self.home = home
    }

    public func run(progress: (@Sendable (String) -> Void)? = nil) async throws -> ScanReport {
        let rules = try RuleSet.bundled()
        let wanted = options.categories
        var findings: [Finding] = []
        var timings: [String: Double] = [:]

        func timed(_ name: String, _ work: () async -> [Finding]) async {
            progress?(name)
            let start = Date()
            findings += await work()
            timings[name] = Date().timeIntervalSince(start)
        }

        if !wanted.isDisjoint(with: [.toolCaches, .models, .logs, .trash]) {
            await timed("known locations") { await RuleScanner(rules: rules, home: home).scan() }
        }
        if !wanted.isDisjoint(with: [.appCaches, .toolCaches]) {
            await timed("app caches") {
                await AppCacheScanner(home: home, claimed: rules.claimedPaths(home: home)).scan()
            }
        }
        if wanted.contains(.projectArtifacts) {
            await timed("projects") {
                await ProjectScanner(options: .init(roots: options.projectRoots, idleDays: options.idleDays),
                                     home: home).scan()
            }
        }
        if wanted.contains(.duplicates) {
            await timed("duplicates") { await DuplicateScanner(roots: [options.downloads]).scan() }
        }
        if wanted.contains(.apps) {
            await timed("apps") { await AppScanner(home: home, unusedDays: options.unusedAppDays).scan() }
        }

        findings = findings
            .filter { wanted.contains($0.category) }
            .sorted { $0.bytes > $1.bytes }
        return ScanReport(findings: findings, volume: VolumeInfo.current(for: home), timings: timings)
    }
}

extension ScanReport {
    /// Bytes that cleaning could reclaim. Apps and the Trash are informational and excluded.
    public var reclaimable: Int64 {
        findings.filter { $0.category != .apps && $0.category != .trash }.reduce(0) { $0 + $1.bytes }
    }

    public static func load(from url: URL) throws -> ScanReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScanReport.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager().createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static var defaultLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KachraClean/last-scan.json")
    }
}
