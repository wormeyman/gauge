import SwiftUI

/// A 0–100 tick scale with a filled bar up to the reading. The ticks are drawn once; only the fill
/// glides to a new reading.
struct Ruler: View {
    var fraction: Double
    var hot = false
    var tint: Color = Theme.ink
    /// Glides to a new reading (a 0.45 s spring) instead of jumping.
    var glides = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            RulerTicks()
            Group {
                if Snapshot.folder == nil {
                    RulerFill(fraction: min(1, max(0, fraction)), color: hot ? Theme.signal : tint, glides: glides)
                        .allowsHitTesting(false)
                } else {
                    // ImageRenderer can't draw AppKit views, so snapshots use a plain shape.
                    Rectangle()
                        .fill(hot ? Theme.signal : tint)
                        .scaleEffect(x: min(1, max(0, fraction)), anchor: .leading)
                }
            }
            .frame(height: 3)
            .padding(.top, 2)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// The ruler's fill as a Core Animation layer. Core Animation runs the glide in the window server,
/// so it costs Gauge nothing per frame; the same glide as a SwiftUI animation re-rendered the window
/// on every display frame, which was the largest part of Gauge's CPU use.
private struct RulerFill: NSViewRepresentable {
    var fraction: Double
    var color: Color
    var glides: Bool

    func makeNSView(context: Context) -> FillView { FillView() }

    func updateNSView(_ view: FillView, context: Context) {
        view.update(fraction: fraction, color: NSColor(color).cgColor,
                    animated: glides && !context.transaction.disablesAnimations)
    }

    final class FillView: NSView {
        private let fill = CALayer()
        private var fraction: Double?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(fill)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            fill.bounds = CGRect(origin: .zero, size: bounds.size)
            fill.position = CGPoint(x: 0, y: bounds.midY)
        }

        func update(fraction: Double, color: CGColor?, animated: Bool) {
            fill.backgroundColor = color
            guard fraction != self.fraction else { return }
            defer { self.fraction = fraction }
            let from = (fill.presentation() ?? fill).value(forKeyPath: "transform.scale.x") as? Double
            fill.setValue(fraction, forKeyPath: "transform.scale.x")
            // The first value appears in place, like a SwiftUI view's first render.
            guard animated, self.fraction != nil, let from else { return }
            // Matches SwiftUI's .smooth(duration: 0.45): a spring with no bounce.
            let glide = CASpringAnimation(perceptualDuration: 0.45, bounce: 0)
            glide.keyPath = "transform.scale.x"
            glide.fromValue = from
            glide.toValue = fraction
            glide.duration = glide.settlingDuration
            fill.add(glide, forKey: "glide")
        }
    }
}

/// Hosts content in its own NSHostingView, filling the space it's offered. A readout that animates on
/// every reading then redraws only itself for each animation frame, instead of the whole window, and its
/// changes don't make the surrounding layout re-measure. Content doesn't inherit the environment, so it
/// sets its own fonts and colours (the default foreground is Theme.ink).
struct Isolated<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if Snapshot.folder == nil {
            IsolatedHost(content: content.foregroundStyle(Theme.ink))
                .accessibilityHidden(true)  // the enclosing control carries the label
        } else {
            // ImageRenderer can't draw AppKit views, so snapshots render the content inline.
            content
        }
    }
}

private struct IsolatedHost<Content: View>: NSViewRepresentable {
    var content: Content

    func makeNSView(context: Context) -> PassthroughHostingView<Content> {
        let view = PassthroughHostingView(rootView: content)
        view.sizingOptions = []  // takes the size SwiftUI proposes rather than reporting its own
        return view
    }

