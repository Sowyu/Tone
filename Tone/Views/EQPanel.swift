import SwiftUI

/// Content of an app's Equalizer window: the response graph above Preamp and Width.
struct EQPanel: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        let eq = model.settings(key).eq
        VStack(spacing: 16) {
            EQGraph(eq: eq) { index, value in
                model.setEQ(key) { $0.bands[index] = value }
            }
            .frame(height: 220)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                parameter("Preamp", value: "\(eq.preamp.signedDB) dB", range: EQSettings.range, \.preamp)
                parameter("Width", value: String(format: "Q %.1f", eq.q), range: EQSettings.qRange, \.q)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func parameter(_ title: String, value: String, range: ClosedRange<Double>,
                           _ path: WritableKeyPath<EQSettings, Double>) -> some View {
        let binding = Binding(get: { model.settings(key).eq[keyPath: path] },
                              set: { new in model.setEQ(key) { $0[keyPath: path] = (new * 10).rounded() / 10 } })
        return GridRow {
            Text(title)
            Slider(value: binding, in: range) { Text(title) }.labelsHidden()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// Ten band gains plus Q, interpolated together so preset changes morph the curve.
struct EQVector: VectorArithmetic {
    var values: [Double]

    static var zero: EQVector { EQVector(values: Array(repeating: 0, count: DSPKernel.bandCount + 1)) }
    static func + (a: EQVector, b: EQVector) -> EQVector { EQVector(values: zip(a.padded, b.padded).map(+)) }
    static func - (a: EQVector, b: EQVector) -> EQVector { EQVector(values: zip(a.padded, b.padded).map(-)) }
    mutating func scale(by rhs: Double) { values = padded.map { $0 * rhs } }
    var magnitudeSquared: Double { padded.reduce(0) { $0 + $1 * $1 } }

    private var padded: [Double] {
        let n = DSPKernel.bandCount + 1
        return values.count == n ? values : values + Array(repeating: 0, count: max(0, n - values.count))
    }

    init(values: [Double]) { self.values = values }
    init(_ eq: EQSettings) { values = eq.bands + [eq.q] }

    var eq: EQSettings {
        var e = EQSettings()
        e.bands = Array(values.prefix(DSPKernel.bandCount))
        e.q = max(values.count > DSPKernel.bandCount ? values[DSPKernel.bandCount] : 1.4, 0.1)
        return e
    }
}

/// Plot geometry: 32 Hz…16 kHz evenly spaced in octaves, with half an octave
/// of curve past each end, ±12 dB.
struct EQLayout {
    let size: CGSize
    static let topLabels: CGFloat = 22
    static let bottomLabels: CGFloat = 22
    static let axisWidth: CGFloat = 34

    var plot: CGRect {
        CGRect(x: 0, y: Self.topLabels + 8, width: size.width - Self.axisWidth,
               height: size.height - Self.topLabels - Self.bottomLabels - 16)
    }

    /// Octaves from 32 Hz, -0.5…9.5 across the plot.
    func x(octave: Double) -> CGFloat { plot.minX + plot.width * CGFloat((octave + 0.5) / 10) }
    func x(_ band: Int) -> CGFloat { x(octave: Double(band)) }

    func y(_ db: Double) -> CGFloat {
        let clamped = min(max(db, -14), 14)
        return plot.midY - CGFloat(clamped / 12) * plot.height / 2
    }

    func db(atY y: CGFloat) -> Double {
        let v = Double((plot.midY - y) / (plot.height / 2)) * 12
        return min(max((v * 10).rounded() / 10, -12), 12)
    }

    func band(atX x: CGFloat) -> Int {
        let octave = Double((x - plot.minX) / plot.width) * 10 - 0.5
        return min(max(Int(octave.rounded()), 0), DSPKernel.bandCount - 1)
    }
}

/// The filter bank's real magnitude response, sampled across the plot.
struct EQResponseShape: Shape {
    var vector: EQVector
    var closedToZero = false

    var animatableData: EQVector {
        get { vector }
        set { vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let layout = EQLayout(size: rect.size)
        let samples = 96
        let octaves = (0...samples).map { -0.5 + 10 * Double($0) / Double(samples) }
        let db = EQResponse.decibels(vector.eq, frequencies: octaves.map { 32 * pow(2, $0) })
        var path = Path()
        for (i, octave) in octaves.enumerated() {
            let p = CGPoint(x: layout.x(octave: octave), y: layout.y(db[i]))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        if closedToZero {
            path.addLine(to: CGPoint(x: layout.plot.maxX, y: layout.y(0)))
            path.addLine(to: CGPoint(x: layout.plot.minX, y: layout.y(0)))
            path.closeSubpath()
        }
        return path
    }
}

/// Handles sit on the curve at each band and move with it.
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
            let db = EQResponse.decibels(vector.eq, frequencies: EQSettings.frequencies)
            ForEach(0..<DSPKernel.bandCount, id: \.self) { i in
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(focused && selected == i ? 1 : 0))
                    .position(x: layout.x(i), y: layout.y(db[i]))
            }
        }
    }
}

struct EQGraph: View {
    let eq: EQSettings
    let onChange: (Int, Double) -> Void

    @State private var dragBand: Int?
    @State private var selected = 5
    @State private var usingKeyboard = false
    @FocusState private var focused: Bool

    private static let dbMarks: [Double] = [12, 6, 0, -6, -12]

    var body: some View {
        GeometryReader { geo in
            let layout = EQLayout(size: geo.size)
            let vector = EQVector(eq)
            ZStack(alignment: .topLeading) {
                grid(layout)
                EQResponseShape(vector: vector, closedToZero: true)
                    .fill(LinearGradient(stops: [.init(color: Color.accentColor.opacity(0.3), location: 0),
                                                 .init(color: Color.accentColor.opacity(0.05), location: 0.5),
                                                 .init(color: Color.accentColor.opacity(0.3), location: 1)],
                                         startPoint: UnitPoint(x: 0, y: layout.y(12) / geo.size.height),
                                         endPoint: UnitPoint(x: 0, y: layout.y(-12) / geo.size.height)))
                EQResponseShape(vector: vector)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                EQHandles(vector: vector, selected: selected, focused: focused && usingKeyboard)
                labels(layout)
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
            .simultaneousGesture(TapGesture(count: 2).onEnded { withAnimation(.snappy) { onChange(selected, 0) } })
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { usingKeyboard = true; selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.rightArrow) { usingKeyboard = true; selected = min(selected + 1, DSPKernel.bandCount - 1); return .handled }
        .onKeyPress(.upArrow) { usingKeyboard = true; nudge(0.5); return .handled }
        .onKeyPress(.downArrow) { usingKeyboard = true; nudge(-0.5); return .handled }
        .accessibilityElement()
        .accessibilityLabel("Equalizer")
        .accessibilityValue(zip(EQSettings.labels, eq.bands).map { "\($0) hertz \($1.signedDB) decibels" }.joined(separator: ", "))
    }

    private func nudge(_ delta: Double) {
        onChange(selected, min(max(eq.bands[selected] + delta, -12), 12))
    }

    private func grid(_ layout: EQLayout) -> some View {
        Path { p in
            for i in 0..<DSPKernel.bandCount {
                p.move(to: CGPoint(x: layout.x(i), y: layout.plot.minY))
                p.addLine(to: CGPoint(x: layout.x(i), y: layout.plot.maxY))
            }
            for db in Self.dbMarks {
                p.move(to: CGPoint(x: layout.plot.minX, y: layout.y(db)))
                p.addLine(to: CGPoint(x: layout.plot.maxX, y: layout.y(db)))
            }
        }
        .stroke(.quaternary, lineWidth: 1)
    }

    private func labels(_ layout: EQLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<DSPKernel.bandCount, id: \.self) { i in
                Text(EQSettings.labels[i])
                    .fixedSize()
                    .position(x: layout.x(i), y: EQLayout.topLabels / 2)
                Text(eq.bands[i].signedDB)
                    .monospacedDigit()
                    .fixedSize()
                    .contentTransition(.numericText(value: eq.bands[i]))
                    .position(x: layout.x(i), y: layout.size.height - EQLayout.bottomLabels / 2)
            }
            ForEach(Self.dbMarks, id: \.self) { db in
                Text(db == 0 ? "0" : (db > 0 ? "+" : "\u{2212}") + "\(Int(abs(db)))")
                    .fixedSize()
                    .position(x: layout.plot.maxX + EQLayout.axisWidth / 2 + 2, y: layout.y(db))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
}
