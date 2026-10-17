import KachraCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    var open: (Category) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                switch model.phase {
                case .scanning:
                    ScanningView()
                case .idle:
                    WelcomeView()
                case .ready, .cleaning:
                    if model.report != nil { ResultsView(open: open) } else { WelcomeView() }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 110)  // room for the floating action bar
            .frame(maxWidth: 1040)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Before the first scan

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 64))
                .foregroundStyle(.indigo.gradient)
                .padding(.top, 40)
            VStack(spacing: 8) {
                Text("Let's find the kachra").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Caches, project dependencies, AI models and duplicates, all explained before anything moves.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.requestScan()
            } label: {
                Label("Scan My Mac", systemImage: "magnifyingglass").font(.title3.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
            .controlSize(.extraLarge)
            .prominentGlassButton()
            .keyboardShortcut(.defaultAction)

            HStack(alignment: .top, spacing: 18) {
                Promise(symbol: "eye", title: "Read-only scan",
                        text: "Scanning never changes a single file.")
                Promise(symbol: "text.bubble", title: "Every item explained",
                        text: "Each suggestion says why it's safe, or why to look first.")
                Promise(symbol: "arrow.uturn.backward", title: "Always undoable",
                        text: "Cleaning moves things to the Trash. Undo puts them back.")
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    struct Promise: View {
        var symbol: String
        var title: String
        var text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.indigo)
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - While scanning

/// One calm, stable working state: the layout is fixed; only checkmarks and numbers change.
struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.04, model.scanProgress))
                    .stroke(.indigo.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: model.scanProgress)
                VStack(spacing: 4) {
                    Text("Scanning").font(.title2.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.duration(context.date.timeIntervalSince(model.scanStarted ?? context.date)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 170, height: 170)
            .padding(.top, 30)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning, \(Int(model.scanProgress * 100)) percent")

            VStack(spacing: 0) {
                ForEach(Array(model.steps.enumerated()), id: \.offset) { index, entry in
                    HStack(spacing: 12) {
                        Group {
                            switch entry.state {
                            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                            case .running: ProgressView().controlSize(.small)
                            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .frame(width: 20)
                        Text(entry.step.title)
                            .foregroundStyle(entry.state == .pending ? .secondary : .primary)
                        Spacer()
                        if case .done(let found) = entry.state, found > 0 {
                            Text(Format.bytes(found)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    if index < model.steps.count - 1 { Divider().padding(.leading, 48) }
                }
            }
            .frame(maxWidth: 460)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

            Text("Only reading file sizes and dates. Nothing is changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel Scan") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Results

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    var open: (Category) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            hero
            VStack(alignment: .leading, spacing: 14) {
                Text("By category").font(.title2.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(Category.displayOrder.filter { model.total($0) > 0 }, id: \.self) { category in
                        CategoryCard(category: category) { open(category) }
                    }
                }
            }
            footer
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 40) {
            SunburstView(findings: model.visibleFindings, onOpen: open)
                .frame(width: 330, height: 330)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ready to clean").font(.title3).foregroundStyle(.secondary)
                    Text(Format.bytes(model.selectedBytes))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .foregroundStyle(model.selectedNeedingReview > 0 ? AnyShapeStyle(.orange.gradient)
                                                                          : AnyShapeStyle(.green.gradient))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button {
                        model.cleanSelection()
                    } label: {
                        Label("Clean \(Format.bytes(model.selectedBytes))", systemImage: "sparkles")
                            .font(.headline).padding(.horizontal, 8).padding(.vertical, 2)
                    }
                    .controlSize(.extraLarge)
                    .prominentGlassButton()
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty || model.phase != .ready)
                    .help("Moves the selected items to the Trash. Undo puts them back.")
                    Button("Review") { open(Category.displayOrder.first { model.total($0) > 0 } ?? .projectArtifacts) }
                        .controlSize(.extraLarge)
                        .glassButton()
                }
                if let volume = model.report?.volume { DiskMeter(volume: volume, safe: model.safeBytes,
                                                                 review: model.reclaimable - model.safeBytes) }
            }
        }
    }

    private var summary: String {
        let count = model.selection.count
        let more = Format.bytes(max(0, model.reclaimable - model.selectedBytes))
        if model.selectedNeedingReview > 0 {
            return "\(count) items selected, \(model.selectedNeedingReview) of them marked review. \(more) more is not selected."
        }
        return "\(count) safe items that regenerate by themselves. \(more) more is worth a look."
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
            Text("Scanned \(Format.relative(model.report?.createdAt) ?? "")")
            if model.lastScanWasLimited {
                Text("·")
                Text("Limited scan (no Full Disk Access)").foregroundStyle(.orange)
            }
            if model.ignoredCount > 0 {
                Text("·")
                Text("\(model.ignoredCount) ignored paths")
            }
            Spacer()
            Button("Scan Again") { model.requestScan() }.buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    var category: Category
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let items = model.findings(in: category)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: category.symbol)
                        .font(.title3)
                        .foregroundStyle(category.tint)
                        .frame(width: 36, height: 36)
                        .background(category.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.headline)
                    Text(Format.bytes(model.total(category)))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                if category.countsAsReclaimable {
                    SafetySplitBar(safe: model.total(category, safety: .safe),
                                   review: model.total(category, safety: .review),
                                   risky: model.total(category, safety: .risky))
                }
                Text(insight(items))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(hovering ? 0.7 : 0.4), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("\(category.title), \(Format.bytes(model.total(category)))")
        .accessibilityHint(insight(items))
    }

    /// A specific, human sentence about what's in the category.
    private func insight(_ items: [Finding]) -> String {
        switch category {
        case .projectArtifacts:
            let projects = Set(items.compactMap { $0.details["project"] }).count
            let idle = items.filter { $0.safety == .safe }.count
            return "\(items.count) folders in \(projects) projects · \(idle) idle with a lockfile"
        case .models:
            let biggest = items.max { $0.bytes < $1.bytes }
            let largest = biggest.map { " · largest \($0.title.split(separator: "/").last ?? "") (\(Format.bytes($0.bytes)))" } ?? ""
            return "\(items.count) models and datasets" + largest
        case .largeFiles:
            let kinds = Dictionary(grouping: items) { $0.owner ?? "File" }
                .sorted { $0.value.count > $1.value.count }
                .prefix(3)
                .map { "\($0.value.count) \($0.key.lowercased())\($0.value.count == 1 ? "" : "s")" }
            return ListFormatter.localizedString(byJoining: kinds)
        case .apps:
            let unused = items.filter { $0.details["unused"] == "yes" }.count
            return unused > 0 ? "\(items.count) apps · \(unused) not opened in \(model.unusedAppDays)+ days"
                              : "\(items.count) apps with their data"
        case .duplicates:
            let copies = items.reduce(0) { $0 + $1.paths.count }
            return "\(copies) extra copies in \(items.count) groups · one copy always kept"
        default:
            let top = items.prefix(3).map { $0.owner ?? $0.title }
            return top.isEmpty ? category.blurb : "Mostly " + ListFormatter.localizedString(byJoining: top)
        }
    }
}

/// The disk as one bar: used, what's safe to reclaim, what's worth a look, free.
struct DiskMeter: View {
    var volume: VolumeInfo
    var safe: Int64
    var review: Int64

    var body: some View {
        let total = max(Double(volume.totalBytes), 1)
        let used = Double(volume.totalBytes - volume.freeBytes)
        let safeW = min(Double(safe), used) / total
        let reviewW = min(Double(review), used - min(Double(safe), used)) / total
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(.secondary.opacity(0.45)).frame(width: geo.size.width * (used / total - safeW - reviewW))
                    Rectangle().fill(.orange.gradient).frame(width: geo.size.width * reviewW)
                    Rectangle().fill(.green.gradient).frame(width: geo.size.width * safeW)
                    Rectangle().fill(.quaternary)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                legend(.green, "Safe")
                legend(.orange, "Worth a look")
                legend(.secondary.opacity(0.45), "Other data")
                Spacer()
                Text("\(Format.bytes(volume.freeBytes)) free of \(Format.bytes(volume.totalBytes))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if volume.purgeableBytes > 0 {
                Text("macOS can also free \(Format.bytes(volume.purgeableBytes)) of purgeable space on its own when needed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 460)
    }

    private func legend(_ color: some ShapeStyle, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }
}
