// FLUTTER DSP core — shared by the AudioWorklet and the Node test harness.
// Control tone: s(θ) = cos θ + A3·cos(3θ + π/2), θ advancing at 2π·F0 per second at 1x.
//  • zero crossings (2 per cycle) give |speed|
//  • E[x·d³] (d = derivative) flips sign with direction, is invariant to gain, speed and polarity

const F0 = 1500;
const A3 = 0.3;
const TONE_PEAK = 0.89; // linear peak used when rendering the tone file

function toneSample(theta) {
  return (Math.cos(theta) + A3 * Math.cos(3 * theta + Math.PI / 2)) / 1.25;
}

class ToneDecoder {
  constructor(sr) {
    this.sr = sr;
    this.calib = 1;          // measured 1x speed ratio of the WOW
    this.flip = false;
    this.gate = 0.0015;      // absolute noise gate on the control input
    this.hpA = Math.exp(-2 * Math.PI * 8 / sr);
    this.hpX = 0; this.hpY = 0;
    this.prev = 0;
    this.env = 0;
    this.n = 0;
    this.state = 0;          // Schmitt state +1 / -1
    this.pendingZC = -1;
    this.lastTc = -1;
    this.halfT = Infinity;
    this.dir = 1;
    this.dirScore = 1;
    this.lastStat = 0;
    this.active = false;
    this.sxd3 = 0; this.sx2 = 0; this.sd2 = 0; this.cnt = 0; this.lobePeak = 0;
    this.hwPeak = 0; this.hw1 = 0; this.hw2 = 0;
    this.lxd3 = 0; this.lx2 = 0; this.ld2 = 0; this.lcnt = 0;
    this.turnarounds = 0; this.prevLobePeak = 0;
    this.posExact = 0;
    this.posInt = 0;
    this.v = 0;              // per-sample rate output (1 = normal speed)
    this.rawSpeed = 0;       // unsigned, uncalibrated (for calibration)
  }

  get H1() { return this.sr / (2 * F0 * this.calib); }

  resetLobe() { this.sxd3 = 0; this.sx2 = 0; this.sd2 = 0; this.cnt = 0; this.lobePeak = 0; this.lxd3 = 0; this.lx2 = 0; this.ld2 = 0; this.lcnt = 0; }

