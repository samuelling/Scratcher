// ---- AudioWorklet processor (appended after dsp.js) ----
class FlutterProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    const sr = sampleRate;
    this.dec = new ToneDecoder(sr);
    this.quad = new QuadDecoder(sr);
    this.control = 'wow';   // 'wow' (mono WOW tone) | 'timecode' (stereo Serato / Traktor / LiveSkratch)
    this.pilot = new PilotReader(sr);
    this.pilotR = new PilotReader(sr);
    this.pad = { on: false, open: true };   // tap-pad fader
    this.wowRead = 'level'; // 'level' | 'pilot'
    this.pilotRef = 0.3;
    this.pilotGain = (f) => this.pilot.lnGain(f);
    this.eng = new ScratchEngine(sr, 45);
    this.faderMode = 'wow';
    this.userGate = 0.0015; this.toneRef = 0;   // gate = max(user gate, 10% of calibrated tone level)
    this.refLevel = 0.3;
    this.faderLo = 0.08; this.faderHi = 0.45;
    this.softCut = 1;
    this.vf = { x: 0, cut: 0.05, width: 0.02, hamster: false };
    this.sim = { on: true, motor: true, hand: false, handV: 0, v: 0, theta: 0, fader: 1, seed: 1 };
    this.cal = null;
    this.binSize = 256; this.binAcc = 0; this.binN = 0; this.newBins = []; this.tapeId = 0;   // tape overview: loudness of every 256 samples
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
        if ('gate' in m) this.userGate = m.gate;
        if ('toneRef' in m) this.toneRef = m.toneRef;
        if ('gate' in m || 'toneRef' in m) d.gate = this.quad.gate = Math.max(this.userGate, 0.1 * this.toneRef);
        if ('flip' in m) d.flip = this.quad.flip = m.flip;
        if ('control' in m) this.control = m.control;
        if ('carrierHz' in m) this.quad.carrierHz = m.carrierHz;
        if ('balance' in m) this.quad.balance = m.balance;
        if ('padStyle' in m) this.pad.on = m.padStyle;
        if ('padOpen' in m) this.pad.open = m.padOpen;
        if ('calib' in m) d.calib = m.calib;
        if ('refLevel' in m) this.refLevel = m.refLevel;
        if ('wowRead' in m) this.wowRead = m.wowRead;
        if ('pilotHz' in m) { this.pilot.setFreq(m.pilotHz); this.pilotR.setFreq(m.pilotHz); }
        if ('pilotRef' in m) this.pilotRef = m.pilotRef;
        if ('outGain' in m) e.outGain = m.outGain;
        if ('sim' in m) this.sim.on = m.sim;
        if ('tapeSec' in m && Math.round(m.tapeSec * sampleRate) !== e.len) {   // a new tape length: a fresh, empty tape
          e.setTape(m.tapeSec);
          this.binAcc = 0; this.binN = 0; this.newBins.length = 0; this.tapeId++;
        }
        if ('loopSec' in m) e.loopLen = Math.min(Math.round(m.loopSec * sampleRate), e.len - 8);
        if ('loopWhole' in m) e.loopWhole = m.loopWhole;
        if ('loopStop' in m) e.loopStop = m.loopStop;
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
    const ctrlInR = inputs[0] && inputs[0][1];
    const stereo = this.control === 'timecode', q = this.quad;
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
    const vfGain = this.pad.on ? (this.pad.open ? 1 : 0) : 1 - faderCurve(vfx, this.vf.cut, this.vf.cut + this.vf.width);

    for (let i = 0; i < N; i++) {
      let c = ctrlIn ? ctrlIn[i] : 0;
      let c2 = ctrlInR ? ctrlInR[i] : 0;
      const usePilot = this.wowRead === 'pilot';
      if (sim.on) {
        const target = sim.hand ? sim.handV : (sim.motor ? 1 : 0);
        sim.v += (target - sim.v) * (sim.hand ? handK : motorK);
        let pil = 0;
        if (usePilot) {
          sim.ph = (sim.ph || 0) + 2 * Math.PI * PILOT_HZ / sr;
          if (sim.ph > 6.283185307179586) sim.ph -= 6.283185307179586;
          sim.fg = (sim.fg || 0) + (sim.fader - (sim.fg || 0)) * 0.03; // ~1 ms digital fader ramp
          pil = 0.35 * sim.fg * Math.sin(sim.ph);
        }
        const lvl = usePilot ? 0.35 : 0.445 * sim.fader;
        if (stereo) {
          sim.q = (sim.q || 0) + 2 * Math.PI * q.carrierHz * sim.v / sr;
          if (Math.abs(sim.q) > 1e6) sim.q %= 2 * Math.PI;
          c = lvl * Math.sin(sim.q) + pil + this.rnd() * 2e-4;    // Serato phase: right leads left
          c2 = lvl * Math.cos(sim.q) + pil + this.rnd() * 2e-4;
        } else {
          sim.theta += 2 * Math.PI * F0 * sim.v / sr;
          const span = 2 * Math.PI * AM_CYCLES; // wrap on whole loudness periods
          if (sim.theta > 1e6) sim.theta -= span * Math.floor(sim.theta / span);
          c = lvl * toneSample(sim.theta) + pil + this.rnd() * 2e-4;
        }
      }
      d.gainLn = usePilot ? this.pilotGain : null;
      const pc = this.pilot.process(c);           // always runs: measures the pilot even in tone-level mode
      let r;
      if (stereo) { const pc2 = this.pilotR.process(c2); r = q.process(usePilot ? pc : c, usePilot ? pc2 : c2); }
      else r = d.process(usePilot ? pc : c);
      const cActive = stereo ? q.active : d.active, cEnv = stereo ? q.env : d.env;

      let g = 1;
      const fm = this.faderMode;
      if ((fm === 'wow' || fm === 'both') && !stereo) {   // timecode decks carry no WOW fader (no pilot): only the on-screen fader cuts
        const lvl = usePilot ? this.pilot.amp / Math.max(1e-4, this.pilotRef) : cEnv / Math.max(1e-4, this.refLevel);
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
        const rs = stereo ? q.rawSpeed : d.rawSpeed, cdir = stereo ? q.dir : d.dir;
        if (cActive) cal.active++;
        if ((cal.n & 31) === 0 && cActive && rs > 0) cal.speeds.push(rs);
        if ((cal.n & 31) === 0 && cActive) { cal.stat += cdir; cal.statN++; cal.env += cEnv; cal.envN++; } // mean direction while the motor runs
        if (cal.n >= cal.N) {
          const s = cal.speeds.sort((a, b) => a - b);
          const med = s.length ? s[Math.floor(s.length / 2)] : 0;
          const lo = s.length ? s[Math.floor(s.length * 0.1)] : 0, hi = s.length ? s[Math.floor(s.length * 0.9)] : 0;
          this.port.postMessage({
            type: 'calibrated', speed: med, spread: med ? (hi - lo) / med : 1,
            stat: cal.statN ? cal.stat / cal.statN : 0, env: cal.envN ? cal.env / cal.envN : 0,
            activeFrac: cal.active / cal.n, pilot: this.pilot.measured(),
            balance: q.levelR > 1e-12 ? Math.sqrt(q.levelL / q.levelR) : 1,
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
        env: stereo ? q.env : d.env, active: stereo ? q.active : d.active, dir: stereo ? q.dir : d.dir,
        stat: stereo ? 0 : d.lastStat, pos: stereo ? q.posInt : d.posInt,
        gain: e.gain, ctrlPk: this.ctrlPk, livePk: this.livePk, outPk: this.outPk,
        simV: sim.v, loopLen: e.loopUsed, bins, pilotAmp: this.pilot.amp, binSize: this.binSize, tapeLen: e.len, tapeId: this.tapeId,
      }, bins ? [bins.buffer] : []);
      this.ctrlPk = 0; this.livePk = 0; this.outPk = 0;
    }
    return true;
  }
}
registerProcessor('flutter', FlutterProcessor);
