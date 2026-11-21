import SwiftUI
import UniformTypeIdentifiers

let accent = Theme.green
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
                    ControlSignalSection(model: model)
                    setup
                    SourceSection(model: model)
                    CalibrateSection(model: model)
                    DiagnosticsSection(model: model)
                }
                .scrollContentBackground(.hidden)
                .background(ThemeBackground())
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
                .scrollContentBackground(.hidden)
                .background(ThemeBackground())
                .navigationTitle("Feel")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { HelpButton { helpTopic = .feel } } }
            }
            .tabItem { Label("Feel", systemImage: "slider.horizontal.3") }
        }
        .tint(accent)
        .toolbarBackground(Theme.bg, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
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
    @ObservedObject private var live: LiveState
    var problem: String?
    var onHelp: () -> Void = {}
    init(model: ScratcherModel, problem: String?, onHelp: @escaping () -> Void = {}) {
        _model = ObservedObject(wrappedValue: model); _live = ObservedObject(wrappedValue: model.live)
        self.problem = problem; self.onHelp = onHelp
    }
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geo in
            let wide = sizeClass == .regular && geo.size.width > geo.size.height
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(Theme.wide(14, .medium)).foregroundStyle(Theme.red)
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
        .background(ThemeBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                (Text("LIVESKRATCH").foregroundStyle(Theme.ink) + Text(".").foregroundStyle(Theme.red))
                    .font(Theme.wide(28, .semibold)).kerning(2)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("LS-1").font(Theme.wide(11, .semibold)).kerning(1.5).foregroundStyle(Theme.blue)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.blue, lineWidth: Theme.stroke))
                Spacer()
                HelpButton(action: onHelp).tint(Theme.ink)
            }
            HStack(spacing: 6) {
                let s = live.state
                Pill(on: s.active, text: s.active ? "Signal" : "No signal", color: s.active ? Theme.green : Theme.red)
                Pill(on: s.locked, text: "1× lock", color: Theme.blue)
                Pill(on: model.settings.calibrated, text: model.settings.calibrated ? "Calibrated" : "Not calibrated",
                     color: Theme.green)
                if s.frozen { Pill(on: true, text: "Frozen", color: Theme.amber) }
                Spacer(minLength: 0)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Readouts(state: live.state, sampleRate: model.sampleRate)
            TapeView(model: model).frame(height: 56)
            Meters(state: live.state)
            if model.settings.faderStyle == .pad {
                FaderPad(model: model)
            } else {
                Crossfader(model: model)
            }
            Transport(model: model)
        }
    }
}

struct Readouts: View {
    let state: ProcessorState
    let sampleRate: Double
    var body: some View {
        HStack(spacing: 8) {
            cell("Speed", String(format: "%+.2f×", state.v), Theme.blue)
            cell("Direction", !state.active ? "—" : (state.dir > 0 ? "FWD" : "BACK"), state.dir > 0 ? Theme.green : Theme.red)
            cell("Behind live", String(format: "%.0f ms", state.lag / sampleRate * 1000), Theme.ink)
        }
    }
    private func cell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Theme.wide(11, .semibold)).kerning(1.2).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(Theme.lcdFont(28)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LCDBackground())
    }
}

/// A status light: a small dot (filled when on) and a label, in an outlined tag.
struct Pill: View {
    let on: Bool, text: String
    var color: Color = Theme.green
    var body: some View {
        HStack(spacing: 6) {
            Circle().stroke(on ? color : Theme.line, lineWidth: Theme.stroke)
                .background(Circle().fill(on ? color : .clear))
                .frame(width: 7, height: 7)
            Text(text.uppercased()).font(Theme.wide(11, .semibold)).kerning(1.2).lineLimit(1).fixedSize()
                .foregroundStyle(on ? Theme.ink : Theme.dim)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Theme.ink : Theme.line, lineWidth: Theme.stroke))
    }
}

/// An outlined readout window.
struct LCDBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: Theme.stroke)
    }
}

struct Crossfader: View {
    @ObservedObject var model: ScratcherModel
    @ObservedObject private var live: LiveState
    init(model: ScratcherModel) { _model = ObservedObject(wrappedValue: model); _live = ObservedObject(wrappedValue: model.live) }
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("CROSSFADER").font(Theme.wide(11, .semibold)).kerning(1.2).foregroundStyle(Theme.dim)
                Spacer()
                Text(String(format: "%.0f%% open", live.state.gain * 100))
                    .font(Theme.lcdFont(13)).foregroundStyle(Theme.dim)
            }
            Slider(value: model.binding(\.vfX), in: 0...1).tint(Theme.green)
        }
    }
}

