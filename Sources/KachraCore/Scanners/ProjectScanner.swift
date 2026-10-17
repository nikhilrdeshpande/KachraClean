import Foundation

/// Finds dependency and build folders inside code projects (`node_modules`, Python virtualenvs,
/// framework build caches, Rust `target`, ...) and judges each one by its project's state.
///
/// This is the category commercial cleaners don't cover (see docs/spec/02).
public struct ProjectScanner: Sendable {
    public struct Options: Sendable {
        public var roots: [URL]
        /// A project untouched for this long is "idle"; its rebuildable artifacts become `safe`.
        public var idleDays: Int
        public var maxDepth: Int

        public init(roots: [URL], idleDays: Int = 30, maxDepth: Int = 12) {
            self.roots = roots
            self.idleDays = idleDays
            self.maxDepth = maxDepth
        }
    }

    enum Kind: String, Sendable {
        case nodeModules = "node_modules"
        case pythonEnv = "Python environment"
        case pycache = "Python bytecode"
        case jsBuildCache = "Framework build cache"
        case rustTarget = "Rust build output"
        case pods = "CocoaPods"
        case gradleBuild = "Gradle build output"
    }

    struct Hit: Sendable {
        var kind: Kind
        var url: URL
        var project: URL
    }

    let options: Options
    let home: URL

    public init(options: Options, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.options = options
        self.home = home
    }

    public func scan() async -> [Finding] {
        let hits = await findArtifacts()
        let sizes = await DiskUsage.allocatedSizes(of: hits.map(\.url), maxConcurrency: 8)

        // Bytecode caches are scattered through a project; report one finding per project.
        var findings: [Finding] = []
        var pycache: [URL: (urls: [URL], bytes: Int64)] = [:]
        var projects: [URL: ProjectInfo] = [:]
        for (index, hit) in hits.enumerated() where sizes[index] > 0 {
            if hit.kind == .pycache {
                let root = projectRoot(containing: hit.project)
                pycache[root, default: ([], 0)].urls.append(hit.url)
                pycache[root]!.bytes += sizes[index]
                continue
            }
            let info = projects[hit.project] ?? ProjectInfo.inspect(hit.project)
            projects[hit.project] = info
            findings.append(finding(for: hit, bytes: sizes[index], project: info))
        }
        for (project, entry) in pycache {
            findings.append(Finding(
                category: .projectArtifacts,
                title: "\(project.lastPathComponent) · Python bytecode",
                owner: project.lastPathComponent,
                paths: entry.urls.map(\.path),
                bytes: entry.bytes,
                safety: .safe,
                reason: "Compiled .pyc files. Python regenerates them automatically on the next run.",
                details: ["project": PathUtil.display(project, home: home), "kind": Kind.pycache.rawValue,
                          "folders": String(entry.urls.count)]
            ))
        }
        return findings
    }

