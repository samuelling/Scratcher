import SwiftUI
import UniformTypeIdentifiers

let accent = Color(red: 1.0, green: 0.42, blue: 0.2)
let revPerSecond = 0.555   // 33⅓ rpm at 1×

/// A titled panel.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
    }
}

/// Labelled slider with a value readout.
struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var body: some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().frame(width: 72, alignment: .trailing).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Perform: platter, tape, meters, transport, crossfader

struct PerformView: View {
    @ObservedObject var model: ScratcherModel

    var body: some View {
        let s = model.state
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                PlatterView(model: model)
                    .frame(maxWidth: 300)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        Readout(label: "Speed", value: String(format: "%+.2f×", s.v))
                        Readout(label: "Direction", value: !s.active ? "—" : (s.dir > 0 ? "▶︎ fwd" : "◀︎ back"))
                        Readout(label: "Behind live", value: String(format: "%.0f ms", s.lag / model.sampleRate * 1000))
                    }
                    HStack(spacing: 8) {
                        Pill(on: s.active, text: s.active ? "Tone OK" : "No tone")
                        Pill(on: s.locked, text: "1× lock")
                        Pill(on: s.frozen, text: "Frozen", color: .cyan)
                        Pill(on: model.settings.calibrated, text: model.settings.calibrated ? "Calibrated" : "Uncalibrated")
                    }
                    Meters(state: s)
                    TapeView(model: model).frame(height: 70)
                }
            }
            HStack(spacing: 10) {
                HoldButton(title: "CUT") { model.setCut($0) }
                Button { model.toggleFreeze() } label: {
                    Label(s.frozen ? "Unfreeze" : "Freeze", systemImage: "snowflake").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).tint(s.frozen ? .cyan : .gray)
                Button { model.jumpToLive() } label: {
                    Label("Jump to live", systemImage: "forward.end.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
            }
            .controlSize(.large)
            VStack(spacing: 4) {
                HStack {
                    Text("Crossfader").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "gain %.0f%%", s.gain * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: model.binding(\.vfX), in: 0...1).tint(accent)
            }
        }
    }
}

struct Readout: View {
    let label: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
    }
}

struct Pill: View {
    let on: Bool, text: String
    var color: Color = .green
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? color.opacity(0.25) : Color(white: 0.2)))
            .foregroundStyle(on ? color : .secondary)
    }
}

/// Momentary button: on while pressed.
struct HoldButton: View {
    let title: String
    let action: (Bool) -> Void
    @State private var down = false
    var body: some View {
        Text(title).font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(down ? Color.red : Color(white: 0.22)))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; action(true) } }
                .onEnded { _ in down = false; action(false) })
    }
}

struct Meters: View {
    let state: ProcessorState
    var body: some View {
        VStack(spacing: 4) {
            bar("WOW in", state.ctrlPk)
            bar("Live in", state.livePk)
            bar("Out", state.outPk)
        }
    }
    func bar(_ label: String, _ pk: Double) -> some View {
        let db = 20 * log10(max(pk, 1e-5)), frac = max(0, min(1, (db + 60) / 60))
        return HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.2))
                    Capsule().fill(db > -1 ? Color.red : accent).frame(width: g.size.width * frac)
                }
            }.frame(height: 6)
            Text(pk < 1e-5 ? "–∞" : String(format: "%.0f", db)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30)
        }
    }
}

/// The platter: turns with the decoded position. With the virtual platter on, drag it to scratch.
struct PlatterView: View {
    @ObservedObject var model: ScratcherModel
    @State private var lastAngle: Double? = nil
    @State private var lastTime = Date()
    @State private var vel = 0.0

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let angle = (model.state.pos / model.sampleRate * revPerSecond).truncatingRemainder(dividingBy: 1) * 2 * .pi
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = min(sz.width, sz.height) / 2 - 2
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(white: 0.09)))
                for k in stride(from: 0.42, to: 0.97, by: 0.06) {
                    let rr = r * k
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(Color(white: 0.16)), lineWidth: 1)
                }
                let lr = r * 0.34
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - lr, y: c.y - lr, width: 2 * lr, height: 2 * lr)), with: .color(accent))
                var mark = Path()
                mark.move(to: CGPoint(x: c.x + cos(angle - .pi / 2) * lr * 0.3, y: c.y + sin(angle - .pi / 2) * lr * 0.3))
                mark.addLine(to: CGPoint(x: c.x + cos(angle - .pi / 2) * r * 0.96, y: c.y + sin(angle - .pi / 2) * r * 0.96))
                ctx.stroke(mark, with: .color(.white), lineWidth: 3)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.black))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard model.settings.virtualPlatter else { return }
                    let c = CGPoint(x: size / 2, y: size / 2)
                    let a = atan2(v.location.y - c.y, v.location.x - c.x)
                    let now = Date()
                    if let la = lastAngle {
                        var d = a - la
                        if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                        let dt = max(1.0 / 240, now.timeIntervalSince(lastTime))
                        let inst = d / dt / (2 * .pi * revPerSecond)
                        vel += (inst - vel) * 0.5
                    } else { vel = 0 }
                    lastAngle = a; lastTime = now
                    model.setHand(down: true, velocity: vel)
                }
                .onEnded { _ in
                    lastAngle = nil; vel = 0
                    model.setHand(down: false, velocity: 0)
                })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The last ~11 s of live audio, with the needle's position (and the freeze loop) marked.
