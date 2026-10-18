import Foundation

/// Measures folders for the Disk Explorer: every item, biggest first (docs/spec/06-disk-explorer.md).
///
/// Metadata only, like `DiskUsage`. One walk of a folder also records the sizes of the folders
/// below it, `cacheDepth` levels deep, so browsing down after the first measurement is instant.
public actor DiskSizer {
    public struct Size: Sendable, Equatable {
        public var bytes: Int64
        /// Files and folders below this one.
        public var items: Int
        /// False when part of the folder couldn't be listed: the real size is at least `bytes`.
        public var complete: Bool

        public init(bytes: Int64, items: Int = 0, complete: Bool = true) {
            self.bytes = bytes
            self.items = items
            self.complete = complete
        }
    }

    /// One item in a folder listing. Files carry their size; folders are measured separately.
    public struct Entry: Sendable, Identifiable, Hashable {
        public var url: URL
        public var name: String
        /// Folders and packages; never a symbolic link.
        public var isDirectory: Bool
        public var isPackage: Bool
        public var isSymbolicLink: Bool
        public var modified: Date?
        public var fileSize: Int64?
        public var id: String { url.path }
    }

    public let home: URL
    let cacheDepth: Int
    private var cache: [String: Size] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheDepth: Int = 3) {
        self.home = home
        self.cacheDepth = cacheDepth
    }

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Direct children of a folder, hidden ones included.
    public nonisolated static func children(of url: URL) -> [Entry] {
        let items = (try? FileManager().contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        return items.compactMap { item in
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { return nil }
            let link = v.isSymbolicLink == true
            let directory = v.isDirectory == true && !link
            // Keep the folder's own spelling (macOS may answer /private/var for /var), so paths match
            // the cache and the scan's findings.
            let child = url.appendingPathComponent(item.lastPathComponent, isDirectory: directory)
            return Entry(url: child, name: item.lastPathComponent, isDirectory: directory,
                         isPackage: v.isPackage == true, isSymbolicLink: link,
                         modified: v.contentModificationDate,
                         fileSize: directory ? nil : (link ? 0 : allocated(v)))
        }
    }

    /// Folders not entered without Full Disk Access: macOS can block on a consent prompt there.
    public nonisolated func isLocked(_ url: URL, avoidingProtected: Bool) -> Bool {
        avoidingProtected && PathUtil.isProtected(url, home: home)
    }

    public func cached(_ url: URL) -> Size? { cache[url.path] }

    /// Size of a folder (or file), from the cache when known. The folder's sub-folders are walked
    /// in parallel, since one of them (a code folder, Library) usually holds most of the files.
    public nonisolated func measure(_ url: URL, avoidingProtected: Bool = false) async -> Size {
        if let known = await cached(url) { return known }
        let skip: @Sendable (URL) -> Bool = { [home] in avoidingProtected && PathUtil.isProtected($0, home: home) }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
            .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
        guard isFolder, !skip(url) else {
            guard let walked = Self.walk(url, cacheDepth: cacheDepth, skip: skip) else { return Size(bytes: 0, complete: false) }
            return walked.size
        }
        guard (try? FileManager().contentsOfDirectory(atPath: url.path)) != nil else {
            return Size(bytes: 0, complete: false)
        }
        let entries = Self.children(of: url)
        var total = Size(bytes: 0, items: entries.count)
        var found: [String: Size] = [:]
        for entry in entries where !entry.isDirectory { total.bytes += entry.fileSize ?? 0 }
        let folders = entries.filter(\.isDirectory).map(\.url)
        let depth = cacheDepth - 1
        let results = await withTaskGroup(of: (String, (size: Size, found: [String: Size])?).self) { group in
            var next = 0
            func enqueue() {
                guard next < folders.count else { return }
                let folder = folders[next]
                next += 1
                group.addTask { (folder.path, Self.walk(folder, cacheDepth: depth, skip: skip)) }
            }
            for _ in 0..<min(8, folders.count) { enqueue() }
            var results: [(String, (size: Size, found: [String: Size])?)] = []
            while let result = await group.next() {
                results.append(result)
                enqueue()
            }
            return results
        }
        for (path, walked) in results {
            guard let walked else { return Size(bytes: 0, complete: false) }  // cancelled; not cached
            total.bytes += walked.size.bytes
            total.items += walked.size.items
            total.complete = total.complete && walked.size.complete
            if depth >= 0 { found[path] = walked.size }
            // Walked from the folder itself, so its own entries are one level shallower.
            found.merge(walked.found) { _, new in new }
        }
        await store(found, root: url.path, size: total)
        return total
    }

    private func store(_ found: [String: Size], root: String, size: Size) {
        cache.merge(found) { _, new in new }
        cache[root] = size
    }

    /// After an item moved to or back from the Trash: folders above it change by `delta` bytes,
    /// and the item itself is measured again when next shown.
    public func adjust(_ path: String, by delta: Int64) {
        let prefix = path + "/"
        for key in cache.keys where key == path || key.hasPrefix(prefix) { cache[key] = nil }
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if var size = cache[parent] {
                size.bytes = max(0, size.bytes + delta)
                cache[parent] = size
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    public func forgetAll() { cache = [:] }

    /// Walks once, summing each folder as its last entry goes by. Returns nil when cancelled.
    nonisolated static func walk(_ root: URL, cacheDepth: Int,
                                 skip: (URL) -> Bool) -> (size: Size, found: [String: Size])? {
        guard let rootValues = try? root.resourceValues(forKeys: Set(keys)) else {
            return (Size(bytes: 0, complete: false), [:])
        }
        if rootValues.isSymbolicLink == true { return (Size(bytes: 0), [:]) }
        if rootValues.isDirectory != true { return (Size(bytes: allocated(rootValues)), [:]) }
        if skip(root) { return (Size(bytes: 0, complete: false), [:]) }

        final class Failures { var paths: [String] = [] }
        let failures = Failures()
        let walker = FileManager().enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                              errorHandler: { url, _ in failures.paths.append(url.path); return true })
        struct Frame {
            var path: String
            var size = Size(bytes: 0)
        }
        var total = Size(bytes: 0)
        var open: [Frame] = []  // open[i] is a folder at depth i + 1
        var found: [String: Size] = [:]

        func close(downTo depth: Int) {
            while open.count > depth {
                let frame = open.removeLast()
                if open.count < cacheDepth { found[frame.path] = frame.size }
                if open.isEmpty { add(frame.size, to: &total) } else { add(frame.size, to: &open[open.count - 1].size) }
            }
        }
        func add(_ size: Size, to target: inout Size) {
            target.bytes += size.bytes
            target.items += size.items
            target.complete = target.complete && size.complete
        }
        // A folder that can't be listed fails as the walk tries to enter it, while it is the deepest
        // open folder. Incompleteness then spreads upward as folders close.
        func noteFailures() {
            for path in failures.paths {
                let name = (path as NSString).lastPathComponent
                if let i = open.lastIndex(where: { ($0.path as NSString).lastPathComponent == name }) ?? open.indices.last {
                    open[i].size.complete = false
                } else {
                    total.complete = false
                }
            }
            failures.paths.removeAll()
        }

        var visited = 0
        while let walker, let url = walker.nextObject() as? URL {
            visited += 1
            if visited % 4_096 == 0, Task.isCancelled { return nil }
            noteFailures()
            close(downTo: walker.level - 1)
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let link = v.isSymbolicLink == true
            if open.isEmpty { total.items += 1 } else { open[open.count - 1].size.items += 1 }
            if v.isDirectory == true, !link {
                // Built from the root as given: the enumerator may report /private/var for /var.
                var frame = Frame(path: (open.last?.path ?? root.path) + "/" + url.lastPathComponent)
                if skip(url) {
                    walker.skipDescendants()
                    frame.size.complete = false
                }
                open.append(frame)
            } else if !link {
                let bytes = allocated(v)
                if open.isEmpty { total.bytes += bytes } else { open[open.count - 1].size.bytes += bytes }
            }
        }
        noteFailures()
        close(downTo: 0)
        return (total, found)
    }

    private nonisolated static func allocated(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }
}

/// Answers "which suggestions are at, or inside, this path?" for the Disk Explorer.
public struct FindingIndex: Sendable {
    /// Every path of every finding, sorted by UTF-8 bytes so a folder's contents are contiguous.
    private let entries: [(path: [UInt8], finding: Finding)]

    public struct Summary: Sendable {
        public var findings: [Finding] = []
        /// Bytes of those findings inside the folder. A finding with paths both inside and outside
        /// (a duplicate group) counts in proportion to its paths inside.
        public var bytes: Int64 = 0
        public var safeBytes: Int64 = 0

        public init() {}
    }

    public init(_ findings: [Finding] = []) {
        entries = findings
            .flatMap { f in f.paths.map { (Array($0.utf8), f) } }
            .sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    /// Findings that list exactly this path.
    public func at(_ path: String) -> [Finding] {
        let key = Array(path.utf8)
        var result: [Finding] = []
        var i = lowerBound(key)
        while i < entries.count, entries[i].path == key {
            if !result.contains(where: { $0.id == entries[i].finding.id }) { result.append(entries[i].finding) }
            i += 1
        }
        return result
    }

    /// Findings with paths below this folder.
    public func inside(_ path: String) -> Summary {
        let prefix = Array((path + "/").utf8)
        var counts: [String: (finding: Finding, inside: Int)] = [:]
        var i = lowerBound(prefix)
        while i < entries.count, entries[i].path.starts(with: prefix) {
            counts[entries[i].finding.id, default: (entries[i].finding, 0)].inside += 1
            i += 1
        }
        var summary = Summary()
        for (finding, inside) in counts.values.sorted(by: { $0.finding.bytes > $1.finding.bytes }) {
            let share = finding.bytes * Int64(inside) / Int64(max(finding.paths.count, 1))
            summary.findings.append(finding)
            summary.bytes += share
            if finding.safety == .safe { summary.safeBytes += share }
        }
        return summary
    }

    private func lowerBound(_ key: [UInt8]) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].path.lexicographicallyPrecedes(key) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
