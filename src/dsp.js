// FLUTTER DSP core — shared by the AudioWorklet and the Node test harness.
// Control tone: s(θ) = cos θ + A3·cos(3θ + π/2), θ advancing at 2π·F0 per second at 1x.
//  • zero crossings (2 per cycle) give |speed|
//  • E[x·d³] (d = derivative) flips sign with direction, is invariant to gain, speed and polarity

const F0 = 1500;
const A3 = 0;
const TONE_PEAK = 0.89; // linear peak used when rendering the tone file
// Loudness envelope = lopsided triangle in log-amplitude: rises over 80% of 60 cycles (32 ms of file),
// falls over 20% (8 ms). The WOW plays reverse with forward-running fine structure, so direction
// is read from the loudness trend (slow vs fast, rising vs falling), never from waveform shape.
const AM_CYCLES = 60, AM_LN = Math.log(0.35), AM_RISE = 0.8;
const AM_SLOPE = -AM_LN / (AM_RISE * AM_CYCLES / F0);   // ln-units per second of file during the rise

function toneLogAmp(theta) {
  let u = theta / (2 * Math.PI * AM_CYCLES); u -= Math.floor(u);
  return u < AM_RISE ? AM_LN * (1 - u / AM_RISE) : AM_LN * (u - AM_RISE) / (1 - AM_RISE);
}
function toneSample(theta) {
  return Math.exp(toneLogAmp(theta)) * Math.sin(theta);
}

class ToneDecoder {
  // Speed: median zero-crossing interval. Direction: loudness trend vs. the expected rise slope.
  constructor(sr) {
    this.sr = sr; this.calib = 1; this.flip = false; this.gate = 0.0015;
    this.hpA = Math.exp(-2 * Math.PI * 8 / sr); this.hpX = 0; this.hpY = 0;
    this.prev = 0; this.env = 0; this.n = 0;
    this.state = 0; this.pendingZC = -1; this.lastTc = -1;
    this.halves = [Infinity, Infinity, Infinity, Infinity, Infinity]; this.halfT = Infinity;
    this.dir = 1; this.cand = 1; this.candN = 0; this.lastStat = 0; this.active = false;
    this.RING = 16384; this.Q = new Float64Array(this.RING); this.Lr = new Float32Array(this.RING); this.qAcc = 0;
    this.posInt = 0; this.v = 0; this.rawSpeed = 0;
    this.gainLn = null; this.gainCorr = 0; // optional: ln|H(f)| of any known filter ahead of the decoder
  }
  get H1() { return this.sr / (2 * F0 * this.calib); }
  process(xin) {
    const n = this.n++, M = this.RING - 1;
    const y = this.hpA * (this.hpY + xin - this.hpX); this.hpX = xin; this.hpY = y;
    const prev = this.prev; this.prev = y;
    const relT = Math.max(0.0015 * this.sr, 2.5 * Math.min(this.halfT, 0.04 * this.sr));
    this.env = Math.max(Math.abs(y), this.env * Math.exp(-1 / relT));
    if (this.qAcc > 1e6) { for (let i = 0; i < this.RING; i++) this.Q[i] -= this.qAcc; this.qAcc = 0; }
    this.qAcc += y * y; this.Q[n & M] = this.qAcc;
    this.active = this.env > this.gate;
    if (!this.active) {
      this.state = 0; this.lastTc = -1; this.halves.fill(Infinity); this.halfT = Infinity;
      this.v = 0; this.rawSpeed = 0; this.Lr[n & M] = -30; return 0;
    }
    if ((prev <= 0 && y > 0) || (prev >= 0 && y < 0)) { const den = prev - y; this.pendingZC = (n - 1) + (den !== 0 ? prev / den : 0); }
    const thr = 0.2 * this.env;
    let confirmed = false;
    if (this.state !== 1 && y > thr) { this.state = 1; confirmed = true; }
    else if (this.state !== -1 && y < -thr) { this.state = -1; confirmed = true; }
    if (confirmed && this.pendingZC >= 0) {
      if (this.lastTc >= 0) {
        const half = this.pendingZC - this.lastTc;
        if (half > 0.25) {
          this.halves.shift(); this.halves.push(half);
          const h = this.halves.filter(isFinite).sort((a, b) => a - b);
          this.halfT = h[h.length >> 1];
          this.rawSpeed = (this.sr / (2 * F0)) / this.halfT;
        }
      }
      this.lastTc = this.pendingZC;
    }
    let vmag = 0;
    if (this.lastTc >= 0 && this.halfT !== Infinity) {
      const tau = n - this.lastTc;
      vmag = this.H1 / Math.max(this.halfT, tau);
      if (tau > 0.12 * this.sr) vmag = 0;
    }
    // loudness over exactly one carrier period (ripple-free), in log units
    const W = Math.max(8, Math.min(4096, Math.round(this.halfT === Infinity ? 64 : 2 * this.halfT)));
    const E = n >= W ? (this.qAcc - this.Q[(n - W) & M]) / W : y * y;
    if (this.gainLn && (n & 15) === 0) this.gainCorr = vmag > 0 ? this.gainLn(F0 * this.calib * vmag) : 0;
    const L = 0.5 * Math.log(E + 1e-14) - this.gainCorr; this.Lr[n & M] = L;
    // trend over D samples, compared with the slope a forward rise would have at this speed
    const D = Math.min(8192, Math.max(2 * W, Math.round(0.001 * this.sr)));
    if (n >= D + W && vmag > 0.06) {
      const diff = L - this.Lr[(n - D) & M];
      const expct = AM_SLOPE * vmag * D / this.sr;
      let r = diff / expct; if (this.flip) r = -r;
      this.lastStat = r;
      let verdict = 0;
      if (r > 0.35 && r < 2.0) verdict = 1;        // slow rise  → forward
      else if (r < -0.35 && r > -2.0) verdict = -1; // slow fall  → backward
      else if (r < -2.6) verdict = 1;               // fast fall  → forward
      else if (r > 2.6) verdict = -1;               // fast rise  → backward
      if (verdict !== 0) {
        if (verdict === this.cand) this.candN++; else { this.cand = verdict; this.candN = 1; }
        if (this.candN >= Math.round(1.0 * D)) this.dir = this.cand;  // outlast a window straddling a rise/fall switch
      }
    }
    this.v = this.dir * vmag;
    this.posInt += this.v;
    return this.v;
  }
}

