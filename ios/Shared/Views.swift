import SwiftUI
import UniformTypeIdentifiers

let accent = Theme.orange
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
        .background(ThemeBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                (Text("LIVESKRATCH").foregroundStyle(Theme.chrome) + Text(".").foregroundStyle(Theme.orange))
                    .font(Theme.wide(22, .black).italic())
                    .shadow(color: .black.opacity(0.8), radius: 0, y: 1)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("LS-2000")
                    .font(Theme.lcdFont(10).weight(.bold))
                    .foregroundStyle(Color(red: 0.06, green: 0.075, blue: 0.1))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.chrome))
                Spacer()
                HelpButton(action: onHelp).tint(Theme.cyan)
            }
            HStack(spacing: 6) {
                let s = model.state
                Pill(on: s.active, text: s.active ? "Signal" : "No signal", color: s.active ? Theme.lime : Theme.orange)
                Pill(on: s.locked, text: "1× lock", color: Theme.cyan)
                Pill(on: model.settings.calibrated, text: model.settings.calibrated ? "Calibrated" : "Not calibrated",
                     color: Theme.lime)
                if s.frozen { Pill(on: true, text: "Frozen", color: Theme.amber) }
                Spacer(minLength: 0)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Readouts(state: model.state, sampleRate: model.sampleRate)
            TapeView(model: model).frame(height: 56)
            Meters(state: model.state)
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
            cell("Speed", String(format: "%+.2f×", state.v))
            cell("Direction", !state.active ? "—" : (state.dir > 0 ? "Fwd" : "Back"))
            cell("Behind live", String(format: "%.0f ms", state.lag / sampleRate * 1000))
        }
    }
    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(Theme.wide(8, .semibold)).foregroundStyle(Theme.lcdDim).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(Theme.lcdFont(22)).foregroundStyle(Theme.cyan)
                .shadow(color: Theme.cyan.opacity(0.7), radius: 6)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LCDBackground())
    }
}

/// A status light: a glowing LED and a label in a dark capsule.
struct Pill: View {
    let on: Bool, text: String
    var color: Color = Theme.lime
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(on ? color : Color(white: 0.18)).frame(width: 7, height: 7)
                .shadow(color: on ? color : .clear, radius: 4)
            Text(text.uppercased()).font(Theme.wide(8, .semibold)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? Color.white.opacity(0.92) : Theme.dim.opacity(0.7))
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Capsule().fill(Color(red: 0.043, green: 0.063, blue: 0.098)).overlay(Capsule().stroke(Theme.line, lineWidth: 1)))
    }
}

/// Recessed LCD window.
struct LCDBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [Theme.lcd, Color(red: 0.024, green: 0.102, blue: 0.133)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lcdLine, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
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
            Slider(value: model.binding(\.vfX), in: 0...1).tint(Theme.orange)
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
        RoundedRectangle(cornerRadius: 18)
            .fill(soundOn
                  ? AnyShapeStyle(RadialGradient(colors: [Color(red: 1, green: 0.63, blue: 0.35).opacity(down ? 0.8 : 0.55),
                                                          Theme.orange.opacity(0.22), Color(red: 0.47, green: 0.12, blue: 0).opacity(0.35)],
                                                 center: .top, startRadius: 0, endRadius: 220))
                  : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.12, green: 0.15, blue: 0.21), Theme.panel], startPoint: .top, endPoint: .bottom)))
            .overlay {
                VStack(spacing: 4) {
                    Text(cuts ? (down ? "CUT" : "TAP TO CUT") : (down ? "OPEN" : "HOLD TO OPEN"))
                        .font(Theme.wide(14, .bold))
                    Text(soundOn ? "SOUND ON" : "SOUND OFF").font(Theme.wide(8, .semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(soundOn ? Color(red: 1, green: 0.54, blue: 0.24) : Theme.line, lineWidth: 1))
            .shadow(color: soundOn ? Theme.orange.opacity(0.4) : .clear, radius: 12)
            .scaleEffect(down ? 0.99 : 1)
            .frame(height: 84)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; model.setPad(down: true) } }
                .onEnded { _ in down = false; model.setPad(down: false) })
            .accessibilityLabel("Fader pad")
    }
}

