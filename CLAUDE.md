# LiveSkratch: working rules

## Keep the web app and the iPhone/iPad app aligned

Sam wants the two apps to stay as close to feature-for-feature as possible. Whenever you add or change a feature, a default, a setting, help text or the WOW switching behaviour in one of them, make the same change in the other in the same piece of work, or say plainly what couldn't be carried over and why.

- Web app: `src/app.html`, `src/dsp.js`, `src/worklet.js`. Run `python3 build.py` to regenerate `index.html`.
- iOS app and AUv3: `ios/Core` (DSP, shared with the Linux tests), `ios/Shared` (UI, settings, help), `ios/App` (RemoteIO host, WOW drive), `ios/AUv3`.
- The DSP lives twice: `src/dsp.js` and `ios/Core/DSP.swift`. Change both.
- Help text and the first-time walkthrough live twice: `HELP` and `WALK` in `src/app.html`, and `ios/Shared/Help.swift`.
- WOW Normal/LiveSkratch switching lives three times: `WOW`/`toLiveSkratch`/`toNormal` in `src/app.html`, `ios/App/WowDrive.swift`, and `wow/scratcher-mode.command`. Normal mode always sets `fader_left = sample` and `fader_right = sample`.
- The built-in test loop is `renderTestLoop` (web) and `TestLoop.synthetic` (iOS).

Differences that are platform limits, not gaps:
- In the browser, more than 2 channels of audio in and out only work well in Chrome or Firefox.
- Switching the WOW from the browser needs the File System Access API (Chrome, Edge).
- The AUv3 plugin is iOS only.

## Tests

- DSP: `swiftc -O ios/Core/*.swift ios/Tests/main.swift -o /tmp/scratcher-tests && /tmp/scratcher-tests`
- Web: load `index.html` in headless Chrome (Playwright) and check for page errors.

## Commits

End commit messages with the attribution lines given in the session.
