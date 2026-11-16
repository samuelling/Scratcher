// Scratcher processor: the Swift equivalent of src/worklet.js.
// Platform-independent: the iOS audio I/O hands it channel pointers once per render block.
// UI ↔ audio thread: plain stored properties (word-sized writes) and request counters, no locks.

import Foundation

public enum FaderMode: String, CaseIterable, Codable { case both, wow, virtual, open }
public enum WowRead: String, CaseIterable, Codable { case pilot, level }

/// What the UI polls each frame.
public struct ProcessorState {
    public var v = 0.0, rate = 0.0, lag = 0.0
    public var locked = false, frozen = false, active = false
    public var env = 0.0, dir = 1, stat = 0.0, pos = 0.0, gain = 0.0
    public var ctrlPk = 0.0, livePk = 0.0, outPk = 0.0
    public var simV = 0.0, loopLen = 0, pilotAmp = 0.0
}

public struct CalibrationResult {
    public var speed: Double, spread: Double, dir: Double, env: Double, activeFrac: Double
    public var pilotHz: Double, pilotAmp: Double
}

public final class Processor {
    public let sr: Double
    public let dec: ToneDecoder
    public let pilot: PilotReader
    public let eng: ScratchEngine

    // ---- parameters (written by the UI thread) ----
    public var wowRead: WowRead = .pilot
    public var pilotRef = 0.3
    public var faderMode: FaderMode = .both
    public var userGate = 0.0015 { didSet { applyGate() } }
    public var toneRef = 0.0 { didSet { applyGate() } }     // gate = max(user gate, 10 % of calibrated tone level)
    public var refLevel = 0.3
    public var faderLo = 0.08, faderHi = 0.45
    public var softCut = false
    public var vfX = 0.0, vfCut = 0.05, vfWidth = 0.02, vfHamster = false
    // virtual platter
    public var simOn = false, simMotor = true, simHand = false, simHandV = 0.0, simFader = 1.0
    var simTheta = 0.0, simPh = 0.0, simFg = 0.0, seed: UInt32 = 1
    public private(set) var simV = 0.0
    // built-in test loop as the live source (set from the UI thread before enabling)
    public var testLoop: UnsafeMutablePointer<Float>? = nil
    public var testLoopFrames = 0
    public var useTestLoop = false
    var testPos = 0

    // ---- requests (UI increments, audio thread handles) ----
    public var jumpRequests = 0; var jumpHandled = 0
    public var freezeTarget = false; var freezeApplied = false
    public var calibrateRequests = 0; var calibrateHandled = 0
    public var recordRequests = 0; var recordHandled = 0

    // ---- results ----
    public private(set) var state = ProcessorState()
    public private(set) var calibration: CalibrationResult? = nil
    public private(set) var calibrationSerial = 0
    /// Diagnostic capture: 4 interleaved channels (raw WOW in, live in, output, fader gain).
    public private(set) var recording: UnsafeMutablePointer<Float>? = nil
    public private(set) var recordingFrames = 0
    public private(set) var recordingSerial = 0
    var recBuf: UnsafeMutablePointer<Float>? = nil
    var recN = 0, recTotal = 0, recCap = 0
    var retiredRec: UnsafeMutablePointer<Float>? = nil

    // calibration accumulators (preallocated)
    let calN: Int
    let calSpeeds: UnsafeMutablePointer<Double>
    var calOn = false, calI = 0, calCount = 0, calActive = 0, calDir = 0.0, calDirN = 0, calEnv = 0.0, calEnvN = 0

    // tape overview: one peak per 256 input samples, ring of 2048
    public let binCount = 2048
    public let bins: UnsafeMutablePointer<Float>
    public private(set) var binHead = 0
    var binAcc: Float = 0, binN = 0
    var ctrlPk = 0.0, livePk = 0.0, outPk = 0.0

