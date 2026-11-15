// ---- AudioWorklet processor (appended after dsp.js) ----
class FlutterProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    const sr = sampleRate;
    this.dec = new ToneDecoder(sr);
    this.eng = new ScratchEngine(sr);
    this.faderMode = 'wow';
    this.refLevel = 0.3;
    this.faderLo = 0.08; this.faderHi = 0.45;
    this.softCut = 1;
    this.sim = { on: true, motor: true, hand: false, handV: 0, v: 0, theta: 0, fader: 1, seed: 1 };
    this.cal = null;
    this.binSize = 256; this.binAcc = 0; this.binN = 0; this.newBins = [];
    this.reportEvery = Math.round(sr / 60); this.since = 0;
    this.ctrlPk = 0; this.livePk = 0; this.outPk = 0;
    this.tmp = [0, 0];
    this.port.onmessage = (e) => this.onMsg(e.data);
  }

  onMsg(m) {
    const d = this.dec, e = this.eng;
    switch (m.type) {
      case 'params':
        if ('smoothMs' in m) e.setSmooth(m.smoothMs);
        if ('mode' in m) e.mode = m.mode;
        if ('snapDelay' in m) e.snapDelay = Math.round(m.snapDelay * 0.001 * sampleRate);
        if ('lock' in m) e.lockEnabled = m.lock;
        if ('faderMode' in m) this.faderMode = m.faderMode;
        if ('faderLo' in m) this.faderLo = m.faderLo;
        if ('faderHi' in m) this.faderHi = m.faderHi;
        if ('gate' in m) d.gate = m.gate;
        if ('flip' in m) d.flip = m.flip;
        if ('calib' in m) d.calib = m.calib;
        if ('refLevel' in m) this.refLevel = m.refLevel;
        if ('outGain' in m) e.outGain = m.outGain;
        if ('sim' in m) this.sim.on = m.sim;
        if ('loopSec' in m) e.loopLen = Math.min(Math.round(m.loopSec * sampleRate), e.len - 8);
        break;
      case 'freeze': e.setFrozen(m.on, m.loopSec); break;
      case 'jump': e.jumpToLive(); break;
      case 'softCut': this.softCut = m.on ? 0 : 1; break;
      case 'simHand': this.sim.hand = m.down; this.sim.handV = m.v; break;
      case 'simMotor': this.sim.motor = m.on; break;
      case 'simFader': this.sim.fader = m.v; break;
      case 'calibrate':
        this.cal = { n: 0, N: Math.round(1.5 * sampleRate), speeds: [], stat: 0, statN: 0, env: 0, envN: 0, active: 0 };
        break;
    }
  }

  rnd() { // tiny LCG for sim noise
    this.sim.seed = (this.sim.seed * 1664525 + 1013904223) >>> 0;
    return this.sim.seed / 4294967296 - 0.5;
  }

  process(inputs, outputs) {
    const ctrlIn = inputs[0] && inputs[0][0];
    const live = inputs[1];
    const liveL = live && live[0];
    const liveR = live && (live[1] || live[0]);
    const out = outputs[0];
    const oL = out[0], oR = out[1] || out[0];
    const N = oL.length;
    const d = this.dec, e = this.eng, sim = this.sim, tmp = this.tmp, sr = sampleRate;
    const handK = 1 - Math.exp(-1 / (0.002 * sr));
    const motorK = 1 - Math.exp(-1 / (0.09 * sr));

    for (let i = 0; i < N; i++) {
      let c = ctrlIn ? ctrlIn[i] : 0;
      if (sim.on) {
        const target = sim.hand ? sim.handV : (sim.motor ? 1 : 0);
        sim.v += (target - sim.v) * (sim.hand ? handK : motorK);
        sim.theta += 2 * Math.PI * F0 * sim.v / sr;
        if (sim.theta > 1e6) sim.theta -= 2 * Math.PI * Math.floor(sim.theta / (2 * Math.PI));
        c = 0.445 * sim.fader * toneSample(sim.theta) + this.rnd() * 2e-4;
      }
      const r = d.process(c);

      let g = 1;
      if (this.faderMode === 'wow') g = faderCurve(d.env / Math.max(1e-4, this.refLevel), this.faderLo, this.faderHi);
      g *= this.softCut;

      const lL = liveL ? liveL[i] : 0, lR = liveR ? liveR[i] : 0;
      e.step(lL, lR, r, g, tmp);
      oL[i] = tmp[0]; if (oR !== oL) oR[i] = tmp[1];

      const ac = Math.abs(c); if (ac > this.ctrlPk) this.ctrlPk = ac;
      const al = Math.max(Math.abs(lL), Math.abs(lR)); if (al > this.livePk) this.livePk = al;
      const ao = Math.abs(tmp[0]); if (ao > this.outPk) this.outPk = ao;

      if (!e.frozen) {
        if (al > this.binAcc) this.binAcc = al;
        if (++this.binN >= this.binSize) { this.newBins.push(this.binAcc); this.binAcc = 0; this.binN = 0; }
      }

      const cal = this.cal;
      if (cal) {
        cal.n++;
        if (d.active) cal.active++;
        if ((cal.n & 31) === 0 && d.active && d.rawSpeed > 0) cal.speeds.push(d.rawSpeed);
        if ((cal.n & 31) === 0 && d.active) { cal.stat += d.lastStat; cal.statN++; cal.env += d.env; cal.envN++; }
        if (cal.n >= cal.N) {
          const s = cal.speeds.sort((a, b) => a - b);
          const med = s.length ? s[Math.floor(s.length / 2)] : 0;
          const lo = s.length ? s[Math.floor(s.length * 0.1)] : 0, hi = s.length ? s[Math.floor(s.length * 0.9)] : 0;
          this.port.postMessage({
            type: 'calibrated', speed: med, spread: med ? (hi - lo) / med : 1,
            stat: cal.statN ? cal.stat / cal.statN : 0, env: cal.envN ? cal.env / cal.envN : 0,
            activeFrac: cal.active / cal.n,
          });
          this.cal = null;
        }
      }
    }

    this.since += N;
    if (this.since >= this.reportEvery) {
      this.since = 0;
      const bins = this.newBins.length ? Float32Array.from(this.newBins) : null;
      this.newBins.length = 0;
      this.port.postMessage({
        type: 'state', v: e.vs, rate: e.rate, lag: e.lag, locked: e.locked, frozen: e.frozen,
        env: d.env, active: d.active, dir: d.dir, stat: d.lastStat, pos: d.posInt,
        gain: e.gain, ctrlPk: this.ctrlPk, livePk: this.livePk, outPk: this.outPk,
        simV: sim.v, loopLen: e.loopLen, bins,
      }, bins ? [bins.buffer] : []);
      this.ctrlPk = 0; this.livePk = 0; this.outPk = 0;
    }
    return true;
  }
}
registerProcessor('flutter', FlutterProcessor);
