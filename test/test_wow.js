// Decoder vs two models of the WOW's playback:
//  'true'    — plain variable-speed interpolation (waveform genuinely reversed)
//  'fwdfine' — what the real WOW showed: fine structure always runs forward at |v|, loudness follows file position
const { F0, toneSample, toneLogAmp, ToneDecoder } = require('../src/dsp.js');
const SR = 48000, FSR = 44100, L = FSR * 10;
const tab = new Float32Array(L); for (let i = 0; i < L; i++) tab[i] = 0.89 * toneSample(2 * Math.PI * F0 * i / FSR);
const rd = p => { p = ((p % L) + L) % L; const i = Math.floor(p), f = p - i; return tab[i] + (tab[(i + 1) % L] - tab[i]) * f; };
function run(vf, dur, mode) {
  const d = new ToneDecoder(SR); let P = L / 2, ph = 0, truth = 0, p0, t0, maxE = 0, bad = 0, N1 = 0;
  const warm = 0.3 * SR, N = dur * SR + warm;
  for (let n = 0; n < N; n++) {
    const v = n < warm ? 1 : vf((n - warm) / SR);
    P += v * FSR / SR;
    let x;
    if (mode === 'true') x = rd(P);
    else { ph += 2 * Math.PI * F0 * Math.abs(v) / SR; x = 0.89 * Math.exp(toneLogAmp(2 * Math.PI * F0 * P / FSR)) * Math.sin(ph); }
    d.process(0.4 * x + (Math.random() - 0.5) * 2e-4); truth += v;
    if (n === warm) { p0 = d.posInt; t0 = truth; }
    if (n > warm) { maxE = Math.max(maxE, Math.abs((d.posInt - p0) - (truth - t0))); if (Math.abs(v) > 0.3) { N1++; if (d.dir !== Math.sign(v)) bad++; } }
  }
  return `${(maxE / SR * 1000).toFixed(1).padStart(6)}ms ${(100 * bad / Math.max(1, N1)).toFixed(1).padStart(5)}%`;
}
const G = {
  'steady 1x': [t => 1, 2], 'stop & hold': [t => t < .5 ? 1 : t < 1.5 ? 0 : 1, 2.5],
  'baby ±1.5 @4Hz': [t => 1.5 * Math.sin(2 * Math.PI * 4 * t), 3], 'slow drag ±0.3': [t => 0.3 * Math.sign(Math.sin(2 * Math.PI * 0.7 * t)), 3],
  'fast ±3 @8Hz': [t => 3 * Math.sin(2 * Math.PI * 8 * t), 3], 'scribble ±2 @15Hz': [t => 2 * Math.sin(2 * Math.PI * 15 * t), 2],
  'rewind -2.5x': [t => t < .3 ? 1 : t < 1.8 ? -2.5 : 1, 2.5], 'spinback -6x': [t => t < .3 ? 1 : t < .8 ? -6 : 1, 1.5],
  'scratch on 1x': [t => 1 + 1.8 * Math.sin(2 * Math.PI * 5 * t), 3],
};
console.log('gesture'.padEnd(20), '   true reverse     WOW-style reverse   (max position error, % wrong direction)');
for (const [k, [f, dur]] of Object.entries(G)) console.log(k.padEnd(20), run(f, dur, 'true'), '   ', run(f, dur, 'fwdfine'));