  process(xin) {
    const n = this.n++;
    // DC / rumble removal
    const y = this.hpA * (this.hpY + xin - this.hpX);
    this.hpX = xin; this.hpY = y;
    const prev = this.prev; this.prev = y;
    const d = y - prev;
    const ay = Math.abs(y);

    // envelope: peak follower whose release scales with the tone period
    const relT = Math.max(0.0015 * this.sr, 2.5 * Math.min(this.halfT, 0.04 * this.sr));
    this.env = Math.max(ay, this.env * Math.exp(-1 / relT));

    const wasActive = this.active;
    this.active = this.env > this.gate;
    if (!this.active) {
      this.state = 0;
      this.resetLobe();
      this.lastTc = -1;
      this.halfT = Infinity;
      this.v = 0;
      this.rawSpeed = 0;
      return 0;
    }
    if (!wasActive) this.resetLobe();

    // lobe statistics
    const ym = 0.5 * (y + prev); // align signal with the half-sample derivative
    // leaky moments spanning a few lobes (phase-averaged even when a lobe is only ~4 samples)
    const tauS = Math.max(24, Math.min(1.5 * (this.halfT === Infinity ? 32 : this.halfT), 0.003 * this.sr));
    const lk = Math.exp(-1 / tauS);
    this.sxd3 = this.sxd3 * lk + ym * d * d * d;
    this.sx2 = this.sx2 * lk + ym * ym;
    this.sd2 = this.sd2 * lk + d * d;
    this.cnt = this.cnt * lk + 1;
    this.lxd3 += ym * d * d * d; this.lx2 += ym * ym; this.ld2 += d * d; this.lcnt++;
    if (ay > this.lobePeak) this.lobePeak = ay;

    // true zero crossing time (sub-sample)
    if ((prev <= 0 && y > 0) || (prev >= 0 && y < 0)) {
      const den = prev - y;
      this.pendingZC = (n - 1) + (den !== 0 ? prev / den : 0);
      this.hw2 = this.hw1; this.hw1 = this.hwPeak; this.hwPeak = 0;
    }
    if (ay > this.hwPeak) this.hwPeak = ay;

    // Schmitt confirmation; threshold follows the last two half-wave peaks so it
    // recovers within a cycle after a fader cut
    const thr = Math.max(0.5 * this.gate, 0.22 * Math.min(this.env, Math.max(this.hw1, this.hwPeak)));
    let confirmed = false;
    if (this.state !== 1 && y > thr) { this.state = 1; confirmed = true; }
    else if (this.state !== -1 && y < -thr) { this.state = -1; confirmed = true; }

    if (confirmed && this.pendingZC >= 0) {
      const tc = this.pendingZC;
      const H1 = this.H1;
      const momentStat = (xd3, x2, d2, N) => {
        if (N < 3 || d2 <= 0 || x2 <= 0) return 0;
        let st = (xd3 / N) / (Math.sqrt(x2 / N) * Math.pow(d2 / N, 1.5)) / 0.47; // ≈ ±1 clean
        return this.flip ? -st : st;
      };
      const statLeaky = momentStat(this.sxd3, this.sx2, this.sd2, this.cnt);
      const statLobe = momentStat(this.lxd3, this.lx2, this.ld2, this.lcnt);
      let stat = statLeaky;
      if (this.lastTc >= 0) {
        let half = tc - this.lastTc;
        if (half > 0.25) {
          const longLobe = this.lcnt >= 10;
          const pk = this.lobePeak, ppk = this.prevLobePeak || pk;
          const levelJump = pk < 0.3 * ppk || pk > 3.3 * ppk;
          if (levelJump && this.halfT !== Infinity && half > 1.7 * this.halfT) {
            // fader cut/open: threshold lagged and skipped marks — count them (odd multiples)
            const k = 2 * Math.round((half / this.halfT - 1) / 2) + 1;
            if (stat > 0.2) this.dir = 1; else if (stat < -0.2) this.dir = -1;
            this.posExact += this.dir * H1 * Math.min(k, 9);
            half = half / k;
          } else if (!levelJump && longLobe && Math.abs(statLobe) < 0.6 && this.halfT !== Infinity && half > 1.3 * this.halfT) {
            // turnaround: the needle re-crossed the same mark — net travel 0, direction flips
            this.dir = -this.dir;
            this.turnarounds++;
            this.sxd3 = 0; this.sx2 = 0; this.sd2 = 0; this.cnt = 0;
            stat = 0;
          } else {
            if (longLobe) stat = statLobe;
            if (stat > 0.2) this.dir = 1;
            else if (stat < -0.2) this.dir = -1;
            this.posExact += this.dir * H1;
          }
          this.halfT = half;
          this.rawSpeed = (this.sr / (2 * F0)) / half;
        }
      }
      this.lastStat = stat;
      this.prevLobePeak = this.lobePeak; this.lobePeak = 0;
      this.lxd3 = 0; this.lx2 = 0; this.ld2 = 0; this.lcnt = 0;
      this.lastTc = tc;
    }

    // speed between crossings (decays if the next crossing is late)
    let vmag = 0;
    if (this.lastTc >= 0 && this.halfT !== Infinity) {
      const tau = n - this.lastTc;
      vmag = this.H1 / Math.max(this.halfT, tau);
      if (tau > 0.12 * this.sr) vmag = 0;
    }
    const vEst = this.dir * vmag;

    // integrate velocity, softly pulled toward the interpolated groove position,
    // and never more than two half-cycles from the last confirmed mark
    const before = this.posInt;
    const H1 = this.H1;
    let pred = this.posExact;
    if (this.lastTc >= 0 && this.halfT !== Infinity) pred += this.dir * H1 * Math.min(1, (n - this.lastTc) / this.halfT);
    let p = before + vEst + (pred - before) * 0.004;
    if (p > this.posExact + 2 * H1) p = this.posExact + 2 * H1;
    if (p < this.posExact - 2 * H1) p = this.posExact - 2 * H1;
    this.posInt = p;
    this.v = p - before;
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

if (typeof module !== 'undefined') module.exports = { F0, A3, TONE_PEAK, toneSample, ToneDecoder, ScratchEngine, faderCurve };
