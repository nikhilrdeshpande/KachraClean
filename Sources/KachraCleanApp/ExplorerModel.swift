import Foundation
import KachraCore
import Observation

/// State for the Disk Explorer: Finder-style columns, each folder sorted by size
/// (docs/spec/06-disk-explorer.md).
@MainActor
@Observable
final class ExplorerModel {
    struct Row: Identifiable, Equatable {
        var entry: DiskSizer.Entry
        var size: DiskSizer.Size?
        var id: String { entry.id }
        var url: URL { entry.url }
        var bytes: Int64 { size?.bytes ?? 0 }
    }

    struct Column: Identifiable {
        var url: URL
        var rows: [Row] = []
        var listed = false
        /// Not entered without Full Disk Access (other apps' containers).
        var locked = false
        var selected: Row.ID?
        var id: String { url.path }
        var measuring: Int { rows.filter { $0.size == nil }.count }
        var bytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
        var complete: Bool { !locked && rows.allSatisfy { $0.size?.complete == true } }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    private(set) var root: URL
    private(set) var columns: [Column] = []
    /// Item waiting for the Move to Trash confirmation.
    var confirmTrash: Row?
    private(set) var avoidProtected = false
    private let sizer = DiskSizer()
    private var tasks: [String: Task<Void, Never>] = [:]

    init() { root = FileManager.default.homeDirectoryForCurrentUser }

    /// The deepest selected item: what the details panel shows and Move to Trash acts on.
    var selectedRow: Row? {
        for column in columns.reversed() {
            if let id = column.selected, let row = column.rows.first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    var isMeasuring: Bool { columns.contains { !$0.listed || $0.measuring > 0 } }

    // MARK: Navigation

    /// Opens the explorer the first time, or again after Full Disk Access changed.
    func start(avoidingProtected: Bool) {
        if columns.isEmpty || avoidingProtected != avoidProtected {
            let changed = !columns.isEmpty
            avoidProtected = avoidingProtected
            if changed { reload() } else { open(root) }
        }
    }

    func open(_ folder: URL) {
        cancelAll()
        root = folder
        columns = [Column(url: folder)]
        load(0)
    }

    func select(_ id: Row.ID?, in index: Int) {
        guard columns.indices.contains(index), columns[index].selected != id else { return }
        columns[index].selected = id
        truncate(after: index)
        if let id, let row = columns[index].rows.first(where: { $0.id == id }), row.entry.isDirectory {
            columns.append(Column(url: row.url))
            load(columns.count - 1)
        }
    }

    /// Opens the columns down to `url` and selects it ("Show in Disk Explorer").
    func reveal(_ url: URL) {
        let path = url.path
        let base = path.hasPrefix(home.path + "/") ? home : url.deletingLastPathComponent()
        if root.path != base.path || columns.isEmpty { open(base) } else { truncate(after: 0); columns[0].selected = nil }
        let parts = path.dropFirst(base.path.count).split(separator: "/").map(String.init)
        var folder = base
        for (depth, name) in parts.enumerated() {
            guard columns.indices.contains(depth) else { break }
            let child = folder.appendingPathComponent(name)
            columns[depth].selected = child.path
            let isLast = depth == parts.count - 1
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue,
               !isLast {
                columns.append(Column(url: child))
                load(columns.count - 1)
            }
            folder = child
        }
    }

    /// Forgets every measured size and measures the open columns again.
    func reload() {
        let urls = columns.map(\.url)
        let selected = columns.map(\.selected)
        cancelAll()
        Task {
            await sizer.forgetAll()
            columns = zip(urls, selected).map { Column(url: $0, selected: $1) }
            for index in columns.indices { load(index) }
        }
    }

    // MARK: After the Trash

    /// An item moved to the Trash: drop its row and shrink the folders above it.
    func removed(_ path: String, bytes: Int64) {
        Task { await sizer.adjust(path, by: -bytes) }
        if let i = columns.firstIndex(where: { $0.selected == path }) {
            columns[i].selected = nil
            truncate(after: i)
        }
        for i in columns.indices {
            columns[i].rows.removeAll { $0.id == path }
            resize(ancestorsOf: path, in: i, by: -bytes)
        }
    }

    /// An item came back from the Trash: list its folder again and grow the folders above it.
    func restored(_ path: String, bytes: Int64) {
        Task { await sizer.adjust(path, by: bytes) }
        let parent = (path as NSString).deletingLastPathComponent
        for i in columns.indices {
            resize(ancestorsOf: path, in: i, by: bytes)
            if columns[i].url.path == parent { load(i) }
        }
    }

    /// Exact size of an item if it has been measured, for trash bookkeeping.
    func knownSize(of path: String) -> Int64? {
        for column in columns { if let row = column.rows.first(where: { $0.id == path }) { return row.size?.bytes } }
        return nil
    }

    // MARK: Loading

    private func load(_ index: Int) {
        let url = columns[index].url
        let avoid = avoidProtected
        if sizer.isLocked(url, avoidingProtected: avoid) {
            columns[index].locked = true
            columns[index].listed = true
            return
        }
        tasks[url.path]?.cancel()
        tasks[url.path] = Task { [sizer] in
            let entries = await Task.detached { DiskSizer.children(of: url) }.value
            var rows: [Row] = []
            for entry in entries {
                rows.append(Row(entry: entry, size: entry.fileSize.map { DiskSizer.Size(bytes: $0) }))
            }
            for i in rows.indices where rows[i].size == nil { rows[i].size = await sizer.cached(rows[i].url) }
            guard !Task.isCancelled, let at = position(of: url) else { return }
            columns[at].rows = Self.sorted(rows)
            columns[at].listed = true

            let todo = rows.filter { $0.size == nil }.map(\.url)
            await withTaskGroup(of: (String, DiskSizer.Size).self) { group in
                var next = 0
                func enqueue() {
                    guard next < todo.count else { return }
                    let folder = todo[next]
                    next += 1
                    group.addTask { (folder.path, await sizer.measure(folder, avoidingProtected: avoid)) }
                }
                for _ in 0..<min(4, todo.count) { enqueue() }
                while let (path, size) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    update(path, size, in: url)
                    enqueue()
                }
            }
        }
    }

    private func update(_ path: String, _ size: DiskSizer.Size, in folder: URL) {
        guard let at = position(of: folder), let row = columns[at].rows.firstIndex(where: { $0.id == path }) else { return }
        columns[at].rows[row].size = size
        columns[at].rows = Self.sorted(columns[at].rows)
    }

    private func resize(ancestorsOf path: String, in index: Int, by delta: Int64) {
        for r in columns[index].rows.indices where path.hasPrefix(columns[index].rows[r].id + "/") {
            columns[index].rows[r].size?.bytes = max(0, columns[index].rows[r].bytes + delta)
        }
        columns[index].rows = Self.sorted(columns[index].rows)
    }

    /// Largest first; items still being measured last, by name.
    static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { a, b in
            switch (a.size, b.size) {
            case let (x?, y?) where x.bytes != y.bytes: x.bytes > y.bytes
            case (nil, _?): false
            case (_?, nil): true
            default: a.entry.name.localizedStandardCompare(b.entry.name) == .orderedAscending
            }
        }
    }

    private func position(of folder: URL) -> Int? { columns.firstIndex { $0.url.path == folder.path } }

    private func truncate(after index: Int) {
        guard columns.count > index + 1 else { return }
        for column in columns[(index + 1)...] {
            tasks[column.id]?.cancel()
            tasks[column.id] = nil
        }
        columns.removeSubrange((index + 1)...)
    }

    private func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }
}
