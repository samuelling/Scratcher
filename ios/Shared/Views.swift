import SwiftUI
import UniformTypeIdentifiers

let accent = Color(red: 1.0, green: 0.42, blue: 0.2)
let revPerSecond = 0.555   // 33⅓ rpm at 1×

// MARK: - App shell: Scratch / Setup / Feel tabs (shared by the app and the plugin)

struct ScratcherTabs<Setup: View>: View {
    @ObservedObject var model: ScratcherModel
    var problem: String? = nil
    @ViewBuilder var setup: Setup

    @State private var helpTopic: HelpTopic? = nil
    @State private var walkthrough = false
    @AppStorage("liveskratch.seenWalkthrough") private var seenWalkthrough = false
    private var isPlugin: Bool { model.host?.isPlugin ?? false }

    var body: some View {
        TabView {
            PlayView(model: model, problem: problem, onHelp: { helpTopic = .scratch })
                .tabItem { Label("Scratch", systemImage: "opticaldisc") }
            NavigationStack {
                Form {
                    setup
                    SourceSection(model: model)
                    CalibrateSection(model: model)
                    DiagnosticsSection(model: model)
                }
                .navigationTitle("Setup")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { HelpButton { helpTopic = .setup } } }
            }
            .tabItem { Label("Setup", systemImage: "cable.connector") }
            NavigationStack {
                Form {
                    FaderSection(model: model)
                    VirtualFaderSection(model: model)
                    FeelSection(model: model)
                }
                .navigationTitle("Feel")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { HelpButton { helpTopic = .feel } } }
            }
            .tabItem { Label("Feel", systemImage: "slider.horizontal.3") }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .sheet(item: $helpTopic) { topic in
            HelpSheet(topic: topic, plugin: isPlugin, onWalkthrough: {
                helpTopic = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { walkthrough = true }
            })
        }
        .fullScreenCover(isPresented: $walkthrough) {
            WalkthroughView(model: model) { walkthrough = false; seenWalkthrough = true }
        }
        .onAppear { if !seenWalkthrough && !isPlugin { walkthrough = true } }
    }
}

// MARK: - Scratch screen

struct PlayView: View {
    @ObservedObject var model: ScratcherModel
    var problem: String?
    var onHelp: () -> Void = {}
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geo in
            let wide = sizeClass == .regular && geo.size.width > geo.size.height
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if wide {
                        HStack(alignment: .center, spacing: 28) {
                            PlatterView(model: model).frame(maxWidth: min(440, geo.size.height - 140))
                            controls
                        }
                    } else {
                        PlatterView(model: model)
                            .frame(maxWidth: 340)
                            .frame(maxWidth: .infinity)
                        controls
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: wide ? .infinity : 620)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(white: 0.06))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LiveSkratch").font(.title2.weight(.heavy))
                Spacer()
                HelpButton(action: onHelp).tint(accent)
            }
            HStack(spacing: 6) {
                let s = model.state
                Pill(on: s.active, text: s.active ? "Tone" : "No tone", color: s.active ? .green : .orange)
                Pill(on: s.locked, text: "1×")
                Pill(on: model.settings.calibrated, text: model.settings.calibrated ? "Calibrated" : "Not calibrated",
                     color: model.settings.calibrated ? .green : .secondary)
                if s.frozen { Pill(on: true, text: "Frozen", color: .cyan) }
                Spacer(minLength: 0)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Readouts(state: model.state, sampleRate: model.sampleRate)
            TapeView(model: model).frame(height: 56)
            Meters(state: model.state)
            Crossfader(model: model)
            Transport(model: model)
        }
    }
}

struct Readouts: View {
    let state: ProcessorState
    let sampleRate: Double
    var body: some View {
        HStack(spacing: 0) {
            cell("Speed", String(format: "%+.2f×", state.v))
            cell("Direction", !state.active ? "—" : (state.dir > 0 ? "Fwd" : "Back"))
            cell("Behind live", String(format: "%.0f ms", state.lag / sampleRate * 1000))
        }
    }
    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Pill: View {
    let on: Bool, text: String
    var color: Color = .green
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? color.opacity(0.22) : Color(white: 0.16)))
            .foregroundStyle(on ? color : Color.secondary)
    }
}

