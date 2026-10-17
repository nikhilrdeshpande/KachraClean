import KachraCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    var show: (Category) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let report = model.report {
                    if let volume = report.volume { DiskBar(volume: volume, reclaimable: report.reclaimable) }
                    totals(report)
                    breakdown(report)
                    Text("Scanned \(Format.relative(report.createdAt) ?? "") · KachraClean only reads during a scan. Cleaning moves items to the Trash.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !model.isScanning {
                    ContentUnavailableView {
                        Label("No scan yet", systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text("Scan to find caches, project dependencies, models and duplicates. Nothing is changed until you choose.")
                    } actions: {
                        Button("Scan My Mac") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let report = model.report {
                Text("\(Format.bytes(report.reclaimable)) you could reclaim").font(.largeTitle.bold())
            } else {
                Text("Let's find the kachra").font(.largeTitle.bold())
            }
            Spacer()
            if case .scanning(let step) = model.phase {
                ProgressView().controlSize(.small)
                Text("Scanning \(step)…").foregroundStyle(.secondary)
            }
        }
    }

    private func totals(_ report: ScanReport) -> some View {
        HStack(spacing: 16) {
            StatTile(title: "Safe to remove", value: Format.bytes(model.safeBytes),
                     caption: "Regenerates by itself. Pre-selected.", tint: .green)
            StatTile(title: "Worth a look", value: Format.bytes(report.reclaimable - model.safeBytes),
                     caption: "Active projects, models, duplicates.", tint: .orange)
            if let v = report.volume {
                StatTile(title: "Purgeable", value: Format.bytes(v.purgeableBytes),
                         caption: "macOS frees this on demand.", tint: .secondary)
            }
        }
    }

    private func breakdown(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where the space is").font(.title3.bold())
            // Apps and the Trash aren't part of the reclaimable total, so they get no bar here.
            ForEach(ContentView.categories.filter { model.total($0) > 0 && $0 != .apps && $0 != .trash },
                    id: \.self) { category in
                Button { show(category) } label: {
                    HStack {
                        Label(category.title, systemImage: category.symbol).frame(width: 260, alignment: .leading)
                        GeometryReader { geo in
                            let max = ContentView.categories.map(model.total).max() ?? 1
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.tint.opacity(0.6))
                                .frame(width: geo.size.width * CGFloat(model.total(category)) / CGFloat(max))
                        }
                        .frame(height: 10)
                        Text(Format.bytes(model.total(category)))
                            .monospacedDigit()
                            .frame(width: 90, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var caption: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DiskBar: View {
    var volume: VolumeInfo
    var reclaimable: Int64

    var body: some View {
        let total = max(Double(volume.totalBytes), 1)
        let used = Double(volume.totalBytes - volume.freeBytes)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 5).fill(.blue.opacity(0.7))
                        .frame(width: geo.size.width * used / total)
                    RoundedRectangle(cornerRadius: 5).fill(.green.opacity(0.8))
                        .frame(width: geo.size.width * min(Double(reclaimable), used) / total)
                        .offset(x: geo.size.width * (used - min(Double(reclaimable), used)) / total)
                }
            }
            .frame(height: 14)
            Text("\(Format.bytes(volume.freeBytes)) free of \(Format.bytes(volume.totalBytes)) · green: what KachraClean found")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
