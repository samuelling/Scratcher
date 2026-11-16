import Foundation

/// Everything the user can set. Codable so the app keeps it in UserDefaults and the AUv3 in its preset state.
struct ScratcherSettings: Codable, Equatable {
    // feel
    var smoothMs = 2.0
    var returnMode: ReturnMode = .snap
    var snapDelayMs = 180.0
    var lock = true
    var loopSec = 4.0
    var outGain = 1.0
    // fader
    var faderMode: FaderMode = .both
    var wowRead: WowRead = .pilot
    var faderLo = 0.08, faderHi = 0.45
    var gateDb = -56.0
    var vfX = 0.0, vfCut = 0.05, vfWidth = 0.02
    var hamster = false
    // calibration
    var flip = false
    var calibrated = false
    var calib = 1.0
    var refLevel = 0.3
    var pilotHz = 18000.0
    var pilotRef = 0.3
    // sources (app)
    var virtualPlatter = false
    var testLoop = true          // play the loop (built-in "ahhh / fresh", or the user's file) as the live source
    var loopFile: String? = nil  // user's loop, stored inside the app (nil = built-in)
    var ctrlChannel = 0          // input channel index carrying the WOW (plugin: 0 = left, 1 = right)
    var liveLeft = 1, liveRight = 1
    var outPair = 0              // 0 = outputs 1–2, 1 = 3–4, …

    func apply(to p: Processor) {
        p.eng.smoothMs = smoothMs
        p.eng.mode = returnMode
        p.eng.snapDelay = Int(snapDelayMs * 0.001 * p.sr)
        p.eng.lockEnabled = lock
        p.eng.setLoopSeconds(loopSec)
        p.eng.outGain = outGain
        p.faderMode = faderMode
        p.wowRead = wowRead
        p.faderLo = faderLo; p.faderHi = faderHi
        p.userGate = pow(10, gateDb / 20)
        p.toneRef = calibrated ? refLevel : 0
        p.vfX = vfX; p.vfCut = vfCut; p.vfWidth = vfWidth; p.vfHamster = hamster
        p.dec.flip = flip
        p.dec.calib = calib
        p.refLevel = refLevel
        if abs(p.pilot.freq - pilotHz) > 0.5 { p.pilot.setFreq(pilotHz) }
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
