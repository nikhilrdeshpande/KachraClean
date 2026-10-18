import Foundation
import KachraCore

let usage = """
    kachra — find reclaimable space on your Mac (read-only unless you pass --yes)

    USAGE
      kachra scan  [--only <categories>] [--top <n>] [--idle-days <n>] [--json]
      kachra clean [--id <id>]... [--category <c>] [--safety safe|review] [--yes]
      kachra explore [<folder>] [--top <n>]

    CATEGORIES
      appCaches, logs, toolCaches, models, largeFiles, projectArtifacts, duplicates, apps, trash

    `scan` saves its report to ~/Library/Application Support/KachraClean/last-scan.json.
    `clean` works from that report. Without --yes it only shows what would move to the Trash.
    `explore` lists a folder's contents by size (default: your home folder). A + means part of
    an item couldn't be read, so it is at least that big.
    """

struct Args {
    var command = ""
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    /// Arguments that aren't options, e.g. the folder for `explore`.
    var operands: [String] = []

    init(_ raw: [String]) {
        var it = raw.makeIterator()
        command = it.next() ?? ""
        while let arg = it.next() {
            guard arg.hasPrefix("--") else { operands.append(arg); continue }
            let key = String(arg.dropFirst(2))
            if ["json", "yes", "help"].contains(key) {
                flags.insert(key)
            } else if let value = it.next() {
                values[key, default: []].append(value)
            }
        }
    }

    func list(_ key: String) -> [String] {
        values[key, default: []].flatMap { $0.split(separator: ",").map(String.init) }
    }

    func int(_ key: String) -> Int? { values[key]?.last.flatMap(Int.init) }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? String(s.prefix(width - 1)) + "…" : s + String(repeating: " ", count: width - s.count)
}

func badge(_ safety: Safety) -> String {
    switch safety {
    case .safe: "safe  "
    case .review: "review"
    case .risky: "risky "
    }
}

func printReport(_ report: ScanReport, top: Int) {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for category in Category.allCases {
        let items = report.findings.filter { $0.category == category }
        guard !items.isEmpty else { continue }
        let total = items.reduce(0) { $0 + $1.bytes }
        let safe = items.filter { $0.safety == .safe }.reduce(0) { $0 + $1.bytes }
        print("\n\(category.title.uppercased())  \(bytes(total))  (safe: \(bytes(safe)), \(items.count) items)")
        for item in items.prefix(top) {
            let path = (item.paths.first ?? "").replacingOccurrences(of: home, with: "~")
            print("  \(pad(item.id, 14)) \(badge(item.safety))  \(pad(bytes(item.bytes), 10)) \(pad(item.title, 42)) \(path)")
        }
        if items.count > top { print("  … \(items.count - top) more") }
    }
    print("")
    print("Reclaimable (excluding apps and Trash): \(bytes(report.reclaimable))")
    let safe = report.findings.filter { $0.safety == .safe && $0.category != .apps }.reduce(0) { $0 + $1.bytes }
    print("Pre-selectable as safe:                 \(bytes(safe))")
    if let v = report.volume {
        print("Disk: \(bytes(v.freeBytes)) free of \(bytes(v.totalBytes)); macOS can purge another \(bytes(v.purgeableBytes)) on demand.")
    }
    let timing = report.timings.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value))s" }
    print("Scan time: " + timing.joined(separator: ", "))
}

let args = Args(Array(CommandLine.arguments.dropFirst()))

do {
    switch args.command {
    case "scan":
        var options = Scanner.Options(idleDays: args.int("idle-days") ?? 30)
        let only = args.list("only").compactMap(Category.init(rawValue:))
        if !only.isEmpty { options.categories = Set(only) }
        let json = args.flags.contains("json")
        let report = try await Scanner(options: options).run { event in
            if !json, case .started(let step) = event {
                FileHandle.standardError.write(Data("scanning \(step.rawValue)…\n".utf8))
            }
        }
        // Only a full scan replaces the saved report that `clean` and the app work from.
        if only.isEmpty { try report.save(to: ScanReport.defaultLocation) }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(report))
        } else {
            printReport(report, top: args.int("top") ?? 10)
        }

    case "clean":
        let report = try ScanReport.load(from: ScanReport.defaultLocation)
        if report.createdAt.timeIntervalSinceNow < -24 * 3_600 {
            FileHandle.standardError.write(Data("Note: this report is from \(report.createdAt.formatted()); run `kachra scan` for current results.\n".utf8))
        }
        let ids = Set(args.list("id"))
        let categories = Set(args.list("category").compactMap(Category.init(rawValue:)))
        let maxSafety = args.values["safety"]?.last.flatMap(Safety.init(rawValue:)) ?? .safe
        guard !ids.isEmpty || !categories.isEmpty else {
            print("Choose what to clean with --id or --category. Nothing was changed.")
            exit(2)
        }
        let selected = report.findings.filter { finding in
            (ids.contains(finding.id) || categories.contains(finding.category))
                && (ids.contains(finding.id) || finding.safety <= maxSafety)
        }
        let dryRun = !args.flags.contains("yes")
        let outcomes = Cleaner(dryRun: dryRun).clean(selected)
        let freed = selected.reduce(0) { $0 + $1.bytes }
        for o in outcomes {
            let status = o.error.map { "skipped: \($0)" } ?? (dryRun ? "would move to Trash" : "moved to Trash")
            print("\(status)  \(o.path)")
        }
        print(dryRun
            ? "\nDry run: \(selected.count) findings, \(bytes(freed)). Re-run with --yes to move them to the Trash."
            : "\nDone. Up to \(bytes(freed)) is now in the Trash; empty the Trash to free it.")

    case "explore":
        let folder = args.operands.first.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let started = Date()
        let sizer = DiskSizer()
        let entries = DiskSizer.children(of: folder)
        let sizes = await withTaskGroup(of: (String, DiskSizer.Size).self) { group in
            for entry in entries { group.addTask { (entry.id, await sizer.measure(entry.url)) } }
            var sizes: [String: DiskSizer.Size] = [:]
            for await (id, size) in group { sizes[id] = size }
            return sizes
        }
        let rows = entries.compactMap { e in sizes[e.id].map { (e, $0) } }.sorted { $0.1.bytes > $1.1.bytes }
        let total = rows.reduce(0) { $0 + $1.1.bytes }
        for (entry, size) in rows.prefix(args.int("top") ?? 25) {
            let shown = bytes(size.bytes) + (size.complete ? " " : "+")
            print("  \(pad(shown, 12)) \(entry.name)\(entry.isDirectory ? "/" : "")")
        }
        if rows.count > (args.int("top") ?? 25) { print("  … \(rows.count - (args.int("top") ?? 25)) more") }
        let complete = rows.allSatisfy { $0.1.complete }
        print("\n\(folder.path): \(bytes(total))\(complete ? "" : "+") in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

    default:
        print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("kachra: \(error.localizedDescription)\n".utf8))
    exit(1)
}
