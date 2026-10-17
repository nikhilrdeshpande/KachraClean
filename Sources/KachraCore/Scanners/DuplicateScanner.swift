import CryptoKit
import Foundation

/// Byte-identical copies of the same file in Downloads (see docs/spec/03).
///
/// Staged so that most files are never read: group by size, then compare a fingerprint of the
/// first and last 64 KB, and only then hash whole files.
public struct DuplicateScanner: Sendable {
    public var roots: [URL]
    /// Files smaller than this are ignored; they free almost nothing and are often intentional.
    public var minimumBytes: Int64

    public init(roots: [URL], minimumBytes: Int64 = 100 * 1024) {
        self.roots = roots
        self.minimumBytes = minimumBytes
    }

    struct Candidate: Sendable {
        var url: URL
        var bytes: Int64
        var allocated: Int64
        var added: Date
    }

    public func scan() async -> [Finding] {
        let bySize = Dictionary(grouping: collect(), by: \.bytes).values.filter { $0.count > 1 }
        var groups: [[Candidate]] = []
        for sameSize in bySize {
            for samePartial in Dictionary(grouping: sameSize, by: { Self.partialHash($0.url) }).values
            where samePartial.count > 1 {
                groups += Dictionary(grouping: samePartial, by: { Self.fullHash($0.url) })
                    .filter { $0.key != nil && $0.value.count > 1 }
                    .map(\.value)
            }
        }
        return groups.map(finding(for:))
    }

    func finding(for group: [Candidate]) -> Finding {
        let keep = Self.chooseKeeper(group)
        let extra = group.filter { $0.url != keep.url }
        return Finding(
            category: .duplicates,
            title: keep.url.lastPathComponent,
            paths: extra.map(\.url.path),
            bytes: extra.reduce(0) { $0 + $1.allocated },
            safety: .review,
            reason: "\(group.count) identical copies. Keeping \(keep.url.lastPathComponent) in \(keep.url.deletingLastPathComponent().lastPathComponent); the others would go to the Trash.",
            lastActivity: group.map(\.added).max(),
            details: ["keep": keep.url.path, "copies": String(group.count)]
        )
    }

    /// Which copy survives:
    /// 1. one without a " (n)" suffix anywhere in its path below the scan root,
    /// 2. then the shortest path (fewest nested re-extractions),
    /// 3. then the one added first.
    static func chooseKeeper(_ group: [Candidate]) -> Candidate {
        group.min { a, b in
            let sa = hasCopySuffix(a.url), sb = hasCopySuffix(b.url)
            if sa != sb { return !sa }
            let la = a.url.pathComponents.count, lb = b.url.pathComponents.count
            if la != lb { return la < lb }
            return a.added < b.added
        }!
    }

    static func hasCopySuffix(_ url: URL) -> Bool {
        url.pathComponents.suffix(3).contains { component in
            let stem = (component as NSString).deletingPathExtension
            return stem.range(of: #" \(\d+\)$"#, options: .regularExpression) != nil
                || stem.hasSuffix(" copy")
        }
    }

    // MARK: - Collection & hashing

    private func collect() -> [Candidate] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .addedToDirectoryDateKey, .creationDateKey, .isPackageKey]
        var result: [Candidate] = []
        for root in roots {
            let enumerator = FileManager().enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
            )
            while let url = enumerator?.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.fileSize, Int64(size) >= minimumBytes else { continue }
                result.append(Candidate(
                    url: url, bytes: Int64(size),
                    allocated: Int64(v.totalFileAllocatedSize ?? size),
                    added: v.addedToDirectoryDate ?? v.creationDate ?? .distantPast
                ))
            }
        }
        return result
    }

    static func partialHash(_ url: URL, chunk: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if let end = try? handle.seekToEnd(), end > UInt64(chunk * 2) {
            try? handle.seek(toOffset: end - UInt64(chunk))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
