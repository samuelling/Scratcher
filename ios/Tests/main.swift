// Linux/macOS command-line tests for the Swift DSP port (mirrors test/test_wow.js, test_pilot.js, test_engine.js).
// Build: swiftc -O ios/Core/*.swift ios/Tests/main.swift -o /tmp/scratcher-tests && /tmp/scratcher-tests

import Foundation

let SR = 48000.0, FSR = 44100.0, L = Int(FSR * 10)
var tab = [Double](repeating: 0, count: L)
for i in 0..<L { tab[i] = 0.89 * Tone.sample(2 * .pi * Tone.f0 * Double(i) / FSR) }
func rd(_ p: Double) -> Double {
    var q = p.truncatingRemainder(dividingBy: Double(L)); if q < 0 { q += Double(L) }
    let i = Int(q), f = q - Double(i); return tab[i] + (tab[(i + 1) % L] - tab[i]) * f
}
var seed: UInt32 = 7
func noise() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed) / 4294967296 - 0.5 }

func runWow(_ vf: (Double) -> Double, _ dur: Double, _ mode: String) -> (Double, Double) {
    let d = ToneDecoder(sr: SR); var P = Double(L) / 2, ph = 0.0, truth = 0.0, p0 = 0.0, t0 = 0.0, maxE = 0.0, bad = 0, n1 = 0
    let warm = Int(0.3 * SR), N = Int(dur * SR) + warm
    for n in 0..<N {
        let v = n < warm ? 1 : vf(Double(n - warm) / SR)
        P += v * FSR / SR
        let x: Double
        if mode == "true" { x = rd(P) } else {
            ph += 2 * .pi * Tone.f0 * abs(v) / SR
            x = 0.89 * exp(Tone.logAmp(2 * .pi * Tone.f0 * P / FSR)) * sin(ph)
        }
        _ = d.process(0.4 * x + noise() * 2e-4); truth += v
        if n == warm { p0 = d.posInt; t0 = truth }
        if n > warm {
            maxE = max(maxE, abs((d.posInt - p0) - (truth - t0)))
            if abs(v) > 0.3 { n1 += 1; if d.dir != (v > 0 ? 1 : -1) { bad += 1 } }
        }
    }
    return (maxE / SR * 1000, 100 * Double(bad) / Double(max(1, n1)))
}

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("  ✗ FAIL:", what) } }

print("== decoder: true reverse vs WOW-style reverse (max position error ms, % wrong direction)")
let gestures: [(String, (Double) -> Double, Double, Double)] = [   // name, v(t), duration, max allowed error (ms)
    ("steady 1x", { _ in 1 }, 2, 2),
    ("stop & hold", { t in t < 0.5 ? 1 : t < 1.5 ? 0 : 1 }, 2.5, 6),
    ("baby ±1.5 @4Hz", { t in 1.5 * sin(2 * .pi * 4 * t) }, 3, 40),
    ("slow drag ±0.3", { t in 0.3 * (sin(2 * .pi * 0.7 * t) >= 0 ? 1 : -1) }, 3, 40),
    ("fast ±3 @8Hz", { t in 3 * sin(2 * .pi * 8 * t) }, 3, 40),
    ("scribble ±2 @15Hz", { t in 2 * sin(2 * .pi * 15 * t) }, 2, 45),
    ("rewind -2.5x", { t in t < 0.3 ? 1 : t < 1.8 ? -2.5 : 1 }, 2.5, 30),
    ("spinback -6x", { t in t < 0.3 ? 1 : t < 0.8 ? -6 : 1 }, 1.5, 60),
]
for (name, f, dur, lim) in gestures {
    let a = runWow(f, dur, "true"), b = runWow(f, dur, "wow")
    print(String(format: "  %-20@ %6.1fms %5.1f%%    %6.1fms %5.1f%%", name as NSString, a.0, a.1, b.0, b.1))
    check(a.0 < lim && b.0 < lim, "\(name) position error under \(lim) ms")
}

