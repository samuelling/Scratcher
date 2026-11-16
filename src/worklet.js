// ---- AudioWorklet processor (appended after dsp.js) ----
class FlutterProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    const sr = sampleRate;
    this.dec = new ToneDecoder(sr);
    this.pilot = new PilotReader(sr);
    this.wowRead = 'level'; // 'level' | 'pilot'
    this.pilotRef = 0.3;
    this.pilotGain = (f) => this.pilot.lnGain(f);
    this.eng = new ScratchEngine(sr);
    this.faderMode = 'wow';
    this.refLevel = 0.3;
    this.faderLo = 0.08; this.faderHi = 0.45;
    this.softCut = 1;
    this.vf = { x: 0, cut: 0.05, width: 0.02, hamster: false };
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
        if ('vfX' in m) this.vf.x = m.vfX;
        if ('vfCut' in m) this.vf.cut = m.vfCut;
        if ('vfWidth' in m) this.vf.width = Math.max(0.005, m.vfWidth);
        if ('hamster' in m) this.vf.hamster = m.hamster;
        if ('faderLo' in m) this.faderLo = m.faderLo;
        if ('faderHi' in m) this.faderHi = m.faderHi;
        if ('gate' in m) d.gate = m.gate;
        if ('flip' in m) d.flip = m.flip;
        if ('calib' in m) d.calib = m.calib;
        if ('refLevel' in m) this.refLevel = m.refLevel;
        if ('wowRead' in m) this.wowRead = m.wowRead;
        if ('pilotHz' in m) this.pilot.setFreq(m.pilotHz);
        if ('pilotRef' in m) this.pilotRef = m.pilotRef;
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
      case 'record':
        this.rec = { n: 0, N: Math.round(m.sec * sampleRate), buf: new Float32Array(Math.round(m.sec * sampleRate) * 4) };
        break;
      case 'calibrate':
        this.pilot.resetMeasure();
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
    // virtual cut fader: deck on the left; open from the edge up to the cut-in point
    const vfx = this.vf.hamster ? 1 - this.vf.x : this.vf.x;
    const vfGain = 1 - faderCurve(vfx, this.vf.cut, this.vf.cut + this.vf.width);

    for (let i = 0; i < N; i++) {
      let c = ctrlIn ? ctrlIn[i] : 0;
      if (sim.on) {
        const target = sim.hand ? sim.handV : (sim.motor ? 1 : 0);
        sim.v += (target - sim.v) * (sim.hand ? handK : motorK);
        sim.theta += 2 * Math.PI * F0 * sim.v / sr;
        const span = 2 * Math.PI * AM_CYCLES; // wrap on whole loudness periods
        if (sim.theta > 1e6) sim.theta -= span * Math.floor(sim.theta / span);
        if (this.wowRead === 'pilot') {
          sim.ph = (sim.ph || 0) + 2 * Math.PI * PILOT_HZ / sr;
          if (sim.ph > 6.283185307179586) sim.ph -= 6.283185307179586;
          sim.fg = (sim.fg || 0) + (sim.fader - (sim.fg || 0)) * 0.03; // ~1 ms digital fader ramp
          c = 0.35 * toneSample(sim.theta) + 0.35 * sim.fg * Math.sin(sim.ph) + this.rnd() * 2e-4;
        } else {
          c = 0.445 * sim.fader * toneSample(sim.theta) + this.rnd() * 2e-4;
        }
      }
      const usePilot = this.wowRead === 'pilot';
      d.gainLn = usePilot ? this.pilotGain : null;
      const pc = this.pilot.process(c);           // always runs: measures the pilot even in tone-level mode
      const cc = usePilot ? pc : c;
      const r = d.process(cc);

      let g = 1;
      const fm = this.faderMode;
      if (fm === 'wow' || fm === 'both') {
        const lvl = usePilot ? this.pilot.amp / Math.max(1e-4, this.pilotRef) : d.env / Math.max(1e-4, this.refLevel);
        g = faderCurve(lvl, this.faderLo, this.faderHi);
      }
      if (fm === 'virtual' || fm === 'both') g *= vfGain;
      g *= this.softCut;

      const lL = liveL ? liveL[i] : 0, lR = liveR ? liveR[i] : 0;
      e.step(lL, lR, r, g, tmp);
      oL[i] = tmp[0]; if (oR !== oL) oR[i] = tmp[1];
      const rec = this.rec;
      if (rec) { // diagnostic capture: raw WOW in, live in, output, fader gain
        const k = rec.n * 4; rec.buf[k] = c; rec.buf[k + 1] = lL; rec.buf[k + 2] = tmp[0]; rec.buf[k + 3] = g;
        if (++rec.n >= rec.N) { this.port.postMessage({ type: 'recorded', buf: rec.buf, sr: sampleRate }, [rec.buf.buffer]); this.rec = null; }
      }

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
        if ((cal.n & 31) === 0 && d.active) { cal.stat += d.dir; cal.statN++; cal.env += d.env; cal.envN++; } // mean direction while the motor runs
        if (cal.n >= cal.N) {
          const s = cal.speeds.sort((a, b) => a - b);
          const med = s.length ? s[Math.floor(s.length / 2)] : 0;
          const lo = s.length ? s[Math.floor(s.length * 0.1)] : 0, hi = s.length ? s[Math.floor(s.length * 0.9)] : 0;
          this.port.postMessage({
            type: 'calibrated', speed: med, spread: med ? (hi - lo) / med : 1,
            stat: cal.statN ? cal.stat / cal.statN : 0, env: cal.envN ? cal.env / cal.envN : 0,
            activeFrac: cal.active / cal.n, pilot: this.pilot.measured(),
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
        simV: sim.v, loopLen: e.loopLen, bins, pilotAmp: this.pilot.amp,
      }, bins ? [bins.buffer] : []);
      this.ctrlPk = 0; this.livePk = 0; this.outPk = 0;
    }
    return true;
  }
}
registerProcessor('flutter', FlutterProcessor);
