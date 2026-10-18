import AppKit
import KachraCore
import QuickLook
import SwiftUI

/// Every folder in the home folder, biggest first, in Finder-style columns, with what the scan
/// knows laid on top (docs/spec/06-disk-explorer.md).
struct DiskExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var volume = VolumeInfo.current()

    var body: some View {
        let explorer = model.explorer
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(Array(explorer.columns.enumerated()), id: \.element.id) { index, column in
                                ExplorerColumnView(column: column, index: index)
                                    .frame(width: 290)
                                    .id(column.id)
                                Divider()
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .onChange(of: explorer.columns.last?.id) { _, last in
                        withAnimation(.snappy) { proxy.scrollTo(last, anchor: .trailing) }
                    }
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity)
            Divider()
            ExplorerDetailsView()
                .frame(width: 300)
                .background(.background.secondary)
        }
        .onAppear {
            explorer.start(avoidingProtected: !model.hasFullDiskAccess)
            volume = VolumeInfo.current()
        }
        .onChange(of: model.hasFullDiskAccess) { _, granted in explorer.start(avoidingProtected: !granted) }
        .quickLookPreview(Bindable(model).previewURL)
        .background {
            // Space previews the selected file, like Finder.
            Button("") { preview(explorer.selectedRow) }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
        .confirmationDialog(
            "Move “\(explorer.confirmTrash?.entry.name ?? "")” to the Trash?",
            isPresented: Binding(get: { explorer.confirmTrash != nil }, set: { if !$0 { explorer.confirmTrash = nil } }),
            presenting: explorer.confirmTrash
        ) { row in
            Button("Move to Trash", role: .destructive) { model.trashFromExplorer(row) }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(confirmationMessage(row))
        }
    }

    private var header: some View {
        let explorer = model.explorer
        let rootColumn = explorer.columns.first
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Disk Explorer").font(.title2.bold())
                if explorer.isMeasuring { ProgressView().controlSize(.small) }
                Spacer()
                if explorer.root.path != explorer.home.path {
                    Button("Home") { explorer.open(explorer.home) }
                }
                Button("Choose Folder…") { chooseFolder() }
                Button {
                    explorer.reload()
                    volume = VolumeInfo.current()
                } label: {
                    Label("Measure Again", systemImage: "arrow.clockwise")
                }
                .help("Forget the measured sizes and measure again")
            }
            .controlSize(.regular)
            if let rootColumn {
                Text(summary(rootColumn)).font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// "Home folder 310 GB · rest of the disk 120 GB (macOS, apps, other users) · 200 GB free".
    private func summary(_ column: ExplorerModel.Column) -> String {
        let explorer = model.explorer
        let name = explorer.root.path == explorer.home.path ? "Home folder" : Format.path(explorer.root.path)
        let measuring = column.measuring
        var parts = ["\(name) \(Format.bytes(column.bytes))\(column.complete ? "" : "+")"]
        if measuring > 0 || !column.listed {
            parts.append("measuring \(measuring) of \(column.rows.count) items")
        } else if explorer.root.path == explorer.home.path, let volume {
            let used = volume.totalBytes - volume.freeBytes
            let rest = used - column.bytes
            if rest > 0 { parts.append("rest of the disk \(Format.bytes(rest)) (macOS, apps, other users)") }
            parts.append("\(Format.bytes(volume.freeBytes)) free")
        }
        if !model.hasFullDiskAccess { parts.append("other apps' containers skipped without Full Disk Access") }
        return parts.joined(separator: " · ")
    }

    private func confirmationMessage(_ row: ExplorerModel.Row) -> String {
        let size = Format.bytes(row.bytes) + (row.size?.complete == false ? "+" : "")
        let undo = "You can undo right after, or restore it from the Trash."
        if let finding = model.findingIndex.at(row.id).first {
            return "\(size). KachraClean suggests this (\(finding.category.title.lowercased())): \(finding.reason) \(undo)"
        }
        let inside = model.findingIndex.inside(row.id)
        if !inside.findings.isEmpty {
            return "\(size). It holds \(inside.findings.count) KachraClean suggestions (\(Format.bytes(inside.bytes))) and other files KachraClean doesn't recognise. \(undo)"
        }
        return "\(size). KachraClean doesn't recognise this, so make sure you don't need it. \(undo)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Explore"
        panel.directoryURL = model.explorer.root
        if panel.runModal() == .OK, let url = panel.url { model.explorer.open(url) }
    }

    private func preview(_ row: ExplorerModel.Row?) {
        guard let row, !row.entry.isDirectory || row.entry.isPackage else { return }
        model.previewURL = row.url
    }
}

