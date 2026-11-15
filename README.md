# Scratcher

A live-input DVS for the **Headache Sound WOW** (Wow & Flutter machine). The WOW plays a control tone instead of music. Scratcher decodes the platter's motion from that tone and uses it to scratch **whatever audio is coming in right now**: a synth, a mic, a drum machine.

It runs in Chrome as a single self-contained page: **https://samuelling.github.io/Scratcher/**

## How it works

- **Tape.** Live input is written continuously into a 32-second ring buffer.
- **Needle.** A read head is driven by the decoded platter motion. Hands off at 1× and it rides just behind live, so you hear the input straight through. Pull back and you're scratching the last few seconds. Let go and it snaps back to live, or stays behind if you prefer that.
- **Freeze.** Stops the tape and loops the last N seconds, so you can scratch a captured phrase like a record.
- **Fader.** The WOW's own crossfader becomes Scratcher's fader: the control tone's level gates the output.

## The control tone (mono)

`s(θ) = cos θ + 0.3·cos(3θ + 90°)` at 1500 Hz.

- **Speed** comes from zero-crossing timing (two crossings per cycle, sub-sample interpolated).
- **Direction** comes from the sign of `E[x·(dx/dt)³]`. It flips when the platter reverses, it's independent of gain and speed, and because only odd harmonics are present it's **unaffected by polarity inversion** anywhere in the signal chain.
- **Turnarounds** are caught as a mirror-symmetric lobe (statistic ≈ 0) and counted as zero net travel. That keeps baby scratches and scribbles from drifting.

Load `scratcher-control-tone-29s.wav` (48 kHz, 16-bit) into the WOW's `samples` folder. WOW samples are capped at 30 s. Set the WOW's beat/sample balance **fully to sample**.

## Setup

1. WOW out → interface input. Live source → another input.
2. Open the page and press **Start audio**. Pick the control input and channel, the live input, and the output.
3. Motor on, hands off, fader open → **Calibrate**.
4. Scratch. <kbd>Space</kbd> jumps to live, <kbd>F</kbd> freezes, hold <kbd>C</kbd> for a keyboard cut.

To try it without the WOW, set the control source to **Virtual platter** and drag the record with the mouse. The built-in test loop gives you something to scratch.

## Dev

```
src/dsp.js      decoder + scratch engine (shared by the worklet and the tests)
src/worklet.js  AudioWorklet processor
src/app.html    UI; build.py inlines the DSP into index.html
test/           node test/test.js — decoder position accuracy across scratch gestures
```

Run `python3 build.py` after editing anything in `src/`.
