import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Big personal files (videos, disk images, archives, datasets, VM disks, ...) anywhere in the
/// home folder, found through Spotlight in well under a second, with a folder walk as fallback
/// when indexing is off. Model weights stored outside the managed caches (ComfyUI, mflux, ...)
/// are reported under AI models, one finding per model folder.
///
/// These are the user's own files, so every finding is `review`: never pre-selected.
public struct LargeFileScanner: Sendable {
    public var home: URL
    public var minimumBytes: Int64
    /// Paths other scanners own (model stores, rule locations); anything inside is skipped.
    public var excluded: Set<String>

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                minimumBytes: Int64 = 500_000_000, excluded: Set<String> = []) {
        self.home = home
        self.minimumBytes = minimumBytes
        self.excluded = excluded
    }

    public enum Kind: String, Sendable {
        case video = "Video"
        case audio = "Audio"
        case diskImage = "Disk image or installer"
        case archive = "Archive"
        case dataset = "Dataset"
        case virtualMachine = "Virtual machine disk"
        case modelWeights = "Model weights"
        case other = "Large file"
    }

    public func scan() async -> [Finding] {
        let paths = spotlightCandidates() ?? walkCandidates()
        var loose: [URL: [URL]] = [:]  // model folder -> weight files
        var findings: [Finding] = []
        for url in paths where !isExcluded(url) {
            let kind = Self.kind(of: url)
            if kind == .modelWeights {
                // Sharded models (<model>/transformer/0.safetensors) are grouped per model folder;
                // in flat folders (ComfyUI's checkpoints/) each file is its own model.
                loose[Self.modelFolder(for: url) ?? url, default: []].append(url)
            } else {
                findings.append(finding(for: url, kind: kind))
            }
        }
        for (folder, files) in loose {
            findings.append(modelFinding(folder: folder, files: files))
        }
        return findings
    }

    // MARK: - Findings

    func finding(for url: URL, kind: Kind) -> Finding {
        let bytes = DiskUsage.allocatedSize(of: url)
        let lastOpened = Self.lastOpened(url)
        var details = ["kind": kind.rawValue, "folder": PathUtil.display(url.deletingLastPathComponent(), home: home)]
        let opened = lastOpened.map { "Last opened \(Self.dateFormatter.string(from: $0))." } ?? "macOS has no record of it being opened."
        if let lastOpened {
            let days = Int(Date().timeIntervalSince(lastOpened) / 86_400)
            details["lastActivity"] = days == 0 ? "today" : "\(days) days ago"
        }
        let advice: String
        switch kind {
        case .video, .audio: advice = "Your own media; only you can tell if you still need it. Consider moving it to an external drive."
        case .diskImage: advice = "Installers and disk images are usually not needed once the app is installed."
        case .archive: advice = "Check whether the extracted copy already exists before removing the archive."
        case .dataset: advice = "Data files from a project or notebook. Remove only if you can regenerate or re-download them."
        case .virtualMachine: advice = "A virtual machine's disk. Removing it deletes everything inside that VM."
        case .modelWeights, .other: advice = "A large file. Check what it is before removing it."
        }
        return Finding(
            category: .largeFiles,
            title: url.lastPathComponent,
            owner: kind.rawValue,
            paths: [url.path],
            bytes: bytes,
            safety: .review,
            reason: "\(opened) \(advice)",
            lastActivity: lastOpened,
            details: details
        )
    }

    func modelFinding(folder: URL, files: [URL]) -> Finding {
        let bytes = DiskUsage.allocatedSize(of: folder)
        let lastUsed = files.compactMap { (try? $0.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate }.max()
        let isFile = (try? folder.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        var details = ["kind": isFile ? "Model weights file" : "Model weights (outside managed caches)",
                       "folder": PathUtil.display(folder, home: home), "files": String(files.count)]
        if let lastUsed {
            let days = Int(Date().timeIntervalSince(lastUsed) / 86_400)
            details["lastActivity"] = days == 0 ? "today" : "\(days) days ago"
        }
        return Finding(
            category: .models,
            title: Self.displayName(for: folder),
            owner: folder.deletingLastPathComponent().lastPathComponent,
            paths: [folder.path],
            bytes: bytes,
            safety: .review,
            reason: "Model weights saved by a tool such as ComfyUI or mflux, outside any download cache. Remove only if you can download or convert them again.",
            lastActivity: lastUsed,
            details: details
        )
    }

    // MARK: - Discovery

    /// Spotlight query for big files in the home folder. Nil when Spotlight can't answer
    /// (indexing off), so the caller falls back to walking.
    func spotlightCandidates() -> [URL]? {
        let text = "kMDItemFSSize > \(minimumBytes)" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, nil, nil) else { return nil }
        MDQuerySetSearchScope(query, [home.path] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        let count = MDQueryGetResultCount(query)
        var urls: [URL] = []
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        // An empty answer from a Mac with indexing disabled looks the same as "no big files";
        // only trust Spotlight when it found something.
        return urls.isEmpty ? nil : urls
    }

    func walkCandidates() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isPackageKey]
        var result: [URL] = []
        let walker = FileManager().enumerator(at: home, includingPropertiesForKeys: keys,
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                              errorHandler: { _, _ in true })
        while let url = walker?.nextObject() as? URL {
            if Task.isCancelled { break }
            if url.deletingLastPathComponent() == home, url.lastPathComponent == "Library" {
                walker?.skipDescendants()
                continue
            }
            if Self.skippedFolderNames.contains(url.lastPathComponent) {
                walker?.skipDescendants()
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  Int64(v.fileSize ?? 0) >= minimumBytes else { continue }
            result.append(url)
        }
        return result
    }

    /// Project artifacts and app bundles belong to other categories.
    static let skippedFolderNames: Set<String> = [
        "node_modules", ".venv", "venv", "__pycache__", "target", "Pods", ".git", "DerivedData",
    ]

    func isExcluded(_ url: URL) -> Bool {
        let path = url.path
        if path.hasPrefix(home.appendingPathComponent("Library").path + "/") { return true }
        if path.hasPrefix(home.appendingPathComponent(".Trash").path + "/") { return true }
        let components = url.pathComponents
        if components.contains(where: { $0.hasSuffix(".app") || Self.skippedFolderNames.contains($0) }) { return true }
        // Inside a Python environment, whatever it's called.
        if components.indices.contains(where: { i in
            FileManager().fileExists(atPath: NSString.path(withComponents: Array(components[...i]) + ["pyvenv.cfg"]))
        }) { return true }
        return excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Classification

    static let modelExtensions: Set<String> = ["safetensors", "gguf", "ckpt", "pt", "pth", "onnx", "mlpackage", "ggml"]
    static let datasetExtensions: Set<String> = ["parquet", "arrow", "npz", "npy", "pkl", "pickle", "h5", "hdf5", "feather", "tfrecord"]
    static let vmExtensions: Set<String> = ["vmdk", "qcow2", "vdi", "vhd", "vhdx", "utm", "pvm", "sparseimage", "sparsebundle"]

    static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if modelExtensions.contains(ext) { return .modelWeights }
        if ext == "bin", url.pathComponents.contains(where: { ["models", "checkpoints", "weights"].contains($0.lowercased()) }) {
            return .modelWeights
        }
        if datasetExtensions.contains(ext) { return .dataset }
        if vmExtensions.contains(ext) || url.lastPathComponent == "rootfs.img" { return .virtualMachine }
        if ["dmg", "iso", "pkg", "mpkg", "xip"].contains(ext) { return .diskImage }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .diskImage) { return .diskImage }
        if type.conforms(to: .archive) { return .archive }
        return .other
    }

    /// Groups sharded weights: `<model>/transformer/0.safetensors` belongs to `<model>`.
    static func modelFolder(for file: URL) -> URL? {
        let parent = file.deletingLastPathComponent()
        let componentFolders: Set<String> = ["transformer", "text_encoder", "text_encoder_2", "vae", "unet",
                                             "tokenizer", "tokenizer_2", "scheduler", "image_encoder"]
        return componentFolders.contains(parent.lastPathComponent.lowercased()) ? parent.deletingLastPathComponent() : nil
    }

    /// "model.safetensors" says nothing; name it after the nearest meaningful folder instead.
    static func displayName(for url: URL) -> String {
        let generic: Set<String> = ["model", "models", "checkpoints", "weights", "transformer", "pytorch_model",
                                    "diffusion_pytorch_model", "adapter_model", "model-00001-of-00002"]
        let stem = (url.lastPathComponent as NSString).deletingPathExtension.lowercased()
        guard generic.contains(stem) else { return url.lastPathComponent }
        var folder = url.deletingLastPathComponent()
        while generic.contains(folder.lastPathComponent.lowercased()), folder.pathComponents.count > 2 {
            folder = folder.deletingLastPathComponent()
        }
        return "\(folder.lastPathComponent) · \(url.lastPathComponent)"
    }

    static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }
}