// MARK: - Column

struct ExplorerColumnView: View {
    @Environment(AppModel.self) private var model
    var column: ExplorerModel.Column
    var index: Int

    var body: some View {
        let total = max(column.bytes, 1)
        List(selection: Binding(get: { column.selected }, set: { model.explorer.select($0, in: index) })) {
            ForEach(column.rows) { row in
                ExplorerRowView(row: row, total: total)
                    .tag(row.id)
                    .contextMenu { contextMenu(row) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if column.locked {
                ContentUnavailableView {
                    Label("Needs Full Disk Access", systemImage: "lock.fill")
                } description: {
                    Text("macOS only lets KachraClean look inside other apps' containers with Full Disk Access.")
                } actions: {
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                }
            } else if !column.listed {
                ProgressView()
            } else if column.rows.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if column.listed, !column.locked {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private var footer: String {
        let count = "\(column.rows.count) \(column.rows.count == 1 ? "item" : "items")"
        let measuring = column.measuring
        return measuring > 0 ? "\(count) · measuring \(measuring)"
                             : "\(count) · \(Format.bytes(column.bytes))\(column.complete ? "" : "+")"
    }

    @ViewBuilder
    private func contextMenu(_ row: ExplorerModel.Row) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
        if !row.entry.isDirectory || row.entry.isPackage {
            Button("Quick Look") { model.previewURL = row.url }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.id, forType: .string)
        }
        Divider()
        Button("Move to Trash…") { model.explorer.confirmTrash = row }
            .disabled(model.explorerRefusal(row) != nil || model.phase == .cleaning || model.isScanning)
    }
}

struct ExplorerRowView: View {
    @Environment(AppModel.self) private var model
    var row: ExplorerModel.Row
    var total: Int64

    var body: some View {
        let finding = model.findingIndex.at(row.id).first
        let inside = row.entry.isDirectory && finding == nil ? model.findingIndex.inside(row.id) : nil
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(finding.map { AnyShapeStyle($0.category.tint) } ?? AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.entry.name).lineLimit(1).truncationMode(.middle)
                    if let finding {
                        Image(systemName: finding.safety.symbol)
                            .font(.caption2)
                            .foregroundStyle(finding.safety.color)
                            .help("\(finding.category.title): \(finding.safety.label.lowercased())")
                    }
                }
                GeometryReader { geo in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(barStyle(finding))
                                .frame(width: geo.size.width * min(1, Double(row.bytes) / Double(total)))
                        }
                }
                .frame(height: 3)
                if let finding {
                    Text(finding.category.title).font(.caption2).foregroundStyle(finding.category.tint)
                } else if let inside, !inside.findings.isEmpty {
                    Text("\(inside.findings.count) \(inside.findings.count == 1 ? "suggestion" : "suggestions") · \(Format.bytes(inside.bytes))")
                        .font(.caption2)
                        .foregroundStyle(inside.safeBytes > 0 ? .green : .orange)
                }
            }
            Spacer(minLength: 4)
            if let size = row.size {
                Text(Format.bytes(size.bytes) + (size.complete ? "" : "+"))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(size.complete ? "" : "Part of this couldn't be read, so it's at least this big.")
            } else {
                ProgressView().controlSize(.mini)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(row.entry.isDirectory ? 1 : 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.entry.name), \(row.size.map { Format.bytes($0.bytes) } ?? "measuring")")
    }

    private func barStyle(_ finding: Finding?) -> AnyShapeStyle {
        if let finding { return AnyShapeStyle(finding.category.tint.gradient) }
        return AnyShapeStyle(Color.secondary.opacity(0.5))
    }

    private var symbol: String {
        let entry = row.entry
        if entry.isSymbolicLink { return "arrow.up.right.square" }
        if entry.isPackage { return entry.url.pathExtension == "app" ? "app.dashed" : "shippingbox.fill" }
        if entry.isDirectory { return "folder.fill" }
        switch entry.url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi": return "film"
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp": return "photo"
        case "zip", "gz", "tar", "xz", "7z", "rar": return "doc.zipper"
        case "dmg", "iso", "img": return "externaldrive"
        case "safetensors", "gguf", "ckpt", "pt", "pth", "bin", "onnx": return "brain"
        default: return "doc"
        }
    }
}

