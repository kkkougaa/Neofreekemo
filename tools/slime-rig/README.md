# Slime rig draft (not shipped)

Prototype for the character hanging from the Dynamic Island, rendered to video
for review before it goes into the tweak. Nothing here is built into the app.

- `render.py` draws the polygon logo SVG; `slime3.py`, `segment.py`, `parts.py`
  find the character, its face holes and the parts (ears, phone, face).
- `export2.py` writes the part images (`slime_*.png` in the BHTwitter bundle,
  upside down) and `slime_meta.json` (pivots, tips); `contour.py` writes the
  119-point outline used for the shape morph (`contour.json`).
- `rig2.py`: 14-bone Verlet spine, two-bone ears, six fur tufts, phone,
  expressions, blink. `goo.py`: puddle -> gather -> stretch -> morph sequence.
- `video.py` renders the review video frames (encode with ffmpeg).

The scripts expect a scratch directory with the intermediate pickles; run them
in the order above.
