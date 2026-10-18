import Foundation

/// Finds which code projects mention each downloaded model, e.g. `from_pretrained("Qwen/Qwen2.5-7B")`
/// or `ollama.chat(model="llama3.2:3b")`, so the models list can say "used by my-app" or "not
/// mentioned in any project".
///
/// Reads small text files only (source, notebooks, configs) and skips dependency folders, whose
/// library code mentions popular models without using them. Bounded by a file count and a time
/// budget; when a budget runs out, the result says so instead of claiming a model is unused.
public struct ModelUsageScanner: Sendable {
    public var roots: [URL]
    public var home: URL
    public var maxFiles = 80_000
    public var maxFileBytes = 1_000_000
    public var timeBudget: TimeInterval = 15

    public init(roots: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.roots = roots
        self.home = home
    }

    public struct Usage: Sendable {
        /// Project folders that mention the model, per lowercased model name.
        public var projects: [String: Set<URL>]
        /// False when the file or time budget ran out before every file was read.
        public var complete: Bool
    }

    static let textExtensions: Set<String> = [
        "py", "ipynb", "js", "mjs", "cjs", "ts", "tsx", "jsx", "json", "yaml", "yml", "toml", "sh", "swift",
        "rs", "go", "java", "kt", "rb", "cfg", "ini", "env", "txt",
    ]
    static let skippedFolders: Set<String> = ProjectScanner.artifactNames.union([
        "site-packages", "dist", "venv", "env", "Library", "Applications", "Pictures", "Music", "Movies",
        // Data and vendored code: many files, none of them the code that loads a model.
        "data", "raw", "vendor", "third_party", "outputs", "output", "logs", "wandb", "runs", "checkpoints",
        "images", "frames", "samples",
    ])

    static func isSkipped(folder name: String) -> Bool {
        let lower = name.lowercased()
        return skippedFolders.contains(name) || skippedFolders.contains(lower) || lower.contains("dataset")
    }
    static let projectMarkers = [".git", "pyproject.toml", "package.json", "requirements.txt", "setup.py", "Cargo.toml"]

    /// Adds "used by" evidence to model findings (Hugging Face repos and Ollama models).
    public func annotate(_ findings: [Finding]) async -> [Finding] {
        let names = findings.compactMap(Self.modelName)
        guard !names.isEmpty else { return findings }
        let usage = await scan(for: Set(names.map { $0.lowercased() }))
        return findings.map { finding in
            guard let name = Self.modelName(finding)?.lowercased() else { return finding }
            var f = finding
            let projects = (usage.projects[name] ?? []).sorted { $0.path < $1.path }
            if projects.isEmpty {
                f.details["usedIn"] = usage.complete ? "No project mentions it" : "Not found in the projects checked"
                if usage.complete { f.reason += " None of your code projects mention it." }
            } else {
                let described = projects.prefix(5).map { project -> String in
                    let info = ProjectInfo.inspect(project)
                    let ago = info.idleDays.map { " (last touched \(Activity.describe(days: $0)))" } ?? ""
                    return project.lastPathComponent + ago
                }
                f.details["usedIn"] = described.joined(separator: ", ") + (projects.count > 5 ? ", and \(projects.count - 5) more" : "")
                f.details["usedInFirst"] = projects[0].lastPathComponent
                f.reason += " Used by \(ListFormatter.localizedString(byJoining: projects.prefix(3).map(\.lastPathComponent)))."
            }
            return f
        }
    }

    /// The name code would use to load the model: `org/name` for Hugging Face, `name:tag` for Ollama.
    static func modelName(_ finding: Finding) -> String? {
        guard finding.category == .models else { return nil }
        switch finding.details["kind"] {
        case "Hugging Face model", "Hugging Face dataset", "Hugging Face space": return finding.details["repo"]
        case "Ollama model": return finding.title
        default: return nil
        }
    }

    /// Wanted names, plus the bare name of Ollama models tagged `latest` (usually written untagged).
    static func lookupTable(_ wanted: Set<String>) -> [String: String] {
        var lookup: [String: String] = [:]
        for name in wanted {
            lookup[name] = name
            if name.hasSuffix(":latest") {
                let bare = String(name.dropLast(7))
                if bare.count >= 4 { lookup[bare] = name }
            }
        }
        return lookup
    }

    /// Folders matched per model name, from one walk of one subtree.
    struct Partial: Sendable {
        var folders: [String: Set<URL>] = [:]
        var complete = true
    }

    /// Reads candidate files once, looking up every token against the wanted names. Subtrees two
    /// levels below each root are walked in parallel; files above that level are read directly.
    public func scan(for wanted: Set<String>) async -> Usage {
        let lookup = Self.lookupTable(wanted)
        let deadline = Date().addingTimeInterval(timeBudget)
        var units: [URL] = []
        var loose: [URL] = []
        for root in roots { collect(root, depth: 1, units: &units, files: &loose) }

        var merged = Partial()
        for file in loose { record(file, lookup: lookup, into: &merged) }
        await withTaskGroup(of: Partial.self) { group in
            var next = 0
            func enqueue() {
                guard next < units.count else { return }
                let unit = units[next]
                next += 1
                group.addTask { walk(unit, lookup: lookup, deadline: deadline, maxFiles: maxFiles) }
            }
            for _ in 0..<min(8, units.count) { enqueue() }
            while let partial = await group.next() {
                for (name, folders) in partial.folders { merged.folders[name, default: []].formUnion(folders) }
                merged.complete = merged.complete && partial.complete
                enqueue()
            }
        }

        var projectOf: [URL: URL] = [:]
        var projects: [String: Set<URL>] = [:]
        for (name, folders) in merged.folders {
            projects[name] = Set(folders.map { projectRoot(of: $0, cache: &projectOf) })
        }
        return Usage(projects: projects, complete: merged.complete)
    }