    func updateNSView(_ view: PassthroughHostingView<Content>, context: Context) {
        view.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassthroughHostingView<Content>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Clicks and hovers go to the SwiftUI control underneath.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The ruler's track and ticks. A separate view with no inputs, so a new reading doesn't redraw it.
private struct RulerTicks: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            ctx.fill(Path(CGRect(x: 0, y: 2, width: w, height: 3)), with: .color(Theme.line2))
            for i in 0...20 {
                let x = (w - 1) * Double(i) / 20 + 0.5
                let bottom: Double = i % 10 == 0 ? 14 : i % 5 == 0 ? 12.5 : 11
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: 8))
                tick.addLine(to: CGPoint(x: x, y: bottom))
                ctx.stroke(tick, with: .color(Theme.faint), lineWidth: 1)
            }
        }
    }
}

/// A thin line (or bar) trace of normalised values.
struct Trace: View {
    var values: [Double]
    var hot = false
    var bars = false
    var tint: Color = Theme.ink

    var body: some View {
        Canvas { ctx, size in
            let color = hot ? Theme.signal : tint
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(baseline, with: .color(Theme.line), lineWidth: 1)
            guard values.count > 1 else { return }
            let step = size.width / Double(values.count - 1)
            func y(_ v: Double) -> Double { size.height - v * size.height }
            if bars {
                let barWidth = size.width / Double(values.count) * 0.64
                for (i, v) in values.enumerated() {
                    let x = size.width / Double(values.count) * (Double(i) + 0.18)
                    ctx.fill(Path(CGRect(x: x, y: y(v), width: barWidth, height: v * size.height)), with: .color(color.opacity(0.7)))
                }
                return
            }
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: Double(i) * step, y: y(v))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.08)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Flat ring chart: tonal steps of the metric colour by rank, orange only for a slice that needs attention.
struct Donut: View {
    var slices: [Slice]
    var tint: Color = Theme.ink
    var center: String
    var caption: String
    var size: CGFloat = 132

    var body: some View {
        ZStack {
            Circle().stroke(Theme.raise2, lineWidth: 14)
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(color(index), style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 3) {
                Text(center).font(Theme.mono(20, .light)).tracking(-0.6)
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(7)
        .frame(width: size, height: size)
    }

    private var segments: [(start: Double, end: Double)] {
        var start = 0.0
        return slices.map { slice in
            let share = max(0, slice.share)
            defer { start += share }
            let gap = share > 0.012 ? 0.004 : 0
            return (start + gap, max(start + gap, start + share - gap))
        }
    }

    func color(_ index: Int) -> Color {
        slices[index].hot ? Theme.signal : tint.opacity(Theme.rampOpacity[min(index, Theme.rampOpacity.count - 1)])
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let count { Text("\(count)").font(Theme.mono(12)).foregroundStyle(Theme.muted) }
                }
                .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing
            }
            Hairline()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

struct FlagLabel: View {
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.signal).frame(width: 6, height: 6)
            Text(text.uppercased()).font(Theme.mono(10.5)).tracking(0.6).foregroundStyle(Theme.signal)
        }
    }
}

/// Label/value rows with monospaced values.
struct Readings: View {
    var stats: [Stat]
    var size: CGFloat = 12

    var body: some View {
        VStack(spacing: 6) {
            // Rows keyed by position: keying by the whole Stat replaced every row whenever its value changed.
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                HStack {
                    Text(stat.label).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    Text(stat.value).font(Theme.mono(size)).lineLimit(1)
                }
                .font(.system(size: size))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Plain bordered button matching the instrument style.
struct QuietButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Theme.bg : Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.ink : (configuration.isPressed ? Theme.raise2 : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? Theme.ink : Theme.line2))
            .contentShape(Rectangle())
    }
}

/// Compact segmented control in the instrument style (hairline frame, raised selection).
struct Segmented<Value: Hashable>: View {
    var options: [(value: Value, label: String, symbol: String?)]
    @Binding var selection: Value
    var accessibilityName: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Group {
                        if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 12))
                        } else {
                            Text(option.label).font(.system(size: 12.5))
                        }
                    }
                    .padding(.horizontal, option.symbol == nil ? 10 : 8)
                    .frame(minWidth: 30, minHeight: 26)
                    .foregroundStyle(selected ? Theme.ink : Theme.muted)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.raise2 : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}