struct Transport: View {
    @ObservedObject var model: ScratcherModel
    var body: some View {
        HStack(spacing: 10) {
            if model.settings.faderStyle == .slider {
                HoldButton(title: "Cut", icon: "scissors") { model.setCut($0) }
            }
            TransportButton(title: model.state.frozen ? "Frozen" : "Freeze", icon: "snowflake",
                            lit: model.state.frozen, color: Theme.amber) { model.toggleFreeze() }
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
            VStack(spacing: 4) {
                Image(systemName: icon).font(.headline)
                Text(title.uppercased()).font(Theme.wide(9, .bold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(Color(red: 0.06, green: 0.075, blue: 0.1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(lit ? AnyShapeStyle(color) : AnyShapeStyle(Theme.chrome))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 0.36, green: 0.4, blue: 0.45), lineWidth: 1))
                    .shadow(color: lit ? color.opacity(0.55) : .black.opacity(0.5), radius: lit ? 10 : 3, y: lit ? 0 : 2)
            )
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
        VStack(spacing: 4) {
            Image(systemName: icon).font(.headline)
            Text(title.uppercased()).font(Theme.wide(9, .bold))
        }
        .foregroundStyle(Color(red: 0.06, green: 0.075, blue: 0.1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(down ? AnyShapeStyle(Theme.orange) : AnyShapeStyle(Theme.chrome))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 0.36, green: 0.4, blue: 0.45), lineWidth: 1))
            .shadow(color: down ? Theme.orange.opacity(0.6) : .black.opacity(0.5), radius: down ? 10 : 3))
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
            Text(label).font(Theme.wide(8, .semibold)).foregroundStyle(Theme.dim).frame(width: 40, alignment: .leading)
            LEDBar(level: frac).frame(height: 8)
        }
    }
}