    /// Nearest ancestor that looks like a project root (has git or a manifest), else the
    /// top-level folder under the scan root.
    func projectRoot(containing dir: URL) -> URL {
        let markers = [".git", "pyproject.toml", "setup.py", "requirements.txt", "package.json", "Cargo.toml"]
        let fm = FileManager()
        let roots = Set(options.roots.map { $0.standardizedFileURL.path })
        var current = dir.standardizedFileURL
        var topLevel = current
        while !roots.contains(current.path), current.path != "/" {
            if markers.contains(where: { fm.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                return current
            }
            topLevel = current
            current = current.deletingLastPathComponent()
        }
        return topLevel
    }

    // MARK: - Judging

    func finding(for hit: Hit, bytes: Int64, project: ProjectInfo) -> Finding {
        let idle = project.idleDays.map { $0 >= options.idleDays } ?? true
        let ago = project.idleDays.map { "\($0) days ago" } ?? "unknown"
        var details = ["project": PathUtil.display(hit.project, home: home), "kind": hit.kind.rawValue,
                       "lastActivity": ago]
        if let lock = project.lockfile { details["lockfile"] = lock }
        if project.isGitRepo { details["git"] = "yes" }

        let (safety, reason): (Safety, String)
        switch hit.kind {
        case .nodeModules:
            switch (project.lockfile, idle) {
            case (let lock?, true):
                (safety, reason) = (.safe, "Project idle since \(ago). Restore exactly from \(lock) with \(project.installCommand).")
            case (let lock?, false):
                (safety, reason) = (.review, "Project active \(ago). Restorable from \(lock), but you'd need to reinstall before working on it.")
            case (nil, _):
                (safety, reason) = (.review, "No lockfile, so a reinstall may resolve different package versions.")
            }
        case .pythonEnv:
            switch (project.pythonManifest, idle) {
            case (let manifest?, true):
                (safety, reason) = (.safe, "Project idle since \(ago). Recreate the environment from \(manifest).")
            case (let manifest?, false):
                (safety, reason) = (.review, "Project active \(ago). Recreatable from \(manifest), but you'd need to reinstall first.")
            case (nil, _):
                (safety, reason) = (.review, "No requirements or lock file found; packages may have been installed by hand.")
            }
        case .jsBuildCache, .gradleBuild:
            (safety, reason) = (.safe, "Build output and caches. Regenerated on the next build or dev-server start.")
        case .rustTarget:
            (safety, reason) = idle
                ? (.safe, "Project idle since \(ago). Cargo rebuilds this on the next build.")
                : (.review, "Project active \(ago). Cargo rebuilds this, but a full rebuild can take a while.")
        case .pods:
            (safety, reason) = project.lockfile != nil && idle
                ? (.safe, "Project idle since \(ago). Restore with `pod install` from Podfile.lock.")
                : (.review, "Restore with `pod install`; check the project still builds afterwards.")
        case .pycache:
            (safety, reason) = (.safe, "Compiled .pyc files. Python regenerates them automatically.")
        }

        // An artifact sitting directly in a scan root (e.g. ~/my-venv) is named after itself,
        // not after the root folder.
        let atRoot = options.roots.contains { $0.standardizedFileURL == hit.project.standardizedFileURL }
        let name = atRoot ? hit.url.lastPathComponent : hit.project.lastPathComponent
        return Finding(
            category: .projectArtifacts,
            title: "\(name) · \(hit.kind.rawValue)",
            owner: name,
            paths: [hit.url.path],
            bytes: bytes,
            safety: safety,
            reason: reason,
            lastActivity: project.lastActivity,
            details: details
        )
    }

    // MARK: - Walking

    func findArtifacts() async -> [Hit] {
        // Fan out over the first level below each root; each subtree is walked on its own task.
        var starts: [URL] = []
        var direct: [Hit] = []
        for root in options.roots {
            let children = (try? FileManager().contentsOfDirectory(
                at: root, includingPropertiesForKeys: Self.walkKeys, options: []
            )) ?? []
            for child in children {
                if let kind = Self.classify(child) {
                    direct.append(Hit(kind: kind, url: child, project: root))
                } else if shouldDescend(child, depth: 1, isRootLevel: root.standardizedFileURL == home.standardizedFileURL) {
                    starts.append(child)
                }
            }
        }
        let unique = Array(Set(starts))
        return await withTaskGroup(of: [Hit].self) { group in
            var running = 0
            var index = 0
            var all: [Hit] = direct
            while index < unique.count || running > 0 {
                while running < 8, index < unique.count {
                    let start = unique[index]
                    group.addTask { walk(start, depth: 1) }
                    running += 1
                    index += 1
                }
                if let hits = await group.next() {
                    all += hits
                    running -= 1
                }
            }
            return all
        }
    }

    static let walkKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]

    /// Walks a directory that is known not to be an artifact itself.
    private func walk(_ url: URL, depth: Int) -> [Hit] {
        guard depth < options.maxDepth else { return [] }
        let children = (try? FileManager().contentsOfDirectory(
            at: url, includingPropertiesForKeys: Self.walkKeys, options: []
        )) ?? []
        var hits: [Hit] = []
        for child in children {
            if let kind = Self.classify(child) {
                hits.append(Hit(kind: kind, url: child, project: url))
            } else if shouldDescend(child, depth: depth + 1, isRootLevel: false) {
                hits += walk(child, depth: depth + 1)
            }
        }
        return hits
    }

