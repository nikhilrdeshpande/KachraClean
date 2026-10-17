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
        /// Without Full Disk Access, opening some folders makes macOS show a consent prompt and
        /// blocks the scan until it's answered. Limited mode skips those locations.
        public var avoidProtectedLocations: Bool

        public init(
            categories: Set<Category> = Set(Category.allCases),
            projectRoots: [URL]? = nil,
            downloads: URL? = nil,
            idleDays: Int = 30,
            unusedAppDays: Int = 180,
            avoidProtectedLocations: Bool = false,
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) {
            self.categories = categories
            self.projectRoots = projectRoots ?? [home]
            self.downloads = downloads ?? home.appendingPathComponent("Downloads")
            self.idleDays = idleDays
            self.unusedAppDays = unusedAppDays
            self.avoidProtectedLocations = avoidProtectedLocations
        }
    }

    public var options: Options
    public var home: URL

    public init(options: Options = Options(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.options = options
        self.home = home
    }

    public enum Step: String, Sendable, CaseIterable {
        case knownLocations = "known locations"
        case appCaches = "app caches"
        case projects = "projects"
        case duplicates = "duplicates"
        case apps = "apps"

        public var title: String {
            switch self {
            case .knownLocations: "Developer tools, models & logs"
            case .appCaches: "App caches"
            case .projects: "Code projects"
            case .duplicates: "Duplicate downloads"
            case .apps: "Applications"
            }
        }
    }

    public enum Progress: Sendable {
        case started(Step)
        case finished(Step, found: Int64)
    }

    /// Steps that will run for the current options, in order.
    public var plannedSteps: [Step] {
        let wanted = options.categories
        var steps: [Step] = []
        if !wanted.isDisjoint(with: [.toolCaches, .models, .logs, .trash]) { steps.append(.knownLocations) }
        if !wanted.isDisjoint(with: [.appCaches, .toolCaches]) { steps.append(.appCaches) }
        if wanted.contains(.projectArtifacts) { steps.append(.projects) }
        if wanted.contains(.duplicates) { steps.append(.duplicates) }
        if wanted.contains(.apps) { steps.append(.apps) }
        return steps
    }

    public func run(progress: (@Sendable (Progress) -> Void)? = nil) async throws -> ScanReport {
        let rules = try RuleSet.bundled()
        let wanted = options.categories
        var findings: [Finding] = []
        var timings: [String: Double] = [:]

        func timed(_ step: Step, _ work: () async -> [Finding]) async {
            guard !Task.isCancelled else { return }
            progress?(.started(step))
            let start = Date()
            let found = await work()
            findings += found
            timings[step.rawValue] = Date().timeIntervalSince(start)
            let counted = found.filter { $0.category != .apps && $0.category != .trash }
            progress?(.finished(step, found: counted.reduce(0) { $0 + $1.bytes }))
        }

        if !wanted.isDisjoint(with: [.toolCaches, .models, .logs, .trash]) {
            await timed(.knownLocations) { await RuleScanner(rules: rules, home: home, avoidProtected: options.avoidProtectedLocations).scan() }
        }
        if !wanted.isDisjoint(with: [.appCaches, .toolCaches]) {
            await timed(.appCaches) {
                await AppCacheScanner(home: home, claimed: rules.claimedPaths(home: home),
                                avoidProtected: options.avoidProtectedLocations).scan()
            }
        }
        if wanted.contains(.projectArtifacts) {
            await timed(.projects) {
                await ProjectScanner(options: .init(roots: options.projectRoots, idleDays: options.idleDays),
                                     home: home).scan()
            }
        }
        if wanted.contains(.duplicates) {
            await timed(.duplicates) { await DuplicateScanner(roots: [options.downloads]).scan() }
        }
        if wanted.contains(.apps) {
            await timed(.apps) { await AppScanner(home: home, unusedDays: options.unusedAppDays,
                                 avoidProtected: options.avoidProtectedLocations).scan() }
        }

        try Task.checkCancellation()
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
