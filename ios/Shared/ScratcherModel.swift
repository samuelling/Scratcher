import SwiftUI
import Combine

/// Whatever owns the audio: the standalone app (RemoteIO) or the AUv3 instance.
protocol ScratcherHost: AnyObject {
    var processor: Processor { get }
    var settings: ScratcherSettings { get set }
    var isPlugin: Bool { get }
    /// Input channel names for the routing UI (app only).
    var inputChannelNames: [String] { get }
    var outputPairNames: [String] { get }
    var routeDescription: String { get }
    /// Name of the loop used as the live source.
    var loopName: String { get }
    /// Use a file as the loop (copied into the app), or nil for the built-in loop.
    func setLoop(file: URL?)
}

/// Loop handling both hosts share.
final class LoopSlot {
    private(set) var current: TestLoop?
    private var retired: TestLoop?     // kept alive one swap longer, in case the render thread was mid-read

    func install(_ loop: TestLoop, into p: Processor) {
        retired = current
        current = loop
        loop.attach(to: p)
    }
    /// Load the saved user loop if there is one, else the built-in loop. Returns false if the user file failed.
    @discardableResult
    func loadDefault(fileName: String?, into p: Processor) -> Bool {
        if let name = fileName, let l = LoopLoader.load(url: LoopLoader.storeDir.appendingPathComponent(name), sampleRate: p.sr) {
            install(l, into: p); return true
        }
        install(TestLoop.synthetic(sampleRate: p.sr), into: p)
        return fileName == nil
    }
}

/// The fast-changing display data.
final class LiveState: ObservableObject {
    @Published var state = ProcessorState()
    @Published var bins: [Float] = Array(repeating: 0, count: 2048)
    @Published var binHead = 0
}

/// UI model shared by the app and the AUv3 view: polls the processor ~30×/s and forwards actions.
final class ScratcherModel: ObservableObject {
    weak var host: ScratcherHost?
    /// Meters, platter and tape: updated 30×/s, so they live in their own object. Only the Scratch screen
    /// watches it; settings screens don't redraw at 30 Hz (which made their dropdowns drop taps).
    let live = LiveState()
    var state: ProcessorState { live.state }
    @Published var calMessage = "Not calibrated: using nominal 1×"
    @Published var calOK: Bool? = nil
    @Published var diagnosticURL: URL? = nil
    @Published var recordingBusy = false
    @Published var notice: String? = nil
    private var timer: Timer?
    private var lastCalSerial = 0, lastRecSerial = 0
    private weak var lastProcessor: Processor?
    private var pilotSeen = 0
    private var handDown = false, handStamp = Date.distantPast