    private func shouldDescend(_ url: URL, depth: Int, isRootLevel: Bool) -> Bool {
        guard let v = try? url.resourceValues(forKeys: Set(Self.walkKeys)),
              v.isDirectory == true, v.isSymbolicLink != true, v.isPackage != true else { return false }
        let name = url.lastPathComponent
        if isRootLevel, ["Library", "Applications", "Pictures", "Music", "Movies"].contains(name) { return false }
        // Hidden folders are mostly tool state (.git, .cache, .npm); artifacts among them are
        // recognised by classify() before this check.
        if name.hasPrefix(".") { return false }
        return true
    }

    /// Recognises an artifact folder by its name *and* a marker that proves what it is.
    static func classify(_ url: URL) -> Kind? {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        let fm = FileManager()
        func parentHas(_ files: String...) -> Bool {
            files.contains { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }
        }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else { return nil }

        switch name {
        case "node_modules":
            return parentHas("package.json") ? .nodeModules : nil
        case "__pycache__":
            return .pycache
        case ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite", ".expo":
            return parentHas("package.json") ? .jsBuildCache : nil
        case "target":
            return parentHas("Cargo.toml") ? .rustTarget : nil
        case "Pods":
            return parentHas("Podfile") ? .pods : nil
        case "build", ".gradle":
            return parentHas("build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts") ? .gradleBuild : nil
        default:
            // Any folder with a pyvenv.cfg is a virtualenv, whatever it's called (.venv, venv, env, ...).
            return fm.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path) ? .pythonEnv : nil
        }
    }
}

/// Facts about the project that owns an artifact folder.
struct ProjectInfo: Sendable {
    var lockfile: String?
    var pythonManifest: String?
    var isGitRepo: Bool
    var lastActivity: Date?

    var idleDays: Int? {
        lastActivity.map { Int(Date().timeIntervalSince($0) / 86_400) }
    }

    var installCommand: String {
        switch lockfile {
        case "pnpm-lock.yaml": "pnpm install"
        case "yarn.lock": "yarn install"
        case "bun.lock", "bun.lockb": "bun install"
        default: "npm ci"
        }
    }

    static let lockfiles = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb",
                            "Cargo.lock", "Podfile.lock"]
    static let pythonManifests = ["uv.lock", "poetry.lock", "Pipfile.lock", "requirements.txt", "pyproject.toml",
                                  "Pipfile", "setup.py", "environment.yml"]
    /// Folders that don't count as "working on the project".
    static let ignoredForActivity: Set<String> = [
        "node_modules", ".venv", "venv", "env", "__pycache__", ".next", ".nuxt", ".svelte-kit", ".turbo",
        ".parcel-cache", ".vite", "target", "Pods", "build", ".gradle", "dist", ".git", ".DS_Store", ".idea",
    ]

    static func inspect(_ project: URL) -> ProjectInfo {
        let fm = FileManager()
        func has(_ name: String) -> Bool { fm.fileExists(atPath: project.appendingPathComponent(name).path) }
        let isGit = has(".git")
        return ProjectInfo(
            lockfile: lockfiles.first(where: has),
            pythonManifest: pythonManifests.first(where: has),
            isGitRepo: isGit,
            lastActivity: lastActivity(of: project, git: isGit)
        )
    }

    /// Newest modification among the project's own files (two levels deep, artifacts excluded),
    /// plus git's index and HEAD log, which change on every commit, checkout or `git add`.
    static func lastActivity(of project: URL, git: Bool) -> Date? {
        let fm = FileManager()
        var latest: Date?
        func consider(_ url: URL) {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               d > (latest ?? .distantPast) { latest = d }
        }
        if git {
            consider(project.appendingPathComponent(".git/index"))
            consider(project.appendingPathComponent(".git/logs/HEAD"))
        }
        var budget = 3_000
        func visit(_ dir: URL, depth: Int) {
            let items = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: []
            )) ?? []
            for item in items where !ignoredForActivity.contains(item.lastPathComponent) {
                budget -= 1
                if budget <= 0 { return }
                consider(item)
                if depth < 2, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    visit(item, depth: depth + 1)
                }
            }
        }
        visit(project, depth: 1)
        return latest
    }
}
