import Foundation

/// Moves findings to the Trash. Nothing is ever deleted directly.
///
/// Every path is checked again here, independently of the scanner that produced it: findings can
/// come from a saved report on disk, which may be stale or edited, so the cleaner never trusts them.
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
    /// Locations rules may clean (tool caches, model stores), `~` expanded.
    let rulePaths: [Category: [String]]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, dryRun: Bool = true) {
        self.home = home
        self.dryRun = dryRun
        let rules = (try? RuleSet.bundled())?.rules ?? []
        var paths: [Category: [String]] = [:]
        for rule in rules {
            paths[rule.category, default: []] += rule.paths.map { PathUtil.expand($0, home: home).resolvedPath }
        }
        rulePaths = paths
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
        let path = url.resolvedPath
        let homePath = home.resolvedPath
        if category == .trash { return "The Trash is only reported; empty it yourself in Finder." }
        if category == .apps, path.hasPrefix("/Applications/") || path.hasPrefix(homePath + "/Applications/") {
            // Apps live outside home; they may only be trashed as whole bundles in known folders.
            return path.hasSuffix(".app") && !path.dropLast(4).contains(".app/")
                ? nil : "Only whole .app bundles can be removed."
        }
        guard path.hasPrefix(homePath + "/") else { return "Outside your home folder." }
        let parts = path.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
        // Never remove a top-level home folder (Documents, Library, Desktop, ...) or ~/Library/<area>.
        if parts.count < 2 { return "Top-level folder in your home; refusing." }
        if parts[0] == "Library", parts.count < 3 { return "Top-level Library folder; refusing." }
        if let reason = Self.sensitivity(of: parts) { return reason }
        if !FileManager().fileExists(atPath: path) { return "No longer exists." }
        return mismatch(path: path, parts: parts, category: category)
    }

    // MARK: - Guards

    /// Credentials, keychains, mail and cloud-synced folders: never cleaned, whatever a finding says.
    static func sensitivity(of parts: [String]) -> String? {
        let joined = parts.joined(separator: "/")
        let protectedAreas = ["Library/Keychains", "Library/Mail", "Library/Messages", "Library/Mobile Documents",
                              "Library/CloudStorage", "Library/Application Support/com.apple.TCC"]
        if protectedAreas.contains(where: { joined == $0 || joined.hasPrefix($0 + "/") }) {
            return "Holds mail, messages, keychains or cloud-synced files; refusing."
        }
        if parts.contains(where: secretFolders.contains) { return "Holds keys or credentials; refusing." }
        let name = parts.last ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if secretFiles.contains(name) || secretExtensions.contains(ext) {
            return "Looks like a credential or key file; refusing."
        }
        return nil
    }

    static let secretFolders: Set<String> = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".password-store", ".docker"]
    static let secretFiles: Set<String> = ["token", "stored_tokens", "credentials", "credentials.json", ".netrc",
                                           ".git-credentials", ".npmrc", ".pypirc"]
    static let secretExtensions: Set<String> = ["pem", "p12", "pfx", "keychain", "keychain-db"]

    /// Each category may only clean the kind of item its scanner produces.
    func mismatch(path: String, parts: [String], category: Category) -> String? {
        let fm = FileManager()
        func under(_ prefixes: [String]) -> Bool {
            prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDirectory)
        let homePath = home.resolvedPath
        switch category {
        case .appCaches:
            return under([homePath + "/Library/Caches"]) ? nil : "Not inside Library/Caches."
        case .logs:
            return under([homePath + "/Library/Logs"]) ? nil : "Not inside Library/Logs."
        case .toolCaches:
            let allowed = (rulePaths[.toolCaches] ?? []) + [homePath + "/Library/Caches", homePath + "/.cache"]
            return under(allowed) ? nil : "Not a known tool cache location."
        case .projectArtifacts:
            let name = parts.last ?? ""
            let isArtifact = ProjectScanner.artifactNames.contains(name)
                || fm.fileExists(atPath: path + "/pyvenv.cfg")
            return isDirectory.boolValue && isArtifact ? nil : "Not a recognised dependency or build folder."
        case .duplicates, .largeFiles:
            return isDirectory.boolValue ? "Expected a single file, found a folder." : nil
        case .apps:
            return parts[0] == "Library" ? nil : "App data must be inside Library."
        case .models, .trash:
            return nil
        }
    }
}

extension URL {
    /// Absolute path with `.`/`..` and symbolic links resolved, for safe prefix comparisons.
    var resolvedPath: String { standardizedFileURL.resolvingSymlinksInPath().path }
}
