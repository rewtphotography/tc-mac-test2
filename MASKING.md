# Masking: handover

Written at the end of the final masking round (alpha 15) for a session that has none of the
earlier context. **Spec v6 (alphas 17 and 18) was reverted**: the code is alpha 16's, plus
spec v7's two colour tools (alpha 19). Section 17 says what v6 was and why it went; section
18 is v7. Everything else here describes the code as it is. `CLAUDE.md` has the project's rules and `docs/NOTES.md` the history, release
by release; this file is the state of masking as it stands, how it works, what every number
is, and what is next. The owner's specifications are in `docs/specs/` (v2 to v5, in order;
each later one wins where they disagree).

**Read first: what could and could not be checked.** The owner's photos are never in this
repository or its build. Masking is developed against eight "proxies" the owner exported
(2048 px on the long edge, from 4672×7008 raws), kept only in a session's scratch space.
The app works at full size, three and a half times larger, and several faults only exist at
that scale. In the final round the full-size pipeline was rebuilt on **stand-ins**: each
proxy enlarged to 4672×7008 in linear light ("soft": every edge about five pixels wide,
like a hand slightly out of focus), and the same with every edge drawn back to about two
pixels by a shock filter ("sharp": like an in-focus edge, but with cartoon texture). The
model's tile answers on them are what it gives in the app, since it is shown the same
pixels either way. Everything below marked "on the stand-ins" was seen there and nowhere
else. **Nobody has seen alpha 15 on a real photo.** The first job of the next session is to
read the owner's alpha 15 log and, if anything is off, ask for a debug bundle: it now holds
full-size crops (see "Debug bundle").

## 1. What the feature is

In Edit mode, **Mask (Test)** at the bottom of the pane: Make Mask finds the photo's
subject and makes a soft mask of it; Show offers ways of looking at it (Background −3 EV
is the one edges are judged in, at 200–400%); Subject, Background or Skin can then be
given Exposure, Saturation and Warmth. Three tools refine a mask by hand: **Refine Edges**
(drag a box), **Refine Hair** (paint), **Clean Edge** (paint), and since alpha 19 **Remove
Colour** (eyedropper, then a box: section 18). Option with any of them puts the automatic
mask back. Every mask and every Refine Edges box ends with **edge colour from inside**
(section 18). Masks last until the folder is closed; nothing is saved with
the photo yet. Export 16-bit TIFF includes the adjustments.

A mask is two pictures the size of the photo (`MaskResult`, `Masking.swift`):
- `alpha`: how much of each pixel the subject covers, 8 bits.
- `shares`: for each of red, green and blue, how much of the pixel's *light* is the
  subject's. Equal to alpha away from edges. At an edge a pixel that is half a dark
  sleeve and half a white wall gets nearly all its light from the wall; its shares are
  near zero though its alpha is a half. Adjustments blend through the shares
  (`Masking.apply`), so darkening the background takes the wall's light out of that pixel.
  On Black and On White use both: the photo times shares, plus the plain colour times
  (1 − alpha).

## 2. Code map

`Sources/TraincullCore/Matting/` has no UI, runs on Linux, and is where the arithmetic is:

