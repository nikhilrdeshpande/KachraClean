import KachraCore
import QuickLook
import SwiftUI

struct CategoryDetailView: View {
    @Environment(AppModel.self) private var model
    var category: Category
    var onBack: () -> Void
    @State private var filter: Safety?
    @State private var sort: Sort = .size

    enum Sort: String, CaseIterable {
        case size = "Size"
        case name = "Name"
        case activity = "Last activity"
    }

    var body: some View {
        @Bindable var model = model
        let all = model.findings(in: category)
        let shown = sorted(all.filter(matches))
        let largest = max(shown.map(\.bytes).max() ?? 1, 1)

        // The details panel lives inside the detail column. SwiftUI's `.inspector` asks the window to
        // grow toward the screen edge, which clipped the sidebar when the window couldn't.
        HStack(spacing: 0) {
        VStack(spacing: 0) {
            header(all: all, shown: shown)
            if all.isEmpty {
                ContentUnavailableView {
                    Label("Nothing left here", systemImage: "checkmark.circle")
                } description: {
                    Text("Everything in \(category.title.lowercased()) has been cleaned or ignored.")
                } actions: {
                    Button("Back to Overview", action: onBack)
                }
                .frame(maxHeight: .infinity)
            } else if shown.isEmpty {
                ContentUnavailableView {
                    Label("No matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No items match the current filter.")
                } actions: {
                    Button("Show All") { filter = nil; model.search = "" }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $model.focused) {
                    ForEach(shown) { finding in
                        FindingRow(finding: finding, largest: largest)
                            .tag(finding.id)
                            .contextMenu { contextMenu(for: finding) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .safeAreaPadding(.bottom, 96)  // floating action bar
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if model.report != nil, model.phase != .scanning, category != .trash, !all.isEmpty {
                let shownIDs = Set(shown.map(\.id))
                ActionBar(category: category,
                          hiddenSelected: all.filter { model.selection.contains($0.id) && !shownIDs.contains($0.id) }.count)
            }
        }
        if model.showInspector {
            Divider()
            InspectorView(category: category)
                .frame(width: 300)
                .background(.background.secondary)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        }
        .animation(.snappy(duration: 0.25), value: model.showInspector)
        .toolbar {
            ToolbarItem {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        .quickLookPreview(Bindable(model).previewURL)
        .background {
            // Space previews the focused item, like Finder.
            Button("") { if let f = model.focusedFinding { model.preview(f) } }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
        .onChange(of: category) {
            model.focused = nil
            filter = nil
        }
        // Standard Mac pattern: the inspector follows the selection instead of always taking space.
        .onChange(of: model.focused) { _, focused in if focused != nil { model.showInspector = true } }
        .onAppear { if model.focused != nil { model.showInspector = true } }
    }

    private func header(all: [Finding], shown: [Finding]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(category.title, systemImage: category.symbol)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary, category.tint)
                Spacer()
                Text(Format.bytes(model.total(category)))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            Text(category.blurb).foregroundStyle(.secondary)
            if category.countsAsReclaimable {
                SafetySplitBar(safe: model.total(category, safety: .safe),
                               review: model.total(category, safety: .review),
                               risky: model.total(category, safety: .risky), height: 8)
            }
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    Text("All \(all.count)").tag(Safety?.none)
                    ForEach(Safety.allCases.filter { s in all.contains { $0.safety == s } }, id: \.self) { s in
                        Text("\(s.label) \(all.filter { $0.safety == s }.count)").tag(Safety?.some(s))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                SearchField(text: Bindable(model).search, prompt: "Filter")
                    .frame(minWidth: 120, maxWidth: 220)
                Spacer(minLength: 0)
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Sort")
                if category == .trash {
                    Button("Open Trash in Finder") { model.openTrash() }.fixedSize()
                } else {
                    // Acts on what's on screen, so a search narrows what gets selected.
                    let filtered = shown.count != all.count
                    let safe = shown.filter { $0.safety == .safe }.count
                    let upToReview = shown.filter { $0.safety <= .review }.count
                    Menu {
                        Button("Select Safe (\(safe))") { model.select(shown, upTo: .safe) }
                            .disabled(safe == 0)
                        Button("Select Safe and Review (\(upToReview))") { model.select(shown, upTo: .review) }
                            .disabled(upToReview == 0)
                        if category == .apps || category == .largeFiles {
                            Button("Select All (\(shown.count))") { model.select(shown, upTo: .risky) }
                        }
                        Divider()
                        Button(filtered ? "Deselect Shown" : "Deselect All") { model.deselect(shown) }
                        if filtered {
                            Button("Deselect Everything in \(category.title)") { model.deselect(all) }
                        }
                    } label: {
                        Label(filtered ? "Select Shown" : "Select", systemImage: "checklist")
                    }
                    .fixedSize()
                }
            }
            if category == .apps {
                Label("Removing an app also removes its settings and data. Nothing here is pre-selected, and KachraClean asks before removing apps.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func matches(_ f: Finding) -> Bool {
        if let filter, f.safety != filter { return false }
        let q = model.search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return f.title.localizedCaseInsensitiveContains(q)
            || (f.owner ?? "").localizedCaseInsensitiveContains(q)
            || f.paths.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private func sorted(_ items: [Finding]) -> [Finding] {
        switch sort {
        case .size: items.sorted { $0.bytes > $1.bytes }
        case .name: items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .activity: items.sorted { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
        }
    }

    @ViewBuilder
    private func contextMenu(for finding: Finding) -> some View {
        Button(model.selection.contains(finding.id) ? "Deselect" : "Select") { model.toggle(finding) }
            .disabled(!model.isSelectable(finding))
        if model.canPreview(finding) { Button("Quick Look") { model.preview(finding) } }
        Button("Show in Finder") { model.reveal(finding) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finding.paths.joined(separator: "\n"), forType: .string)
        }
        Divider()
        Button("Never Suggest This Again") { model.ignore(finding) }
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    var finding: Finding
    var largest: Int64

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { model.selection.contains(finding.id) }, set: { _ in model.toggle(finding) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!model.isSelectable(finding))
            .accessibilityLabel("Select \(finding.title)")

            ItemIcon(finding: finding, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.title).font(.body.weight(.medium)).lineLimit(1)
                    if let activity = activityChip { Text(activity).font(.caption).foregroundStyle(.tertiary) }
                    if let project = finding.details["usedInFirst"] {
                        Label("Used by \(project)", systemImage: "folder.fill")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                            .lineLimit(1)
                            .help(finding.details["usedIn"] ?? "")
                    }
                }
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            SafetyBadge(safety: finding.safety)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Format.bytes(finding.bytes)).monospacedDigit().font(.body.weight(.medium))
                Capsule()
                    .fill(finding.category.tint.opacity(0.7))
                    .frame(width: max(3, 70 * Double(finding.bytes) / Double(largest)), height: 3)
                    .frame(width: 70, alignment: .trailing)
            }
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.title), \(Format.bytes(finding.bytes)), \(finding.safety.label)")
    }

    private var subtitle: String {
        if finding.category == .apps { return finding.details["usage"] ?? finding.reason }
        return finding.reason
    }

    private var activityChip: String? {
        guard finding.category == .projectArtifacts || finding.category == .apps,
              let date = finding.lastActivity else { return nil }
        return Format.relative(date)
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    var category: Category

    var body: some View {
        if let f = model.focusedFinding {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        ItemIcon(finding: f, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.title3.bold()).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            if let owner = f.owner, owner != f.title { Text(owner).foregroundStyle(.secondary) }
                        }
                    }
                    HStack {
                        Text(Format.bytes(f.bytes)).font(.system(.title, design: .rounded).weight(.semibold))
                        Spacer()
                        SafetyBadge(safety: f.safety)
                    }
                    section("Why") { Text(f.reason).fixedSize(horizontal: false, vertical: true) }
                    if !facts(f).isEmpty {
                        section("Evidence") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(facts(f), id: \.0) { key, value in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(key).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                                        Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                    if let commands = f.details["commands"], !commands.isEmpty {
                        section("Free it with Docker's own commands") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(commands.split(separator: "\n").map(String.init), id: \.self) { line in
                                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(parts[0]).font(.callout)
                                        HStack {
                                            Text(parts.last ?? "").font(.caption.monospaced()).textSelection(.enabled)
                                            Spacer()
                                            Button("Copy") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(parts.last ?? "", forType: .string)
                                            }
                                            .controlSize(.small)
                                        }
                                    }
                                }
                                Text("Run these in Terminal. KachraClean never runs them for you.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    section(f.paths.count == 1 ? "Location" : "\(f.paths.count) locations") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(f.paths.prefix(8), id: \.self) { p in
                                Text(Format.path(p)).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            if f.paths.count > 8 {
                                Text("and \(f.paths.count - 8) more").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    VStack(spacing: 8) {
                        Button {
                            model.toggle(f)
                        } label: {
                            Label(model.selection.contains(f.id) ? "Deselect" : "Select for Cleaning",
                                  systemImage: model.selection.contains(f.id) ? "minus.circle" : "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .glassButton()
                        .disabled(!model.isSelectable(f))
                        if model.canPreview(f) {
                            Button {
                                model.preview(f)
                            } label: {
                                Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity)
                            }
                            .controlSize(.large)
                            .glassButton()
                            .help("Preview (Space)")
                        }
                        HStack {
                            Button("Show in Finder") { model.reveal(f) }
                            Spacer()
                            Button("Never Suggest Again") { model.ignore(f) }
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        if f.paths.first?.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/") == true {
                            Button("Show in Disk Explorer") { model.showInExplorer(f) }
                                .buttonStyle(.link)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: category.symbol).font(.largeTitle).foregroundStyle(category.tint)
                Text(category.title).font(.headline)
                Text(category.blurb).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Select an item to see why it's suggested.").font(.callout).foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// Human-readable evidence, in a sensible order.
    private func facts(_ f: Finding) -> [(String, String)] {
        let labels: [(String, String)] = [
            ("repo", "Repository"), ("usedIn", "Used by"), ("project", "Project"), ("kind", "Kind"), ("lastActivity", "Last activity"), ("lockfile", "Lockfile"),
            ("git", "Git repo"), ("usage", "Usage"), ("bundleID", "Bundle ID"), ("copies", "Copies"),
            ("keep", "Keeping"), ("folders", "Folders"), ("folder", "Folder"), ("revisions", "Revisions"),
            ("files", "Files"), ("shared", "Shared"), ("external", "Linked files"), ("command", "CLI equivalent"),
            ("installs", "Installs"), ("source", "Downloaded from"), ("docker", "Docker reports"),
        ]
        var result = labels.compactMap { key, label in
            f.details[key].map { (label, key == "keep" ? Format.path($0) : $0) }
        }
        if f.category == .apps, let app = f.details["appBytes"].flatMap(Int64.init),
           let related = f.details["relatedBytes"].flatMap(Int64.init) {
            result.append(("App", Format.bytes(app)))
            result.append(("Its data", Format.bytes(related)))
        }
        return result
    }
}

/// Compact in-content search field (a toolbar search field would widen the detail column).
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .background {
            // ⌘F focuses the filter.
            Button("") { focused = true }.keyboardShortcut("f").opacity(0)
        }
    }
}
