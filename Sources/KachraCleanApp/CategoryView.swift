import KachraCore
import SwiftUI

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    var category: Category
    @State private var filter: Safety?

    var body: some View {
        let all = model.findings(in: category)
        let shown = all.filter { filter == nil || $0.safety == filter }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.title2.bold())
                    Text("\(all.count) items · \(Format.bytes(model.total(category)))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Picker("Show", selection: $filter) {
                    Text("All").tag(Safety?.none)
                    ForEach(Safety.allCases, id: \.self) { Text($0.label).tag(Safety?.some($0)) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Menu("Select") {
                    Button("All safe items") { model.selectAll(in: category, upTo: .safe) }
                    Button("Safe and review items") { model.selectAll(in: category, upTo: .review) }
                    Divider()
                    Button("None") { model.deselectAll(in: category) }
                }
                .fixedSize()
            }
            .padding(16)
            Divider()
            if category == .apps {
                Text("Removing an app also removes its settings and data. Nothing is pre-selected here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            List(shown) { finding in
                FindingRow(finding: finding)
            }
            .listStyle(.inset)
        }
    }
}

struct FindingRow: View {
    @Environment(AppModel.self) private var model
    var finding: Finding
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { model.selection.contains(finding.id) },
                    set: { _ in model.toggle(finding) }
                ))
                .labelsHidden()
                .disabled(!model.isSelectable(finding))

                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).font(.body.weight(.medium)).lineLimit(1)
                    Text(finding.reason).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                }
                Spacer(minLength: 12)
                SafetyBadge(safety: finding.safety)
                Text(Format.bytes(finding.bytes))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.borderless)
            }
            if expanded { details.padding(.leading, 30) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let activity = Format.relative(finding.lastActivity) {
                detailLine("Last activity", activity)
            }
            ForEach(finding.details.sorted(by: { $0.key < $1.key }).filter { !["rule", "appBytes", "relatedBytes"].contains($0.key) },
                    id: \.key) { key, value in
                detailLine(key.capitalized, value)
            }
            ForEach(finding.paths.prefix(6), id: \.self) { path in
                Text(Format.path(path)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if finding.paths.count > 6 {
                Text("… and \(finding.paths.count - 6) more").font(.caption).foregroundStyle(.secondary)
            }
            Button("Show in Finder") { model.reveal(finding) }.controlSize(.small)
        }
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.caption.weight(.semibold)).frame(width: 110, alignment: .leading)
            Text(value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct SafetyBadge: View {
    var safety: Safety

    var body: some View {
        Text(safety.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(safety.color)
            .background(safety.color.opacity(0.12), in: Capsule())
    }
}
