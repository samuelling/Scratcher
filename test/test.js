const { F0, toneSample, ToneDecoder, ScratchEngine } = require('../src/dsp.js');
const SR = 48000, FILE_SR = 44100;
// WOW emulation: tone stored as a 44.1k table, read with linear interpolation at platter speed
const tableLen = FILE_SR * 2;
const table = new Float32Array(tableLen);
for (let i = 0; i < tableLen; i++) table[i] = 0.89 * toneSample(2 * Math.PI * F0 * i / FILE_SR);
function run(name, velFn, dur, opts = {}) {
  const dec = new ToneDecoder(SR);
  const N = Math.round(dur * SR);
  let filePos = 0, truth = 0, maxErr = 0, sumErr = 0, cnt = 0;
  const gain = opts.gain ?? 0.5, pol = opts.invert ? -1 : 1;
  const offset = [];
  let warm = Math.round((opts.warm ?? 0.3) * SR);
  let startTruth = null, startDec = null;
  let vlog = [];
  for (let n = 0; n < N + warm; n++) {
    const t = (n - warm) / SR;
    const v = n < warm ? 1 : velFn(t);
    filePos += v * FILE_SR / SR;
    const i = Math.floor(filePos), f = filePos - i;
    const a = table[((i % tableLen) + tableLen) % tableLen], b = table[(((i + 1) % tableLen) + tableLen) % tableLen];
    let amp = opts.ampFn ? opts.ampFn(t) : 1;
    if (n < warm) amp = 1;
    let x = pol * gain * amp * (a + (b - a) * f) + (Math.random() - 0.5) * 2e-4;
    dec.process(x);
    truth += v;
    if (n === warm) { startTruth = truth; startDec = dec.posInt; }
    if (n > warm) {
      const err = (dec.posInt - startDec) - (truth - startTruth);
      maxErr = Math.max(maxErr, Math.abs(err)); sumErr += err * err; cnt++;
      if (n % 2400 === 0) vlog.push(`${t.toFixed(2)}:${v.toFixed(2)}/${dec.v.toFixed(2)}`);
    }
  }
  const finalErr = (dec.posInt - startDec) - (truth - startTruth);
  console.log(`${name.padEnd(28)} maxErr ${(maxErr / SR * 1000).toFixed(2)}ms  rms ${(Math.sqrt(sumErr / cnt) / SR * 1000).toFixed(2)}ms  final ${(finalErr / SR * 1000).toFixed(2)}ms`);
  if (opts.verbose) console.log('  ', vlog.join(' '));
  return dec;
}
run('steady 1x', t => 1, 2, { verbose: false });
run('steady 1x inverted', t => 1, 2, { invert: true });
run('steady 1x quiet (-40dB)', t => 1, 2, { gain: 0.005 });
run('baby scratch 4Hz ±1.5', t => 1.5 * Math.sin(2 * Math.PI * 4 * t), 3);
run('baby scratch inverted', t => 1.5 * Math.sin(2 * Math.PI * 4 * t), 3, { invert: true });
run('fast scratch 8Hz ±3', t => 3 * Math.sin(2 * Math.PI * 8 * t), 3);
run('scribble 15Hz ±2', t => 2 * Math.sin(2 * Math.PI * 15 * t), 2);
run('slow drag ±0.1', t => 0.1 * Math.sign(Math.sin(2 * Math.PI * 0.5 * t)), 4);
run('very slow ±0.03', t => 0.03 * Math.sin(2 * Math.PI * 0.3 * t), 4);
run('stop & hold', t => t < 0.5 ? 1 : t < 1.5 ? 0 : 1, 2.5);
run('spinback -6x', t => t < 0.3 ? 1 : t < 0.8 ? -6 : 1, 1.5);
run('scratch w/ 1x offset', t => 1 + 1.8 * Math.sin(2 * Math.PI * 5 * t), 3);
run('fader cut (hard) static', t => 1, 2, { ampFn: t => (Math.floor(t * 8) % 2) ? 1 : 0 });
run('fader cut -50dB + scratch', t => 1.5 * Math.sin(2 * Math.PI * 4 * t), 3, { ampFn: t => (Math.floor(t * 16) % 2) ? 1 : 0.006 });
