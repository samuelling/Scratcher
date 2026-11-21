// Scratcher DSP core: a line-for-line Swift port of src/dsp.js.
// Pure Swift + Foundation (no Apple-only frameworks) so it also builds and tests on Linux.
// Real-time safe: no allocation after init.

import Foundation

public enum Tone {
    public static let f0: Double = 1500
    /// Loudness envelope: a lopsided triangle in log-amplitude, rising over 80 % of 60 carrier cycles
    /// (32 ms of file) and falling over 20 % (8 ms). The WOW plays reverse with forward-running fine
    /// structure, so direction is read from this loudness trend, never from waveform shape.
    public static let amCycles: Double = 60
    public static let amLn: Double = log(0.35)
    public static let amRise: Double = 0.8
    public static let amSlope: Double = -amLn / (amRise * amCycles / f0)   // ln-units per second of file

    @inline(__always) public static func logAmp(_ theta: Double) -> Double {
        var u = theta / (2 * .pi * amCycles); u -= u.rounded(.down)
        return u < amRise ? amLn * (1 - u / amRise) : amLn * (u - amRise) / (1 - amRise)
    }
    @inline(__always) public static func sample(_ theta: Double) -> Double {
        exp(logAmp(theta)) * sin(theta)
    }
}

public let pilotHz: Double = 18000

@inline(__always) public func faderCurve(_ level: Double, _ lo: Double, _ hi: Double) -> Double {
    let t = max(0, min(1, (level - lo) / (hi - lo)))
    return t * t * (3 - 2 * t)
}

// MARK: - Biquad

public struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0

    mutating func notch(_ sr: Double, _ f: Double, _ q: Double) {
        let w = 2 * .pi * f / sr, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        b0 = 1 / a0; b1 = -2 * c / a0; b2 = 1 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }
    mutating func highpass(_ sr: Double, _ f: Double, _ q: Double) {
        let w = 2 * .pi * f / sr, al = sin(w) / (2 * q), c = cos(w), a0 = 1 + al
        b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = (1 + c) / 2 / a0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }
    /// Natural-log magnitude response at f Hz.
    func lnMag(_ sr: Double, _ f: Double) -> Double {
        let w = 2 * .pi * f / sr, c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 0.5 * log((nr * nr + ni * ni) / (dr * dr + di * di) + 1e-20)
    }
    @inline(__always) mutating func process(_ x: Double) -> Double {   // transposed direct form II
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// MARK: - Pilot-tone fader reader

/// The WOW's fader is set to cut the BEAT only; the beat is a steady ~18 kHz pilot whose amplitude is the
/// fader position. Two wide notches remove it before decoding; I/Q demodulation reads its level.
public final class PilotReader {
    let sr: Double
    var n1 = Biquad(), n2 = Biquad(), hp1 = Biquad(), hp2 = Biquad()
    var c = 1.0, s = 0.0, cw = 1.0, sw = 0.0
    var i1 = 0.0, q1 = 0.0, i2 = 0.0, q2 = 0.0
    let k: Double
    public private(set) var amp = 0.0
    public private(set) var freq = pilotHz
    var hpPrev = 0.0, zc = 0, hpN = 0, hpSq = 0.0

    public init(sr: Double) {
        self.sr = sr
        k = 1 - exp(-2 * .pi * 700 / sr)
        hp1.highpass(sr, 12000, 0.54); hp2.highpass(sr, 12000, 1.31)
        setFreq(pilotHz)
    }
    public func setFreq(_ f: Double) {
        freq = min(f, sr * 0.45)
        n1.notch(sr, freq, 0.8); n2.notch(sr, freq, 0.8)
        let w = 2 * .pi * freq / sr; cw = cos(w); sw = sin(w)
    }
    /// Returns the control signal with the pilot notched out; updates `amp`.
    @inline(__always) public func process(_ x: Double) -> Double {
        let nc = c * cw - s * sw, ns = s * cw + c * sw
        let g = 1.5 - 0.5 * (nc * nc + ns * ns); c = nc * g; s = ns * g
        i1 += (x * c - i1) * k; q1 += (x * s - q1) * k
        i2 += (i1 - i2) * k; q2 += (q1 - q2) * k
        amp = 2 * (i2 * i2 + q2 * q2).squareRoot()
        let h = hp2.process(hp1.process(x))
        if hpPrev <= 0 && h > 0 { zc += 1 }
        hpPrev = h; hpN += 1; hpSq += h * h
        return n2.process(n1.process(x))
    }
    public func lnGain(_ f: Double) -> Double { n1.lnMag(sr, f) + n2.lnMag(sr, f) }
    public func resetMeasure() { zc = 0; hpN = 0; hpSq = 0 }
    public func measured() -> (hz: Double, amp: Double) {
        hpN > 0 ? (Double(zc) * sr / Double(hpN), (2 * hpSq / Double(hpN)).squareRoot()) : (0, 0)
    }
}

// MARK: - Control-tone decoder

/// Speed: median zero-crossing interval. Direction: loudness trend compared with the expected rise slope.
public final class ToneDecoder {
    public let sr: Double
    public var calib = 1.0
    public var flip = false
    public var gate = 0.0015
    /// Optional known filter ahead of the decoder whose gain is subtracted from the loudness.
    public var gainFilter: PilotReader? = nil

    let hpA: Double
    var hpX = 0.0, hpY = 0.0, prev = 0.0
    public private(set) var env = 0.0
    var n = 0
    var state = 0
    var pendingZC = -1.0, lastTc = -1.0
    var halves = [Double](repeating: .infinity, count: 5)
    var sorted = [Double](repeating: 0, count: 5)
    public private(set) var halfT = Double.infinity
    public private(set) var dir = 1
    var cand = 1, candN = 0
    public private(set) var lastStat = 0.0
    public private(set) var active = false
    let ringSize = 16384
    let Q: UnsafeMutablePointer<Double>
    let Lr: UnsafeMutablePointer<Double>
    var qAcc = 0.0
    var gainCorr = 0.0
    public private(set) var posInt = 0.0
    public private(set) var v = 0.0
    public private(set) var rawSpeed = 0.0

    public init(sr: Double) {
        self.sr = sr
        hpA = exp(-2 * .pi * 8 / sr)
        Q = .allocate(capacity: ringSize); Q.initialize(repeating: 0, count: ringSize)
        Lr = .allocate(capacity: ringSize); Lr.initialize(repeating: 0, count: ringSize)
    }
    deinit { Q.deallocate(); Lr.deallocate() }

    var h1: Double { sr / (2 * Tone.f0 * calib) }

    @inline(__always) public func process(_ xin: Double) -> Double {
        let n = self.n; self.n += 1
        let M = ringSize - 1
        let y = hpA * (hpY + xin - hpX); hpX = xin; hpY = y
        let prev = self.prev; self.prev = y
        let relT = max(0.0015 * sr, 2.5 * min(halfT, 0.04 * sr))
        env = max(abs(y), env * exp(-1 / relT))
        if qAcc > 1e6 { for i in 0..<ringSize { Q[i] -= qAcc }; qAcc = 0 }
        qAcc += y * y; Q[n & M] = qAcc
        active = env > gate
        if !active {
            state = 0; lastTc = -1
            for i in 0..<5 { halves[i] = .infinity }
            halfT = .infinity; v = 0; rawSpeed = 0; Lr[n & M] = -30
            return 0
        }
        if (prev <= 0 && y > 0) || (prev >= 0 && y < 0) {
            let den = prev - y
            pendingZC = Double(n - 1) + (den != 0 ? prev / den : 0)
        }
        let thr = 0.2 * env
        var confirmed = false
        if state != 1 && y > thr { state = 1; confirmed = true }
        else if state != -1 && y < -thr { state = -1; confirmed = true }
        if confirmed && pendingZC >= 0 {
            if lastTc >= 0 {
                let half = pendingZC - lastTc
                if half > 0.25 {
                    for i in 0..<4 { halves[i] = halves[i + 1] }
                    halves[4] = half
                    // median of the finite entries (insertion sort into a preallocated scratch array)
                    var m = 0
                    for i in 0..<5 where halves[i].isFinite {
                        var j = m; let h = halves[i]
                        while j > 0 && sorted[j - 1] > h { sorted[j] = sorted[j - 1]; j -= 1 }
                        sorted[j] = h; m += 1
                    }
                    halfT = sorted[m >> 1]
                    rawSpeed = (sr / (2 * Tone.f0)) / halfT
                }
            }
            lastTc = pendingZC
        }
        var vmag = 0.0
        if lastTc >= 0 && halfT.isFinite {
            let tau = Double(n) - lastTc
            vmag = h1 / max(halfT, tau)
            if tau > 0.12 * sr { vmag = 0 }
        }
        // loudness over exactly one carrier period (ripple-free), in log units
        let W = max(8, min(4096, halfT.isFinite ? Int((2 * halfT).rounded()) : 64))
        let E = n >= W ? (qAcc - Q[(n - W) & M]) / Double(W) : y * y
        if let gf = gainFilter, n & 15 == 0 { gainCorr = vmag > 0 ? gf.lnGain(Tone.f0 * calib * vmag) : 0 }
        if gainFilter == nil { gainCorr = 0 }
        let L = 0.5 * log(E + 1e-14) - gainCorr
        Lr[n & M] = L
        // trend over D samples vs. the slope a forward rise would have at this speed
        let D = min(8192, max(2 * W, Int((0.001 * sr).rounded())))
        if n >= D + W && vmag > 0.06 {
            let diff = L - Lr[(n - D) & M]
            let expct = Tone.amSlope * vmag * Double(D) / sr
            var r = diff / expct; if flip { r = -r }
            lastStat = r
            var verdict = 0
            if r > 0.35 && r < 2.0 { verdict = 1 }          // slow rise → forward
            else if r < -0.35 && r > -2.0 { verdict = -1 }  // slow fall → backward
            else if r < -2.6 { verdict = 1 }                 // fast fall → forward
            else if r > 2.6 { verdict = -1 }                 // fast rise → backward
            if verdict != 0 {
                if verdict == cand { candN += 1 } else { cand = verdict; candN = 1 }
                if candN >= D { dir = cand }                 // outlast a window straddling a rise/fall switch
            }
        }
        v = Double(dir) * vmag
        posInt += v
        return v
    }
}

// MARK: - Scratch engine (tape + needle)

public enum ReturnMode: String, CaseIterable, Codable { case snap, stay }

public final class ScratchEngine {
    public let sr: Double
    let len: Int, mask: Int
    let Lb: UnsafeMutablePointer<Float>, Rb: UnsafeMutablePointer<Float>
    public private(set) var w = 0                 // absolute write count
    public private(set) var play = 0.0            // absolute play position
    let minLag: Double
    public private(set) var rate = 0.0
    public private(set) var vs = 0.0
    public var smoothMs = 2.0
    public var lockEnabled = true
    public private(set) var locked = false
    var steadyCount = 0
    public var mode: ReturnMode = .snap
    public var snapDelay: Int
    var xfade = 0, xfadePos = 0.0
    let xfadeLen: Int
    public private(set) var frozen = false
    var freezeW = 0
    public var loopLen: Int
    public private(set) var gain = 0.0
    public var outGain = 1.0
    var started = false
    let dcA: Double
    var dxL = 0.0, dyL = 0.0, dxR = 0.0, dyR = 0.0

    public init(sr: Double, seconds: Double = 32) {
        self.sr = sr
        var l = 1; while Double(l) < sr * seconds { l <<= 1 }
        len = l; mask = l - 1
        Lb = .allocate(capacity: l); Lb.initialize(repeating: 0, count: l)
        Rb = .allocate(capacity: l); Rb.initialize(repeating: 0, count: l)
        minLag = (0.0025 * sr).rounded()
        snapDelay = Int((0.18 * sr).rounded())
        xfadeLen = Int((0.025 * sr).rounded())
        loopLen = Int((4 * sr).rounded())
        dcA = exp(-2 * .pi * 6 / sr)
    }
    deinit { Lb.deallocate(); Rb.deallocate() }

    @inline(__always) func readCh(_ buf: UnsafeMutablePointer<Float>, _ pos: Double) -> Double {
        let fl = pos.rounded(.down), i = Int(fl), f = pos - fl, m = mask
        let y0 = Double(buf[(i - 1) & m]), y1 = Double(buf[i & m]), y2 = Double(buf[(i + 1) & m]), y3 = Double(buf[(i + 2) & m])
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * f + c2) * f + c1) * f + y1
    }

    public func jumpToLive() {
        if frozen { return }
        xfadePos = Double(w) - minLag
        xfade = 1
    }
    public func setLoopSeconds(_ s: Double) { loopLen = min(Int((s * sr).rounded()), len - 8) }
    public func setFrozen(_ on: Bool) {
        if on && !frozen { frozen = true; freezeW = w }
        else if !on && frozen { frozen = false; jumpToLive() }
    }
    public var lag: Double { Double(frozen ? freezeW : w) - play }

    /// v = decoder rate, fader = target gain (0…1). Returns (l, r).
    @inline(__always) public func step(_ inL: Float, _ inR: Float, _ v: Double, _ fader: Double) -> (Double, Double) {
        if !frozen { Lb[w & mask] = inL; Rb[w & mask] = inR; w += 1 }
        if !started { play = Double(w) - minLag; started = true }

        let k = 1 - exp(-1 / (max(0.05, smoothMs) * 0.001 * sr))
        vs += (v - vs) * k
        var r = vs
        if lockEnabled {
            let dev = abs(vs - 1)
            if dev < 0.03 { steadyCount += 1 } else { steadyCount = 0 }
            if locked && dev > 0.06 { locked = false }
            if !locked && Double(steadyCount) > 0.2 * sr { locked = true }
            if locked { r = 1 }
        } else { locked = false; steadyCount = 0 }
        rate = r

        play += r
        let top = Double(frozen ? freezeW : w)
        if frozen {
            let lo = top - Double(loopLen), hi = top - 2
            while play >= hi { play -= Double(loopLen) }
            while play < lo { play += Double(loopLen) }
        } else {
            if play > top - minLag { play = top - minLag }
            if play < top - Double(len) + 4 { play = top - Double(len) + 4 }
        }
        if !frozen && mode == .snap && locked && xfade == 0 && steadyCount > snapDelay && lag > minLag + 48 {
            jumpToLive()
        }
        var l = readCh(Lb, play), rr = readCh(Rb, play)
        if xfade > 0 {
            xfadePos += r
            if xfadePos > Double(w) - minLag { xfadePos = Double(w) - minLag }
            let g = Double(xfade) / Double(xfadeLen)
            let e = 0.5 - 0.5 * cos(.pi * min(1, g))
            let l2 = readCh(Lb, xfadePos), r2 = readCh(Rb, xfadePos)
            l = l * (1 - e) + l2 * e; rr = rr * (1 - e) + r2 * e
            xfade += 1
            if xfade > xfadeLen { play = xfadePos; xfade = 0 }
        }
        gain += (fader - gain) * 0.03                          // ~0.7 ms fader smoothing
        dyL = dcA * (dyL + l - dxL); dxL = l                   // DC blocker: a stopped record is silence
        dyR = dcA * (dyR + rr - dxR); dxR = rr
        let g = gain * outGain
        return (dyL * g, dyR * g)
    }
}