/// The on-screen fader as a tap pad, like a PT01's cut switch: touch it to chop the sound.
struct FaderPad: View {
    @ObservedObject var model: ScratcherModel
    @State private var down = false
    var body: some View {
        let cuts = model.settings.padCuts
        let soundOn = cuts ? !down : down
        let col = soundOn ? Theme.green : Theme.red
        RoundedRectangle(cornerRadius: 12)
            .fill(down ? col : .clear)
            .background(Hatch(color: col.opacity(soundOn && !down ? 0.35 : 0)).clipShape(RoundedRectangle(cornerRadius: 12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(col, lineWidth: Theme.stroke))
            .overlay {
                VStack(spacing: 4) {
                    Text(cuts ? (down ? "CUT" : "TAP TO CUT") : (down ? "OPEN" : "HOLD TO OPEN"))
                        .font(Theme.wide(20, .semibold)).kerning(3)
                    Text(soundOn ? "SOUND ON" : "SOUND OFF").font(Theme.wide(11, .semibold)).kerning(2)
                        .foregroundStyle(down ? Color.black.opacity(0.7) : Theme.dim)
                }
                .foregroundStyle(down ? Color.black : col)
            }
            .frame(height: 84)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; model.setPad(down: true) } }
                .onEnded { _ in down = false; model.setPad(down: false) })
            .accessibilityLabel("Fader pad")
    }
}

/// Fine diagonal hatching, for "on" areas without a solid fill.
struct Hatch: View {
    let color: Color
    var body: some View {
        Canvas { ctx, sz in
            var p = Path()
            var x: CGFloat = -sz.height
            while x < sz.width { p.move(to: CGPoint(x: x, y: sz.height)); p.addLine(to: CGPoint(x: x + sz.height, y: 0)); x += 8 }
            ctx.stroke(p, with: .color(color), lineWidth: 1)
        }
    }
}

struct Transport: View {
    @ObservedObject var model: ScratcherModel
    @ObservedObject private var live: LiveState
    init(model: ScratcherModel) { _model = ObservedObject(wrappedValue: model); _live = ObservedObject(wrappedValue: model.live) }
    var body: some View {
        HStack(spacing: 10) {
            if model.settings.faderStyle == .slider {
                HoldButton(title: "Cut", icon: "scissors") { model.setCut($0) }
            }
            TransportButton(title: live.state.frozen ? "Frozen" : "Freeze", icon: "snowflake",
                            lit: live.state.frozen, color: Theme.amber) { model.toggleFreeze() }
            TransportButton(title: "Live", icon: "forward.end", lit: false, color: Theme.blue) { model.jumpToLive() }
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
                Image(systemName: icon).font(.system(size: 17, weight: .regular))
                Text(title.uppercased()).font(Theme.wide(12, .semibold)).kerning(1.5).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(lit ? Color.black : color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(lit ? color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: Theme.stroke))
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
            Image(systemName: icon).font(.system(size: 17, weight: .regular))
            Text(title.uppercased()).font(Theme.wide(12, .semibold)).kerning(1.5)
        }
        .foregroundStyle(down ? Color.black : Theme.red)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(down ? Theme.red : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.red, lineWidth: Theme.stroke))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !down { down = true; action(true) } }
            .onEnded { _ in down = false; action(false) })
    }
}

struct Meters: View {
    let state: ProcessorState
    var body: some View {
        VStack(spacing: 6) {
            bar("WOW", state.ctrlPk)
            bar("LIVE", state.livePk)
            bar("OUT", state.outPk)
        }
    }
    private func bar(_ label: String, _ pk: Double) -> some View {
        let db = 20 * log10(max(pk, 1e-5)), frac = max(0, min(1, (db + 60) / 60))
        return HStack(spacing: 8) {
            Text(label).font(Theme.wide(11, .semibold)).kerning(1.2).foregroundStyle(Theme.dim).frame(width: 40, alignment: .leading)
            LEDBar(level: frac).frame(height: 10)
        }
    }
}

