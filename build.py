#!/usr/bin/env python3
"""Inline src/dsp.js + src/worklet.js into src/app.html -> index.html (single self-contained page)."""
from pathlib import Path
root = Path(__file__).parent
dsp = (root / 'src/dsp.js').read_text() + '\n' + (root / 'src/worklet.js').read_text()
assert '</script' not in dsp
(root / 'index.html').write_text((root / 'src/app.html').read_text().replace('/*__DSP__*/', dsp))
print('built index.html')
