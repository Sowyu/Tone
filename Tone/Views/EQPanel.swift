import SwiftUI

/// The EQ panel that slides out on the popover's left edge.
struct EQPanel: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        let s = model.settings(key)
        let preamp = Binding(get: { model.settings(key).eq.preamp }, set: { v in model.setEQ(key) { $0.preamp = v } })
        let width = Binding(get: { model.settings(key).eq.q }, set: { v in model.setEQ(key) { $0.q = v } })
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: model.icon(key)).resizable().frame(width: 18, height: 18)
                Text(model.displayName(key)).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Toggle("Equalizer", isOn: Binding(get: { model.settings(key).eqEnabled }, set: { model.setEQEnabled(key, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                Button {
                    Motion.animate { model.eqTarget = nil }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close equalizer")
            }

            EQGraph(bands: s.eq.bands) { index, value in
                model.setEQ(key) { $0.bands[index] = value }
            }
            .frame(height: 150)
            .opacity(s.eqEnabled ? 1 : 0.45)

            LabeledSlider(title: "Preamp", readout: "\(s.eq.preamp.signedDB) dB") {
                ToneSlider(value: preamp, range: EQSettings.range, step: 0.1, origin: 0,
                           accessibilityLabel: "Preamp", accessibilityValue: "\(s.eq.preamp.signedDB) decibels")
            }
            LabeledSlider(title: "Width", readout: String(format: "%.1f Q", s.eq.q)) {
                ToneSlider(value: width, range: EQSettings.qRange, step: 0.1,
                           accessibilityLabel: "Width", accessibilityValue: String(format: "Q %.1f", s.eq.q))
            }
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(width: PanelController.eqWidth)
        .panelCard()
    }
}

private struct LabeledSlider<S: View>: View {
    let title: String
    let readout: String
    @ViewBuilder let slider: S

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(readout).monospacedDigit().foregroundStyle(.secondary)
            }
            slider
        }
    }
}

/// Ten values that SwiftUI can interpolate, so preset changes morph the curve.
struct EQVector: VectorArithmetic {
    var values: [Double]

    static var zero: EQVector { EQVector(values: Array(repeating: 0, count: DSPKernel.bandCount)) }
    static func + (a: EQVector, b: EQVector) -> EQVector { EQVector(values: zip(a.padded, b.padded).map(+)) }
    static func - (a: EQVector, b: EQVector) -> EQVector { EQVector(values: zip(a.padded, b.padded).map(-)) }
    mutating func scale(by rhs: Double) { values = padded.map { $0 * rhs } }
    var magnitudeSquared: Double { padded.reduce(0) { $0 + $1 * $1 } }

    private var padded: [Double] {
        values.count == DSPKernel.bandCount ? values : values + Array(repeating: 0, count: max(0, DSPKernel.bandCount - values.count))
    }
}

/// Plot geometry shared by the curve shape, the points and the gesture.
struct EQLayout {
    let size: CGSize
    static let leftInset: CGFloat = 34
    static let bottomInset: CGFloat = 16
    static let pad: CGFloat = 8

    var plot: CGRect {
        CGRect(x: Self.leftInset, y: Self.pad, width: size.width - Self.leftInset - Self.pad,
               height: size.height - Self.bottomInset - Self.pad * 2)
    }

    func x(_ band: Int) -> CGFloat { plot.minX + plot.width * CGFloat(band) / CGFloat(DSPKernel.bandCount - 1) }

    func y(_ db: Double) -> CGFloat {
        let r = EQSettings.range
        return plot.midY - CGFloat(db / r.upperBound) * plot.height / 2
    }

    func db(atY y: CGFloat) -> Double {
        let r = EQSettings.range
        let v = Double((plot.midY - y) / (plot.height / 2)) * r.upperBound
        return min(max((v * 10).rounded() / 10, r.lowerBound), r.upperBound)
    }

    func band(atX x: CGFloat) -> Int {
        let f = (x - plot.minX) / plot.width * CGFloat(DSPKernel.bandCount - 1)
        return min(max(Int(f.rounded()), 0), DSPKernel.bandCount - 1)
    }
}

struct EQCurveShape: Shape {
    var vector: EQVector
    var closed = false

