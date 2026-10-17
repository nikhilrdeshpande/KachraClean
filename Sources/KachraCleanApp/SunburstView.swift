import KachraCore
import SwiftUI

/// Two-ring sunburst of what the scan found: categories inside, their biggest items outside.
/// Sunbursts convey hierarchy better than treemaps on first use (Stasko et al.), and tiny slices
/// are consolidated so every visible petal is big enough to hover (DaisyDisk's approach).
struct SunburstView: View {
    struct Segment: Identifiable {
        let id: String
        let category: Category
        let title: String
        let bytes: Int64
        let start: Double  // fraction 0...1
        let end: Double
        let ring: Int  // 0 = categories, 1 = items
        let safety: Safety?
    }

    var findings: [Finding]
    var onOpen: (Category) -> Void
    @State private var hovered: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var segments: [Segment] {
        let usable = findings.filter { $0.category.countsAsReclaimable && $0.bytes > 0 }
        let total = Double(usable.reduce(0) { $0 + $1.bytes })
        guard total > 0 else { return [] }
        var result: [Segment] = []
        var cursor = 0.0
        for category in Category.displayOrder {
            let items = usable.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
            let catBytes = items.reduce(0) { $0 + $1.bytes }
            guard catBytes > 0 else { continue }
            let catStart = cursor
            let catEnd = cursor + Double(catBytes) / total
            result.append(Segment(id: "cat-\(category.rawValue)", category: category, title: category.title,
                                  bytes: catBytes, start: catStart, end: catEnd, ring: 0, safety: nil))
            var itemCursor = catStart
            var otherBytes: Int64 = 0
            var otherCount = 0
            for item in items {
                let fraction = Double(item.bytes) / total
                if fraction < 0.006 {  // too thin to hover: consolidate
                    otherBytes += item.bytes
                    otherCount += 1
                    continue
                }
                result.append(Segment(id: item.id, category: category, title: item.title, bytes: item.bytes,
                                      start: itemCursor, end: itemCursor + fraction, ring: 1, safety: item.safety))
                itemCursor += fraction
            }
            if otherBytes > 0 {
                result.append(Segment(id: "other-\(category.rawValue)", category: category,
                                      title: "\(otherCount) smaller items", bytes: otherBytes,
                                      start: itemCursor, end: catEnd, ring: 1, safety: nil))
            }
            cursor = catEnd
        }
        return result
    }

    var body: some View {
        let segs = segments
        let total = segs.filter { $0.ring == 0 }.reduce(0) { $0 + $1.bytes }
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let rings: [(inner: CGFloat, outer: CGFloat)] = [
                (radius * 0.42, radius * 0.68), (radius * 0.70, radius * 0.98),
            ]
            ZStack {
                ForEach(segs) { seg in
                    let ring = rings[seg.ring]
                    let isHovered = hovered == seg.id
                    let dimmed = hovered != nil && !isHovered && hoveredCategory(segs) != seg.category
                    RingSegment(start: seg.start, end: seg.end, inner: ring.inner,
                                outer: ring.outer + (isHovered ? 4 : 0))
                        .fill(fill(for: seg))
                        .opacity(dimmed ? 0.35 : 1)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: hovered)
                        .accessibilityElement()
                        .accessibilityLabel("\(seg.title), \(Format.bytes(seg.bytes))")
                        .accessibilityAddTraits(seg.ring == 0 ? .isButton : [])
                        .accessibilityAction { onOpen(seg.category) }
                }
                centerLabel(segs, total: total)
                    .frame(width: rings[0].inner * 1.7)
            }
            .contentShape(Circle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = hit(point, center: center, rings: rings, segs: segs)?.id
                case .ended: hovered = nil
                }
            }
            .onTapGesture { point in
                if let seg = hit(point, center: center, rings: rings, segs: segs) { onOpen(seg.category) }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func hoveredCategory(_ segs: [Segment]) -> Category? {
        segs.first { $0.id == hovered }?.category
    }

    private func fill(for seg: Segment) -> some ShapeStyle {
        let base = seg.category.tint
        if seg.ring == 0 { return AnyShapeStyle(base.gradient) }
        switch seg.safety {
        case .safe?: return AnyShapeStyle(base.opacity(0.75))
        case .review?: return AnyShapeStyle(base.opacity(0.5))
        case .risky?: return AnyShapeStyle(base.opacity(0.35))
        case nil: return AnyShapeStyle(base.opacity(0.25))
        }
    }

    @ViewBuilder
    private func centerLabel(_ segs: [Segment], total: Int64) -> some View {
        let seg = segs.first { $0.id == hovered }
        VStack(spacing: 2) {
            if let seg {
                Image(systemName: seg.category.symbol).foregroundStyle(seg.category.tint)
                Text(seg.title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                Text(Format.bytes(seg.bytes)).font(.title3.weight(.semibold)).monospacedDigit()
                if let safety = seg.safety { SafetyBadge(safety: safety) }
            } else {
                Text("Found").font(.subheadline).foregroundStyle(.secondary)
                Text(Format.bytes(total)).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                Text("Hover to explore").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentTransition(.numericText())
    }

    private func hit(_ point: CGPoint, center: CGPoint,
                     rings: [(inner: CGFloat, outer: CGFloat)], segs: [Segment]) -> Segment? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        guard let ring = rings.firstIndex(where: { distance >= $0.inner && distance <= $0.outer + 4 }) else { return nil }
        // 0 at 12 o'clock, clockwise.
        var angle = atan2(dx, -dy) / (2 * .pi)
        if angle < 0 { angle += 1 }
        return segs.first { $0.ring == ring && angle >= $0.start && angle < $0.end }
    }
}

/// An annular sector; `start`/`end` are fractions of a full turn starting at 12 o'clock.
struct RingSegment: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let gap = min(0.002, (end - start) / 4)  // hairline separation between petals
        let a0 = Angle.degrees((start + gap) * 360 - 90)
        let a1 = Angle.degrees((end - gap) * 360 - 90)
        var p = Path()
        p.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}
