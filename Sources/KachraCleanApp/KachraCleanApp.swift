import AppKit
import SwiftUI

@main
struct KachraCleanApp: App {
    @State private var model = AppModel()

    init() {
        // Launched as a bare executable (swift run) the process would stay in the background.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("KachraClean", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { NSApplication.shared.activate() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.recheckFullDiskAccess()  // picks up a grant made in System Settings
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan") { model.requestScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle) { model.undoLatest() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
            }
            CommandMenu("Clean") {
                Button(model.scope.map { "Move Selected \($0.title) to Trash" } ?? "Move Everything Selected to Trash") {
                    model.cleanSelection()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.scopedSelection.isEmpty || model.phase != .ready)
                Button("Select Only Safe Items") { model.selectOnlySafe() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Open Trash") { model.openTrash() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Stepper(value: $model.idleDays, in: 7...365, step: 7) {
                    LabeledContent("Project is idle after", value: "\(model.idleDays) days")
                }
                Text("Dependencies of projects untouched for this long, with a lockfile, are marked safe.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $model.unusedAppDays, in: 30...720, step: 30) {
                    LabeledContent("App is unused after", value: "\(model.unusedAppDays) days")
                }
                Text("Only apps with a recorded last-opened date can be called unused.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Large files start at", selection: $model.largeFileMB) {
                    ForEach([100, 250, 500, 1000, 2000, 5000], id: \.self) { mb in
                        Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb)
                    }
                }
            } header: {
                Text("Thresholds")
            } footer: {
                Text("Changes apply to the next scan.").font(.caption)
            }
            Section("Ignored") {
                LabeledContent("Paths KachraClean won't suggest", value: "\(model.ignoredCount)")
                Button("Suggest Ignored Items Again") { model.clearIgnored() }
                    .disabled(model.ignoredCount == 0)
            }
            Section("Permissions") {
                LabeledContent("Full Disk Access", value: model.hasFullDiskAccess ? "Granted" : "Not granted")
                if !model.hasFullDiskAccess {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