class ScratchEngine {
  constructor(sr, seconds = 32) {
    this.sr = sr;
    let len = 1; while (len < sr * seconds) len <<= 1;
    this.len = len; this.mask = len - 1;
    this.L = new Float32Array(len); this.R = new Float32Array(len);
    this.w = 0;                  // absolute write count
    this.play = 0;               // absolute play position
    this.minLag = Math.round(0.0025 * sr);
    this.rate = 0;
    this.vs = 0;                 // smoothed velocity
    this.smoothMs = 2;
    this.lockEnabled = true;
    this.locked = false;
    this.steadyCount = 0;
    this.mode = 'snap';          // 'snap' | 'stay'
    this.snapDelay = Math.round(0.18 * sr);
    this.xfade = 0; this.xfadeLen = Math.round(0.025 * sr); this.xfadePos = 0;
    this.frozen = false; this.freezeW = 0; this.loopLen = Math.round(4 * sr);
    this.gain = 0; this.outGain = 1;
    this.started = false;
    this.dcA = Math.exp(-2 * Math.PI * 6 / sr);
    this.dxL = 0; this.dyL = 0; this.dxR = 0; this.dyR = 0;
  }

  setSmooth(ms) { this.smoothMs = ms; }

  readCh(buf, pos) {
    const i = Math.floor(pos), f = pos - i, m = this.mask;
    const y0 = buf[(i - 1) & m], y1 = buf[i & m], y2 = buf[(i + 1) & m], y3 = buf[(i + 2) & m];
    const c1 = 0.5 * (y2 - y0);
    const c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3;
    const c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    return ((c3 * f + c2) * f + c1) * f + y1;
  }

  jumpToLive() {
    if (this.frozen) return;
    this.xfadePos = this.w - this.minLag;
    this.xfade = 1;
  }

  setFrozen(on, loopSec) {
    if (loopSec) this.loopLen = Math.min(Math.round(loopSec * this.sr), this.len - 8);
    if (on && !this.frozen) { this.frozen = true; this.freezeW = this.w; }
    else if (!on && this.frozen) { this.frozen = false; this.jumpToLive(); }
  }

  get lag() { return (this.frozen ? this.freezeW : this.w) - this.play; }

