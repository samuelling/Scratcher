// Control tone (scratched) + pilot tone gated by a fader, mixed into one mono cable.
const { F0, toneSample, ToneDecoder, PilotReader, faderCurve } = require('../src/dsp.js');
const SR = 48000;
let MODE='lp';
function run(name, velFn, faderFn, pilotHz = 18000, measuredHz = null) {
  const dec = new ToneDecoder(SR), pr = new PilotReader(SR); pr.mode = MODE; dec.gainLn = f => pr.lnGain(f);
  if (measuredHz) pr.setFreq(measuredHz);
  let th = 0, ph = 0, truth = 0, p0 = 0, t0 = 0, maxErr = 0, gErr = 0, gN = 0, lagMax = 0;
  const N = SR * 3, warm = SR * 0.3;
  let lastOpenTrue = 0, wasOpen = true, cutEvents = [];
  for (let n = 0; n < N; n++) {
    const t = n / SR, v = n < warm ? 1 : velFn(t - warm / SR), f = n < warm ? 1 : faderFn(t - warm / SR);
    th += 2 * Math.PI * F0 * v / SR; ph += 2 * Math.PI * pilotHz / SR;
    const x = 0.35 * toneSample(th) + 0.35 * f * Math.sin(ph) + (Math.random() - 0.5) * 2e-4;
    const clean = pr.process(x);
    dec.process(clean); truth += v;
    if (n === warm) { p0 = dec.posInt; t0 = truth; }
    if (n > warm) {
      maxErr = Math.max(maxErr, Math.abs((dec.posInt - p0) - (truth - t0)));
      const g = faderCurve(pr.amp / 0.35, 0.08, 0.45);
      gErr += Math.abs(g - f); gN++;
    }
  }
  console.log(`${name.padEnd(34)} posMaxErr ${(maxErr / SR * 1000).toFixed(2)}ms  fader meanAbsErr ${(gErr / gN).toFixed(3)}`);
}
for (MODE of ['notch']) { console.log('--', MODE);
const cuts = t => { const u = (t * 20) % 2, r = 0.02; return u < 1 ? (u < r ? u / r : 1) : (u - 1 < r ? 1 - (u - 1) / r : 0); }; // 10 Hz cuts, 1 ms ramps
run('1x, fader static open', t => 1, t => 1);
run('baby scratch, transformer cuts', t => 1.5 * Math.sin(2 * Math.PI * 4 * t), cuts);
run('fast scratch ±3, cuts', t => 3 * Math.sin(2 * Math.PI * 8 * t), cuts);
run('scribble ±2, cuts', t => 2 * Math.sin(2 * Math.PI * 15 * t), cuts);
run('pilot pitched +5% (uncalibrated)', t => 1.5 * Math.sin(2 * Math.PI * 4 * t), cuts, 18900);
run('pilot pitched +5% (calibrated)', t => 1.5 * Math.sin(2 * Math.PI * 4 * t), cuts, 18900, 18900);
}
