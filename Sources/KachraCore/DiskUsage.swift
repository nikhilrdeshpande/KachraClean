import Foundation

/// Measures how much disk space files really occupy (allocated blocks, not logical length).
///
/// Metadata only: no file is ever opened for reading. Symbolic links are not followed.
public enum DiskUsage {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Allocated size of a file, or of everything below a directory.
    public static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return fileSize(values) }

        let enumerator = FileManager().enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        )
        var total: Int64 = 0
        while let item = enumerator?.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isDirectory != true else { continue }
            total += fileSize(v)
        }
        return total
    }

    /// Sizes many locations concurrently. Order of the result matches `urls`.
    public static func allocatedSizes(of urls: [URL], maxConcurrency: Int = 8) async -> [Int64] {
        await withTaskGroup(of: (Int, Int64).self) { group in
            var results = [Int64](repeating: 0, count: urls.count)
            var next = 0
            func enqueue() {
                guard next < urls.count else { return }
                let index = next
                let url = urls[index]
                group.addTask { (index, allocatedSize(of: url)) }
                next += 1
            }
            for _ in 0..<min(maxConcurrency, urls.count) { enqueue() }
            while let (index, size) = await group.next() {
                results[index] = size
                enqueue()
            }
            return results
        }
    }

    /// Most recent modification time of the item or its direct children; a cheap activity signal.
    public static func lastModified(_ url: URL) -> Date? {
        let fm = FileManager()
        var latest = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let children = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        )) ?? []
        for child in children {
            if let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               date > (latest ?? .distantPast) {
                latest = date
            }
        }
        return latest
    }

    private static func fileSize(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }
}

extension VolumeInfo {
    /// Reads capacity figures for the volume containing `url` (the home volume by default).
    public static func current(for url: URL = FileManager.default.homeDirectoryForCurrentUser) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return VolumeInfo(
            totalBytes: Int64(v.volumeTotalCapacity ?? 0),
            freeBytes: Int64(v.volumeAvailableCapacity ?? 0),
            availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}