    init(host: ScratcherHost) {
        self.host = host
        lastCalSerial = host.processor.calibrationSerial
        lastRecSerial = host.processor.recordingSerial
        if host.settings.calibrated { calMessage = Self.describe(host.settings); calOK = true }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    deinit { timer?.invalidate() }

    var settings: ScratcherSettings {
        get { host?.settings ?? ScratcherSettings() }
        set { objectWillChange.send(); host?.settings = newValue }
    }
    /// SwiftUI binding to one setting.
    func binding<T>(_ kp: WritableKeyPath<ScratcherSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] }, set: { var s = self.settings; s[keyPath: kp] = $0; self.settings = s })
    }

    var sampleRate: Double { host?.processor.sr ?? 48000 }

    private func tick() {
        guard let host else { return }
        let p = host.processor
        if p !== lastProcessor {   // the host rebuilt its processor (new sample rate)
            lastProcessor = p; lastCalSerial = p.calibrationSerial; lastRecSerial = p.recordingSerial
            recordingBusy = false
        }
        // a finger resting on the platter without moving holds it still
        if handDown && Date().timeIntervalSince(handStamp) > 0.06 { p.simHandV = 0 }
        live.state = p.state
        p.resetPeaks()
        // tape overview
        var b = live.bins
        let n = min(b.count, p.binCount)
        for i in 0..<n { b[i] = p.bins[i] }
        live.bins = b; live.binHead = p.binHead
        // calibration finished?
        if p.calibrationSerial != lastCalSerial, let c = p.calibration {
            lastCalSerial = p.calibrationSerial
            finishCalibration(c)
        }
        // diagnostic finished?
        if p.recordingSerial != lastRecSerial, let r = p.recording {
            lastRecSerial = p.recordingSerial
            diagnosticURL = WavWriter.writeFloat(interleaved: r, frames: p.recordingFrames, channels: 4,
                                                 sampleRate: p.sr, name: "scratcher-diagnostic")
            recordingBusy = false
        }
        autoPilot()
    }

    /// The WOW is in pilot mode if an 18 kHz pilot is present: an unfiltered pilot scrambles the speed reading.
    private func autoPilot() {
        guard settings.wowRead == .level, !settings.virtualPlatter else { pilotSeen = 0; return }
        if state.active && state.pilotAmp > 0.004 && state.pilotAmp > 0.15 * state.env { pilotSeen += 1 } else { pilotSeen = 0 }
        if pilotSeen > 20 {
            settings.wowRead = .pilot; pilotSeen = 0
            calMessage = "Pilot tone detected: switched the fader reading to Pilot tone. Calibrate again."
            calOK = nil
        }
    }

    // MARK: actions
    func jumpToLive() { host?.processor.jumpRequests += 1 }
    func toggleFreeze() { guard let p = host?.processor else { return }; p.freezeTarget.toggle() }
    /// Live: back to now after a scratch. Record: a normal record, the needle stays where you leave it. Loop: hold what's recorded.
    enum PlayMode { case live, record, loop }
    func setPlayMode(_ m: PlayMode) {
        guard let p = host?.processor else { return }
        switch m {
        case .loop: p.freezeTarget = true
        case .live, .record:
            var s = settings; s.returnMode = m == .live ? .snap : .stay; settings = s
            p.freezeTarget = false
        }
    }
    func setCut(_ on: Bool) { host?.processor.softCut = on }
    /// Tap pad: finger down or up.
    func setPad(down: Bool) {
        guard let p = host?.processor else { return }
        p.padOpen = settings.padCuts ? !down : down
    }
    /// Pad state with no finger on it (called when the pad mode changes).
    func resetPad() { setPad(down: false) }
    func setHand(down: Bool, velocity: Double) {
        guard let p = host?.processor else { return }
        handDown = down; handStamp = Date()
        p.simHandV = down ? max(-12, min(12, velocity)) : 0; p.simHand = down
    }
    func setSimMotor(_ on: Bool) { host?.processor.simMotor = on }
    func setSimFader(_ v: Double) { host?.processor.simFader = v }

    func calibrate() {
        guard let host else { return }
        var s = settings; s.calib = 1; s.flip = false; s.calibrated = false; settings = s   // measure from nominal, ungated
        calMessage = "Listening for 1.5 s… motor on, hands off"; calOK = nil
        host.processor.calibrateRequests += 1
    }
    private func finishCalibration(_ c: CalibrationResult) {
        if c.activeFrac < 0.9 || c.speed <= 0 {
            calMessage = settings.controlSignal == .timecode
                ? "No steady timecode: check both timecode inputs and that the record or file is playing at normal speed."
                : "No steady control tone: check the input channel, the tone is playing, and the WOW meter is moving."
            calOK = false; return
        }
        if c.spread > 0.12 {
            calMessage = String(format: "Speed unsteady (±%.0f%%): hands off the platter and try again.", c.spread * 50); calOK = false; return
        }
        var s = settings
        if s.controlSignal == .timecode {
            // speed was measured against the carrier we assumed: the true carrier is that much faster or slower
            guard c.speed > 0.3 && c.speed < 4 else {
                calMessage = "That doesn't look like timecode at 1 to 2 kHz: check both timecode inputs and that the record or file is playing."; calOK = false; return
            }
            s.carrierHz *= c.speed
            s.balance = min(4, max(0.25, c.balance))
        } else {
            s.calib = c.speed
        }
        s.refLevel = c.env
        if c.dir < 0 { s.flip = true }
        if s.wowRead == .pilot && s.controlSignal != .timecode {   // only a WOW carries the pilot
            guard c.pilotHz > 12000, c.pilotHz < 23000, c.pilotAmp > 0.003 else {
                calMessage = "Control tone OK, but no pilot above 12 kHz: is the pilot beat playing and the WOW fader open?"; calOK = false; return
            }
            s.pilotHz = c.pilotHz; s.pilotRef = c.pilotAmp
        }
        s.calibrated = true
        settings = s
        calMessage = Self.describe(s); calOK = true
    }
    static func describe(_ s: ScratcherSettings) -> String {
        var t = s.controlSignal == .timecode
            ? String(format: "Timecode carrier %.1f Hz · level %.1f dBFS", s.carrierHz, 20 * log10(max(1e-6, s.refLevel)))
            : String(format: "1× = %.4f of nominal · level %.1f dBFS", s.calib, 20 * log10(max(1e-6, s.refLevel)))
        if s.flip { t += " · flipped" }
        if s.wowRead == .pilot && s.controlSignal != .timecode { t += String(format: " · pilot %.2f kHz", s.pilotHz / 1000) }
        return t
    }

    func recordDiagnostic(seconds: Double = 10) {
        guard let p = host?.processor, !recordingBusy else { return }
        diagnosticURL = nil; recordingBusy = true
        p.requestRecording(seconds: seconds)
    }
}
