// The window: a steering wheel that turns with the controller, live graphs of the tilt, the steering and the raw
// sensors, and the settings.

import AppKit
import Charts
import SwiftUI

// MARK: - Colours

extension Color {
    // Categorical slots 1-3 (blue, orange, aqua), each with its light and dark step; checked for colour-blind
    // separation as a set in both modes.
    static let series1 = Color.dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let series2 = Color.dynamic(light: 0xeb6834, dark: 0xd95926)
    static let series3 = Color.dynamic(light: 0x1baf7a, dark: 0x199e70)
    static let statusGood = Color(nsColor: NSColor(hex: 0x0ca30c))
    static let statusWarning = Color(nsColor: NSColor(hex: 0xfab219))
    static let statusCritical = Color(nsColor: NSColor(hex: 0xd03b3b))

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

// MARK: - Window

struct ContentView: View {
    @Bindable var engine: Engine
    @State private var hoverAgo: Double?
    @State private var rawKind = RawKind.gyro

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(engine: engine)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    SidePanel(engine: engine).padding(16)
                }
                .frame(width: 330)
                Divider()
                ChartsPanel(engine: engine, hoverAgo: $hoverAgo, rawKind: $rawKind)
                    .padding(16)
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { DispatchQueue.main.async { applyKeepOnTop() } }
        .onChange(of: engine.keepOnTop) { applyKeepOnTop() }
    }

    private func applyKeepOnTop() {
        for window in NSApp.windows { window.level = engine.keepOnTop ? .floating : .normal }
    }
}

// MARK: - Status

enum ChipState {
    case good, warning, critical, idle
    var icon: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .idle: return "pause.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .good: return .statusGood
        case .warning: return .statusWarning
        case .critical: return .statusCritical
        case .idle: return .secondary
        }
    }
}

struct StatusChip: View {
    let state: ChipState
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.icon).foregroundStyle(state.color)
            Text(text)
        }
        .font(.callout)
        .lineLimit(1)
    }
}

struct StatusBar: View {
    let engine: Engine