// MARK: - Stereo timecode decoder (Serato, Traktor, LiveSkratch stereo)

/// Commercial timecode carries the same carrier on both channels a quarter-cycle apart, so the pair traces a
/// circle: its angle is the needle's position within a carrier cycle, and which way it turns is the direction.
/// LiveSkratch only needs speed and direction (it scratches live audio, not a track), so the position bits
/// the timecode also carries are ignored: this is a "relative mode" decoder that works with any such timecode.
public final class QuadDecoder {
    public let sr: Double
    public var carrierHz: Double = 1000
    public var flip = false
    public var gate = 0.0015
    /// Right-channel gain that makes both channels equal (measured by calibration).
    public var balance = 1.0

    // DC removal at 2 % of the carrier: identical on both channels, so it shifts their phase equally and the
    // angle stays exact, while a stopped record's leftover level clears in a few ms instead of ~50.
    var hpA = 0.0, hpFor = -1.0
    var xL = 0.0, yL = 0.0, xR = 0.0, yR = 0.0
    public private(set) var env = 0.0
    public private(set) var active = false
    var prevPhase = 0.0, havePrev = false
    var phi = 0.0                                     // unwrapped phase, radians
    let ringSize = 8192
    let ring: UnsafeMutablePointer<Double>
    var n = 0, filled = 0
    public private(set) var v = 0.0
    public private(set) var dir = 1
    public private(set) var rawSpeed = 0.0
    public private(set) var posInt = 0.0
    public private(set) var levelL = 0.0, levelR = 0.0  // slow RMS, for calibration

