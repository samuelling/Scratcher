const { F0, toneSample, ToneDecoder, ScratchEngine } = require('../src/dsp.js');
const SR=48000; const dec=new ToneDecoder(SR), eng=new ScratchEngine(SR); let th=0; const out=[0,0];
let nan=0, maxJump=0, prev=0; const lagLog=[];
for(let n=0;n<SR*4;n++){ const t=n/SR;
  const v = t<1?1 : t<1.5? 1.5*Math.sin(2*Math.PI*4*(t-1))-0.4 : 1;
  th+=2*Math.PI*F0*v/SR;
  const r=dec.process(0.445*toneSample(th));
  const live=Math.sin(2*Math.PI*220*t)*0.5;
  eng.step(live,live,r,1,out);
  if(!isFinite(out[0])) nan++;
  if(t>0.1){maxJump=Math.max(maxJump,Math.abs(out[0]-prev));} prev=out[0];
  if(n%(SR/4)==0) lagLog.push(`${t.toFixed(2)}s lag=${(eng.lag/SR*1000).toFixed(1)}ms ${eng.locked?'L':'-'}`);
}
console.log('nan',nan,'maxJump',maxJump.toFixed(3)); console.log(lagLog.join(' | '));
eng.setFrozen(true,2); for(let n=0;n<SR*3;n++){ eng.step(0,0,1,1,out); if(!isFinite(out[0])) nan++; } console.log('frozen lag', (eng.lag/SR).toFixed(2),'s nan',nan);