    var body: some View {
        HStack(spacing: 22) {
            controller
            game
            Spacer(minLength: 12)
            if let notice = engine.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var controller: StatusChip {
        let rate = engine.motionRate
        if engine.simulate { return StatusChip(state: .warning, text: "Simulated controller · \(rate) updates/s") }
        guard let name = engine.controllerName else {
            return StatusChip(state: .critical, text: "No controller: pair the G5 Pro in Switch mode")
        }
        if rate == 0 { return StatusChip(state: .warning, text: "\(name) · no motion data") }
        return StatusChip(state: .good, text: "\(name) · \(rate) updates/s")
    }

    private var game: StatusChip {
        guard engine.gameAnswering else {
            return StatusChip(state: .critical, text: "BeamNG isn't answering: is it running with the mod?")
        }
        if !engine.game.hasCar { return StatusChip(state: .warning, text: "BeamNG: no car to steer") }
        if engine.game.steering { return StatusChip(state: .good, text: "BeamNG is steering the car") }
        return StatusChip(state: .idle, text: "BeamNG connected · gyro steering off")
    }
}

// MARK: - Side panel

struct SidePanel: View {
    @Bindable var engine: Engine

    var body: some View {
        let latest = engine.latest
        VStack(alignment: .leading, spacing: 16) {
            WheelView(angle: latest?.wheel ?? 0, steer: latest?.sent ?? 0, on: engine.gyroEnabled)
                .frame(height: 250)

            TiltMeter(tilt: latest?.tilt ?? 0,
                      threshold: engine.keepTurning && engine.threshold < engine.range ? engine.threshold : nil)

            HStack(alignment: .firstTextBaseline) {
                stat("Steering sent", latest?.sent.map(steeringText) ?? "off", .leading)
                Spacer()
                stat("Wheel", latest.map { String(format: "%+.0f°", $0.wheel) } ?? "–", .center)
                Spacer()
                stat("Tilt", latest.map { String(format: "%+.0f°", $0.tilt) } ?? "–", .trailing)
            }

            HStack {
                Toggle("Gyro steering", isOn: Binding(get: { engine.gyroEnabled }, set: { engine.setGyro($0) }))
                    .toggleStyle(.switch)
                Spacer()
                Button("Set straight") { engine.recenter() }
                    .help("Makes the controller's current tilt count as straight")
            }

            Divider()
            buttonsSection
            Divider()
            tuningSection
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Window").font(.headline)
                Toggle("Pause graphs", isOn: $engine.paused)
                Toggle("Keep this window on top", isOn: $engine.keepOnTop)
                Toggle("Simulate a controller", isOn: Binding(get: { engine.simulate }, set: { engine.setSimulate($0) }))
                    .help("Makes up a controller turning left and right, to test the graphs and the mod")
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Controller buttons").font(.headline)
            Text("Press these together on the controller.").font(.caption).foregroundStyle(.secondary)
            ForEach(ButtonAction.allCases) { action in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(action.title)
                        Spacer()
                        if engine.learning == action {
                            Button("Cancel") { engine.cancelLearning() }
                        } else {
                            Button("Change") { engine.learn(action) }
                            Button("Default") { engine.resetButtons(action) }
                                .disabled(engine.bindings[action] == action.defaultButtons)
                        }
                    }
                    if engine.learning == action {
                        Label(learningPrompt, systemImage: "gamecontroller")
                            .font(.callout)
                    } else {
                        Text(engine.label(for: action)).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var learningPrompt: String {
        if engine.controllerName == nil { return "Connect the controller first" }
        if engine.learned.isEmpty { return "Press the button or buttons now, then let go" }
        return "\(engine.buttonNames(engine.learned)): let go to save"
    }

    private var tuningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tuning").font(.headline)
            SliderRow(title: "Full lock", value: $engine.range, bounds: 15...540, step: 5, format: "%.0f° of wheel",
                      help: "How far the wheel turns each way for full lock. Less is quicker steering; real cars are around 450°.")
            Toggle("Keep turning past a tilt", isOn: $engine.keepTurning)
            SliderRow(title: "Keep turning past", value: $engine.threshold, bounds: 30...85, step: 1, format: "%.0f° tilt",
                      help: "Up to this tilt the wheel follows the controller exactly. Tilt further and it keeps turning; tilt back to unwind.")
                .disabled(!engine.keepTurning)
            SliderRow(title: "Turning speed", value: $engine.speed, bounds: 30...720, step: 10, format: "%.0f°/s",
                      help: "How fast it keeps turning with the controller tilted all the way (90°); slower just past the threshold")
                .disabled(!engine.keepTurning)
            if let lockHint {
                Label(lockHint, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            SliderRow(title: "Dead zone", value: $engine.deadzone, bounds: 0...10, step: 0.5, format: "%.1f°",
                      help: "Tilt ignored around straight")
            SliderRow(title: "Curve", value: $engine.curve, bounds: 0.5...3, step: 0.1, format: "%.1f",
                      help: "Above 1 makes small tilts gentler, for finer control at speed")
            Toggle("Steer the other way", isOn: $engine.invert)
            Toggle("Send as a wheel, not a gamepad", isOn: $engine.direct)
                .help("Skips BeamNG's gamepad smoothing and its speed-based steering limit")
        }
    }

    private var lockHint: String? {
        if engine.keepTurning && engine.range <= engine.threshold {
            return String(format: "Full lock comes before %.0f° of tilt, so the wheel never needs to keep turning. "
                          + "Set Full lock above %.0f° to use it.", engine.threshold, engine.threshold)
        }
        if !engine.keepTurning && engine.range > 90 {
            return "Full lock is more than you can tilt (90°). Turn on Keep turning to reach it."
        }
        return nil
    }
}

/// The controller's tilt on a 90° left ... 90° right scale. Past the threshold (the darker ends), the wheel keeps
/// turning.
struct TiltMeter: View {
    let tilt: Double
    let threshold: Double?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (deg: Double) -> CGFloat in w / 2 + CGFloat(max(-90, min(90, deg)) / 90) * (w / 2) }
                ZStack {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                        if let threshold {
                            Rectangle().fill(Color.secondary.opacity(0.45)).frame(width: x(-threshold))
                            Rectangle().fill(Color.secondary.opacity(0.45)).frame(width: w - x(threshold))
                                .offset(x: x(threshold))
                        }
                    }
                    .frame(width: w, height: 8)
                    .clipShape(Capsule())
                    Rectangle().fill(Color.secondary).frame(width: 1, height: 14)
                    Capsule().fill(Color.primary).frame(width: 4, height: 18).offset(x: x(tilt) - w / 2)
                }
                .frame(width: w, height: geo.size.height)
            }
            .frame(height: 18)
            HStack {
                Text(threshold == nil ? "90° left" : "« keeps turning")
                Spacer()
                Text("controller tilt")
                Spacer()
                Text(threshold == nil ? "90° right" : "keeps turning »")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

func steeringText(_ v: Double) -> String {
    let side = abs(v) < 0.005 ? "" : (v < 0 ? " left" : " right")
    return String(format: "%.2f", abs(v)) + side
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double
    let format: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: bounds, step: step)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Wheel

/// The wheel turns to the wheel angle; the arc around it fills with the steering sent to the game.
struct WheelView: View {
    let angle: Double
    let steer: Double
    let on: Bool
    /// How far round the arc reaches at full lock, degrees from the top.
    private let arcReach = 125.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ArcShape(from: -arcReach, to: arcReach)
                    .stroke(Color.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                ArcShape(from: 0, to: steer * arcReach)
                    .stroke(Color.series1, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .opacity(on ? 1 : 0)
                WheelShape()
                    .rotationEffect(.degrees(angle))
                    .padding(size * 0.085)
                    .opacity(on ? 1 : 0.35)
                Text("L").font(.caption2.bold()).foregroundStyle(.secondary)
                    .position(endPoint(-arcReach - 12, size))
                Text("R").font(.caption2.bold()).foregroundStyle(.secondary)
                    .position(endPoint(arcReach + 12, size))
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func endPoint(_ degrees: Double, _ size: CGFloat) -> CGPoint {
        let r = size / 2 - 3
        let a = (degrees - 90) * .pi / 180
        return CGPoint(x: size / 2 + r * cos(a), y: size / 2 + r * sin(a))
    }
}

/// An arc of the wheel's outer ring; angles in degrees, clockwise from 12 o'clock.
struct ArcShape: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let a = min(from, to), b = max(from, to)
        guard b - a > 0.2 else { return path }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - 4,
                    startAngle: .degrees(a - 90), endAngle: .degrees(b - 90), clockwise: false)
        return path
    }
}

struct WheelShape: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let rim = s * 0.08
            let r = s / 2 - rim / 2
            let ink = GraphicsContext.Shading.color(.primary.opacity(0.78))

            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: ink, lineWidth: rim)
            var spokes = Path()
            spokes.move(to: CGPoint(x: c.x - r, y: c.y + s * 0.03))
            spokes.addLine(to: CGPoint(x: c.x, y: c.y))
            spokes.addLine(to: CGPoint(x: c.x + r, y: c.y + s * 0.03))
            spokes.move(to: c)
            spokes.addLine(to: CGPoint(x: c.x, y: c.y + r))
            ctx.stroke(spokes, with: ink, style: StrokeStyle(lineWidth: s * 0.065, lineCap: .round, lineJoin: .round))
            let hub = s * 0.14
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: 2 * hub, height: 2 * hub)), with: ink)

            // The notch at the top shows which way is straight.
            var notch = Path()
            notch.move(to: CGPoint(x: c.x, y: c.y - r - rim / 2 - 1))
            notch.addLine(to: CGPoint(x: c.x, y: c.y - r + rim / 2 + 1))
            ctx.stroke(notch, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: s * 0.04)
        }
    }
}