struct Crossfader: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Crossfader").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%% open", model.state.gain * 100))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: model.binding(\.vfX), in: 0...1)
        }
    }
}

struct Transport: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        HStack(spacing: 10) {
            HoldButton(title: "Cut", icon: "scissors") { model.setCut($0) }
            TransportButton(title: model.state.frozen ? "Frozen" : "Freeze", icon: "snowflake",
                            lit: model.state.frozen, color: .cyan) { model.toggleFreeze() }
            TransportButton(title: "Live", icon: "forward.end.fill", lit: false, color: accent) { model.jumpToLive() }
        }
        .frame(height: 54)
    }
}

struct TransportButton: View {
    let title: String, icon: String
    let lit: Bool
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.headline)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(lit ? color.opacity(0.35) : Color(white: 0.15)))
            .foregroundStyle(lit ? color : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// Momentary: on while pressed.
struct HoldButton: View {
    let title: String, icon: String
    let action: (Bool) -> Void
    @State private var down = false
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.headline)
            Text(title).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(down ? Color.red : Color(white: 0.15)))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !down { down = true; action(true) } }
            .onEnded { _ in down = false; action(false) })
    }
}

struct Meters: View {
    let state: ProcessorState
    var body: some View {
        VStack(spacing: 5) {
            bar("WOW", state.ctrlPk)
            bar("Live", state.livePk)
            bar("Out", state.outPk)
        }
    }
    private func bar(_ label: String, _ pk: Double) -> some View {
        let db = 20 * log10(max(pk, 1e-5)), frac = max(0, min(1, (db + 60) / 60))
        return HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.16))
                    Capsule().fill(db > -1 ? Color.red : accent).frame(width: g.size.width * frac)
                }
            }
            .frame(height: 5)
        }
    }
}

/// The platter turns with the decoded position. With the virtual platter on, drag it to scratch.
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
                func disc(_ rr: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)) }
                ctx.fill(disc(r), with: .color(Color(white: 0.1)))
                for k in stride(from: 0.42, to: 0.97, by: 0.055) {
                    ctx.stroke(disc(r * k), with: .color(Color(white: 0.15)), lineWidth: 1)
                }
                let lr = r * 0.34
                ctx.fill(disc(lr), with: .color(accent))
                var mark = Path()
                mark.move(to: CGPoint(x: c.x + cos(angle - .pi / 2) * lr * 0.3, y: c.y + sin(angle - .pi / 2) * lr * 0.3))
                mark.addLine(to: CGPoint(x: c.x + cos(angle - .pi / 2) * r * 0.96, y: c.y + sin(angle - .pi / 2) * r * 0.96))
                ctx.stroke(mark, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ctx.fill(disc(4), with: .color(.black))
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
                        vel += (d / dt / (2 * .pi * revPerSecond) - vel) * 0.5
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

/// The last ~11 s of live audio, with the needle and the freeze loop marked.
struct TapeView: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Canvas { ctx, sz in
            let bins = model.bins, n = bins.count, head = model.binHead
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 8), with: .color(Color(white: 0.1)))
            let w = sz.width / CGFloat(n), mid = sz.height / 2
            var p = Path()
            for i in 0..<n {
                let v = CGFloat(min(1, bins[(head + i) % n] * 1.4))
                p.addRect(CGRect(x: CGFloat(i) * w, y: mid - v * mid * 0.9, width: max(1, w), height: max(1, v * mid * 1.8)))
            }
            ctx.fill(p, with: .color(Color(white: 0.42)))
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

// MARK: - Settings rows

