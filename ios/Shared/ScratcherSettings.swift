import Foundation

/// Everything the user can set. Codable so the app keeps it in UserDefaults and the AUv3 in its preset state.
enum FaderStyle: String, Codable, CaseIterable { case pad, slider }

struct ScratcherSettings: Codable, Equatable {
    // feel
    var smoothMs = 2.0
    var returnMode: ReturnMode = .snap
    var snapDelayMs = 180.0
    var lock = true
    var loopSec = 4.0            // Loop length; at the tape length it means the whole tape
    var tapeSec = 45.0           // how much live audio is kept to scratch: 45, 120 or 300 s (plugin: up to 120)
    var loopStop = false         // Loop ends: stop like a run-out groove (false: wrap round)
    var tapeZoom = true          // tape strip: a 10 s window following the needle (false: the whole tape)
    var outGain = 1.0
    // fader
    var faderMode: FaderMode = .both
    var wowRead: WowRead = .pilot
    var faderLo = 0.08, faderHi = 0.45
    var gateDb = -56.0
    var vfX = 0.0, vfCut = 0.05, vfWidth = 0.02
    var hamster = false
    var faderStyle: FaderStyle = .pad
    var padCuts = true           // pad: touching it cuts the sound (false: touching it opens the sound)
    // control signal
    var controlSignal: ControlSignal = .wowTone
    var carrierHz = 1000.0       // stereo timecode carrier (set exactly by calibration)
    var balance = 1.0            // stereo timecode: right-channel gain from calibration
    // calibration
    var flip = false
    var tcSerato = true          // saved after timecode switched to Serato's phase (see decodeLenient)
    var calibrated = false
    var calib = 1.0
    var refLevel = 0.3
    var pilotHz = 18000.0
    var pilotRef = 0.3
    // sources (app)
    var virtualPlatter = false
    var testLoop = true          // play the loop (built-in "ahhh / fresh", or the user's file) as the live source
    var loopFile: String? = nil  // user's loop, stored inside the app (nil = built-in)
    var ctrlChannel = 0          // input channel index carrying the WOW, or timecode left (plugin: 0 = left, 1 = right)
    var ctrlChannelR = 1         // stereo timecode right channel (app)
    var liveLeft = 1, liveRight = 1
    var outPair = 0              // 0 = outputs 1–2, 1 = 3–4, …

    /// Change what the control input carries; the old calibration no longer applies.
    mutating func setControl(_ c: ControlSignal) {
        guard c != controlSignal else { return }
        controlSignal = c; calibrated = false; flip = false; calib = 1; balance = 1
        if c == .timecode && ctrlChannelR == ctrlChannel { ctrlChannelR = ctrlChannel + 1 }
    }

    func apply(to p: Processor) {
        p.eng.smoothMs = smoothMs
        p.eng.mode = returnMode
        p.eng.snapDelay = Int(snapDelayMs * 0.001 * p.sr)
        p.eng.lockEnabled = lock
        p.tapeTarget = min(tapeSec, p.maxTape)
        p.eng.setLoopSeconds(min(loopSec, tapeSec))
        p.eng.loopWhole = loopSec >= min(tapeSec, p.maxTape) - 0.01
        p.eng.loopStop = loopStop
        p.eng.outGain = outGain
        p.faderMode = faderMode
        p.wowRead = wowRead
        p.faderLo = faderLo; p.faderHi = faderHi
        p.userGate = pow(10, gateDb / 20)
        p.toneRef = calibrated ? refLevel : 0
        p.vfX = vfX; p.vfCut = vfCut; p.vfWidth = vfWidth; p.vfHamster = hamster
        p.padStyle = faderStyle == .pad
        if faderStyle == .pad { p.padOpen = padCuts }   // resting state: open if the pad cuts, shut if it opens
        p.control = controlSignal
        p.dec.flip = flip
        p.dec.calib = calib
        p.quad.flip = flip
        p.quad.carrierHz = carrierHz
        p.quad.balance = balance
        p.refLevel = refLevel
        if abs(p.pilot.freq - pilotHz) > 0.5 { p.setPilotFreq(pilotHz) }
        p.pilotRef = pilotRef
        p.simOn = virtualPlatter
        p.useTestLoop = testLoop
    }
}

extension ScratcherSettings {
    /// Decode saved settings on top of the defaults, so settings saved by an older build (missing keys) still load.
    static func decodeLenient(_ data: Data) -> ScratcherSettings? {
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(ScratcherSettings()),
              var base = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return nil }
        base.merge(saved) { _, new in new }
        if saved["tcSerato"] == nil, (saved["controlSignal"] as? String) == "timecode" {   // timecode now follows Serato's phase:
            base["flip"] = false; base["calibrated"] = false                                    // a direction saved before that no longer applies
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        return try? JSONDecoder().decode(ScratcherSettings.self, from: merged)
    }
    static func load(key: String) -> ScratcherSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = decodeLenient(d) else { return ScratcherSettings() }
        return s
    }
    func save(key: String) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: key) }
    }
}