// MARK: - Graphs

enum RawKind: String, CaseIterable, Identifiable {
    case gyro = "Gyro", accel = "Accelerometer"
    var id: Self { self }
}

struct LegendEntry: Identifiable {
    var id: String { name }
    let color: Color
    let name: String
    let value: String?
    var thin = false
}

struct ChartHeader: View {
    let title: String
    let detail: String
    let entries: [LegendEntry]
    let probeAgo: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(probeAgo.map { String(format: "%.1f s ago", -$0) } ?? "now")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                ForEach(entries) { e in
                    HStack(spacing: 5) {
                        Capsule().fill(e.color).frame(width: 16, height: e.thin ? 1.5 : 3)
                        Text(e.name).font(.caption).foregroundStyle(.secondary)
                        Text(e.value ?? "–").font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }
}

/// One point of a line, split into segments wherever the value was missing, so gaps stay gaps.
struct LinePoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let segment: Int
}

func linePoints(_ data: [Sample], now: Double, _ value: (Sample) -> Double?) -> [LinePoint] {
    var points: [LinePoint] = []
    var segment = 0
    var gap = false
    for s in data {
        if let y = value(s) {
            if gap { segment += 1; gap = false }
            points.append(LinePoint(id: s.id, x: s.t - now, y: y, segment: segment))
        } else {
            gap = true
        }
    }
    return points
}

struct ChartsPanel: View {
    let engine: Engine
    @Binding var hoverAgo: Double?
    @Binding var rawKind: RawKind