    /// Splits the tree into work units: folders at depth 2 become units, shallower files are listed.
    private func collect(_ dir: URL, depth: Int, units: inout [URL], files: inout [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let children = (try? FileManager().contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])) ?? []
        for child in children {
            guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true,
                  v.isPackage != true else { continue }
            if v.isDirectory == true {
                guard !isExcludedFolder(child) else { continue }
                if depth >= 2 { units.append(child) } else { collect(child, depth: depth + 1, units: &units, files: &files) }
            } else if Self.textExtensions.contains(child.pathExtension.lowercased()) {
                files.append(child)
            }
        }
    }

    private func isExcludedFolder(_ url: URL) -> Bool {
        Self.isSkipped(folder: url.lastPathComponent)
            || FileManager().fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
    }

    private func walk(_ unit: URL, lookup: [String: String], deadline: Date, maxFiles: Int) -> Partial {
        var partial = Partial()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let walker = FileManager().enumerator(at: unit, includingPropertiesForKeys: keys,
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                              errorHandler: { _, _ in true })
        var entries = 0
        var files = 0
        while let url = walker?.nextObject() as? URL {
            entries += 1
            if entries % 512 == 0, Date() > deadline || Task.isCancelled {
                partial.complete = false
                break
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                if isExcludedFolder(url) { walker?.skipDescendants() }
                continue
            }
            guard Self.textExtensions.contains(url.pathExtension.lowercased()),
                  (v.fileSize ?? 0) <= maxFileBytes else { continue }
            files += 1
            if files > maxFiles {
                partial.complete = false
                break
            }
            record(url, lookup: lookup, into: &partial)
        }
        return partial
    }

    private func record(_ file: URL, lookup: [String: String], into partial: inout Partial) {
        guard let data = try? Data(contentsOf: file), data.count <= maxFileBytes else { return }
        let plain = lookup.keys.filter { !$0.contains("/") && !$0.contains(":") }.map(\.count)
        let plainLengths = plain.min().map { $0...plain.max()! }
        Self.forEachCandidate(in: data, plainLengths: plainLengths) { token in
            if let name = lookup[token] { partial.folders[name, default: []].insert(file.deletingLastPathComponent()) }
        }
    }

    /// Splits text into runs of name characters and yields each run, its `/`-separated parts, and
    /// each pair of adjacent parts (`models/Qwen/Qwen2.5-7B` yields `qwen/qwen2.5-7b`). Lowercased.
    /// Runs without `/` or `:` are only yielded when `plainLengths` allows their length (bare
    /// Ollama names), which keeps ordinary words from costing an allocation.
    static func forEachCandidate(in data: Data, plainLengths: ClosedRange<Int>? = nil, _ visit: (String) -> Void) {
        func isNameByte(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x2F || b == 0x3A  // - . _ / :
        }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var start = -1
            var separated = false
            for i in 0...buffer.count {
                let b = i < buffer.count ? buffer[i] : 0
                if isNameByte(b) {
                    if start < 0 { start = i; separated = false }
                    if b == 0x2F || b == 0x3A { separated = true }
                    continue
                }
                guard start >= 0 else { continue }
                defer { start = -1 }
                let length = i - start
                guard length >= 3, length <= 200 else { continue }
                if !separated {
                    if let plainLengths, plainLengths.contains(length) {
                        visit(String(decoding: buffer[start..<i], as: UTF8.self).lowercased())
                    }
                    continue
                }
                let run = String(decoding: buffer[start..<i], as: UTF8.self).lowercased()
                visit(run)
                let parts = run.split(separator: "/")
                guard parts.count > 1 else { continue }
                for (index, part) in parts.enumerated() {
                    visit(String(part))
                    if index + 1 < parts.count { visit("\(part)/\(parts[index + 1])") }
                }
            }
        }
    }

    /// Nearest folder with a project marker, up to (not including) the home folder; otherwise the
    /// file's own folder.
    func projectRoot(of dir: URL, cache: inout [URL: URL]) -> URL {
        if let known = cache[dir] { return known }
        let fm = FileManager()
        let homePath = home.resolvedPath
        var current = URL(fileURLWithPath: dir.resolvedPath)
        var result = dir
        while current.path.hasPrefix(homePath + "/") {
            if Self.projectMarkers.contains(where: { fm.fileExists(atPath: current.appendingPathComponent($0).path) }) {
                result = current
                break
            }
            current.deleteLastPathComponent()
        }
        cache[dir] = result
        return result
    }
}
