import KachraCore
import SwiftUI

struct SafetyBadge: View {
    var safety: Safety

    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(safety.color)
            .background(safety.color.opacity(0.13), in: Capsule())
            .help(safety.explanation)
    }
}

/// Horizontal bar split by safety level, for a category's composition.
struct SafetySplitBar: View {
    var safe: Int64
    var review: Int64
    var risky: Int64
    var height: CGFloat = 6

    var body: some View {
        let total = max(Double(safe + review + risky), 1)
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach([(safe, Safety.safe), (review, .review), (risky, .risky)], id: \.1) { bytes, safety in
                    if bytes > 0 {
                        Capsule().fill(safety.color.gradient)
                            .frame(width: max(height, geo.size.width * Double(bytes) / total))
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Safe \(Format.bytes(safe)), review \(Format.bytes(review)), careful \(Format.bytes(risky))")
    }
}

/// Floating action bar for one category: what's selected *here* and the button that cleans it.
/// Selections in other categories are mentioned, never included.
struct ActionBar: View {
    @Environment(AppModel.self) private var model
    var category: Category
    /// Selected items in this category that the current filter or search hides.
    var hiddenSelected: Int

    var body: some View {
        let chosen = model.selectedFindings(in: category)
        let bytes = chosen.reduce(0) { $0 + $1.bytes }
        let review = chosen.filter { $0.safety != .safe }.count
        let elsewhere = model.selectedFindings.filter { $0.category != category }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chosen.isEmpty ? "Nothing selected" : "\(Format.bytes(bytes)) of \(category.title.lowercased()) selected")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Group {
                    if chosen.isEmpty {
                        Text("Tick items to move them to the Trash.").foregroundStyle(.secondary)
                    } else if review > 0 {
                        Label(detail(count: chosen.count, "\(review) marked review"), systemImage: "eye.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(detail(count: chosen.count, "all safe · undoable")).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if !elsewhere.isEmpty {
                    Text("Not included: \(Format.bytes(elsewhere.reduce(0) { $0 + $1.bytes })) selected in other categories")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 20)
            if model.phase == .cleaning { ProgressView().controlSize(.small) }
            Button {
                model.cleanSelection()
            } label: {
                Label(chosen.count == 1 ? "Move 1 Item to Trash" : "Move \(chosen.count) Items to Trash", systemImage: "trash")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .prominentGlassButton()
            .disabled(chosen.isEmpty || model.phase != .ready)
            .help("Moves only the selected \(category.title.lowercased()) to the Trash (⌘⌫). Undo puts them back.")
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .frame(maxWidth: 680)
        .padding(.bottom, 16)
        .padding(.horizontal, 24)
    }

    private func detail(count: Int, _ tail: String) -> String {
        let hidden = hiddenSelected > 0 ? " · \(hiddenSelected) hidden by filter" : ""
        return "\(count) \(count == 1 ? "item" : "items") · \(tail)\(hidden)"
    }
}

/// Transient message with Undo, shown after cleaning.
struct ToastView: View {
    @Environment(AppModel.self) private var model
    var toast: AppModel.Toast

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.failed ? .orange : .green)
                .font(.title3)
            Text(toast.message).font(.callout.weight(.medium))
            if toast.undo != nil {
                Button("Undo") { model.undo(toast) }
                    .glassButton()
            }
            if toast.undo == .clean {
                Button("Open Trash") { model.openTrash() }
                    .buttonStyle(.borderless)
            }
            Button {
                model.dismissToast()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.top, 12)
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Give KachraClean Full Disk Access").font(.headline)
                Text("Without it, macOS hides other apps' containers and some caches, so results are incomplete. KachraClean still only reads during a scan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { model.openFullDiskAccessSettings() }.glassButton()
            Button("Check Again") { model.recheckFullDiskAccess() }.buttonStyle(.borderless)
        }
        .padding(14)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Shown before scanning without Full Disk Access. Without it, macOS can pause the scan with
/// consent prompts for other apps' data, so we explain, offer the fix, and offer a limited scan.
struct PermissionGate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill").font(.system(size: 40)).foregroundStyle(.indigo.gradient)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let KachraClean see your whole disk").font(.title2.bold())
                    Text("macOS hides other apps' caches and data unless you grant Full Disk Access.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Click **Open Settings** below.")
                step(2, "Turn on **KachraClean** in the list. If it isn't there, click + and choose the app.")
                step(3, "Come back here. The scan starts by itself.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Label("KachraClean only reads during a scan. Nothing leaves your Mac.", systemImage: "eye")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Scan Without It") { model.scan() }
                    .help("Skips other apps' containers and macOS caches, so results are smaller.")
                Spacer()
                Button("Cancel", role: .cancel) { model.showPermissionGate = false }
                Button("Open Settings") { model.openFullDiskAccessSettings() }
                    .keyboardShortcut(.defaultAction)
                    .prominentGlassButton()
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.bold))
                .frame(width: 22, height: 22)
                .background(.indigo.opacity(0.2), in: Circle())
            Text(text)
        }
    }
}