    var body: some View {
        let all = engine.displayed
        let now = engine.displayedNow
        let shown = hoverAgo.flatMap { nearest(all, to: now + $0) } ?? all.last
        // At most about 200 points a line: plenty for the eye, and keeps the drawing quick.
        let step = max(1, all.count / 200)
        let data = step == 1 ? all : all.enumerated().filter { $0.offset % step == 0 || $0.offset == all.count - 1 }.map(\.element)
        VStack(spacing: 18) {
            TiltChart(data: data, now: now, range: engine.range, deadzone: engine.deadzone,
                      threshold: engine.keepTurning && engine.threshold < engine.range ? engine.threshold : nil,
                      shown: shown, hoverAgo: $hoverAgo)
            SteeringChart(data: data, now: now, shown: shown, hoverAgo: $hoverAgo)
            RawChart(data: data, now: now, kind: $rawKind, shown: shown, hoverAgo: $hoverAgo)
        }
    }

    private func nearest(_ data: [Sample], to t: Double) -> Sample? {
        data.min { abs($0.t - t) < abs($1.t - t) }
    }
}

let timeTicks: [Double] = [-10, -8, -6, -4, -2, 0]

extension View {
    /// Applies the shared time axis, and reports where the pointer is, in seconds before now.
    func timeChart(hover: Binding<Double?>) -> some View {
        self
            .chartXScale(domain: -Engine.window...0)
            .chartXAxis {
                AxisMarks(values: timeTicks) { value in
                    let v = value.as(Double.self) ?? 0
                    AxisGridLine(stroke: hairline)
                    AxisValueLabel(anchor: v == 0 ? .topTrailing : .top) {
                        Text(v == 0 ? "now" : "\(Int(v)) s")
                    }
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard let frame = proxy.plotFrame else { return }
                                let x = point.x - geo[frame].origin.x
                                if let ago: Double = proxy.value(atX: x), ago >= -Engine.window, ago <= 0 {
                                    hover.wrappedValue = ago
                                } else {
                                    hover.wrappedValue = nil
                                }
                            case .ended:
                                hover.wrappedValue = nil
                            }
                        }
                }
            }
            .frame(minHeight: 130)
    }
}

let lineStroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
/// Gridlines: thin and solid, so they stay behind the data.
let hairline = StrokeStyle(lineWidth: 0.5)

struct TiltChart: View {
    let data: [Sample]
    let now: Double
    let range: Double
    let deadzone: Double
    /// Tilt past which the wheel keeps turning; nil when it doesn't.
    let threshold: Double?
    let shown: Sample?
    @Binding var hoverAgo: Double?

    var body: some View {
        // Mark where the tilt stops mapping 1:1: the keep-turning threshold, or full lock.
        let mark = threshold ?? min(range, 90)
        let (above, below) = threshold == nil ? ("full lock right", "full lock left")
                                              : ("keeps turning right past here", "keeps turning left past here")
        let limit = threshold == nil ? min(90, max(mark + 15, 30)) : 90
        let fused = linePoints(data, now: now) { $0.tilt }
        let accel = linePoints(data, now: now) { $0.accelTilt }
        VStack(alignment: .leading, spacing: 6) {
            ChartHeader(title: "Tilt", detail: "degrees from straight; the shaded band is the dead zone", entries: [
                LegendEntry(color: .series1, name: "Gyro + accelerometer (steers)", value: shown.map { deg($0.tilt) }),
                LegendEntry(color: .secondary, name: "Accelerometer alone", value: shown.map { deg($0.accelTilt) },
                            thin: true),
            ], probeAgo: hoverAgo)
            Chart {
                RectangleMark(xStart: .value("Time", -Engine.window), xEnd: .value("Time", 0),
                              yStart: .value("Tilt", -deadzone), yEnd: .value("Tilt", deadzone))
                    .foregroundStyle(Color.secondary.opacity(0.14))
                RuleMark(y: .value("Limit", mark))
                    .foregroundStyle(Color.secondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading) {
                        Text(above).font(.caption2).foregroundStyle(.secondary)
                    }
                RuleMark(y: .value("Limit", -mark))
                    .foregroundStyle(Color.secondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .bottom, alignment: .leading) {
                        Text(below).font(.caption2).foregroundStyle(.secondary)
                    }
                ForEach(accel) { p in
                    LineMark(x: .value("Time", p.x), y: .value("Tilt", p.y), series: .value("Line", "accel\(p.segment)"))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                ForEach(fused) { p in
                    LineMark(x: .value("Time", p.x), y: .value("Tilt", p.y), series: .value("Line", "fused\(p.segment)"))
                        .foregroundStyle(Color.series1)
                        .lineStyle(lineStroke)
                }
                if let hoverAgo {
                    RuleMark(x: .value("Time", hoverAgo)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: -limit...limit)
            .chartYAxis {
                AxisMarks(position: .leading, values: stride(from: -90.0, through: 90, by: 30).filter { abs($0) <= limit }) { value in
                    AxisGridLine(stroke: hairline)
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))°") } }
                }
            }
            .timeChart(hover: $hoverAgo)
        }
    }
}

func deg(_ v: Double) -> String { String(format: "%+.1f°", v) }

struct SteeringChart: View {
    let data: [Sample]
    let now: Double
    let shown: Sample?
    @Binding var hoverAgo: Double?