/// Label and value on one line, slider underneath: never squeezes on a phone.
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct SourceSection: View {
    @ObservedObject var model: ScratcherModel
    @State private var pickingLoop = false
    var body: some View {
        Section {
            Picker("Scratch", selection: model.binding(\.testLoop)) {
                Text("Loop").tag(true); Text("Live input").tag(false)
            }
            .pickerStyle(.segmented)
            LabeledContent("Loop") {
                Text(model.host?.loopName ?? "").lineLimit(1).truncationMode(.middle)
            }
            Button("Load a loop from Files…") { pickingLoop = true }
            if model.settings.loopFile != nil {
                Button("Use the built-in loop") { model.host?.setLoop(file: nil); model.objectWillChange.send() }
            }
            Toggle("Virtual platter", isOn: model.binding(\.virtualPlatter))
            if model.settings.virtualPlatter {
                Toggle("Motor on", isOn: Binding(get: { model.host?.processor.simMotor ?? true },
                                                set: { model.setSimMotor($0); model.objectWillChange.send() }))
            }
        } header: {
            Text("What you scratch")
        } footer: {
            Text("Virtual platter lets you scratch by dragging the on-screen platter, no WOW needed.")
        }
        .fileImporter(isPresented: $pickingLoop, allowedContentTypes: [.audio]) { r in
            if case .success(let url) = r { model.host?.setLoop(file: url); model.objectWillChange.send() }
        }
    }
}

struct CalibrateSection: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Section {
            Button { model.calibrate() } label: { Label("Calibrate", systemImage: "scope") }
            Text(model.calMessage).font(.footnote)
                .foregroundStyle(model.calOK == true ? .green : model.calOK == false ? .orange : .secondary)
            Toggle("Flip direction", isOn: model.binding(\.flip))
        } header: {
            Text("Calibrate")
        } footer: {
            Text("Motor on, hands off, control tone playing (and the pilot beat in pilot mode). Takes 1.5 s.")
        }
    }
}

struct DiagnosticsSection: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Section {
            Button(model.recordingBusy ? "Recording…" : "Record 10 s diagnostic") { model.recordDiagnostic() }
                .disabled(model.recordingBusy)
            if let url = model.diagnosticURL {
                ShareLink(item: url) { Label("Share diagnostic", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("A 4-channel WAV of WOW in, live in, output and fader gain, for troubleshooting.")
        }
    }
}

struct FaderSection: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Section {
            Picker("Fader", selection: model.binding(\.faderMode)) {
                Text("WOW + virtual").tag(FaderMode.both); Text("WOW only").tag(FaderMode.wow)
                Text("Virtual only").tag(FaderMode.virtual); Text("Always open").tag(FaderMode.open)
            }
            Picker("Read WOW fader by", selection: model.binding(\.wowRead)) {
                Text("Pilot tone").tag(WowRead.pilot); Text("Tone level").tag(WowRead.level)
            }
            SliderRow(label: "Cut point", value: model.binding(\.faderLo), range: 0...0.6)
            SliderRow(label: "Fully open", value: model.binding(\.faderHi), range: 0.1...1)
            SliderRow(label: "Tone gate", value: model.binding(\.gateDb), range: -80 ... -20) { String(format: "%.0f dB", $0) }
        } header: {
            Text("WOW fader")
        } footer: {
            Text("Pilot tone is the reliable mode: the fader cuts the 18 kHz pilot beat, so the platter is tracked through every cut.")
        }
    }
}

struct VirtualFaderSection: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Section("On-screen crossfader") {
            SliderRow(label: "Cut-in", value: model.binding(\.vfCut), range: 0...0.5)
            SliderRow(label: "Curve", value: model.binding(\.vfWidth), range: 0.005...0.5)
            Toggle("Hamster (reverse)", isOn: model.binding(\.hamster))
        }
    }
}

struct FeelSection: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Section("Feel") {
            SliderRow(label: "Smoothing", value: model.binding(\.smoothMs), range: 0.3...12) { String(format: "%.1f ms", $0) }
            Picker("After a scratch", selection: model.binding(\.returnMode)) {
                Text("Snap back").tag(ReturnMode.snap); Text("Stay behind").tag(ReturnMode.stay)
            }
            if model.settings.returnMode == .snap {
                SliderRow(label: "Snap delay", value: model.binding(\.snapDelayMs), range: 0...1000) { String(format: "%.0f ms", $0) }
            }
            Toggle("Lock to exactly 1×", isOn: model.binding(\.lock))
            SliderRow(label: "Freeze loop", value: model.binding(\.loopSec), range: 0.25...16) { String(format: "%.2f s", $0) }
            SliderRow(label: "Output gain", value: model.binding(\.outGain), range: 0...2) { String(format: "%.0f%%", $0 * 100) }
        }
    }
}
