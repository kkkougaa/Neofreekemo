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

## Draft v2

- Cheek triangles filled, paw cut out (wrist pivot) for waving, nose at 78%.
- `rig3.py`: the engine (14-bone spine with a settable root direction, gravity
  and stiffness, free root and floor for falling; bones for ears, fur, phone and
  paw; ten expressions with eye shapes, lid tilt and ear poses).
- `scene3.py`: the v2 review video (greeting wave, phone, facing-side bubble,
  expression sheet, climbing the pill ends to look at the clock and battery,
  falling and reuniting by a goo thread, music mode on a wide island).
- `sheet.py`: the close-up expression sheet.

## Draft v3

- Body drawn on a shared-vertex mesh along the spine (`Rig.warp`), so bends never
  open cracks; parts are placed with the same mesh mapping. In the app this maps
  to SpriteKit's `SKWarpGeometryGrid`.
- `meniscus.py`: liquid junction where the body leaves the island: concave
  Bezier fillets tangent to the pill outline (flat middle, round ends) and to the
  body edge (`edges.json`), plus a solid neck.
- Stretchy-arm wave; only "sleepy" kept among the new expressions; no climbing.
- `sceneA.py`: island close-up (the review video).
- The falling sequence was tried and dropped; it is not part of the design.