/// Segmented meter: thin outlined cells, green, then amber, then red at the top.
struct LEDBar: View {
    let level: Double
    var body: some View {
        Canvas { ctx, sz in
            let n = 36, gap: CGFloat = 2
            let w = (sz.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Int((level * Double(n)).rounded())
            for i in 0..<n {
                let f = Double(i) / Double(n)
                let c: Color = f > 0.88 ? Theme.red : f > 0.72 ? Theme.amber : Theme.green
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: sz.height)
                if i < lit { ctx.fill(Path(r), with: .color(c)) }
                else { ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.line), lineWidth: 1) }
            }
        }
    }
}

/// The platter turns with the decoded position. With the virtual platter on, drag it to scratch.
struct PlatterView: View {
    @ObservedObject var model: ScratcherModel
    @ObservedObject private var live: LiveState
    init(model: ScratcherModel) { _model = ObservedObject(wrappedValue: model); _live = ObservedObject(wrappedValue: model.live) }
    @State private var lastAngle: Double? = nil
    @State private var lastTime = Date()
    @State private var vel = 0.0

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let angle = (live.state.pos / model.sampleRate * revPerSecond).truncatingRemainder(dividingBy: 1) * 2 * .pi
            let locked = live.state.locked
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = min(sz.width, sz.height) / 2 - 2
                let lw: CGFloat = max(1.5, r / 110)
                func disc(_ rr: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)) }
                ctx.stroke(disc(r - lw), with: .color(Theme.ink), lineWidth: lw)            // platter edge
                // strobe ticks: green and solid at 1×
                var ticks = Path()
                for i in 0..<60 {
                    let a = angle + Double(i) / 60 * 2 * .pi
                    let r1 = r - lw * 4, r2 = r - lw * (i % 5 == 0 ? 10 : 7)
                    ticks.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                    ticks.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
                }
                ctx.stroke(ticks, with: .color(locked ? Theme.green : Theme.dim), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let vr = r * 0.84
                ctx.stroke(disc(vr), with: .color(Theme.ink), lineWidth: lw)                  // record edge
                for k in 0..<5 {                                                              // grooves
                    ctx.stroke(disc(vr * (0.88 - CGFloat(k) * 0.1)), with: .color(Theme.line),
                               style: StrokeStyle(lineWidth: lw, dash: k % 2 == 1 ? [lw * 2, lw * 4] : []))
                }
                // the one filled object: the label, turning with the record
                let lr = r * 0.3
                ctx.fill(disc(lr), with: .color(Theme.blue))
                ctx.stroke(disc(lr * 0.73), with: .color(.black), lineWidth: lw)
                var lab = ctx
                lab.translateBy(x: c.x, y: c.y)
                lab.rotate(by: .radians(angle))
                lab.draw(Text("LIVESKRATCH").font(.system(size: max(7, lr * 0.24), weight: .semibold).width(.condensed))
                            .foregroundStyle(Color.black), at: CGPoint(x: 0, y: -lr * 0.2))
                lab.draw(Text("33⅓").font(.system(size: max(6, lr * 0.16), weight: .semibold).width(.condensed))
                            .foregroundStyle(Color.black), at: CGPoint(x: 0, y: lr * 0.35))
                // cue line
                var mark = Path()
                mark.move(to: CGPoint(x: c.x + cos(angle - .pi / 2) * lr * 1.2, y: c.y + sin(angle - .pi / 2) * lr * 1.2))
                mark.addLine(to: CGPoint(x: c.x + cos(angle - .pi / 2) * (vr - lw * 3), y: c.y + sin(angle - .pi / 2) * (vr - lw * 3)))
                ctx.stroke(mark, with: .color(Theme.red), style: StrokeStyle(lineWidth: lw * 2, lineCap: .round))
                ctx.fill(disc(r * 0.025), with: .color(.black))
                ctx.stroke(disc(r * 0.025), with: .color(Theme.ink), lineWidth: lw)
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
    @ObservedObject private var live: LiveState
    init(model: ScratcherModel) { _model = ObservedObject(wrappedValue: model); _live = ObservedObject(wrappedValue: model.live) }
    var body: some View {
        Canvas { ctx, sz in
            let bins = live.bins, n = bins.count, head = live.binHead
            let frame = CGRect(origin: .zero, size: sz).insetBy(dx: 0.75, dy: 0.75)
            ctx.stroke(Path(roundedRect: frame, cornerRadius: 8), with: .color(Theme.line), lineWidth: Theme.stroke)
            let w = sz.width / CGFloat(n), mid = sz.height / 2
            var center = Path(); center.move(to: CGPoint(x: 0, y: mid)); center.addLine(to: CGPoint(x: sz.width, y: mid))
            ctx.stroke(center, with: .color(Theme.line), lineWidth: 1)
            let s = live.state
            // the envelope as two thin lines
            for sign in [-1.0, 1.0] {
                var p = Path()
                var i = 0
                while i < n {
                    let v = CGFloat(min(1, max(bins[(head + i) % n], bins[(head + i + 1) % n]).squareRoot()))
                    let pt = CGPoint(x: CGFloat(i) * w, y: mid + CGFloat(sign) * v * (mid - 5))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    i += 2
                }
                ctx.stroke(p, with: .color(s.frozen ? Theme.amber : Theme.ink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            if s.frozen {
                let lw = CGFloat(Double(s.loopLen) / 256) * w
                ctx.stroke(Path(roundedRect: CGRect(x: sz.width - lw + 2, y: 3, width: lw - 4, height: sz.height - 6), cornerRadius: 4),
                           with: .color(Theme.amber), style: StrokeStyle(lineWidth: Theme.stroke, dash: [3, 5]))
            }
            let x = sz.width - CGFloat(s.lag / 256) * w
            ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: sz.height)), with: .color(Theme.red))
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
                Text(format(value)).font(Theme.lcdFont(17)).foregroundStyle(Theme.blue)
            }
            Slider(value: $value, in: range).tint(Theme.green)
        }
    }
}

