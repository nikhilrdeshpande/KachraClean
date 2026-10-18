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
        /// Bytes each trashed path held, so the Disk Explorer can shrink and grow folders on Undo.
        var sizes: [String: Int64] = [:]
    }

    struct Toast: Identifiable, Equatable {
        enum Undo: Equatable {
            case clean
            case ignore(paths: Set<String>)
        }

        let id = UUID()
        var message: String
        var undo: Undo?
        var failed = false
    }

    // MARK: State

    var phase: Phase = .idle
    var report: ScanReport? {
        didSet { findingIndex = FindingIndex(visibleFindings) }
    }
    /// Which suggestions sit at or inside a path, for the Disk Explorer.
    private(set) var findingIndex = FindingIndex()
    let explorer = ExplorerModel()
    /// True while the Disk Explorer is on screen: ⌘⌫ then acts on the explorer's selection.
    var onExplorer = false
    /// A screen to switch to, e.g. from "Show in Disk Explorer" or a suggestion in the explorer.
    var navigationRequest: Destination?
    /// Path checks for the explorer's Move to Trash button (the cleaner checks again when moving).
    private let guardRails = Cleaner(dryRun: true)
    var selection: Set<String> = []
    /// The category on screen, or nil on the Overview. Cleaning acts on what's in view: inside a
    /// category only that category's selection moves, so a selection made elsewhere never rides along.
    var scope: Category?
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
        didSet {
            UserDefaults.standard.set(Array(ignoredPaths), forKey: "ignoredPaths")
            findingIndex = FindingIndex(visibleFindings)
        }
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
        findingIndex = FindingIndex(visibleFindings)
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

    /// Selected findings in one category, or everywhere for nil.
    func selectedFindings(in category: Category?) -> [Finding] {
        selectedFindings.filter { category == nil || $0.category == category }
    }

    /// What the Clean action would move right now.
    var scopedSelection: [Finding] { selectedFindings(in: scope) }

    var selectedBytes: Int64 { selectedFindings.reduce(0) { $0 + $1.bytes } }

    var selectedNeedingReview: Int { selectedFindings.filter { $0.safety != .safe }.count }

    /// Whether the report is too old to pre-select from (see `freshScanAge`).
    var reportIsStale: Bool {
        guard let report else { return false }
        return report.createdAt.timeIntervalSinceNow < -Self.freshScanAge
    }

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

    /// Cleans the selection in scope. Reversible moves happen immediately with Undo;
    /// removing apps asks first.
    func cleanSelection() {
        let chosen = scopedSelection
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
            let sizes = trashedSizes(trashed, of: chosen)
            for (path, bytes) in sizes { explorer.removed(path, bytes: bytes) }
            lastClean = CleanRecord(findings: chosen.filter { touchedIDs.contains($0.id) }, outcomes: trashed,
                                    bytes: freed, sizes: sizes)
            let skipped = failedIDs.count
            showToast(
                "Moved \(Format.bytes(freed)) to the Trash" + (skipped > 0 ? " · \(skipped) skipped" : ""),
                undo: trashed.isEmpty ? nil : .clean
            )
            phase = .ready
        }
    }

    /// Bytes per trashed path: measured by the explorer when known, else the finding's size split
    /// evenly across its paths.
    private func trashedSizes(_ outcomes: [Cleaner.Outcome], of findings: [Finding]) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for outcome in outcomes {
            guard let finding = findings.first(where: { $0.id == outcome.findingID }) else { continue }
            sizes[outcome.path] = explorer.knownSize(of: outcome.path)
                ?? finding.bytes / Int64(max(finding.paths.count, 1))
        }
        return sizes
    }

    /// Moves an item picked in the Disk Explorer to the Trash. Suggestions inside it leave the
    /// results; Undo brings both back.
    func trashFromExplorer(_ row: ExplorerModel.Row) {
        guard phase != .cleaning, !isScanning else { return }
        let previous = phase
        let url = row.url
        phase = .cleaning
        Task {
            let outcomes = await Task.detached { Cleaner(dryRun: false).trash([url]) }.value
            phase = previous
            guard let outcome = outcomes.first, outcome.trashedTo != nil else {
                showToast("\(row.entry.name) wasn't moved: \(outcomes.first?.error ?? "unknown error")", failed: true)
                return
            }
            let path = url.path
            let inside = { (p: String) in p == path || p.hasPrefix(path + "/") }
            let gone = report?.findings.filter { $0.paths.allSatisfy(inside) } ?? []
            let goneIDs = Set(gone.map(\.id))
            report?.findings.removeAll { goneIDs.contains($0.id) }
            selection.subtract(goneIDs)
            if let f = focused, goneIDs.contains(f) { focused = nil }
            persist()
            explorer.removed(path, bytes: row.bytes)
            lastClean = CleanRecord(findings: gone, outcomes: [outcome], bytes: row.bytes, sizes: [path: row.bytes])
            showToast("Moved \(row.entry.name) (\(Format.bytes(row.bytes))) to the Trash", undo: .clean)
        }
    }

    func undoLastClean() {
        guard let record = lastClean, phase != .cleaning, !isScanning else { return }
        let restored = Cleaner().restore(record.outcomes)
        for outcome in restored { explorer.restored(outcome.path, bytes: record.sizes[outcome.path] ?? 0) }
        let restoredIDs = Set(restored.map(\.findingID))
        let listed = Set(report?.findings.map(\.id) ?? [])
        let back = record.findings.filter { restoredIDs.contains($0.id) && !listed.contains($0.id) }
        report?.findings.append(contentsOf: back)
        report?.findings.sort { $0.bytes > $1.bytes }
        selection.formUnion(back.map(\.id))
        persist()
        lastClean = nil
        showToast("Put back \(restored.count) items")
    }

    // MARK: Ignore list

    func ignore(_ finding: Finding) {
        let added = Set(finding.paths).subtracting(ignoredPaths)
        ignoredPaths.formUnion(added)
        selection.remove(finding.id)
        if focused == finding.id { focused = nil }
        showToast("KachraClean won't suggest \(finding.title) again", undo: .ignore(paths: added))
    }

    var canUndo: Bool {
        if case .ignore = toast?.undo { return true }
        return lastClean != nil
    }

    var undoTitle: String {
        if case .ignore = toast?.undo { return "Undo Never Suggest" }
        return "Undo Clean"
    }

    /// ⌘Z: the most recent undoable action.
    func undoLatest() {
        if let toast, case .ignore = toast.undo { undo(toast) } else { undoLastClean() }
    }

    /// Runs the toast's Undo action.
    func undo(_ toast: Toast) {
        switch toast.undo {
        case .clean: undoLastClean()
        case .ignore(let paths):
            ignoredPaths.subtract(paths)
            dismissToast()
        case nil: break
        }
    }

    func clearIgnored() { ignoredPaths = [] }

    var ignoredCount: Int { ignoredPaths.count }

    // MARK: Helpers

    func showToast(_ message: String, undo: Toast.Undo? = nil, failed: Bool = false) {
        toast = Toast(message: message, undo: undo, failed: failed)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(undo != nil || failed ? 12 : 4))
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

    /// Opens the Disk Explorer at a finding's first location.
    func showInExplorer(_ finding: Finding) {
        guard let path = finding.paths.first else { return }
        explorer.start(avoidingProtected: !hasFullDiskAccess)
        explorer.reveal(URL(fileURLWithPath: path))
        navigationRequest = .explorer
    }

    /// Why an explorer item can't go to the Trash, or nil when it can.
    func explorerRefusal(_ row: ExplorerModel.Row) -> String? {
        guardRails.refusal(for: row.url, category: nil)
    }

    /// ⌘⌫ in the explorer: asks to move the selected item to the Trash.
    func requestExplorerTrash() {
        guard let row = explorer.selectedRow, explorerRefusal(row) == nil else { return }
        explorer.confirmTrash = row
    }

    var canTrashExplorerSelection: Bool {
        guard let row = explorer.selectedRow, phase != .cleaning, !isScanning else { return false }
        return explorerRefusal(row) == nil
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
