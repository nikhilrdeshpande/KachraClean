import Foundation

/// Lists downloaded AI models one by one: Hugging Face repos (models and datasets) and Ollama
/// models, with exact sizes and last-use times.
///
/// Both stores deduplicate data into shared blob folders and point to it from per-model folders
/// (Hugging Face via snapshot symlinks, Ollama via JSON manifests). Moving a model's folder to the
/// Trash would therefore free nothing; a finding's paths are the model's own folder/manifest
/// *plus the blobs no other model uses*. Blobs no model references at all are reported as orphans.
/// This reads the same on-disk layout `hf cache ls` and `ollama list` use, without needing either tool.
public struct ModelScanner: Sendable {
    public var home: URL
    public var environment: [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    /// Roots this scanner owns; other scanners must skip them.
    public var claimedPaths: Set<String> { [huggingFaceHub.path, ollamaModels.path] }

    var huggingFaceHub: URL {
        if let hub = environment["HF_HUB_CACHE"] ?? environment["HUGGINGFACE_HUB_CACHE"] { return URL(fileURLWithPath: hub) }
        if let hfHome = environment["HF_HOME"] { return URL(fileURLWithPath: hfHome).appendingPathComponent("hub") }
        return home.appendingPathComponent(".cache/huggingface/hub")
    }

    var ollamaModels: URL {
        environment["OLLAMA_MODELS"].map(URL.init(fileURLWithPath:)) ?? home.appendingPathComponent(".ollama/models")
    }

    public func scan() async -> [Finding] {
        huggingFace() + ollama()
    }

    // MARK: - Shared accounting

    struct Blob {
        var bytes: Int64
        var accessed: Date?
        var modified: Date?
    }

    /// One model's own files plus the set of blobs it references.
    struct Entry {
        var title: String
        var ownPaths: [URL]
        var blobs: Set<String>
        var details: [String: String]
        var reason: String
        /// Every blob the model reads, including ones inside its own folder; for last-use time.
        var usage: Set<String> = []
    }

    static func blobInfo(_ path: String) -> Blob {
        let url = URL(fileURLWithPath: path)
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                                  .contentAccessDateKey, .contentModificationDateKey])
        return Blob(bytes: Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0),
                    accessed: v?.contentAccessDate, modified: v?.contentModificationDate)
    }

    /// Turns entries into findings, splitting blobs into exclusive (removed with the model) and
    /// shared (kept), and adds one finding for blobs nobody references.
    func findings(entries: [Entry], allBlobs: Set<String>, owner: String, orphanTitle: String,
                  orphanReason: String) -> [Finding] {
        var users: [String: Int] = [:]
        for e in entries { for b in e.blobs { users[b, default: 0] += 1 } }
        var info: [String: Blob] = [:]
        func blob(_ p: String) -> Blob {
            if let b = info[p] { return b }
            let b = Self.blobInfo(p)
            info[p] = b
            return b
        }

        var result: [Finding] = []
        for e in entries {
            let exclusive = e.blobs.filter { users[$0] == 1 }
            let shared = e.blobs.subtracting(exclusive)
            let bytes = exclusive.reduce(Int64(0)) { $0 + blob($1).bytes }
                + e.ownPaths.reduce(Int64(0)) { $0 + DiskUsage.allocatedSize(of: $1) }
            let lastUsed = e.blobs.union(e.usage).compactMap { blob($0).accessed }.max()
            var details = e.details
            details["files"] = String(e.blobs.union(e.usage).count)
            if !shared.isEmpty {
                details["shared"] = "\(shared.count) files (\(ByteCountFormatter.string(fromByteCount: shared.reduce(0) { $0 + blob($1).bytes }, countStyle: .file))) shared with other models, kept"
            }
            if let lastUsed { details["lastActivity"] = Activity.describe(lastUsed) }
            guard bytes > 0 else { continue }
            result.append(Finding(
                category: .models,
                title: e.title,
                owner: owner,
                paths: e.ownPaths.map(\.path) + exclusive.sorted(),
                bytes: bytes,
                safety: .review,
                reason: e.reason,
                lastActivity: lastUsed,
                details: details
            ))
        }

        let orphans = allBlobs.subtracting(users.keys)
        let orphanBytes = orphans.reduce(Int64(0)) { $0 + blob($1).bytes }
        if orphanBytes > 0 {
            result.append(Finding(
                category: .models,
                title: orphanTitle,
                owner: owner,
                paths: orphans.sorted(),
                bytes: orphanBytes,
                safety: .safe,
                reason: orphanReason,
                details: ["files": String(orphans.count)]
            ))
        }
        return result
    }

    // MARK: - Hugging Face

    func huggingFace() -> [Finding] {
        let fm = FileManager()
        let hub = huggingFaceHub
        guard let repos = try? fm.contentsOfDirectory(at: hub, includingPropertiesForKeys: nil, options: []) else { return [] }
        let cli = Self.findExecutable(["hf", "huggingface-cli"], home: home, environment: environment)
        var entries: [Entry] = []
        var allBlobs = Set<String>()
        allBlobs.formUnion(Self.files(in: hub.appendingPathComponent("blobs")))

        for repo in repos {
            let name = repo.lastPathComponent
            guard let sep = name.range(of: "--") else { continue }
            let kind = String(name[..<sep.lowerBound])  // models | datasets | spaces
            guard ["models", "datasets", "spaces"].contains(kind) else { continue }
            let id = name[sep.upperBound...].replacingOccurrences(of: "--", with: "/")
            allBlobs.formUnion(Self.files(in: repo.appendingPathComponent("blobs")))

            // Every file in every snapshot resolves (through symlinks) to a blob. Links that lead
            // outside the cache (a user's own files) are never counted, so they can't be trashed.
            var blobs = Set<String>()
            var external = 0
            let snapshots = repo.appendingPathComponent("snapshots")
            let revisions = (try? fm.contentsOfDirectory(atPath: snapshots.path))?.count ?? 0
            let insideCache = [hub.resolvedPath + "/blobs/", repo.resolvedPath + "/"]
            if let walker = fm.enumerator(at: snapshots, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
                while let file = walker.nextObject() as? URL {
                    let real = file.resolvingSymlinksInPath()
                    guard (try? real.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    if insideCache.contains(where: real.path.hasPrefix) {
                        blobs.insert(real.path)
                    } else {
                        external += 1
                    }
                }
            }
            let singular = kind == "models" ? "model" : String(kind.dropLast())
            var details = ["repo": id, "kind": singular == "model" ? "Hugging Face model" : "Hugging Face \(singular)",
                           "revisions": String(revisions)]
            if let cli { details["command"] = "\(cli.lastPathComponent) cache rm \(singular)/\(id)" }
            if external > 0 { details["external"] = "\(external) linked files outside the cache, kept" }
            entries.append(Entry(
                title: id,
                ownPaths: [repo],
                blobs: blobs,
                details: details,
                reason: singular == "model"
                    ? "Downloaded model weights. Hugging Face downloads them again on next use, which can take a while for large models; gated models need a login."
                    : "Downloaded \(singular). Fetched again on next use; large or gated ones take time and may need a login."
            ))
        }
        // Blobs inside repo folders are already covered by removing the repo folder itself.
        let inRepoBlob: (String) -> Bool = { path in entries.contains { e in e.ownPaths.contains { path.hasPrefix($0.resolvedPath + "/") } } }
        for i in entries.indices {
            entries[i].usage = entries[i].blobs
            entries[i].blobs = entries[i].blobs.filter { !inRepoBlob($0) }
        }
        let orphanCandidates = allBlobs.filter { !inRepoBlob($0) }

        return findings(entries: entries, allBlobs: orphanCandidates, owner: "Hugging Face",
                        orphanTitle: "Unreferenced Hugging Face files",
                        orphanReason: "Leftover downloads no model or dataset points to anymore (old revisions, interrupted downloads). Same as `hf cache prune`.")
    }

    // MARK: - Ollama

    func ollama() -> [Finding] {
        let root = ollamaModels
        let manifests = root.appendingPathComponent("manifests")
        let blobsDir = root.appendingPathComponent("blobs").resolvingSymlinksInPath()
        let fm = FileManager()
        guard fm.fileExists(atPath: manifests.path) else { return [] }

        struct Manifest: Decodable {
            struct Layer: Decodable { var digest: String }
            var layers: [Layer]?
            var config: Layer?
        }
        var entries: [Entry] = []
        if let walker = fm.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
            while let file = walker.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: file),
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
                // manifests/<registry>/<namespace>/<model>/<tag>
                let parts = file.path.dropFirst(manifests.path.count + 1).split(separator: "/").map(String.init)
                guard parts.count >= 4 else { continue }
                let namespace = parts[1], model = parts[2], tag = parts[3]
                let name = (namespace == "library" ? model : "\(namespace)/\(model)") + ":" + tag
                let digests = (manifest.layers ?? []).map(\.digest) + [manifest.config?.digest].compactMap { $0 }
                let blobs = Set(digests.compactMap(Self.blobName(forDigest:)).map { blobsDir.appendingPathComponent($0).path }
                    .filter { fm.fileExists(atPath: $0) })
                entries.append(Entry(
                    title: name,
                    ownPaths: [file],
                    blobs: blobs,
                    details: ["kind": "Ollama model", "command": "ollama rm \(name)"],
                    reason: "Local LLM weights. Restore with `ollama pull \(name)`; custom models built from a Modelfile need rebuilding."
                ))
            }
        }
        return findings(entries: entries, allBlobs: Set(Self.files(in: blobsDir)), owner: "Ollama",
                        orphanTitle: "Unreferenced Ollama files",
                        orphanReason: "Model layers no installed model uses anymore (left after `ollama rm` or failed pulls).")
    }

    // MARK: - Helpers

    /// `sha256:<64 hex>` → the blob's file name. Anything else (including path tricks such as
    /// `../`) is rejected, since manifests are just JSON files on disk.
    static func blobName(forDigest digest: String) -> String? {
        let parts = digest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "sha256", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return "sha256-\(parts[1])"
    }

    /// Files in a blob folder, as resolved paths so they compare equal to resolved symlink targets.
    static func files(in dir: URL) -> [String] {
        let resolved = dir.resolvingSymlinksInPath()
        return ((try? FileManager().contentsOfDirectory(atPath: resolved.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { resolved.appendingPathComponent($0).path }
    }

    /// Finds a CLI on PATH or in common user install locations (pipx/uv tools, Homebrew).
    static func findExecutable(_ names: [String], home: URL, environment: [String: String]) -> URL? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let dirs = path + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        for name in names {
            for dir in dirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager().isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