struct ControlSignalSection: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        let timecode = model.settings.controlSignal == .timecode
        Section {
            Picker("Control signal", selection: Binding(get: { model.settings.controlSignal },
                                                       set: { c in var s = model.settings; s.setControl(c); model.settings = s })) {
                Text("WOW tone").tag(ControlSignal.wowTone)
                Text("Stereo timecode").tag(ControlSignal.timecode)
            }
            if timecode {
                Picker("Timecode", selection: Binding(get: { model.settings.carrierHz < 1500 ? 1000.0 : 2000.0 },
                                                      set: { hz in var s = model.settings; s.carrierHz = hz; s.calibrated = false; model.settings = s })) {
                    Text("Serato · LiveSkratch").tag(1000.0)
                    Text("Traktor").tag(2000.0)
                }
            }
        } header: {
            Text("Control")
        } footer: {
            Text(timecode
                 ? (model.host?.isPlugin == true
                    ? "Stereo timecode uses both plugin inputs, so you scratch the loop (or a loaded file). Calibrate detects the exact timecode."
                    : "Control vinyl or CDs (Serato, Traktor), or the LiveSkratch timecode file played by an SC-1000 / SC-500. Needs two inputs. Calibrate detects the exact timecode.")
                 : "The LiveSkratch tone, played by a WOW in LiveSkratch mode.")
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
                .foregroundStyle(model.calOK == true ? Theme.green : model.calOK == false ? Theme.red : Theme.dim)
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
            Text(model.settings.controlSignal == .timecode
                 ? "Timecode mode: a timecode deck has no WOW fader, so only the on-screen fader cuts the sound. These settings apply to the WOW tone."
                 : "Pilot tone is the reliable mode: the fader cuts the 18 kHz pilot beat, so the platter is tracked through every cut.")
        }
    }
}

struct VirtualFaderSection: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        Section {
            Picker("Style", selection: model.binding(\.faderStyle)) {
                Text("Tap pad").tag(FaderStyle.pad); Text("Slider").tag(FaderStyle.slider)
            }
            .pickerStyle(.segmented)
            if model.settings.faderStyle == .pad {
                Picker("Touching the pad", selection: model.binding(\.padCuts)) {
                    Text("Cuts the sound").tag(true); Text("Opens the sound").tag(false)
                }
            } else {
                SliderRow(label: "Cut-in", value: model.binding(\.vfCut), range: 0...0.5)
                SliderRow(label: "Curve", value: model.binding(\.vfWidth), range: 0.005...0.5)
                Toggle("Hamster (reverse)", isOn: model.binding(\.hamster))
            }
        } header: {
            Text("On-screen fader")
        } footer: {
            Text(model.settings.faderStyle == .pad
                 ? "Like a PT01's cut switch: tap the pad in rhythm to chop the sound."
                 : "A crossfader slider, with a Cut button beside Freeze and Live.")
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
