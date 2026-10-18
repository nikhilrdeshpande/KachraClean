import AppKit
import Foundation
import KachraCore
import Observation

/// The Objective-C runtime also declares a `Category` type; prefer ours throughout the app.
typealias Category = KachraCore.Category
/// Foundation's string `Scanner` would otherwise shadow the KachraClean scanner.
typealias Scanner = KachraCore.Scanner

/// App state: the current report, what the user has ticked, scan progress, undo history.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case cleaning
    }

    enum StepState: Equatable {
        case pending
        case running
        case done(found: Int64)
    }

    struct CleanRecord {
        var findings: [Finding]
        var outcomes: [Cleaner.Outcome]
        var bytes: Int64
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var canUndo: Bool
    }

    // MARK: State

    var phase: Phase = .idle
    var report: ScanReport?
    var selection: Set<String> = []
    var steps: [(step: Scanner.Step, state: StepState)] = []
    var scanStarted: Date?
    var toast: Toast?
    var errorMessage: String?
    var hasFullDiskAccess = AppModel.checkFullDiskAccess()
    /// Finding shown in the inspector.
    var focused: Finding.ID?
    var search = ""
    var showInspector = false
    /// Sheet explaining Full Disk Access before a scan.
    var showPermissionGate = false
    /// Whether the current report came from a limited scan (no Full Disk Access).
    var lastScanWasLimited = false
    var lastClean: CleanRecord?
    /// Set when a clean needs explicit confirmation (it includes apps).
    var pendingConfirmation: [Finding]?

    // MARK: Settings (persisted)

    var idleDays: Int {
        didSet { UserDefaults.standard.set(idleDays, forKey: "idleDays") }
    }
    var unusedAppDays: Int {
        didSet { UserDefaults.standard.set(unusedAppDays, forKey: "unusedAppDays") }
    }
    var largeFileMB: Int {
        didSet { UserDefaults.standard.set(largeFileMB, forKey: "largeFileMB") }
    }
    /// File shown in Quick Look.
    var previewURL: URL?
    private(set) var ignoredPaths: Set<String> {
        didSet { UserDefaults.standard.set(Array(ignoredPaths), forKey: "ignoredPaths") }
    }

    /// How long a saved scan stays trustworthy enough to pre-select from.
    static let freshScanAge: TimeInterval = 24 * 3_600

    private var scanTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        idleDays = defaults.object(forKey: "idleDays") as? Int ?? 30
        unusedAppDays = defaults.object(forKey: "unusedAppDays") as? Int ?? 180
        largeFileMB = defaults.object(forKey: "largeFileMB") as? Int ?? 500
        ignoredPaths = Set(defaults.stringArray(forKey: "ignoredPaths") ?? [])
        if let saved = try? ScanReport.load(from: ScanReport.defaultLocation) {
            report = saved
            // Things change: a project idle last week may be active today. Only a recent scan
            // gets its safe items pre-selected.
            selection = saved.createdAt.timeIntervalSinceNow > -Self.freshScanAge ? defaultSelection(saved) : []
            phase = .ready
        }
    }

    // MARK: Derived values

    /// Findings the user hasn't asked us to ignore.
    var visibleFindings: [Finding] {
        report?.findings.filter { !isIgnored($0) } ?? []
    }

    func findings(in category: Category) -> [Finding] {
        visibleFindings.filter { $0.category == category }
    }

    func total(_ category: Category) -> Int64 {
        findings(in: category).reduce(0) { $0 + $1.bytes }
    }

    func total(_ category: Category, safety: Safety) -> Int64 {
        findings(in: category).filter { $0.safety == safety }.reduce(0) { $0 + $1.bytes }
    }

    var reclaimable: Int64 {
        visibleFindings.filter { $0.category.countsAsReclaimable }.reduce(0) { $0 + $1.bytes }
    }

    var safeBytes: Int64 {
        visibleFindings.filter { $0.safety == .safe && $0.category.countsAsReclaimable }.reduce(0) { $0 + $1.bytes }
    }

    var selectedFindings: [Finding] {
        visibleFindings.filter { selection.contains($0.id) }
    }

    var selectedBytes: Int64 { selectedFindings.reduce(0) { $0 + $1.bytes } }

    var selectedNeedingReview: Int { selectedFindings.filter { $0.safety != .safe }.count }

    var focusedFinding: Finding? {
        focused.flatMap { id in report?.findings.first { $0.id == id } }
    }

    var isScanning: Bool { phase == .scanning }

    var scanProgress: Double {
        guard !steps.isEmpty else { return 0 }
        let done = steps.filter { if case .done = $0.state { return true } else { return false } }.count
        return Double(done) / Double(steps.count)
    }

    func isSelectable(_ finding: Finding) -> Bool { finding.category != .trash }

    func isIgnored(_ finding: Finding) -> Bool {
        finding.paths.contains { ignoredPaths.contains($0) }
    }

    func defaultSelection(_ report: ScanReport) -> Set<String> {
        Set(report.findings
            .filter { $0.safety == .safe && $0.category.countsAsReclaimable && !isIgnored($0) }
            .map(\.id))
    }

    // MARK: Scanning

    /// Entry point for every "Scan" button: asks for Full Disk Access first when it's missing.
    func requestScan() {
        recheckFullDiskAccess()
        if hasFullDiskAccess { scan() } else { showPermissionGate = true }
    }

    func scan() {
        guard !isScanning, phase != .cleaning else { return }
        showPermissionGate = false
        recheckFullDiskAccess()
        let limited = !hasFullDiskAccess
        lastScanWasLimited = limited
        let scanner = Scanner(options: .init(idleDays: idleDays, unusedAppDays: unusedAppDays,
                                             largeFileBytes: Int64(largeFileMB) * 1_000_000,
                                             avoidProtectedLocations: limited))
        steps = scanner.plannedSteps.map { ($0, .pending) }
        scanStarted = Date()
        phase = .scanning
        dismissToast()
        scanTask = Task {
            do {
                let result = try await scanner.run { event in
                    Task { @MainActor in self.apply(event) }
                }
                try? result.save(to: ScanReport.defaultLocation)
                report = result
                selection = defaultSelection(result)
                focused = nil
                lastClean = nil
                phase = .ready
            } catch is CancellationError {
                phase = report == nil ? .idle : .ready
            } catch {
                errorMessage = error.localizedDescription
                phase = report == nil ? .idle : .ready
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        phase = report == nil ? .idle : .ready
    }

    private func apply(_ event: Scanner.Progress) {
        switch event {
        case .started(let step):
            if let i = steps.firstIndex(where: { $0.step == step }) { steps[i].state = .running }
        case .finished(let step, let found):
            if let i = steps.firstIndex(where: { $0.step == step }) { steps[i].state = .done(found: found) }
        }
    }

    // MARK: Selection

    func toggle(_ finding: Finding) {
        guard isSelectable(finding) else { return }
        if selection.contains(finding.id) { selection.remove(finding.id) } else { selection.insert(finding.id) }
    }

    func select(_ findings: [Finding], upTo maxSafety: Safety) {
        for f in findings where f.safety <= maxSafety && isSelectable(f) { selection.insert(f.id) }
    }

    func deselect(_ findings: [Finding]) {
        selection.subtract(findings.map(\.id))
    }

    func selectOnlySafe() {
        selection = Set(visibleFindings.filter { $0.safety == .safe && $0.category.countsAsReclaimable }.map(\.id))
    }

    // MARK: Cleaning

    /// Cleans the current selection. Reversible moves happen immediately with Undo;
    /// removing apps asks first.
    func cleanSelection() {
        let chosen = selectedFindings
        guard !chosen.isEmpty, phase == .ready else { return }
        if chosen.contains(where: { $0.category == .apps }) {
            pendingConfirmation = chosen
        } else {
            perform(chosen)
        }
    }

    func confirmPending() {
        if let chosen = pendingConfirmation { perform(chosen) }
        pendingConfirmation = nil
    }

    private func perform(_ chosen: [Finding]) {
        phase = .cleaning
        Task {
            let outcomes = await Task.detached { Cleaner(dryRun: false).clean(chosen) }.value
            let failedIDs = Set(outcomes.filter { $0.error != nil }.map(\.findingID))
            // Fully cleaned findings leave the list; partly cleaned ones stay, but every item that
            // did reach the Trash can still be put back with Undo.
            let trashed = outcomes.filter { $0.trashedTo != nil }
            let touchedIDs = Set(trashed.map(\.findingID))
            let doneIDs = Set(chosen.map(\.id)).subtracting(failedIDs)
            let freed = chosen.filter { doneIDs.contains($0.id) }.reduce(0) { $0 + $1.bytes }
            report?.findings.removeAll { doneIDs.contains($0.id) }
            selection.subtract(doneIDs)
            if let f = focused, doneIDs.contains(f) { focused = nil }
            persist()
            lastClean = CleanRecord(findings: chosen.filter { touchedIDs.contains($0.id) }, outcomes: trashed,
                                    bytes: freed)
            let skipped = failedIDs.count
            showToast(
                "Moved \(Format.bytes(freed)) to the Trash" + (skipped > 0 ? " · \(skipped) skipped" : ""),
                canUndo: !trashed.isEmpty
            )
            phase = .ready
        }
    }

    func undoLastClean() {
        guard let record = lastClean, phase == .ready else { return }
        let restored = Cleaner().restore(record.outcomes)
        let restoredIDs = Set(restored.map(\.findingID))
        let listed = Set(report?.findings.map(\.id) ?? [])
        let back = record.findings.filter { restoredIDs.contains($0.id) && !listed.contains($0.id) }
        report?.findings.append(contentsOf: back)
        report?.findings.sort { $0.bytes > $1.bytes }
        selection.formUnion(back.map(\.id))
        persist()
        lastClean = nil
        showToast("Put back \(restored.count) items", canUndo: false)
    }

    // MARK: Ignore list

    func ignore(_ finding: Finding) {
        ignoredPaths.formUnion(finding.paths)
        selection.remove(finding.id)
        if focused == finding.id { focused = nil }
        showToast("KachraClean won't suggest \(finding.title) again", canUndo: false)
    }

    func clearIgnored() { ignoredPaths = [] }

    var ignoredCount: Int { ignoredPaths.count }

    // MARK: Helpers

    func showToast(_ message: String, canUndo: Bool) {
        toast = Toast(message: message, canUndo: canUndo)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(canUndo ? 12 : 4))
            if !Task.isCancelled { toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    private func persist() {
        if let report { try? report.save(to: ScanReport.defaultLocation) }
    }

    /// Quick Look for single files (videos, documents, images).
    func canPreview(_ finding: Finding) -> Bool {
        guard finding.paths.count == 1, let path = finding.paths.first else { return false }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    func preview(_ finding: Finding) {
        guard canPreview(finding), let path = finding.paths.first else { return }
        previewURL = URL(fileURLWithPath: path)
    }

    func reveal(_ finding: Finding) {
        let urls = finding.paths.prefix(20).map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func recheckFullDiskAccess() {
        let granted = Self.checkFullDiskAccess()
        let newlyGranted = granted && !hasFullDiskAccess
        hasFullDiskAccess = granted
        // Granted while the permission sheet was waiting: continue straight into the scan.
        if newlyGranted, showPermissionGate { scan() }
    }

    /// The TCC folder is only listable with Full Disk Access; listing it is a harmless probe.
    static func checkFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }
}

extension Category {
    /// Apps and the Trash are informational; they never count toward "reclaimable".
    var countsAsReclaimable: Bool { self != .apps && self != .trash }
}