// MARK: - Details

struct ExplorerDetailsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let row = model.explorer.selectedRow {
            details(row)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("Where your space is").font(.headline)
                Text("Every folder, biggest first. Suggestions from the last scan are marked, and folders that hold them say how much.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("A + means part of a folder couldn't be read, so it's at least that big.")
                    .font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
        }
    }

    private func details(_ row: ExplorerModel.Row) -> some View {
        let findings = model.findingIndex.at(row.id)
        let inside = row.entry.isDirectory ? model.findingIndex.inside(row.id) : FindingIndex.Summary()
        let refusal = model.explorerRefusal(row)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: row.id))
                        .resizable().frame(width: 44, height: 44)
                    Text(row.entry.name).font(.title3.bold()).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let size = row.size {
                        Text(Format.bytes(size.bytes) + (size.complete ? "" : "+"))
                            .font(.system(.title, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                        if !size.complete {
                            Text("At least this much. Part of it couldn't be read\(model.hasFullDiskAccess ? "" : " without Full Disk Access").")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if row.entry.isDirectory {
                            Text("\(size.items.formatted()) items inside").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                    }
                    if let modified = row.entry.modified, let ago = Format.relative(modified) {
                        Text("Modified \(ago)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach(findings) { finding in
                    section("KachraClean suggests") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(finding.category.title, systemImage: finding.category.symbol)
                                    .foregroundStyle(finding.category.tint)
                                Spacer()
                                SafetyBadge(safety: finding.safety)
                            }
                            Text(finding.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Button("Open in \(finding.category.title)") { open(finding) }.buttonStyle(.link)
                        }
                    }
                }
                if !inside.findings.isEmpty {
                    section("Inside: \(inside.findings.count) suggestions") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(Format.bytes(inside.bytes)) suggested, \(Format.bytes(inside.safeBytes)) of it safe.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(byCategory(inside.findings), id: \.0) { category, bytes in
                                Button {
                                    model.navigationRequest = .category(category)
                                } label: {
                                    HStack {
                                        Label(category.title, systemImage: category.symbol).foregroundStyle(category.tint)
                                        Spacer()
                                        Text(Format.bytes(bytes)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .font(.callout)
                            }
                        }
                    }
                } else if findings.isEmpty, model.report != nil {
                    Text("Not something the scan recognises. Check what it is before removing it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                section("Location") {
                    Text(Format.path(row.id)).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 8) {
                    Button(role: .destructive) {
                        model.explorer.confirmTrash = row
                    } label: {
                        Label("Move to Trash…", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .glassButton()
                    .disabled(refusal != nil || model.phase == .cleaning || model.isScanning)
                    .help("Moves it to the Trash (⌘⌫). Undo puts it back.")
                    if let refusal {
                        Label(refusal, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !row.entry.isDirectory || row.entry.isPackage {
                        Button {
                            model.previewURL = row.url
                        } label: {
                            Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .glassButton()
                        .help("Preview (Space)")
                    }
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                        Spacer()
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.id, forType: .string)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func open(_ finding: Finding) {
        model.focused = finding.id
        model.navigationRequest = .category(finding.category)
    }

    private func byCategory(_ findings: [Finding]) -> [(Category, Int64)] {
        Dictionary(grouping: findings, by: \.category)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.bytes }) }
            .sorted { $0.1 > $1.1 }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