print("== pilot fader (control + 18 kHz pilot cut at 10 Hz with 1 ms ramps)")
do {
    let cuts: (Double) -> Double = { t in let u = (t * 20).truncatingRemainder(dividingBy: 2), r = 0.02
        return u < 1 ? (u < r ? u / r : 1) : (u - 1 < r ? 1 - (u - 1) / r : 0) }
    for (name, vf) in [("baby", { (t: Double) in 1.5 * sin(2 * .pi * 4 * t) }), ("fast ±3", { (t: Double) in 3 * sin(2 * .pi * 8 * t) })] {
        let d = ToneDecoder(sr: SR), pr = PilotReader(sr: SR); d.gainFilter = pr
        var th = 0.0, ph = 0.0, truth = 0.0, p0 = 0.0, t0 = 0.0, maxE = 0.0, gErr = 0.0, gN = 0.0
        let warm = Int(0.3 * SR)
        for n in 0..<(Int(3 * SR) + warm) {
            let t = Double(n - warm) / SR, v = n < warm ? 1 : vf(t), f = n < warm ? 1 : cuts(t)
            th += 2 * .pi * Tone.f0 * v / SR; ph += 2 * .pi * 18000 / SR
            _ = d.process(pr.process(0.35 * Tone.sample(th) + 0.35 * f * sin(ph) + noise() * 2e-4)); truth += v
            if n == warm { p0 = d.posInt; t0 = truth }
            if n > warm { maxE = max(maxE, abs((d.posInt - p0) - (truth - t0))); gErr += abs(faderCurve(pr.amp / 0.35, 0.08, 0.45) - f); gN += 1 }
        }
        print(String(format: "  %-10@ position err %5.1f ms, fader mean abs err %.3f", name as NSString, maxE / SR * 1000, gErr / gN))
        check(maxE / SR * 1000 < 40 && gErr / gN < 0.03, "pilot \(name)")
    }
}

print("== processor: virtual platter, calibration, snap-to-live, diagnostic capture")
do {
    let p = Processor(sr: SR)
    p.simOn = true; p.wowRead = .pilot
    let blk = 128
    let outL = UnsafeMutablePointer<Float>.allocate(capacity: blk), outR = UnsafeMutablePointer<Float>.allocate(capacity: blk)
    let live = UnsafeMutablePointer<Float>.allocate(capacity: blk)
    var t = 0.0
    func run(_ seconds: Double) {
        for _ in 0..<Int(seconds * SR / Double(blk)) {
            for i in 0..<blk { live[i] = Float(0.5 * sin(2 * .pi * 220 * t)); t += 1 / SR }
            p.render(frames: blk, ctrl: nil, liveL: live, liveR: live, outL: outL, outR: outR)
        }
    }
    run(1.0)
    p.calibrateRequests += 1; run(1.8)
    if let c = p.calibration {
        print(String(format: "  calibration: speed %.4f spread %.3f dir %.2f pilot %.0f Hz", c.speed, c.spread, c.dir, c.pilotHz))
        check(abs(c.speed - 1) < 0.01 && c.spread < 0.06 && c.dir > 0.9 && abs(c.pilotHz - 18000) < 50, "calibration values")
    } else { check(false, "calibration finished") }
    p.simHand = true; p.simHandV = -1.0; run(0.4)
    print(String(format: "  hand pulls back: dir %d, lag %.0f ms", p.state.dir, p.state.lag / SR * 1000))
    check(p.state.dir == -1, "backward while pulled back")
    p.simHand = false; run(1.5)
    print(String(format: "  released: locked %@, lag %.1f ms", p.state.locked ? "yes" : "no", p.state.lag / SR * 1000))
    check(p.state.locked && p.state.lag / SR * 1000 < 3, "snap back to live")
    p.requestRecording(seconds: 0.5); run(0.7)
    check(p.recording != nil && p.recordingFrames == Int(0.5 * SR), "diagnostic capture")
    var finite = true; for i in 0..<blk where !outL[i].isFinite { finite = false }
    check(finite, "finite output")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