    public init(sr: Double) {
        self.sr = sr
        ring = .allocate(capacity: ringSize); ring.initialize(repeating: 0, count: ringSize)
    }
    deinit { ring.deallocate() }

    @inline(__always) public func process(_ l: Double, _ r: Double) -> Double {
        if carrierHz != hpFor { hpFor = carrierHz; hpA = exp(-2 * .pi * max(5, 0.02 * carrierHz) / sr) }
        let a = hpA * (yL + l - xL); xL = l; yL = a
        let b0 = hpA * (yR + r - xR); xR = r; yR = b0
        let b = b0 * balance
        levelL += (a * a - levelL) * 0.0005; levelR += (b0 * b0 - levelR) * 0.0005
        // quadrature magnitude is ripple-free, so a short peak hold is enough
        let mag = (a * a + b * b).squareRoot()
        let relT = max(0.002 * sr, 3 * sr / max(50, carrierHz))
        env = max(mag, env * exp(-1 / relT))
        // hysteresis: wake only when clearly above the gate, so noise at the threshold can't flicker it on
        active = active ? env > gate : env > 2 * gate
        let M = ringSize - 1
        if !active {
            havePrev = false; v = 0; rawSpeed = 0
            ring[n & M] = phi; n += 1; filled = 0
            return 0
        }
        if mag < 0.5 * gate {           // a dip into the noise: hold the phase rather than follow the noise
            ring[n & M] = phi; n += 1; posInt += v
            return v
        }
        let p = atan2(a, b)   // Serato / Traktor convention: forward = right channel leads left by a quarter cycle
        if havePrev {
            var d = p - prevPhase
            if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
            phi += d
        }
        prevPhase = p; havePrev = true
        ring[n & M] = phi
        // speed over one carrier period at 1×: cancels the ripple from channel imbalance and phase error
        let W = max(4, min(4096, Int((sr / carrierHz).rounded())))
        filled += 1
        if filled > W {
            var s = (phi - ring[(n - W) & M]) / (2 * .pi * Double(W) * carrierHz / sr)
            if flip { s = -s }
            v = s
            rawSpeed = abs(s)
            if abs(s) > 0.02 { dir = s > 0 ? 1 : -1 }
        }
        n += 1
        posInt += v
        return v
    }
}

/// The LiveSkratch stereo timecode: a plain quadrature sine pair in the Serato / Traktor phase (left = sin, right = cos),
/// so forward play turns the same way as Serato or Traktor control vinyl.
public enum StereoTimecode {
    public static let hz: Double = 1000
}
