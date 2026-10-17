import AppKit
import Foundation
import KachraCore
import Observation

/// The Objective-C runtime also declares a `Category` type; prefer ours throughout the app.
typealias Category = KachraCore.Category

/// State of the app: the current report, what the user has ticked, and scan/clean progress.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning(step: String)
        case ready
        case cleaning
    }

    var phase: Phase = .idle
    var report: ScanReport?
    var selection: Set<String> = []
    var lastCleanSummary: String?
    var errorMessage: String?
    var hasFullDiskAccess = AppModel.checkFullDiskAccess()

    init() {
        if let saved = try? ScanReport.load(from: ScanReport.defaultLocation) {
            report = saved
            selection = Self.defaultSelection(saved)
            phase = .ready
        }
    }

    /// Pre-select only what is safe; apps are never pre-selected.
    static func defaultSelection(_ report: ScanReport) -> Set<String> {
        Set(report.findings.filter { $0.safety == .safe && $0.category != .apps && $0.category != .trash }.map(\.id))
    }

    // MARK: - Derived values

    func findings(in category: Category) -> [Finding] {
        report?.findings.filter { $0.category == category } ?? []
    }

    func total(_ category: Category) -> Int64 {
        findings(in: category).reduce(0) { $0 + $1.bytes }
    }

    var selectedFindings: [Finding] {
        report?.findings.filter { selection.contains($0.id) } ?? []
    }

    var selectedBytes: Int64 { selectedFindings.reduce(0) { $0 + $1.bytes } }

    var safeBytes: Int64 {
        report?.findings.filter { $0.safety == .safe && $0.category != .apps }.reduce(0) { $0 + $1.bytes } ?? 0
    }

    func isSelectable(_ finding: Finding) -> Bool { finding.category != .trash }

    // MARK: - Actions

    func scan() {
        guard phase != .cleaning, !isScanning else { return }
        phase = .scanning(step: "Starting")
        lastCleanSummary = nil
        Task {
            do {
                let result = try await Scanner().run { step in
                    Task { @MainActor in self.phase = .scanning(step: step) }
                }
                try? result.save(to: ScanReport.defaultLocation)
                report = result
                selection = Self.defaultSelection(result)
                phase = .ready
            } catch {
                errorMessage = error.localizedDescription
                phase = report == nil ? .idle : .ready
            }
        }
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    func selectAll(in category: Category, upTo maxSafety: Safety) {
        for finding in findings(in: category) where finding.safety <= maxSafety && isSelectable(finding) {
            selection.insert(finding.id)
        }
    }

    func deselectAll(in category: Category) {
        selection.subtract(findings(in: category).map(\.id))
    }

    func toggle(_ finding: Finding) {
        if selection.contains(finding.id) { selection.remove(finding.id) } else { selection.insert(finding.id) }
    }

    func moveSelectionToTrash() {
        let chosen = selectedFindings
        guard !chosen.isEmpty else { return }
        phase = .cleaning
        Task {
            let outcomes = await Task.detached { Cleaner(dryRun: false).clean(chosen) }.value
            let failed = outcomes.filter { $0.error != nil }
            let failedIDs = Set(failed.map(\.findingID))
            let done = chosen.filter { !failedIDs.contains($0.id) }
            let freed = done.reduce(0) { $0 + $1.bytes }
            report?.findings.removeAll { finding in done.contains { $0.id == finding.id } }
            selection.subtract(done.map(\.id))
            if let report { try? report.save(to: ScanReport.defaultLocation) }
            lastCleanSummary = failed.isEmpty
                ? "Moved \(done.count) items (\(Format.bytes(freed))) to the Trash. Empty the Trash to free the space."
                : "Moved \(done.count) items (\(Format.bytes(freed))) to the Trash. \(failed.count) paths were skipped: \(failed.first?.error ?? "")"
            phase = .ready
        }
    }

    func reveal(_ finding: Finding) {
        let urls = finding.paths.prefix(20).map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func recheckFullDiskAccess() { hasFullDiskAccess = Self.checkFullDiskAccess() }

    /// The TCC database is only readable with Full Disk Access; reading its directory listing is
    /// a harmless probe.
    static func checkFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func path(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
