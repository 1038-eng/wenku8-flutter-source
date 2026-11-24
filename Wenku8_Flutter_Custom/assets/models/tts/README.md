# Offline TTS model assets (not stored in Git)

The Kokoro int8 model files are ~206MB unpacked (model.int8.onnx alone is
114MB, above GitHub's 100MB per-file limit), so they are **not committed**.
Download and place them here before building:

```bash
curl -L -o kokoro.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2
tar -xjf kokoro.tar.bz2
cp -r kokoro-int8-multi-lang-v1_1/. assets/models/tts/kokoro/
```

Expected files under `assets/models/tts/kokoro/`:
`model.int8.onnx`, `voices.bin`, `tokens.txt`, `lexicon-us-en.txt`,
`lexicon-zh.txt`, `phone-zh.fst`, `number-zh.fst`, `date-zh.fst`,
`LICENSE`, `README.md` (plus optional `espeak-ng-data/`).

License: Apache-2.0. Male voice sid 59 (`zm_010`), female sid 3 (`zf_001`).

See `操作手册_补充.md` for the complete build and verification steps.