    var animatableData: EQVector {
        get { vector }
        set { vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let layout = EQLayout(size: rect.size)
        let points = vector.values.indices.map { CGPoint(x: layout.x($0), y: layout.y(vector.values[$0])) }
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        // Catmull-Rom through every point, converted to cubic Béziers.
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: layout.y(0)))
            path.addLine(to: CGPoint(x: first.x, y: layout.y(0)))
            path.closeSubpath()
        }
        return path
    }
}

/// Animates the ten handles together with the curve.
private struct EQHandles: View, Animatable {
    var vector: EQVector
    var selected: Int?
    var focused: Bool
    nonisolated var animatableData: EQVector {
        get { vector }
        set { vector = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let layout = EQLayout(size: geo.size)
            ForEach(vector.values.indices, id: \.self) { i in
                Circle()
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.blue, lineWidth: focused && selected == i ? 2 : 0).padding(-2))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .position(x: layout.x(i), y: layout.y(vector.values[i]))
            }
        }
    }
}

struct EQGraph: View {
    let bands: [Double]
    let onChange: (Int, Double) -> Void

    @State private var dragBand: Int?
    @State private var selected = 5
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let layout = EQLayout(size: geo.size)
            let vector = EQVector(values: bands)
            ZStack(alignment: .topLeading) {
                grid(layout)
                EQCurveShape(vector: vector, closed: true)
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                EQCurveShape(vector: vector)
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                EQHandles(vector: vector, selected: selected, focused: focused)
                axisLabels(layout)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let band = dragBand ?? layout.band(atX: g.startLocation.x)
                        dragBand = band
                        selected = band
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { onChange(band, layout.db(atY: g.location.y)) }
                    }
                    .onEnded { _ in dragBand = nil }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    Motion.animate { onChange(selected, 0) }
                }
            )
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.rightArrow) { selected = min(selected + 1, DSPKernel.bandCount - 1); return .handled }
        .onKeyPress(.upArrow) { nudge(0.5); return .handled }
        .onKeyPress(.downArrow) { nudge(-0.5); return .handled }
        .accessibilityElement()
        .accessibilityLabel("Equalizer curve")
        .accessibilityValue(zip(EQSettings.labels, bands).map { "\($0) hertz \($1.signedDB) dB" }.joined(separator: ", "))
    }

    private func nudge(_ delta: Double) {
        let r = EQSettings.range
        onChange(selected, min(max(bands[selected] + delta, r.lowerBound), r.upperBound))
    }

    private func grid(_ layout: EQLayout) -> some View {
        Path { p in
            for i in 0..<DSPKernel.bandCount {
                p.move(to: CGPoint(x: layout.x(i), y: layout.plot.minY))
                p.addLine(to: CGPoint(x: layout.x(i), y: layout.plot.maxY))
            }
            for db in [-12.0, -6, 6, 12] {
                p.move(to: CGPoint(x: layout.plot.minX, y: layout.y(db)))
                p.addLine(to: CGPoint(x: layout.plot.maxX, y: layout.y(db)))
            }
        }
        .stroke(.white.opacity(0.07), lineWidth: 0.5)
        .overlay(
            Path { p in
                p.move(to: CGPoint(x: layout.plot.minX, y: layout.y(0)))
                p.addLine(to: CGPoint(x: layout.plot.maxX, y: layout.y(0)))
            }
            .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        )
    }

    private func axisLabels(_ layout: EQLayout) -> some View {
        let maxDB = bands.max() ?? 0
        let minDB = bands.min() ?? 0
        var marks: [Double] = [maxDB]
        if abs(maxDB - minDB) > 1.5 { marks.append(minDB) }
        if !marks.contains(where: { abs($0) < 1.5 }) { marks.append(0) }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, db in
                Text(db.signedDB)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: EQLayout.leftInset - 6, alignment: .trailing)
                    .position(x: (EQLayout.leftInset - 6) / 2, y: layout.y(db))
            }
            ForEach(EQSettings.labels.indices, id: \.self) { i in
                Text(EQSettings.labels[i])
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: layout.x(i), y: layout.size.height - EQLayout.bottomInset / 2)
            }
        }
        .allowsHitTesting(false)
    }
}