    public init(sr: Double) {
        self.sr = sr
        dec = ToneDecoder(sr: sr)
        pilot = PilotReader(sr: sr)
        eng = ScratchEngine(sr: sr)
        calN = Int((1.5 * sr).rounded())
        calSpeeds = .allocate(capacity: calN / 32 + 8)
        bins = .allocate(capacity: binCount); bins.initialize(repeating: 0, count: binCount)
    }
    deinit { calSpeeds.deallocate(); bins.deallocate(); recBuf?.deallocate(); retiredRec?.deallocate() }

    func applyGate() { dec.gate = max(userGate, 0.1 * toneRef) }

    /// UI thread: allocate a capture buffer, then ask the audio thread to fill it.
    /// (The buffer is reused, never freed while running: the audio thread may be writing into it.)
    public func requestRecording(seconds: Double) {
        let frames = Int(seconds * sr)
        if frames > recCap {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: frames * 4); b.initialize(repeating: 0, count: frames * 4)
            retiredRec = recBuf              // an older, smaller buffer stays allocated until the processor goes away
            recBuf = b; recCap = frames
        }
        recTotal = frames
        recordRequests += 1
    }

    @inline(__always) func rnd() -> Double {
        seed = seed &* 1664525 &+ 1013904223
        return Double(seed) / 4294967296 - 0.5
    }

    /// Render one block. `ctrl` may be nil (no WOW input), `liveR` may equal `liveL` (mono).
    public func render(frames: Int,
                       ctrl: UnsafePointer<Float>?,
                       liveL: UnsafePointer<Float>?, liveR: UnsafePointer<Float>?,
                       outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>) {
        // handle requests
        if jumpHandled != jumpRequests { jumpHandled = jumpRequests; eng.jumpToLive() }
        if freezeApplied != freezeTarget { freezeApplied = freezeTarget; eng.setFrozen(freezeTarget) }
        if calibrateHandled != calibrateRequests {
            calibrateHandled = calibrateRequests
            pilot.resetMeasure(); calOn = true; calI = 0; calCount = 0; calActive = 0
            calDir = 0; calDirN = 0; calEnv = 0; calEnvN = 0
        }
        if recordHandled != recordRequests, let b = recBuf { recordHandled = recordRequests; recording = nil; recN = 0; _ = b }

        let handK = 1 - exp(-1 / (0.002 * sr)), motorK = 1 - exp(-1 / (0.09 * sr))
        let vx = vfHamster ? 1 - vfX : vfX
        let vfGain = 1 - faderCurve(vx, vfCut, vfCut + max(0.005, vfWidth))
        let usePilot = wowRead == .pilot
        dec.gainFilter = usePilot ? pilot : nil
        let span = 2 * Double.pi * Tone.amCycles

        for i in 0..<frames {
            var c = Double(ctrl?[i] ?? 0)
            if simOn {
                let target = simHand ? simHandV : (simMotor ? 1 : 0)
                simV += (target - simV) * (simHand ? handK : motorK)
                simTheta += 2 * .pi * Tone.f0 * simV / sr
                if simTheta > 1e6 { simTheta -= span * (simTheta / span).rounded(.down) }
                if usePilot {
                    simPh += 2 * .pi * pilotHz / sr; if simPh > 2 * .pi { simPh -= 2 * .pi }
                    simFg += (simFader - simFg) * 0.03
                    c = 0.35 * Tone.sample(simTheta) + 0.35 * simFg * sin(simPh) + rnd() * 2e-4
                } else {
                    c = 0.445 * simFader * Tone.sample(simTheta) + rnd() * 2e-4
                }
            }
            let pc = pilot.process(c)               // always runs: measures the pilot even in tone-level mode
            let r = dec.process(usePilot ? pc : c)

            var g = 1.0
            if faderMode == .wow || faderMode == .both {
                let lvl = usePilot ? pilot.amp / max(1e-4, pilotRef) : dec.env / max(1e-4, refLevel)
                g = faderCurve(lvl, faderLo, faderHi)
            }
            if faderMode == .virtual || faderMode == .both { g *= vfGain }
            if softCut { g = 0 }

            var lL: Float = 0, lR: Float = 0
            if useTestLoop, let t = testLoop, testLoopFrames > 0 {
                if testPos >= testLoopFrames { testPos = 0 }   // the loop may have been swapped for a shorter one
                lL = t[2 * testPos]; lR = t[2 * testPos + 1]
                testPos += 1; if testPos >= testLoopFrames { testPos = 0 }
            } else {
                lL = liveL?[i] ?? 0; lR = liveR?[i] ?? lL
            }
            let (oL, oR) = eng.step(lL, lR, r, g)
            outL[i] = Float(oL); outR[i] = Float(oR)

            if let b = recBuf, recording == nil, recordHandled == recordRequests, recN < recTotal {
                let k = recN * 4
                b[k] = Float(c); b[k + 1] = lL; b[k + 2] = Float(oL); b[k + 3] = Float(g)
                recN += 1
                if recN >= recTotal { recording = b; recordingFrames = recTotal; recordingSerial += 1 }
            }

            let ac = abs(c); if ac > ctrlPk { ctrlPk = ac }
            let al = Double(max(abs(lL), abs(lR))); if al > livePk { livePk = al }
            let ao = abs(oL); if ao > outPk { outPk = ao }
            if !eng.frozen {
                if Float(al) > binAcc { binAcc = Float(al) }
                binN += 1
                if binN >= 256 { bins[binHead] = binAcc; binHead = (binHead + 1) % binCount; binAcc = 0; binN = 0 }
            }

            if calOn {
                calI += 1
                if dec.active { calActive += 1 }
                if calI & 31 == 0 && dec.active {
                    if dec.rawSpeed > 0 { calSpeeds[calCount] = dec.rawSpeed; calCount += 1 }
                    calDir += Double(dec.dir); calDirN += 1; calEnv += dec.env; calEnvN += 1
                }
                if calI >= calN { finishCalibration() }
            }
        }

        state = ProcessorState(v: eng.vs, rate: eng.rate, lag: eng.lag, locked: eng.locked, frozen: eng.frozen,
                               active: dec.active, env: dec.env, dir: dec.dir, stat: dec.lastStat, pos: dec.posInt,
                               gain: eng.gain, ctrlPk: ctrlPk, livePk: livePk, outPk: outPk,
                               simV: simV, loopLen: eng.loopLen, pilotAmp: pilot.amp)
    }

    /// The UI calls this after reading `state` to reset the peak meters.
    public func resetPeaks() { ctrlPk = 0; livePk = 0; outPk = 0 }

    func finishCalibration() {
        calOn = false
        // in-place insertion sort of the collected speeds (runs once, ~2k values)
        let n = calCount
        if n > 1 { for i in 1..<n { let x = calSpeeds[i]; var j = i
            while j > 0 && calSpeeds[j - 1] > x { calSpeeds[j] = calSpeeds[j - 1]; j -= 1 }; calSpeeds[j] = x } }
        let med = n > 0 ? calSpeeds[n / 2] : 0
        let lo = n > 0 ? calSpeeds[Int(Double(n) * 0.1)] : 0, hi = n > 0 ? calSpeeds[Int(Double(n) * 0.9)] : 0
        let m = pilot.measured()
        calibration = CalibrationResult(speed: med, spread: med > 0 ? (hi - lo) / med : 1,
                                        dir: calDirN > 0 ? calDir / Double(calDirN) : 0,
                                        env: calEnvN > 0 ? calEnv / Double(calEnvN) : 0,
                                        activeFrac: Double(calActive) / Double(max(1, calI)),
                                        pilotHz: m.hz, pilotAmp: m.amp)
        calibrationSerial += 1
    }
}
