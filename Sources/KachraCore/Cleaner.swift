import Foundation

/// Moves findings to the Trash. Nothing is ever deleted directly.
public struct Cleaner: Sendable {
    public struct Outcome: Sendable {
        public var findingID: String
        public var path: String
        /// Where the item ended up in the Trash, or nil for a dry run / failure.
        public var trashedTo: String?
        public var error: String?
    }

    public var home: URL
    public var dryRun: Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, dryRun: Bool = true) {
        self.home = home
        self.dryRun = dryRun
    }

    public func clean(_ findings: [Finding]) -> [Outcome] {
        var outcomes: [Outcome] = []
        for finding in findings {
            for path in finding.paths {
                let url = URL(fileURLWithPath: path)
                if let problem = refusal(for: url, category: finding.category) {
                    outcomes.append(Outcome(findingID: finding.id, path: path, trashedTo: nil, error: problem))
                    continue
                }
                if dryRun {
                    outcomes.append(Outcome(findingID: finding.id, path: path, trashedTo: nil, error: nil))
                    continue
                }
                do {
                    var resulting: NSURL?
                    try FileManager().trashItem(at: url, resultingItemURL: &resulting)
                    outcomes.append(Outcome(findingID: finding.id, path: path, trashedTo: resulting?.path, error: nil))
                } catch {
                    outcomes.append(Outcome(findingID: finding.id, path: path, trashedTo: nil,
                                            error: error.localizedDescription))
                }
            }
        }
        return outcomes
    }

    /// Puts trashed items back where they came from (Undo). Returns the outcomes that were restored.
    @discardableResult
    public func restore(_ outcomes: [Outcome]) -> [Outcome] {
        let fm = FileManager()
        var restored: [Outcome] = []
        for outcome in outcomes {
            guard let trashed = outcome.trashedTo, !fm.fileExists(atPath: outcome.path) else { continue }
            let original = URL(fileURLWithPath: outcome.path)
            try? fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: URL(fileURLWithPath: trashed), to: original)) != nil {
                restored.append(outcome)
            }
        }
        return restored
    }

    /// Why a path must not be touched, or nil if it may go to the Trash.
    public func refusal(for url: URL, category: Category) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        if category == .trash { return "The Trash is only reported; empty it yourself in Finder." }
        if category == .apps {
            // Apps live outside home; they may only be trashed as whole bundles in known folders.
            let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(homePath + "/Applications/")
            if inApplications { return path.hasSuffix(".app") ? nil : "Only whole .app bundles can be removed." }
        }
        guard path.hasPrefix(homePath + "/") else { return "Outside your home folder." }
        let relative = String(path.dropFirst(homePath.count + 1))
        let depth = relative.split(separator: "/").count
        // Never remove a top-level home folder (Documents, Library, Desktop, ...) or ~/Library/<area>.
        if depth < 2 { return "Top-level folder in your home; refusing." }
        if relative.hasPrefix("Library/"), depth < 3 { return "Top-level Library folder; refusing." }
        if !FileManager().fileExists(atPath: path) { return "No longer exists." }
        return nil
    }
}