    var body: some View {
        let sent = linePoints(data, now: now) { $0.sent }
        let applied = linePoints(data, now: now) { $0.applied }
        VStack(alignment: .leading, spacing: 6) {
            ChartHeader(title: "Steering", detail: "−1 full left … +1 full right", entries: [
                LegendEntry(color: .series1, name: "Sent to BeamNG", value: shown.map { $0.sent.map(signed) ?? "off" }),
                LegendEntry(color: .series2, name: "Applied in the car (after the game's smoothing)",
                            value: shown?.applied.map(signed)),
            ], probeAgo: hoverAgo)
            Chart {
                RuleMark(y: .value("Steering", 0)).foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(applied) { p in
                    LineMark(x: .value("Time", p.x), y: .value("Steering", p.y), series: .value("Line", "applied\(p.segment)"))
                        .foregroundStyle(Color.series2)
                        .lineStyle(lineStroke)
                }
                ForEach(sent) { p in
                    LineMark(x: .value("Time", p.x), y: .value("Steering", p.y), series: .value("Line", "sent\(p.segment)"))
                        .foregroundStyle(Color.series1)
                        .lineStyle(lineStroke)
                }
                if let hoverAgo {
                    RuleMark(x: .value("Time", hoverAgo)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: -1.08...1.08)
            .chartYAxis {
                AxisMarks(position: .leading, values: [-1.0, -0.5, 0, 0.5, 1]) { value in
                    AxisGridLine(stroke: hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(v == 0 ? "0" : String(format: "%+.1f", v)) }
                    }
                }
            }
            .timeChart(hover: $hoverAgo)
        }
    }
}

func signed(_ v: Double) -> String { String(format: "%+.2f", v) }

struct RawChart: View {
    let data: [Sample]
    let now: Double
    @Binding var kind: RawKind
    let shown: Sample?
    @Binding var hoverAgo: Double?

    var body: some View {
        let isGyro = kind == .gyro
        let pick: (Sample) -> V3 = { isGyro ? $0.gyro : $0.accel }
        let axes: [(String, Color, (V3) -> Double)] = [("x", .series1, { $0.x }), ("y", .series2, { $0.y }),
                                                       ("z", .series3, { $0.z })]
        let peak = data.reduce(0.0) { m, s in let v = pick(s); return max(m, abs(v.x), abs(v.y), abs(v.z)) }
        let limit = isGyro ? max(30, (peak / 30).rounded(.up) * 30) : max(1.25, (peak / 0.5).rounded(.up) * 0.5)
        let unit = isGyro ? "°/s" : "g"
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                ChartHeader(
                    title: "Raw sensors",
                    detail: isGyro ? "turning speed around the controller's axes"
                                   : "acceleration; held still, it's just gravity (1 g down)",
                    entries: axes.map { name, color, get in
                        LegendEntry(color: color, name: axisName(name, gyro: isGyro),
                                    value: shown.map { String(format: isGyro ? "%+.0f" : "%+.2f", get(pick($0))) + " " + unit })
                    },
                    probeAgo: hoverAgo)
                Picker("", selection: $kind) {
                    ForEach(RawKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            Chart {
                RuleMark(y: .value("Value", 0)).foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(axes, id: \.0) { name, color, get in
                    ForEach(data) { s in
                        LineMark(x: .value("Time", s.t - now), y: .value("Value", get(pick(s))), series: .value("Axis", name))
                            .foregroundStyle(color)
                            .lineStyle(lineStroke)
                    }
                }
                if let hoverAgo {
                    RuleMark(x: .value("Time", hoverAgo)).foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYScale(domain: -limit...limit)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(isGyro ? "\(Int(v))" : String(format: "%.1f", v)) }
                    }
                }
            }
            .timeChart(hover: $hoverAgo)
        }
    }

    private func axisName(_ axis: String, gyro: Bool) -> String {
        guard gyro else { return axis == "x" ? "x (right)" : axis == "y" ? "y (forward)" : "z (out of the face)" }
        // Which way of turning each axis picks up, holding the controller flat.
        switch axis {
        case "x": return "x (tip forward/back)"
        case "y": return "y (tilt like a wheel)"
        default: return "z (twist flat)"
        }
    }
}