  // v = decoder rate, fader = target gain (0..1), returns [l, r]
  step(inL, inR, v, fader, out) {
    if (!this.frozen) {
      this.L[this.w & this.mask] = inL; this.R[this.w & this.mask] = inR;
      this.w++;
    }
    if (!this.started) { this.play = this.w - this.minLag; this.started = true; }

    const k = 1 - Math.exp(-1 / (Math.max(0.05, this.smoothMs) * 0.001 * this.sr));
    this.vs += (v - this.vs) * k;
    let rate = this.vs;

    // steady 1x lock (motor running, hands off)
    if (this.lockEnabled) {
      const dev = Math.abs(this.vs - 1);
      if (dev < 0.03) this.steadyCount++; else this.steadyCount = 0;
      if (this.locked && dev > 0.06) this.locked = false;
      if (!this.locked && this.steadyCount > 0.2 * this.sr) this.locked = true;
      if (this.locked) rate = 1;
    } else { this.locked = false; this.steadyCount = 0; }
    this.rate = rate;

    this.play += rate;
    const top = (this.frozen ? this.freezeW : this.w);
    if (this.frozen) {
      const lo = top - this.loopLen, hi = top - 2;
      while (this.play >= hi) this.play -= this.loopLen;
      while (this.play < lo) this.play += this.loopLen;
    } else {
      if (this.play > top - this.minLag) this.play = top - this.minLag;
      if (this.play < top - this.len + 4) this.play = top - this.len + 4;
    }

    // snap back to live after a scratch, once the platter is steady again
    if (!this.frozen && this.mode === 'snap' && this.locked && this.xfade === 0 &&
        this.steadyCount > this.snapDelay && this.lag > this.minLag + 48) {
      this.jumpToLive();
    }

    let l = this.readCh(this.L, this.play), r = this.readCh(this.R, this.play);
    if (this.xfade > 0) {
      this.xfadePos += rate;
      if (this.xfadePos > this.w - this.minLag) this.xfadePos = this.w - this.minLag;
      const g = this.xfade / this.xfadeLen;
      const e = 0.5 - 0.5 * Math.cos(Math.PI * Math.min(1, g));
      const l2 = this.readCh(this.L, this.xfadePos), r2 = this.readCh(this.R, this.xfadePos);
      l = l * (1 - e) + l2 * e; r = r * (1 - e) + r2 * e;
      this.xfade++;
      if (this.xfade > this.xfadeLen) { this.play = this.xfadePos; this.xfade = 0; }
    }

    // fader smoothing (~0.7 ms) keeps cuts crisp but click-free
    this.gain += (fader - this.gain) * 0.03;
    // DC blocker: a stopped record is silence, not a held sample
    this.dyL = this.dcA * (this.dyL + l - this.dxL); this.dxL = l;
    this.dyR = this.dcA * (this.dyR + r - this.dxR); this.dxR = r;
    const g = this.gain * this.outGain;
    out[0] = this.dyL * g; out[1] = this.dyR * g;
  }
}

function faderCurve(level, lo, hi) {
  const t = Math.max(0, Math.min(1, (level - lo) / (hi - lo)));
  return t * t * (3 - 2 * t);
}

if (typeof module !== 'undefined') module.exports = { F0, A3, AM_CYCLES, toneLogAmp, TONE_PEAK, toneSample, ToneDecoder, ScratchEngine, faderCurve };

// ---- Pilot-tone fader reader --------------------------------------------------
// The WOW's fader is set to cut the BEAT only; the beat is a steady pilot tone
// (~18 kHz). Its amplitude = fader position. The control tone (sample) is never cut.
const PILOT_HZ = 18000;