| File | What is in it |
|---|---|
| `Planes.swift` | `Gray` (a plane of floats; `sample`, `resized`, `fitted` = area-averaged shrink), `Photo` (8-bit RGBX), `PixelRect`, `Buf`, `PlaneMath` (box blur, min/max filter, distance transform), `parallelRows` |
| `Sharpness.swift` | `SharpnessMap`: how blurred each part of the proxy is, and of each face |
| `SubjectSelect.swift` | `SubjectRules` (every first-pass number), `SubjectSelect.keep` (which pieces of the model's answer are the subject), `SubjectChoice` (which face) |
| `CloseUps.swift` | `CloseUps.tiles` (the close-up grid), `edgeZone`, `Canvas` (tiles merged with feathered weights; `seamRatio`), `BodyPose` |
| `Matte.swift` | `MatteSettings` (every edge number), `Matte` (the edge engine), `MatteOutput`, `EdgeQuality`, `MatteTier` |
| `EdgePlace.swift` | **New in alpha 15.** `EdgeOffset`, `Matte.edgePoints` (the photo's own edge measured along the mask's), `Matte.recentre`, `Matte.edgeOffset` |
| `ClosedForm.swift` | closed-form matting (the Max tier; used only by Refine Hair's colour-matting path and the Debug hair tiers) |
| `Oklab.swift` | Oklab from linear RGB, chroma, hue difference, distance |
| `Skin.swift` | the skin mask |
| `InsideColour.swift` | **Alpha 19.** Edge colour from inside: `InsideColour.field` (depth, nearest solid source), `median3`, `shares`, `rimColour`, `isRim`, `apply` (tiled) |
| `RemoveColour.swift` | **Alpha 19.** `Refine.removeColour`, `RemoveColourSettings`, `Refine.hairZone` (the engine's zone, per pixel) |
| `Refine.swift` | the three tools' arithmetic: `Refine.edges`, `.hair`, `.clean`, `.restore`, `.paste`, `RefineStroke`, `CleanSettings`, `RefineContext`, `RefineResult` |

`Sources/TrainCull/` is the Mac app (compiled only by the build):

| File | What is in it |
|---|---|
| `Models.swift` | `BundledModels`, `BiRefNetModel.shared` (subject) and `.matting` (hair), load, unload, `segment` |
| `Masking.swift` | `Masking.base` (faces, sharpness, pose, the model passes), `birefnetPass`, `make`, `result`, the caches, `debugBundle`, `apply` (how a mask is used when rendering) |
| `Refining.swift` | `MaskTool`, `RefineOp`, `RefineUndo`, `Masking.look` (a model shown one area, in one pass or tiles), `Masking.refine`, `Masking.undone` |
| `Session.swift` | the switches (`edgeSnap`, `decontamination`, `colourGuard`, `edgeRecentre`, …), `makeMask`, `applyTool`, `undoTool`, `refined` (each photo's automatic mask, list of operations and undo data), model lingering |
| `LocalPane.swift` | the Mask (Test) panel and its Debug group |
| `HeroView.swift` | the large image; `tool`, `marks`, `onBox`, `onStroke`, `drawTools` |
| `Log.swift` | the log and its JSONL copy; `JobMeter` (time and memory of a job) |

Tests: `Tests/TraincullCoreTests` (Linux and Mac; 117 tests, synthetic pictures only; v7's in `SpecV7Tests`) and
`Tests/TrainCullTests` (Mac build only: runs both Core ML models on made-up pictures).

## 3. The pipeline, stage by stage

Sizes are for the owner's 4672×7008 photos. "Proxy" is the photo at 2048 px on the long
edge (1365×2048).

1. **Neutral render** (`Masking.neutral`): the raw developed with Apple's defaults and
   the camera's white balance, none of the frame's edits. Kept for the last three photos.
2. **Faces, sharpness, primary subject** (`Masking.base`, `SubjectChoice.rank`,
   `SharpnessMap`): faces from Vision; the sharpness map from the proxy; the primary face
   by size and sharpness.
3. **Body pose** (`Masking.bodyPoses`, Vision): limbs of the primary person, so that a
   sharp forearm is never dropped by the selection rules.
4. **Whole-frame pass** (`birefnetPass`): the proxy squashed to 1024×1024, BiRefNet_HR,
   answer stretched back to the proxy.
5. **Selection** (`SubjectSelect.keep`): connected pieces of the answer are kept if they
   are the primary's, attached, or as sharp as the face allows (Focus strictness); small
   specks go, small holes are filled.
6. **Close-up tiles** (`CloseUps.tiles`, `Canvas`): square tiles over the subject's box
   (side at most half the box's longer side, at most 1024 proxy px, 25% overlap, at most
   eight), each cut from the *full-size* photo, squashed to 1024², run through the model.
   Their answers are merged with weights that fade over 24 px at tile borders, and replace
   the whole-frame answer only within about 16 proxy px of its edge (`edgeZone`). The
   result, "the first pass" or m0, is kept at half the photo's size (2336×3504).
   **One model pixel is 1.9 to 3.4 photo pixels here** (`SubjectBase.firstPassPixel`).
7. **The edge engine** (`Matte`, at the photo's full size, only in a band round the edge):
   - *Setup* (`prepare`, `classify`): a quarter-size three-way split (certain subject,
     certain background, uncertain band); the hair zone (a box round each head, outside
     the oval of the face); quarter-size colour fields F̂ and B̂ (the nearest certain
     subject and background colours, spread by push-pull).
   - *Enlarge* (`snap`): the first pass sampled bilinearly at full size; values within
     0.06 of 0 or 1 taken as 0 or 1 ("haze").
   - *Re-centre* (`recentre`, **new**): see section 4.
   - *Colour snap* (`colourSnap`): within ±4 px of the edge, away from hair, each pixel's
     alpha moves towards where its colour sits on the line from B to F in linear light,
     as far as the two colours can be told apart (`Matte.apart`) and by at most 0.6;
     then a 2 px guided filter as far as the snap acted.
   - *Finish* (`finish`): alpha written out; colour shares from `Matte.shares` for edge
     pixels, including the inner tail (section 4); in the hair zone, the Debug hair tiers'
     colour matting if one is chosen (Off is the default and what the owner uses).
   - *Colour guard* (`guardColour`): chroma, hue and lightness checks on every pixel
     with shares of its own (section 5).
   - *Metrics* (`edgeQuality`, `edgeOffset`): section 6.
8. **Skin** (`SkinMask`): from skin colour learned at the cheeks and nose.
9. **Tools** (`Masking.refine`): each works on a patch of the photo, decides a new mask
   there, runs the same engine on the patch (so shares and the guard apply), and lays the
   result in through the box's or stroke's soft edge (`Refine.paste`).
   - *Refine Edges*: the box grown 15%, shown to BiRefNet_HR (one pass; then in tiles of
     up to 1536 px if the area is over 1840 px across); only pieces touching the present
     mask are kept; pockets of background inside the box opened on strong evidence only;
     if the subject runs off the area it grows, up to four times or six seconds.
   - *Refine Hair*: the stroke's bounds grown 20%, shown to BiRefNet-matting; its matte
     replaces the mask under the stroke and is not moved by the engine. Or colour matting
     (closed-form) when the backdrop is plain and unlike the hair (`Refine.hairMethod`);
     on the test photos that never applies. Debug can force either.
   - *Clean Edge*: under the stroke, within 5 px of the present edge, each pixel is
     assigned by its colour (and a little by focus) against the colours either side; then
     the engine re-centres it.

## 4. What changed in the final round, and why (alpha 15)

The owner's report on alpha 14: a pale rim three or four pixels wide round every finger,
arm and waist in Background −3 EV, and colour still being added on 6303. Traced on the
stand-ins, on 6303's index finger. Alpha at given distances from the true edge (negative is
inside the subject), averaged over about 1,550 edge points, sharp stand-in:

| Stage | −6 | −4 | −2 | −1 | 0 | +1 | +2 | +3 | +4 | 0.5 line at |
|---|---|---|---|---|---|---|---|---|---|---|
| The photo's own coverage (from its colours) | 1.00 | 1.00 | 0.99 | 0.89 | 0.53 | 0.13 | 0.01 | 0.00 | 0.00 | 0 |
| 1 Model answer, 1 px = 3.2 photo px | 0.98 | 0.94 | 0.78 | 0.61 | 0.44 | 0.28 | 0.15 | 0.07 | 0.04 | −0.34 ± 1.21 |
| 2 Enlarged smoothly | 0.98 | 0.93 | 0.76 | 0.61 | 0.45 | 0.30 | 0.17 | 0.09 | 0.05 | −0.32 ± 0.97 |
| 3 Tiles merged, kept at half size | 0.98 | 0.92 | 0.75 | 0.62 | 0.47 | 0.32 | 0.20 | 0.12 | 0.06 | −0.21 ± 0.98 |
| 4 Enlarged to full size | 0.98 | 0.92 | 0.75 | 0.62 | 0.47 | 0.32 | 0.20 | 0.12 | 0.06 | −0.21 ± 0.98 |
| 5 Haze + steepen ×2 | 0.99 | 0.99 | 0.93 | 0.74 | 0.44 | 0.17 | 0.04 | 0.01 | 0.00 | −0.21 ± 0.98 |
| 6 Colour snap + tidy = **alpha 14** | 0.99 | 0.99 | 0.96 | 0.82 | 0.46 | 0.13 | 0.02 | 0.01 | 0.00 | −0.14 ± 0.73 |
| 7 Re-centred (no snap) | 0.99 | 0.99 | 0.98 | 0.88 | 0.52 | 0.12 | 0.01 | 0.00 | 0.00 | −0.03 ± 0.78 |
| 8 Re-centred + snap + tidy = **alpha 15** | 0.99 | 0.99 | 0.98 | 0.86 | 0.48 | 0.11 | 0.01 | 0.00 | 0.00 | −0.09 ± 0.74 |

(Those rows were taken before the last adjustments to the step; the whole-photo figures in
section 7 are final.) What that and the pixel values showed:

1. **The model's edge is wide, and wanders.** One model pixel is 3.2 photo pixels; its
   transition is two and a half model pixels, so about 8 photo pixels against a real
   edge of 2 to 5. Its half-way line is within half a pixel of the true edge on average
   (the segmentation model sits a third of a model pixel further out than the matting
   model on the same picture), but more than 1.5 px off on a quarter to a half of the
   edge. Half-size storage and the two enlargements move it by about 0.1 px: not the
   cause. Nothing takes a maximum of base and tiles; there is no outward feather.
2. **Steepening by a fixed ×2 leaves the edge half as wide again as the photo's**, and
   the colour snap is centred on the model's line with its weight fading to nothing 4.5
   px away and a cap of 0.6: it could not pull back the stretches that were 2–3 px out.
3. **The visible rim is mostly light, not coverage.** On 6303 the wall behind the finger
   is near white (linear 1.0, 0.92, 0.69) and the finger's edge is in shadow (luminance
   0.06). The three pixels just inside the edge are 80–95% finger and still two to three
   times brighter than the finger, from the wall's light. Their alpha is ≥ 0.95, where
   decontamination was switched off, so they stayed bright when the wall was darkened:
   0.19, 0.15, 0.10 beside a wall at 0.115 and a finger at 0.06. That is the pale rim.
4. **The subject colour was read too far in.** F̂ comes from certain pixels a dozen or more
   pixels inside the edge, where a finger is lighter than at its shaded edge; against it,
   an edge pixel reads as "all subject" and is not cleaned.
5. **Bright pairs failed the contrast gate.** Skin against a pale wall are far apart but
   both bright; the proportional measure the snap and the shares used scored them a third.

What was built (all in `Matte.swift` and `EdgePlace.swift`; the Debug switch **Edge
re-centre** turns 1–3 off):

1. **`edgePoints`**: along the mask's half-way line, at each pixel, a line straight across
   the edge is sampled in the photo at half-pixel steps, in **linear light**, three lines
   abreast. The strongest colour change within reach is the photo's edge. It gives: the
   signed offset; the photo's edge width (rise over steepest slope) and the mask's; the
   colours either side, taken clear of the blur; and a confidence (strong enough, and
   standing out from the ends of the line). Linear light because a lens blurs evenly
   either side of an edge there; in display values the steepest point sits about half a
   pixel towards the darker side.
2. **`recentre`**: those are gathered at quarter size, smoothed along the edge (twice
   over about ten photo pixels), points more than 1.5 px from their neighbours' consensus
   dropped, and then every band pixel takes the mask's value from "offset" pixels across
   the edge and is steepened by mask width over photo width (or widened by a short blur
   across the edge where the photo's edge is the wider). Not in the hair zone, and scaled
   down out of focus. Where nothing could be measured the old ×2 stands.
3. **Edge-local colours** (`fEdge`, `bEdge`): where an edge was measured, the colours
   read beside it replace F̂ and B̂ for the snap, the shares and the guard.
4. **Inner tail** (`finish`, `innerTail`): pixels with alpha ≥ 0.95 within about eight
   pixels inside the edge get colour shares too, if their colour says they are at least
   70% subject (`tailCoverage`; less and it is a cuff or a highlight, left alone).
   Barely-covered pixels (alpha under 0.1) may only lose light through the shares.
5. **`Matte.apart`**: colours count as distinct if they are so in proportion *or* differ
   by 0.45 outright (`colourPlain`); the outright floor (0.10–0.25) that keeps the snap
   off black boots on dark asphalt is unchanged.
6. **`Matte.shares` splits what is off the line.** A pixel's light is its subject part
   plus its background part. What it has beyond that model (texture, grain) now goes to
   whichever side supplies most of the pixel's light. Before, all of it went to the
   background: on a bright subject against a dark ground that made the "background's
   light" a dim, strongly coloured remainder, which is what the colour guard kept
   catching on 6303 (3,000 of its 5,125 corrections were "for its brightness", all on
   the subject-darkened side).
7. **`blownOut`** now starts at 0.93 of clipping, not 0.80: a pale green wall at 0.89 is
   not clipped, and treating it as lost left its green in the edge.
8. **The guard's lightness bound** (priority 2c): section 5.

## 5. The colour guard

`guardColour` looks at every band pixel whose shares are its own (not plain alpha).
- **Chroma and hue** (spec v5): the pixel is composited with the background three stops
  down, and with the subject three stops down, and each is compared in Oklab with the
  photo's pixels within two pixels and with the edge's two colours. More chroma than
  the most of those (+0.02), more chroma for its brightness than 1.25× the most (+0.02),
  or a hue more than 15° from all of them: the three shares are replaced by one
  (luminance-weighted). Logged as "colour guard: N of M … (more colourful outright a, for
  its brightness b, hue with the background darkened c, with the subject darkened d)".
- **Lightness** (new): the subject's own colour as the pixel implies it is (pixel ×
  shares) ÷ coverage, where coverage is alpha, or what the pixel's colour says if that is
  more and the colours are distinct. Its luminance must lie between the pixel's and the
  subject colour's beside the edge, within 4% (`guardLightness`). Below: the shares are
  scaled up together (never so far that a channel passes 1). Above: scaled down
  (`guardLighter`). Logged separately: "lightness: N … raised, M … lowered".
  **The "raised" count is not a count of faults.** An inner-tail pixel that is 90%
  subject gets shares that make it 0.9 of the subject's brightness, which is physically
  right; the bound brings it to 0.96. Tens of thousands are normal. "Lowered" should be
  small; large numbers there mean the shares are claiming more light than alpha explains.

## 6. Every metric in the log, how it is computed, and what it can't see

| Log text / JSON field | How | Blind spots |
|---|---|---|
| `halo 0–3 px` / `3–10 px`, hair and elsewhere (`halo_near_*`, `halo_*`) | mean final alpha in rings just outside the snapped edge, measured at half size | Rings are counted from the mask's own edge: **a mask that is uniformly too large reads clean.** The 0–3 ring is mostly the edge's own softness. |
| `erosion …` | the same inside: mean (1 − alpha) | as above |
| `colour fringe a → b` (`colour_fringe`) | away from hair, where the two colours are distinct: mean distance between alpha and where the pixel's colour puts it, before and after the snap | Only as good as the colour fields; says nothing where colours are alike. The hair zone's border is reported apart. |
| `colour guard: N of M` (`colour_guard_corrections`) | section 5 | M now includes inner-tail pixels, so it is several times alpha 14's. |
| `lightness: … raised, … lowered` (`lightness_corrections`) | section 5 | "Raised" is mostly by design. |
| `edge placement: edge offset +x px (mean size y, z% over 1.5 px) · edge width a px, the photo's b px · from n clear edge points of m` (`edge_offset`, `edge_offset_size`, `edge_offset_far`, `edge_width`, `photo_edge_width`, `edge_points_measured`) | `edgeOffset(of:)`: `edgePoints` on the *final* alpha; mean signed distance from the photo's strongest change to the mask's 0.5 line. **Positive: the mask reaches beyond the true edge. Negative: inside the subject.** Only points away from hair, in focus, with confidence over 0.5. Looks ±1.5 model pixels (4.5 to 12 px). | "Strongest change" is not always the subject's edge: a dark outline, a nail, a seam within reach can win. Edges whose two sides are alike are not measured at all (the count says how many were). The mean hides stretches that cancel: read "mean size" and "% over 1.5 px" with it. Target: mean within ±0.5 px. `OFFSET?` is warned beyond that. |
| `first pass: edge offset …` (`first_pass_edge_offset`, `first_pass_edge_width`) | the same on the enlarged first pass, before anything is moved | |
| `re-centred: looked ±r px, mean move, mean steepening ×g` | what `recentre` applied | |
| `seam ratio` (`SEAM?` over 3) | steps across tile borders against steps half a tile in | |
| `decontaminated: N edge pixels … (K of them just inside the edge), mean shift` | pixels given shares of their own; K are inner-tail pixels | |

## 7. Status of the acceptance items (stand-ins; alpha 14's edge → alpha 15)

Signed edge offset, whole photo, sharp / soft stand-in (mean; % of edge points over 1.5 px):

| Photo | First pass | Alpha 14's edge | Alpha 15 | Colour guard (alpha 15) |
|---|---|---|---|---|
| 6303 | +0.64 / +0.34 (33% / 26%) | +0.37 / +0.19 (15% / 14%) | +0.05 / +0.07 (3% / 3%) | 278 of 149,645 / 1,318 of 175,102 |
| 6372 | +0.58 / −0.41 (51% / 26%) | +0.17 / −0.23 (14% / 14%) | +0.07 / −0.01 (5% / 3%) | 7,264 of 432,655 / 7,933 of 478,097 |
| 6378 | +0.81 / +0.58 (54% / 33%) | +0.27 / +0.07 (24% / 16%) | +0.02 / −0.13 (5% / 3%) | 1,761 of 615,684 / 2,020 of 664,235 |
| 6465 | +1.69 / +0.98 (57% / 55%) | +1.43 / +0.97 (46% / 48%) | **+0.60 / +0.45** (14% / 9%) | 0 of 98,520 / 2 of 108,899 |
| 6957 | +0.42 / +0.62 (27% / 32%) | +0.08 / +0.06 (4% / 10%) | +0.01 / −0.07 (1% / 2%) | 17 of 200,833 / 39 of 235,690 |
| 7006 | +0.55 / +0.36 (35% / 21%) | +0.34 / +0.19 (21% / 14%) | +0.08 / +0.03 (6% / 4%) | 542 of 196,842 / 1,568 of 250,660 |
| 7451 | +0.04 / −0.33 (46% / 39%) | +0.37 / +0.13 (19% / 12%) | +0.11 / +0.11 (4% / 3%) | 19 of 209,149 / 35 of 209,165 |
| 7473 | not measurable (nearly all hair) | | | 28 of 1,142,785 / 19 of 1,132,670 |

Alpha 14's own guard on the same stand-in of 6303 corrected 6,299 of 57,859 (the owner's
real photo: 5,125 of 49,154), so the stand-ins behave like the real thing there.

| Item | Status |
|---|---|
| P1: no pale rim on 6303 fingers and sleeve | Gone on both stand-ins; a faint green tint remains on the soft one. **Not seen on the real photo.** |
| P1: 7451 waist and arm | Gone on both stand-ins. |
| P1: 6957 hand and waist | No rim on either before or after on the stand-ins (bright hand, dark room); unchanged. The owner sees one on the real photo: to check. |
| P1: no regression: 7473 hair at the window, footwear, selection | Unchanged on the stand-ins (the hair zone is not re-centred; selection code untouched). |
| P1: offset within ±0.5 px | Met on six of seven measurable photos; 6465 is +0.45 to +0.60 (its first pass is 1–1.7 px out on half its edge, more than the step can find reliably). |
| P2a: guard ≈ 0 | 0.01% to 1.7% of checked pixels, and many more pixels are checked now. On 6303: 278 to 1,318, where alpha 14's engine corrected 2,067 to 6,299 on the same stand-ins (6.5–11%). 6372 is highest (7,300–7,900, as before). Mostly "hue with the background darkened". |
| P2b: dark seam after Refine Hair on 6303 | Not reproduced as dark on the stand-ins (alpha 14 there left the edge slightly pale). The likely cause, the subject colour under a stroke being taken from far away, is removed: edge-local colours, the inner tail and the lightness bound now apply under the brush too. **To confirm on the real photo.** |
| P2c: lightness bound | Built, tested, logged separately. |
| P3a: large box "0 px changed" | **Not reproduced.** The engine's tiled path changes 20,000–56,000 px for the same box size on the stand-ins. `Masking.refine` now logs both counts and the share of the area the tiles call subject, and keeps the single look (with a `TILES?` warning) if the tiles change nothing. If it happens again that log line says where to look. |
| P3b: Clean Edge jagged | The decision's step is wider (0.15) and the engine now re-centres and width-matches the brush's result; smooth on both stand-ins. |
| P3c: Refine Hair never chooses colour matting | The contrast figure was saturated (it reached 1 at a tenth of its range); it is now the Oklab distance between the two average colours over 0.6. It reads 0.42 on 6303's fingers. **The two thresholds (contrast needed 0.5, backdrop busyness allowed 0.03) are uncalibrated**: real backdrops read 0.14–0.33 busy. They are in Debug and need tuning on the seamless-backdrop shots the owner has said they will supply. |

## 8. Models

| | Subject | Hair |
|---|---|---|
| Model | `ZhengPeng7/BiRefNet_HR` | `ZhengPeng7/BiRefNet-matting` |
| Licence | MIT | MIT |
| In the app as | `BiRefNet.mlmodelc` | `BiRefNetMatting.mlmodelc` |
| Input / output | 1024×1024 sRGB image / 1024×1024 mask | the same |
| Precision | weights and arithmetic 16-bit | the same |
| Size | about 400 MB each; the download is 822 MB | |

- **Conversion**: `tools/convert_birefnet.py convert <out> [side] [repo]`, in the build's
  Linux job (`.github/workflows/build.yml`, job `birefnet`; about eight minutes, cached on
  the script's hash). BiRefNet uses deformable convolution, which Core ML has no operation
  for; the script replaces it with the same arithmetic written with `grid_sample`
  (`deform_conv2d_gs`), checks that against torchvision's (`check`), then checks the whole
  patched model against the original before converting (parity 2·10⁻⁶ at 1024).
- **In the build**: `scripts/fetch-models.sh` compiles both on the Mac; they are copied
  into the app. **The app never uses the network**; the build fails if networking is linked.
- **Parity on the Mac**: `Tests/TrainCullTests` (`testBiRefNetFindsTheSubject`, IoU on a
  made-up disc; `testBiRefNetPipelineEndToEnd`; `testMattingModelLooksAndToolsLayBack`).
- **Run on**: CPU + GPU by default (Debug: Run model on). The first Neural Engine run
  takes minutes to prepare.
- Both models stay loaded for two minutes after leaving Edit (`Session.modelLingers`) and
  are dropped at once under memory pressure.

## 9. Memory and timing

From the owner's alpha 14 log (M3 Pro, 36 GB, 33-megapixel raws):
- A model pass: about 0.87 s warm; 1.5–2 GB while it runs.
- The app holds about **4.4 GB after tools** and peaks at **6.5 GB with both models
  loaded**.
- First Refine Hair stroke: **7–8 s cold** (the matting model loads), about **1.1 s warm**.
- A whole-frame subject is seven model passes (one whole frame, six tiles).

What is held: three neutral renders (131 MB each), three `SubjectBase`s, one `Matte` with
its own copy of the photo and band-sized buffers (300–400 MB for a full-frame band), each
mask's alpha (33 MB) and shares (131 MB), per-photo tool undo data.

Alpha 15's edge step costs more. On the four-core Linux machine used here the engine
went from 1.4–2.5 s to 2.0–3.3 s per photo (4.2 s for 7473). `edgePoints` runs twice (once
to re-centre, once for the log's figure on the finished mask); the second could be
dropped or made optional if time matters. Not measured on a Mac.

## 10. Every threshold, its default, where it lives

`MatteSettings` (`Matte.swift`). The app sets only the four Debug switches; everything
else is the default.

| Setting | Default | For |
|---|---|---|
| `foregroundThreshold` / `backgroundThreshold` | 0.97 / 0.03 | what counts as certain in the first pass |
| `bandIn` / `bandOut` | 0.02 / 0.06 of face height (4–64 px, 8–160 px) | the uncertain band's width at soft edges |
| `adaptiveBand`, `crispIn` / `crispOut`, `softEdge` | true, 2 / 3 quarter-size cells, 4 | a narrower band where the first pass's edge is crisp |
| `hairOnly` | true | colour-matting tiers only in the hair zone |
| `haze` | 0.06 | first-pass values this near 0 or 1 are 0 or 1 |
| `steepen` | 2 | steepening where the photo's edge can't be measured (and everywhere with re-centre off) |
| `recentre` | true | section 4 (Debug: Edge re-centre) |
| `recentreReach`, `recentreLeast`, `recentreMost` | 1.5 model px, 4.5 px, 12 px | how far either side the photo's edge is looked for |
| `recentreSmooth` | 3 model px | smoothing along the edge |
| `gainLeast` / `gainMost` | 0.3 / 6 | limits on mask width ÷ photo width (under 1 widens) |
| `edgeStrength` | 0.012 per px, linear light | a colour change counts as an edge from here, fully at 3× |
| `colourSnap` | true | (Debug: Edge snap) |
| `colourRing` | 4 px at 33 MP (scales with √MP, least 2) | the snap's ring |
| `colourLow` / `colourHigh` | 0.08 / 0.20 | proportional contrast gate |
| `colourFloor` / `colourFull` | 0.10 / 0.25 | outright difference gate (display values) |
| `colourPlain` | 0.45 | outright difference that passes whatever the proportion |
| `colourReach` | 0.6 | most the snap may move one pixel's alpha |
| `decontaminate` | true | (Debug: Decontamination) |
| `innerTail`, `tailCoverage` | true, 0.7 | section 4.4 |
| `costFalloff` | 50 | how fast trust in the shares falls with distance off the F–B line |
| `colourGuard`, `guardChroma`, `guardHue` | true, 0.02, 15° | section 5 (Debug: Colour guard) |
| `guardLightness`, `guardLighter` | 0.04, true | section 5 |
| `guardContrast`, `relaxGuards` | 0.6, false | guards on the hair tiers; off under the hair brush |
| `snapPasses`, `snapRadius`, `snapLow`, `snapHigh` | 0, 6, 0.3, 0.7 | the old brightness snap (off since alpha 13: it left edges jagged) |
| `snapSkipsBright`, `snapNeedsBackground` | false, 0 | spec v5 1.3, tried and left off (it put a rim back on 7451) |
| `contrastLow/High`, `guidedRadius`, `guidedEpsilon`, `rays`, `raySteps`, `distanceWeight`, `softPrior`, `hardPrior`, `laplacianEpsilon`, `maxIterations`, `tolerance`, `tileCore`, `tileApron` | see the file | the Fast, High and Max hair tiers |

Also in `Matte.swift`: `blownOut` (0.93–0.99 of clipping on any channel, 0.90–0.97 on
luminance); the hair zone's box (2.6 face widths × 3 face heights, centred a quarter of a
face height above the face's middle); the inner tail's reach (a box blur of radius 2
quarter-size cells at 33 MP: full to about 4 px inside the edge, none beyond about 10).

`SubjectRules` (`SubjectSelect.swift`): `feather` 24, `speckle` 0.0002, `hole` 0.00002
(floor 2 px), `attachDistance` 0.01, `sharpAllowance` 1.0, `focusStrictness` 1.0 (the
panel's Loose 0.6 / Moderate 1.0 / Strict 1.4), `unmeasuredArea` 0.02, `boxExpand` 0.10,
`mergeFraction` 0.05 and `mergePlus` 6 (tiles may change the mask within 0.05 × face
height + 6 proxy px of its edge), `tileCap` 1024, `tileLeast` 384, `tileOverlap` 0.25,
`tilesMost` 8, `capsule` 0.35, `poseConfidence` 0.3.

`CleanSettings` (`Refine.swift`): `strength` 1, `tightness` 0 (the two sliders),
`sharpnessWeight` 0.25, `colourWeight` 0.75, `step` 0.15, `reach` 5 px at 33 MP,
`growBar` 0.25.

Tools, elsewhere: box look area +15% (`Refine.lookArea(box:)`), stroke +20%; tiles when
the area is over 1840 px across, up to 1536 px each, at most 12 (`Masking.look`,
`wantsTiles`); pieces kept if they touch the mask or overlap 30% (`keepTouching`); paste
feather 6 px; patch margin max(96, long edge ÷ 16); box growth up to 4 times or 6 s;
gap opening (`openGaps`): Oklab distance to background under 0.05, to subject over 0.2,
enclosed 90%, at least 12 px and at most an eighth of the box; hair method: contrast
needed 0.5, busyness allowed 0.03 (`RefineOptions`, Debug sliders); colour matting under
a stroke limited to within 80 px (at 33 MP) of the edge on the subject's side.

`Masking.swift`: `proxyLongEdge` 2048, `keptNeutrals` 3, `keptBases` 3; `HALO?` warned
over 0.02, `OFFSET?` over 0.5 px. `Session.swift`: `modelLingers` 120 s.
`HeroView.swift`: `maxZoom` 4.

## 11. Debug switches, debug bundle, log format

**Debug group** (Mask (Test) → Debug): Hair tier (Off/Fast/High/Max; Off is the mask),
Edge re-centre, Edge snap, Decontamination, Colour guard, Edge colour from inside (each
remakes this photo's edge without the model and replays the tool operations), Hair method (Automatic / Colour
matting / Matting model) with its two threshold sliders, Legacy Vision mask, Run model on
(CPU + GPU / CPU + Neural Engine / All), Export Debug Bundle.

**Debug bundle** (`Masking.writeBundle`; a folder `<name>-maskdebug` next to the raw):
`proxy.png`, `faces.json`, `m0_birefnet.png` (after selection), `m0_final.png` (after
tiles), `final_alpha.png`, `F.png` (the subject through its shares, on black),
`sharpness.png`, `pose.json`, `regions.json` (subject box, tiles, tool boxes and strokes,
switches, crops), `README.txt`, and **new: `crop<n>_photo.png`, `crop<n>_alpha.png`,
`crop<n>_shares.png`**: up to four full-size pieces (1200 px square), one round each
place a tool was last used, or round the middle of the subject. **To have an edge looked
into on real pixels, ask the owner to draw a Refine Edges box over it and export.** With
those three pictures the composite the owner sees can be rebuilt exactly:
Background −3 EV is `linear(photo) × (shares + (1 − shares) ÷ 8)`.

**Log** (Help → Diagnostics shows the file): a text line per event, `HH:mm:ss.SSS  area
text`, and beside it a `.jsonl` with one object per line: `ts`, `level`, `category`
(`model`, `base`, `pose`, `mask`, `tool`, `cache`, `memory`, …), `message` (the text),
and `fields` where there are numbers. Fields on a finished mask (`category` "mask"):
`image`, `tier`, `seconds`, `edge_pixels`, the halo and erosion figures, `colour_fringe`,
`edge_offset`, `edge_offset_size`, `edge_offset_far`, `edge_width`, `photo_edge_width`,
`first_pass_edge_offset`, `first_pass_edge_width`, `first_pass_pixel`,
`edge_points_measured`, `colour_guard_corrections`, `lightness_corrections`. On a model
call: `call`, `what`, `input_side`, `units`, and `JobMeter`'s time and memory. On a tool
operation (`category` "tool"): `image`, `tool`, `method`, `restore`, `pixels_changed`,
`colour_guard_corrections`, `seconds`.

## 12. The test photos

Eight frames from one event, Sony a7 IV, 4672×7008. The owner refers to them by number.

| | What it tests |
|---|---|
| 6303 | peace sign held up beside the face against a pale, bright background: fingers, thumb, sleeve. The rim was reported here first. Subject fills the frame (six tiles, 3.2 photo px per model px). |
| 6372, 6378 | costume with a headpiece, long red hair, a rose; busy coloured background |
| 6465 | red braids, green dress; the first pass sits furthest out here |
| 6957 | navy suit in a dark room; an outstretched hand; blonde hair of someone behind at the waist |
| 7006 | crowd behind |
| 7451 | black top against a white wall; a narrow gap between arm and waist; black boots on dark asphalt (the snap must leave these alone) |
| 7473 | head and shoulders, curly hair against a bright window on one side and a brown room on the other. The hair at the window is "near perfect" and must not change. |

Photoshop's Select Subject masks for all eight are the owner's reference for *selection*
(solved since alpha 11: agreement 0.99). Edges are judged by eye in Background −3 EV.

## 13. Known issues

- **Nothing in alpha 15 has been seen on a real photo.** The stand-ins are softer or
  more cartoon-like than a real raw; real grain, lens fringes and sharpening halos are
  not in them. The edge-local colours and the inner tail do per-pixel colour arithmetic a
  few pixels inside the subject, bounded by `tailCoverage`, the trust in `shares` and the
  lightness bound; if a real photo shows mottling or flattened rim-light just inside an
  edge against a bright background, that is where to look (switch Decontamination off to
  confirm, then narrow `tailCoverage` or the tail's reach).
- **6465's edge** stays about half a pixel out on average.
- **Refine Edges on a soft (out-of-focus) edge** can still land a few pixels inside it in
  places: shown an enlarged blurry picture, the model draws a hard edge at the inner side
  of the blur, further than the re-centring looks. The base mask is better than the box
  there.
- **Strongly out-of-focus parts** keep the model's soft edge: no re-centring and no
  inner-tail cleaning (both are scaled by the focus map).
- **A faint green tint** remains along 6303's fingers on the soft stand-in.
- **With the subject darkened** instead of the background, a thin coloured line can show
  at bright-subject edges (6957's hand): the shares favour the subject's side.
- **Hair zone**: a box round each face. Long hair below it is treated as a plain edge;
  with no face the whole edge counts as hair and is neither snapped nor re-centred.
- **Refine Hair thresholds** are uncalibrated (section 7).
- The skin mask and the Zones view are not remade after a tool operation.
- The hair tiers (Fast/High/Max) under Debug are the old automatic colour matting, kept
  for comparison; the owner found they made hair worse (spec v4).

## 14. What was tried and did not work

- **Apple Vision as the subject source** (alphas 7–8): person segmentation takes in the
  people behind (41% extra area on crowd shots; IoU 0.77 against Photoshop). Kept behind
  Debug → Legacy Vision mask.
- **SAM 2.1** (alphas 9–11): selects parts, not wholes (it left out a headpiece that is a
  quarter of the subject); Apple's Core ML export always returns three answers and rates a
  part highest; a second pass on a box crop missed 24%. Removed with spec v3. BiRefNet
  with the sharpness rules scored 0.993.
- **BiRefNet at 2048**: selects the same subject as at 1024 (99.2–99.5% agreement), five
  times slower, four times the memory. Detail comes from tiles instead.
- **Automatic gap check** (spec v4 1.5): prototyped as specified (colour near the
  background's, far from the subject's, no sharp detail, enclosed). It flagged 17 regions
  on 6303 and 205 on 6372, among them a white sash. A plain costume has no detail either
  and the sharpness map is measured at edges. Gaps are opened only inside a Refine Edges
  box, on strict evidence.
- **Automatic defringe / per-channel decontamination** (alpha 13): each channel's share
  was nudged until that channel reproduced the pixel. The photos have a one-pixel green
  lens fringe on bright edges; on 7451 a fringe pixel got shares of 2% red and 15% green,
  a green line once the background was darkened. Replaced by the line fit in `shares`
  (alpha 14) and the split of the remainder (alpha 15). A separate automatic defringe was
  never built; the owner deferred it.
- **Brightness (guided-filter) snap** (alpha 12): switches on and off along an edge with
  how well brightness explains it, and left edges jagged in steps of a few pixels.
- **Skipping the snap beside blown-out backgrounds** (spec v5 1.3): left a light rim
  exactly where the owner sees one. The settings exist, off.
- **Automatic hair matting** (Fast/High/Max as the default): made hair worse on busy
  backgrounds; replaced by the Refine Hair brush.
- **In the final round**: measuring the photo's edge in display values (half a pixel off
  at bright edges; linear light is right); judging an edge's clearness against the middle
  value along the sampled line (every soft edge read as unclear; the ends of the line are
  used); taking coverage as the larger of alpha and the colour's in `shares` (it tinted
  what was left for the background: guard hits went up from 870 to 5,360); looking 2.2
  model pixels either side instead of 1.5 (better on one stand-in of 6465, worse on the
  other and on 6303).
- **Running the matting model over the whole edge band automatically** was not needed
  and not tried: it would be about as many passes again as the tiles (0.9 s each).

## 15. How to work on this without the owner's photos

1. `swift test` (Linux: `export PATH=/opt/swift/usr/bin:$PATH`). `EdgePlaceTests` covers
   the final round on synthetic discs: an edge three pixels out and too wide is put right;
   a soft photo edge keeps a soft mask edge; no pale rim just inside a dark subject; the
   lightness bound stops a dark seam; the split of a pixel's light; the contrast gate; the
   hair contrast figure.
2. Real pixels: ask the owner for the log (`.jsonl` beside it) and a debug bundle with a
   Refine Edges box drawn over the trouble. From `crop<n>_*.png` the composite can be
   rebuilt and the engine run on the crop (`Matte(photo:coarse:faces:…)` with the crop
   of `final_alpha` as the first pass reproduces the tools' patch path).
3. Never commit photos, crops, bundles or logs. Scratch tests that read them must not be
   committed either.

## 16. Next steps: Priority 5 (UI)

The owner's order.

**Built in alpha 16: a and c** (see `docs/NOTES.md`, "Alpha 16"). b, d and e are not.

**a. Overlay bug: brush strokes and boxes stay on screen permanently.** They should show
only while a tool is active or when "Show edits" is on. Today `Session.toolChanged()`
sets `view.marks = maskTool == .none ? [] : ops.map { $0.mark }` (about line 1239 of
`Session.swift`), and the tool stays chosen after an operation, so the marks stay. Wanted:
marks only while the pointer is down (the live box or stroke is already drawn by
`HeroNSView` itself) plus a brief fade after the operation, unless Show edits is on.
`HeroNSView.marks` / `drawTools` (`HeroView.swift`) need no change beyond being given an
empty list.

**b. Edit stack engine.** Every operation should work from the current mask (the result
of all before it), which is already so; but hiding or deleting one must recompute only
the later operations that overlap it, and each operation's result should be cached so
toggling is fast. Today `Session.refined[id]` holds `(automatic: MaskResult, ops:
[RefineOp], undos: [RefineUndo])`, where a `RefineUndo` is the rectangle and the alpha
and shares it replaced. Suggested shape: for each operation keep `rect`, the alpha and
shares it *produced* in that rect (its cache), a `hidden` flag, and the model answer(s)
it used (so a recompute does not run the model again: `Masking.look`'s result is the
expensive part, the engine on a patch is 0.3–2 s). To hide or delete operation k: start
from the automatic mask, lay the cached results of the visible operations before k that
do not depend on anything changed, and re-run (from their kept model answers) those after
k whose patch rectangle overlaps a changed rectangle; propagate the changed area as each
is re-run. `Refine.edges/.hair/.clean` already take the current alpha and return a
`RefineResult` with its `patch`; `Refine.paste` lays it in. "Replay on Remake" exists
(`makeMask` → `again`, about line 1187) and re-runs everything, model included.

**c. A "Show edits" checkbox** next to the tool picker (`LocalPane.swift`), available as
soon as a mask exists: a `@Published` flag on `Session` that `toolChanged()` reads.

**d. History panel**, opened from a button next to Undo, in the style of Procreate's
layers: one row per operation (tool, a thumbnail of its patch, the time), an eye to hide,
a delete button, a spinner while recomputing. A SwiftUI popover or sheet over
`session.refined[current]`; thumbnails from the cached result's rectangle of the photo
with the mark drawn over it.

**e. Reorder mode**, entered with a button whose tooltip warns that the stack will be
re-run. Drag to reorder, then Confirm (re-runs from the first moved operation) or Cancel
(restores at once from the caches). The whole reorder is one Undo step: `undoTool` needs
to become a stack of states rather than of rectangles (or a reorder pushes one composite
undo entry holding the previous order and caches).

Not this round, by the owner's decision: automatic hand and foot boxes from pose,
automatic gap check, automatic defringe, compressing the matting model.

**Before UI work**, though: read the owner's alpha 15 log for `edge placement`, `colour
guard` and `lightness` on the eight photos, and whether the rim is gone on the real 6303,
7451 and 6957. If it is not, the crops in a debug bundle will say which of section 4's
causes is still at work.

## 17. Spec v6 (alphas 17 and 18): reverted

`docs/specs/masking-spec-v6.md` (and its addenda) were built in alpha 17, with a follow-up
in alpha 18: a "subject light bound" (per channel, then reshaped into an Oklab hue rule), an
exact sRGB curve and an sRGB copy of the render, shares never clipped per channel, limits on
what a Refine Edges box may take out and a larger look area, Strength and Tightness on
Refine Hair, an Edge Brush in place of Clean Edge, an automatic hand pass, a smaller hair zone
that left out the body, an Ignore faces switch, filled pinholes at 1.0, and the lost-mask fix
(masks kept, spilled to disk under memory pressure). On the owner's photos they made things
worse: the box regressed on 6957 and 6372, 4-px coloured squares appeared along edges on 6303
and 7451 (most likely the light bound's trust, which was decided per quarter-size cell), a
grey halo appeared round 6372's prop, and the green/teal fringe was not visibly reduced.
Spec v7 rolled the app and engine back to alpha 16 with git (`git checkout 5c95b58 --
Sources Tests`, commit 9151f0c). **The lost-mask fix went with it** (the owner listed kept
masks as not this round): only the last two photos keep their masks again, see
`docs/NOTES.md`. The build workflow's storage fix, not masking code, stayed.

## 18. Spec v7 (alpha 19): edge colour from inside, Remove Colour

`docs/specs/masking-spec-v7.md`. Two blunt colour tools on top of alpha 16. **Checked on
synthetic pictures built from the owner's measured pixels only**; this session has none of
the photos.

**Rollback check (i).** With edge colour from inside off and no Remove Colour box, the engine's
output is alpha 16's byte for byte: `SpecV7Tests.testOutputIsAlpha16sWithTheSwitchOff`
compares FNV hashes of alpha and shares, taken from the alpha 16 code itself, for the Off and
High tiers of the strand scene, a disc with and without a face, and a Refine Edges box. The
debug bundle names the switch only when it is on, so with it off it too is alpha 16's.

**Edge colour from inside** (`InsideColour`, `MatteSettings.insideColour`, Debug "Edge colour
from inside", on in the app, off in the engine's defaults). The last step of `Matte.finish`
(after decontamination and the colour guard), so it also ends every Refine Edges box (its
patch runs the engine); off for Clean Edge and Refine Hair patches. Never changes alpha.
- Solid subject: alpha ≥ 0.98 (250/255) and at least 6 px inside, measured as the distance
  from the pixel's centre to the nearest pixel under a half (`solidDepth`). Its colour: the
  render in linear light (the engine's 2.2 curve, as in alpha 16), each channel the median of
  the 3×3 round it.
- Nearest-solid fill: outward from the solid subject's own border, breadth first, each pixel
  taking the source of the neighbour it was reached from, within 30 px of that source
  (`reach`); beyond, the inside colour is unknown and the pixel is left. (A breadth-first
  fill rather than `SharpnessMap`'s push-pull: push-pull averages, and the spec wants the
  nearest.)
- Edge band: alpha over 1/255, from the soft edge's outer end to 4 px inside the half-way
  line: depth ≤ 5 on the measure above (`bandInside`; the pixel the line runs beside is 1).
- Per pixel: P = I × shares; the rim test below; otherwise P′ = k·α·F̂ with
  k = min(1, minₖ Iₖ ÷ (α·F̂ₖ)), shares P′ ÷ I (0 where the photo has no light).
- **Rim light, changed from the spec** (two defaults, owner to confirm): the threshold is
  **0.05**, not 0.03, in Oklab L; and a part-covered pixel is judged by the nearest fully
  covered pixel within 3 px (`rimLook`), using that pixel's own part ÷ alpha from the shares as
  they were. Why: on the spec's own test (a) the sleeve is L 0.191 and its teal pixel
  (0, 39, 33) is 0.226, 0.034 lighter (dark colours take big Oklab steps for a few code
  values), so 0.03 keeps it as rim light; and part-covered pixels still hold some background
  light after decontamination, so judged on their own a teal edge against white read lighter
  than a real rim against a dark ground, and no threshold passed both (a) and (d). The real
  rim in (d) is 0.084 lighter. With the photo's own colour at the neighbour instead of its
  part, a lens's spill of a bright background (alpha 15's pale rim) read as rim light.
- Not under Refine Hair strokes; in the hair zone (alpha 16's box, unchanged) only where the
  skin model says the inside colour is skin (value ≥ 0.5). The skin model is learned as the
  skin mask's is, from cheeks and nose, where the first-pass mask is sure. With no face the
  whole outline is hair zone in alpha 16's engine, so only skin is recoloured there.
- Tiled (256 px, with a 40 px apron), every change worked out first and written after, so
  tiles never read each other's half-done work.
- Log: `edge colour from inside: N pixels recoloured, M skipped as brighter (rim light), U
  with no inside colour, mean Oklab ΔE x`; JSON `inside_colour_recoloured`, `_rim`,
  `_unknown`, `_delta_e`.

**Remove Colour** (`Refine.removeColour`, tool "Remove Colour"). A click with the tool picks
a colour: a 5×5 median of the neutral render (`Masking.median5`); Shift-click adds one. The
panel shows them as swatches with Clear, and a Tolerance slider (Oklab, 0.01–0.15, 0.05).
A box acts only inside itself and within 40 px of the mask's outline either side. Per pixel:
B the nearest sample (Oklab), F̂ the inside colour as above; within the tolerance of B, t = 1;
else within the tolerance of the segment F̂–B (Oklab), t = the fraction along B − F̂ in linear
light; α′ = min(α, 1 − t). The change in alpha is softened (Gaussian σ 0.75, "radius 1.5"),
averaged over pixels that had coverage to lose (else bare background beside a removed
piece diluted it and left a ghost), inside the box only. Pieces under 50 px it cut loose go;
holes under 50 px it opened close. Changed pixels get P′ = k·α′·F̂ from the inside colour of the
new mask (no inside colour: shares scaled with alpha, all three together); unchanged edge
pixels in the box get edge colour from inside as usual. Laid in through the box's 6 px soft
edge like Refine Edges. Stored as an operation with its samples and tolerance (in the debug
bundle's `regions.json` too), undone, replayed after Remake, Option-restore as for any box.
Moving the tolerance does the last operation again in its place if it is a Remove Colour box
(no new undo step). Log: `remove colour: N px changed, mean alpha removed x, samples k,
tolerance y`, then what was cut loose or closed.

**Test numbers** (`SpecV7Tests`, the engine's 2.2 curve; the owner's 7451 values):
- (a) sleeve (29, 26, 25) on white, the six edge pixels: chroma of P/α before 0.0099, 0.0246,
  0.0356, 0.0420, 0.0338, 0.0154 → after 0.0057, 0.0043, 0.0000, 0.0000, 0.0047, 0.0062
  (the sleeve itself 0.0062 on this curve); all ≤ 0.012. The two pixels with red 0 come out
  at 0: their subject part is black, all their light goes to the background.
- (b) skin (155, 113, 85): (a, b) of P/α from the skin's 0.0097, 0.0141, 0.0052 (≤ 0.015).
- (c) waist (127, 87, 63), edge alphas 1, 1, 0.6 on a warm ground: 0.0073, 0.0132, 0.0051.
- (d) a 3-px rim (222, 150, 92), Oklab L 0.736 against the skin's 0.653: unchanged, every
  pixel kept as rim light. A 20-px rim: the outer pixels' (a, b) from the rim's 0.0000.
- (e) a disc whose whole edge is in the hair zone, not skin: 0 recoloured, shares identical
  to the switch off. The same with a skin model of its colour: 5,084 recoloured.
- (e2) the skin exception: a disc of skin whose whole edge lies in a face's hair zone, with a
  one-pixel green fringe just inside the edge (6303's fingers beside the face), and a skin
  model of that skin. All 372 fringe pixels are in the zone and are recoloured; without the
  skin model all 372 are left alone. A green as far from the skin as 7451's olive (112, 124,
  84): (a, b) of P/α from the skin's 0.078 → 0.014 (≤ 0.015, as (b)). A strong green (88,
  118, 70): 0.108 → 0.023 in absolute terms, because its red is so low that k is about 0.3
  and the part comes out skin-hued but much darker, and a darker colour of the same hue has a
  smaller (a, b); at the skin's lightness it is 0.0003 from the skin's (a, b).
- (f) what is compared: in the core tests, alpha is identical with the switch on and off
  (4,004 pixels recoloured, 0 rim). The rendered Photo view with no adjustments is checked on
  the Mac (`TiffExportTests.testPhotoViewIsTheSameWhateverTheShares`): a black disc with a
  teal fringe, masked with the switch off and on (the shares differ), drawn through
  `Masking.apply` in Photo view, is pixel-identical to the photo drawn alone, both times. In
  the app that view, with no adjustments, doesn't hand the mask to the render at all.
- (g) no share vector with a channel at 0 beside one over 0.1, except where the photo's
  channel is 0, in (a), (b), (c), (f) and (h).
- (h) pink disc, 8-px orange crescent, green ground, orange sampled, tolerance 0.05: 2,182 px
  changed, mean alpha removed 0.693; the most coverage left anywhere on the crescent 26 of
  255 (four corner pixels, the softening); the disc's edge at 70.0 px where the crescent was
  and 70.25 px elsewhere (radius 70); the orange 58 px inside untouched.
- (i) byte-identical to alpha 16, above.

**Acceptance on real photos (the owner):** at 300% in On Black and Background −3 EV:
7451 no teal on the sleeve edges, no olive on the skin in the arm–waist gap (the right waist's
yellow may stay); 6303 no green along fingers, cuff, sleeve and no 4-px squares; 6957 the
box removes the finger slivers and the blurry hair in the gap as in alpha 16; 6372 with the
orange wall sampled, a box round the rose removes the orange without eating petals or the
hand; 7006 and 7473 hair unchanged from alpha 16.

**Known issues added by v7**
- Where the fringe's photo has a channel at 0 (7451's (0, 32, 28)), k is 0: the subject's
  part there is black, and with the background darkened the pixel shows only its own (teal)
  light at an eighth. Blunt, as specified; not compensated.
- The rim test's two changes above are defaults made here, not the owner's numbers.
- No face: alpha 16 treats the whole outline as hair zone, so edge colour from inside acts only
  where the inside is skin (and with no face there is no skin model: not at all).
- Remove Colour's segment test uses the inside colour of the mask before the box; where the
  mask takes in more than 6 px of the wall, the "inside" there is the wall and only the
  "within tolerance of B" rule acts, which is what removes such a piece.
