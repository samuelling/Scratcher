# LiveSkratch

A live-input DVS for the **Headache Sound WOW** (Wow & Flutter machine). The WOW plays a control tone instead of music. LiveSkratch decodes the platter's motion from that tone and uses it to scratch **whatever audio is coming in right now**: a synth, a mic, a drum machine.

It comes in two forms:

- **iPad / iPhone app + AUv3 plugin** (`ios/`): native, lowest latency, full interface channel routing, a one-switch WOW setup screen, and an Audio Unit effect for AUM and other hosts.
- **Web app** for Chrome on a Mac, as a single self-contained page: **https://samuelling.github.io/Scratcher/**

## How it works

- **Tape.** Live input is written continuously into a 32-second ring buffer.
- **Needle.** A read head is driven by the decoded platter motion. Hands off at 1× and it rides just behind live, so you hear the input straight through. Pull back and you're scratching the last few seconds. Let go and it snaps back to live, or stays behind if you prefer that.
- **Freeze.** Stops the tape and loops the last N seconds, so you can scratch a captured phrase like a record.
- **Fader.** The WOW's own crossfader becomes LiveSkratch's fader, read one of two ways:
  - **Pilot tone (recommended).** In the WOW's `wow_settings.txt`, set `fader_left = beat` and `fader_right = beat`, and put the pilot in the `beats` folder (or let `wow/scratcher-mode.command` do all of this). The fader then cuts an 18 kHz pilot tone whose level is the fader position, while the control tone is never cut, so the platter stays tracked through every cut. Two wide notches remove the pilot before decoding. A low-pass would rotate the 3rd harmonic's phase and flip direction above about 2×. Calibrate measures the pilot's exact frequency and level.
  - **Tone level.** The fader cuts the control tone itself. It's simpler, but platter motion is invisible while the fader is closed.
- **Virtual fader.** An on-screen cut fader with cut-in, curve and hamster settings, used alone or together with the WOW's fader.

## The control tone

A 1500 Hz sine whose **loudness** follows a lopsided triangle (in log amplitude): it rises over 32 ms of file and falls over 8 ms, repeating 250 times over a 10 s seamless loop.

- **Speed** comes from zero-crossing timing (median of recent half-periods).
- **Direction** comes from the loudness trend. A slow rise or a fast fall means forward; a slow fall or a fast rise means backward. The rate is compared with what's expected at the current speed. The loudness is measured over exactly one carrier cycle, so the carrier's own ripple cancels.
- **Why loudness, not waveform shape:** diagnostic recordings showed that the WOW plays reverse with the fine waveform still running *forward*. File position goes backward smoothly, but every millisecond-scale snippet is forward-shaped. Any shape-based scheme (a phased harmonic, a sawtooth waveform) therefore always reads "forward" on the WOW. Loudness follows file position, so it reverses correctly. The cost is about 10–15 ms of direction latency at turnarounds.

`test/test_wow.js` checks the decoder against both true reverse and WOW-style reverse.

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
test/           test_wow.js: accuracy under true and WOW-style reverse; test_pilot.js: tracking through pilot-fader cuts; test_engine.js
```

Run `python3 build.py` after editing anything in `src/`.


## Control signals: WOW tone or stereo timecode

- **WOW tone (mono).** The WOW has a mono output, so it plays the LiveSkratch tone described above.
- **Stereo timecode.** Serato or Traktor control vinyl and CDs, or `wow/00-liveskratch-timecode.wav` (a copyright-free 1 kHz quadrature pair) played by an SC-1000 / SC-500. The two channels carry the same carrier a quarter-cycle apart, so the pair traces a circle whose angle is the position within a cycle and whose turning direction is the platter's. LiveSkratch scratches live audio rather than a track, so it needs only speed and direction: a relative-mode decoder that ignores the position bits works with any such timecode. Calibrate finds the exact carrier (1 or 2 kHz), the left/right balance and the direction. Simulated scratches track within 0.3–3.4 ms, against 15–38 ms for the mono WOW tone.

The on-screen fader is a tap pad by default, like a PT01's cut switch (touch cuts, or touch opens); the slider is still available.

## iPad / iPhone (ios/)

Open `ios/LiveSkratch.xcodeproj` in Xcode 16+, pick your iPad, and press Run. Two targets:

- **LiveSkratch**, the app. Pick the WOW's input channel, the live audio channel(s) and the output pair under *Audio routing*. With nothing plugged in it scratches a built-in loop (synthesised "ahhh" and "fresh" stabs over a beat); *Load loop…* swaps in any audio file and keeps it as the default.
- **LiveSkratchAU**, an AUv3 effect ("Sam Ling: LiveSkratch"). In AUM, make a stereo channel from two interface inputs, the WOW on the left and the live audio on the right, and insert LiveSkratch. Crossfader, cut, freeze, jump-to-live, gain and source are host parameters you can map to MIDI.

**WOW setup without Terminal.** Plug the WOW into the iPad, open *WOW setup*, choose the WOW's drive in Files once, then flip *Normal / LiveSkratch*. The switch edits `wow_settings.txt` (keeping its alignment and line endings), swaps the tone files in, and parks your own beats and samples in a `LiveSkratch/` folder on the WOW, with a backup of your settings, so switching back works from any device. It also recognises a WOW switched by `wow/scratcher-mode.command`.

Layout: `ios/Core` is the DSP (a line-for-line port of `src/dsp.js` and `src/worklet.js`, no allocation on the audio thread), `ios/Shared` the settings, UI and loop code both targets use, `ios/App` the RemoteIO host and WOW setup, `ios/AUv3` the plugin. The DSP has command-line tests that also run on Linux:

```
swiftc -O ios/Core/*.swift ios/Tests/main.swift -o /tmp/liveskratch-tests && /tmp/liveskratch-tests
```