class Biquad {
  constructor() { this.b0 = 1; this.b1 = 0; this.b2 = 0; this.a1 = 0; this.a2 = 0; this.z1 = 0; this.z2 = 0; }
  notch(sr, f, q) {
    const w = 2 * Math.PI * f / sr, al = Math.sin(w) / (2 * q), c = Math.cos(w), a0 = 1 + al;
    this.b0 = 1 / a0; this.b1 = -2 * c / a0; this.b2 = 1 / a0; this.a1 = -2 * c / a0; this.a2 = (1 - al) / a0; return this;
  }
  lowpass(sr, f, q) {
    const w = 2 * Math.PI * f / sr, al = Math.sin(w) / (2 * q), c = Math.cos(w), a0 = 1 + al;
    this.b0 = (1 - c) / 2 / a0; this.b1 = (1 - c) / a0; this.b2 = (1 - c) / 2 / a0; this.a1 = -2 * c / a0; this.a2 = (1 - al) / a0; return this;
  }
  highpass(sr, f, q) {
    const w = 2 * Math.PI * f / sr, al = Math.sin(w) / (2 * q), c = Math.cos(w), a0 = 1 + al;
    this.b0 = (1 + c) / 2 / a0; this.b1 = -(1 + c) / a0; this.b2 = (1 + c) / 2 / a0; this.a1 = -2 * c / a0; this.a2 = (1 - al) / a0; return this;
  }
  // natural-log magnitude response at f Hz
  lnMag(sr, f) {
    const w = 2 * Math.PI * f / sr, c1 = Math.cos(w), s1 = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w);
    const nr = this.b0 + this.b1 * c1 + this.b2 * c2, ni = -(this.b1 * s1 + this.b2 * s2);
    const dr = 1 + this.a1 * c1 + this.a2 * c2, di = -(this.a1 * s1 + this.a2 * s2);
    return 0.5 * Math.log((nr * nr + ni * ni) / (dr * dr + di * di) + 1e-20);
  }
  process(x) { // transposed direct form II
    const y = this.b0 * x + this.z1;
    this.z1 = this.b1 * x - this.a1 * y + this.z2;
    this.z2 = this.b2 * x - this.a2 * y;
    return y;
  }
}

class PilotReader {
  constructor(sr) {
    this.sr = sr;
    this.n1 = new Biquad(); this.n2 = new Biquad();
    this.mode = 'notch'; // a low-pass would rotate the 3rd harmonic's phase and flip direction above ~2x
    this.lp = [0, 1, 2].map(() => new Biquad());
    this.hp1 = new Biquad().highpass(sr, 12000, 0.54); this.hp2 = new Biquad().highpass(sr, 12000, 1.31);
    this.c = 1; this.s = 0; this.i1 = 0; this.q1 = 0; this.i2 = 0; this.q2 = 0;
    this.k = 1 - Math.exp(-2 * Math.PI * 700 / sr); // ~0.5 ms demod smoothing
    this.amp = 0;
    this.setFreq(PILOT_HZ);
    // calibration helpers
    this.hpPrev = 0; this.zc = 0; this.hpN = 0; this.hpSq = 0;
  }
  setFreq(f) {
    this.f = Math.min(f, this.sr * 0.45);
    const q = 0.8; // two wide notches: robust to the fader's on/off splatter
    this.n1.notch(this.sr, this.f, q); this.n2.notch(this.sr, this.f, q);
    // 6th-order Butterworth low-pass well below the pilot (kills it and most of its gating splatter)
    const fc = Math.min(10000, this.f * 0.55), qs = [0.5176, 0.7071, 1.9319];
    this.lp.forEach((b, i) => b.lowpass(this.sr, fc, qs[i]));
    const w = 2 * Math.PI * this.f / this.sr; this.cw = Math.cos(w); this.sw = Math.sin(w);
  }
  // returns the control signal with the pilot notched out; updates this.amp
  process(x) {
    // rotating phasor local oscillator
    const c = this.c * this.cw - this.s * this.sw, s = this.s * this.cw + this.c * this.sw;
    const g = 1.5 - 0.5 * (c * c + s * s); this.c = c * g; this.s = s * g;
    const k = this.k;
    this.i1 += (x * c - this.i1) * k; this.q1 += (x * s - this.q1) * k;
    this.i2 += (this.i1 - this.i2) * k; this.q2 += (this.q1 - this.q2) * k;
    this.amp = 2 * Math.sqrt(this.i2 * this.i2 + this.q2 * this.q2);
    // calibration: frequency + level of whatever lives above 12 kHz
    const h = this.hp2.process(this.hp1.process(x));
    if ((this.hpPrev <= 0 && h > 0)) this.zc++;
    this.hpPrev = h; this.hpN++; this.hpSq += h * h;
    if (this.mode === 'notch') return this.n2.process(this.n1.process(x));
    return this.lp[2].process(this.lp[1].process(this.lp[0].process(x)));
  }
  lnGain(f) { return this.n1.lnMag(this.sr, f) + this.n2.lnMag(this.sr, f); }
  resetMeasure() { this.zc = 0; this.hpN = 0; this.hpSq = 0; }
  measured() { return { hz: this.hpN ? this.zc * this.sr / this.hpN : 0, amp: this.hpN ? Math.sqrt(2 * this.hpSq / this.hpN) : 0 }; }
}

if (typeof module !== 'undefined') Object.assign(module.exports, { PILOT_HZ, Biquad, PilotReader });