/// Segmented LED meter: lime, then amber, then orange at the top.
struct LEDBar: View {
    let level: Double
    var body: some View {
        Canvas { ctx, sz in
            let n = 32, gap: CGFloat = 2
            let w = (sz.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Int((level * Double(n)).rounded())
            for i in 0..<n {
                let f = Double(i) / Double(n)
                let c: Color = f > 0.9 ? Theme.orange : f > 0.75 ? Theme.amber : Theme.lime
                let r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: sz.height)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(i < lit ? c : c.opacity(0.1)))
            }
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
            let locked = model.state.locked
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = min(sz.width, sz.height) / 2 - 2
                func disc(_ rr: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)) }
                // brushed-chrome platter
                ctx.fill(disc(r), with: .linearGradient(Gradient(stops: [
                    .init(color: Color(white: 0.96), location: 0), .init(color: Color(red: 0.6, green: 0.64, blue: 0.68), location: 0.35),
                    .init(color: Color(white: 0.91), location: 0.5), .init(color: Color(red: 0.49, green: 0.53, blue: 0.58), location: 0.7),
                    .init(color: Color(white: 0.86), location: 1)]),
                    startPoint: CGPoint(x: c.x - r, y: c.y - r), endPoint: CGPoint(x: c.x + r, y: c.y + r)))
                // strobe dots: four rows; the second glows orange when locked at 1×
                for row in 0..<4 {
                    let rr = r - r * 0.04 - CGFloat(row) * r * 0.045, nDots = 72 - row * 4
                    for i in 0..<nDots {
                        let a = angle + Double(i) / Double(nDots) * 2 * .pi
                        let p = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                        let dr = max(1, r * 0.011)
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - dr, y: p.y - dr, width: 2 * dr, height: 2 * dr)),
                                 with: .color(locked && row == 1 ? Theme.orange : Color(red: 0.27, green: 0.3, blue: 0.35)))
                    }
                }
                // black vinyl and grooves
                let vr = r * 0.8
                ctx.fill(disc(vr), with: .color(Color(red: 0.027, green: 0.031, blue: 0.043)))
                for k in stride(from: 0.46, to: 0.98, by: 0.035) {
                    ctx.stroke(disc(vr * k), with: .color(Color(red: 0.08, green: 0.1, blue: 0.14)), lineWidth: 1)
                }
                ctx.fill(disc(vr), with: .linearGradient(Gradient(colors: [.clear, Theme.cyan.opacity(0.10), Theme.orange.opacity(0.08), .clear]),
                                                         startPoint: CGPoint(x: c.x - vr, y: c.y - vr), endPoint: CGPoint(x: c.x + vr, y: c.y + vr)))
                // label, rotating with the record
                let lr = r * 0.34
                ctx.fill(disc(lr), with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.69, blue: 0.48), locked ? Theme.orange : Color(red: 0.85, green: 0.31, blue: 0.05)]),
                                                         center: CGPoint(x: c.x - lr * 0.3, y: c.y - lr * 0.35), startRadius: 2, endRadius: lr * 1.3))
                ctx.stroke(disc(lr * 0.8), with: .color(.black.opacity(0.3)), lineWidth: 1.5)
                var lab = ctx
                lab.translateBy(x: c.x, y: c.y)
                lab.rotate(by: .radians(angle))
                lab.draw(Text("LIVESKRATCH").font(.system(size: max(7, lr * 0.2), weight: .black).width(.expanded))
                            .foregroundStyle(Color(red: 0.09, green: 0.03, blue: 0)), at: CGPoint(x: 0, y: -lr * 0.28))
                lab.draw(Text("LS-2000 · 33⅓").font(.system(size: max(6, lr * 0.14), design: .monospaced))
                            .foregroundStyle(Color(red: 0.09, green: 0.03, blue: 0)), at: CGPoint(x: 0, y: lr * 0.34))
                // cue marker on the vinyl
                var mark = Path()
                mark.move(to: CGPoint(x: c.x + cos(angle - .pi / 2) * vr * 0.62, y: c.y + sin(angle - .pi / 2) * vr * 0.62))
                mark.addLine(to: CGPoint(x: c.x + cos(angle - .pi / 2) * vr * 0.97, y: c.y + sin(angle - .pi / 2) * vr * 0.97))
                ctx.stroke(mark, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                // spindle
                ctx.fill(disc(max(3, r * 0.03)), with: .radialGradient(Gradient(colors: [.white, Color(red: 0.49, green: 0.53, blue: 0.58)]),
                                                                        center: c, startRadius: 0, endRadius: r * 0.03))
            }
            .shadow(color: .black.opacity(0.6), radius: 14, y: 10)
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
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: 10), with: .color(Theme.lcd))
            ctx.stroke(Path(roundedRect: CGRect(origin: .zero, size: sz).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10), with: .color(Theme.lcdLine), lineWidth: 1)
            let w = sz.width / CGFloat(n), mid = sz.height / 2
            var p = Path()
            for i in 0..<n {
                let v = CGFloat(min(1, bins[(head + i) % n] * 1.4))
                p.addRect(CGRect(x: CGFloat(i) * w, y: mid - v * mid * 0.9, width: max(1, w), height: max(1, v * mid * 1.8)))
            }
            ctx.fill(p, with: .color(Theme.cyan.opacity(0.55)))
            let s = model.state
            if s.frozen {
                let lw = CGFloat(Double(s.loopLen) / 256) * w
                ctx.fill(Path(CGRect(x: sz.width - lw, y: 0, width: lw, height: sz.height)), with: .color(Theme.amber.opacity(0.12)))
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
                .foregroundStyle(model.calOK == true ? Theme.lime : model.calOK == false ? Theme.orange : Theme.dim)
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