struct TapeView: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Canvas { ctx, sz in
            let bins = model.bins, n = bins.count, head = model.binHead
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 8), with: .color(Color(white: 0.09)))
            let w = sz.width / CGFloat(n), mid = sz.height / 2
            var p = Path()
            for i in 0..<n {
                let v = CGFloat(min(1, bins[(head + i) % n] * 1.4))
                let x = CGFloat(i) * w
                p.addRect(CGRect(x: x, y: mid - v * mid * 0.92, width: max(1, w), height: max(1, v * mid * 1.84)))
            }
            ctx.fill(p, with: .color(Color(white: 0.45)))
            let s = model.state
            if s.frozen {
                let lw = CGFloat(Double(s.loopLen) / 256) * w
                ctx.fill(Path(CGRect(x: sz.width - lw, y: 0, width: lw, height: sz.height)), with: .color(Color.cyan.opacity(0.15)))
            }
            let x = sz.width - CGFloat(s.lag / 256) * w
            ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: sz.height)), with: .color(accent))
        }
    }
}

// MARK: - Settings shared by the app and the plugin

struct SettingsSections: View {
    @ObservedObject var model: ScratcherModel
    @State private var pickingLoop = false

    var body: some View {
        let s = model.settings
        VStack(spacing: 14) {
            Card(title: "Source") {
                Picker("Scratch", selection: model.binding(\.testLoop)) {
                    Text("Loop").tag(true); Text("Live input").tag(false)
                }.pickerStyle(.segmented)
                HStack {
                    Image(systemName: "repeat").foregroundStyle(.secondary)
                    Text(model.host?.loopName ?? "").lineLimit(1)
                    Spacer()
                    Button("Load loop…") { pickingLoop = true }
                    if s.loopFile != nil { Button("Built-in") { model.host?.setLoop(file: nil); model.objectWillChange.send() } }
                }
                .fileImporter(isPresented: $pickingLoop, allowedContentTypes: [.audio]) { r in
                    if case .success(let url) = r { model.host?.setLoop(file: url); model.objectWillChange.send() }
                }
                Toggle("Virtual platter (no WOW needed: drag the platter)", isOn: model.binding(\.virtualPlatter))
                if s.virtualPlatter {
                    Toggle("Motor on", isOn: Binding(get: { model.host?.processor.simMotor ?? true },
                                                    set: { model.setSimMotor($0); model.objectWillChange.send() }))
                }
            }

            Card(title: "Calibrate") {
                Text("Motor on, hands off, control tone playing (and the pilot beat, in pilot mode). Takes 1.5 s.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Calibrate") { model.calibrate() }.buttonStyle(.borderedProminent).tint(accent)
                    Toggle("Flip direction", isOn: model.binding(\.flip)).fixedSize()
                }
                Text(model.calMessage).font(.callout)
                    .foregroundStyle(model.calOK == true ? .green : model.calOK == false ? .orange : .secondary)
            }

            Card(title: "Fader") {
                Picker("Fader", selection: model.binding(\.faderMode)) {
                    Text("WOW + virtual").tag(FaderMode.both); Text("WOW").tag(FaderMode.wow)
                    Text("Virtual").tag(FaderMode.virtual); Text("Always open").tag(FaderMode.open)
                }.pickerStyle(.segmented)
                Picker("Read the WOW fader from", selection: model.binding(\.wowRead)) {
                    Text("Pilot tone (recommended)").tag(WowRead.pilot); Text("Tone level").tag(WowRead.level)
                }.pickerStyle(.segmented)
                ValueSlider(label: "WOW cut point", value: model.binding(\.faderLo), range: 0...0.6)
                ValueSlider(label: "WOW full open", value: model.binding(\.faderHi), range: 0.1...1)
                ValueSlider(label: "Tone gate", value: model.binding(\.gateDb), range: -80 ... -20) { String(format: "%.0f dB", $0) }
                ValueSlider(label: "Virtual cut-in", value: model.binding(\.vfCut), range: 0...0.5)
                ValueSlider(label: "Virtual curve", value: model.binding(\.vfWidth), range: 0.005...0.5)
                Toggle("Hamster (reverse the crossfader)", isOn: model.binding(\.hamster))
            }

            Card(title: "Feel") {
                ValueSlider(label: "Smoothing", value: model.binding(\.smoothMs), range: 0.3...12) { String(format: "%.1f ms", $0) }
                Picker("After a scratch", selection: model.binding(\.returnMode)) {
                    Text("Snap back to live").tag(ReturnMode.snap); Text("Stay behind").tag(ReturnMode.stay)
                }.pickerStyle(.segmented)
                ValueSlider(label: "Snap delay", value: model.binding(\.snapDelayMs), range: 0...1000) { String(format: "%.0f ms", $0) }
                Toggle("1× lock (motor speed plays exactly 1×)", isOn: model.binding(\.lock))
                ValueSlider(label: "Freeze loop", value: model.binding(\.loopSec), range: 0.25...16) { String(format: "%.2f s", $0) }
                ValueSlider(label: "Output gain", value: model.binding(\.outGain), range: 0...2) { String(format: "%.0f%%", $0 * 100) }
            }

            Card(title: "Diagnostics") {
                Text("Records 10 s of WOW in, live in, output and fader gain as a 4-channel WAV to send for troubleshooting.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.recordingBusy ? "Recording…" : "Record 10 s diagnostic") { model.recordDiagnostic() }
                        .disabled(model.recordingBusy)
                    if let url = model.diagnosticURL {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
    }
}
