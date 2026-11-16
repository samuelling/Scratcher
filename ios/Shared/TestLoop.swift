import Foundation

/// The default live source when nothing is plugged in: a stereo loop played round and round.
/// Either the user's own file (see LoopLoader) or a 4 s, 120 bpm loop synthesised at launch: kick / snare / hats,
/// a bass line, and formant-voice "ahhh" and "fresh" stabs, synthesised from scratch (no samples).
final class TestLoop {
    let frames: Int
    let data: UnsafeMutablePointer<Float>   // interleaved L/R
    let name: String

    init(frames: Int, data: UnsafeMutablePointer<Float>, name: String) { self.frames = frames; self.data = data; self.name = name }

    static func synthetic(sampleRate sr: Double) -> TestLoop {
        let frames = Int(4 * sr)
        let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2); data.initialize(repeating: 0, count: frames * 2)
        let beat = sr / 2   // 120 bpm
        var seed: UInt32 = 99
        func noise() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed) / 2147483648 - 1 }
        func add(_ i: Int, _ l: Double, _ r: Double) { if i >= 0 && i < frames { data[2 * i] += Float(l); data[2 * i + 1] += Float(r) } }
        for b in 0..<8 {
            let s0 = Int(Double(b) * beat)
            if b % 2 == 0 || b == 7 {   // kick
                var ph = 0.0
                for k in 0..<Int(0.35 * sr) { let t = Double(k) / sr
                    ph += 2 * .pi * (48 + 110 * exp(-t * 30)) / sr
                    let v = 0.6 * sin(ph) * exp(-t * 7); add(s0 + k, v, v) }
            }
            if b % 2 == 1 {             // snare
                for k in 0..<Int(0.25 * sr) { let t = Double(k) / sr
                    let v = (0.35 * noise() + 0.25 * sin(2 * .pi * 190 * t)) * exp(-t * 18); add(s0 + k, v * 0.9, v) }
            }
            for h in 0..<2 {            // hats
                let hs = s0 + Int(Double(h) * beat / 2)
                for k in 0..<Int(0.05 * sr) { let t = Double(k) / sr
                    let v = 0.12 * noise() * exp(-t * 90); add(hs + k, v * (h == 0 ? 1 : 0.6), v * (h == 0 ? 0.6 : 1)) }
            }
            let notes = [55.0, 55, 65.4, 49, 55, 55, 73.4, 65.4]   // bass
            var ph = 0.0
            for k in 0..<Int(beat * 0.9) { let t = Double(k) / sr
                ph += 2 * .pi * notes[b] / sr
                let v = 0.22 * tanh(2.5 * sin(ph)) * exp(-t * 2.5); add(s0 + k, v, v) }
        }
        // a voiced source (sawtooth at f0 with vibrato) through two resonators: the formants make the vowel
        func voice(at s0: Int, dur: Double, f0: Double, gain: Double, formants: (Double) -> (Double, Double), env: (Double) -> Double) {
            var ph = 0.0, b1 = 0.0, b2 = 0.0, c1 = 0.0, c2 = 0.0
            var buf = [Double](repeating: 0, count: Int(dur * sr))
            let r = 0.993
            for k in 0..<Int(dur * sr) { let t = Double(k) / sr
                ph += 2 * .pi * f0 * (1 + 0.03 * sin(2 * .pi * 5.5 * t)) / sr
                let src = ph.truncatingRemainder(dividingBy: 2 * .pi) / .pi - 1
                let (f1, f2) = formants(t)
                let w1 = 2 * Double.pi * f1 / sr, w2 = 2 * Double.pi * f2 / sr
                let y1 = src + 2 * r * cos(w1) * b1 - r * r * b2; b2 = b1; b1 = y1
                let y2 = src + 2 * r * cos(w2) * c1 - r * r * c2; c2 = c1; c1 = y2
                buf[k] = (y1 + 0.6 * y2) * env(t) }
            let pk = buf.reduce(0) { max($0, abs($1)) }
            for k in 0..<buf.count { let v = buf[k] * gain / max(pk, 1e-9); add(s0 + k, v, v) }   // gain = peak level
        }
        /// band of noise around fc (fricatives: "f" ≈ 6 kHz wide, "sh" ≈ 2.8 kHz)
        func hiss(at s0: Int, dur: Double, fc: Double, gain: Double, env: (Double) -> Double) {
            var b1 = 0.0, b2 = 0.0
            var buf = [Double](repeating: 0, count: Int(dur * sr))
            let r = 0.9, w = 2 * Double.pi * min(fc, 0.45 * sr) / sr
            for k in 0..<Int(dur * sr) { let t = Double(k) / sr
                let y = noise() + 2 * r * cos(w) * b1 - r * r * b2; b2 = b1; b1 = y
                buf[k] = y * env(t) }
            let pk = buf.reduce(0) { max($0, abs($1)) }
            for k in 0..<buf.count { let v = buf[k] * gain / max(pk, 1e-9); add(s0 + k, v * 0.95, v) }
        }
        // "ahhh" on beats 1 and 5
        for b in [0.0, 4.0] {
            voice(at: Int(b * beat), dur: 0.7, f0: 210, gain: 0.55, formants: { _ in (780, 1180) },
                  env: { t in min(1, t * 40) * exp(-t * 2.6) })
        }
        // "fresh" on beats 3 and 7: f → r → e → sh
        for b in [2.0, 6.0] {
            let s0 = Int(b * beat)
            hiss(at: s0, dur: 0.07, fc: 6000, gain: 0.12, env: { t in sin(.pi * t / 0.07) })
            voice(at: s0 + Int(0.05 * sr), dur: 0.2, f0: 190, gain: 0.5,
                  formants: { t in let u = min(1, t / 0.07); return (380 + 170 * u, 1250 + 650 * u) },   // "r" glides into "e"
                  env: { t in min(1, t * 60) * (t < 0.15 ? 1 : max(0, 1 - (t - 0.15) / 0.05)) })
            hiss(at: s0 + Int(0.22 * sr), dur: 0.32, fc: 2800, gain: 0.3,
                 env: { t in min(1, t * 30) * exp(-t * 6) })
        }
        var pk: Float = 0
        for i in 0..<(frames * 2) { pk = max(pk, abs(data[i])) }
        if pk > 0.9 { let g = 0.9 / pk; for i in 0..<(frames * 2) { data[i] *= g } }
        return TestLoop(frames: frames, data: data, name: "Built-in “ahhh / fresh” loop")
    }
    deinit { data.deallocate() }

    func attach(to p: Processor) {
        p.testLoopFrames = 0      // render ignores the loop while it is being swapped
        p.testLoop = data
        p.testLoopFrames = frames
    }
}
