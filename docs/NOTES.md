# TrainCull for Mac: notes

## What it is

Point it at a folder of raw files and it works: no catalog, no import. Thumbnails on the left,
one large image on the right, ratings and edits saved to standard `.xmp` sidecars next to the
raws. The raw developer at the end (Photoshop and Camera Raw today) is replaceable.

Principles, from the owner:

1. The file system is the library. No catalog or database.
2. Never clobber a sidecar. Change only the fields the app owns; keep every other byte.
3. Sidecars hold what describes the photo (rating, label, edits). Data that exists only for
   the app's own sorting (names, handles, keywords, stack data) goes in JSON, never the sidecar.
4. Native first: Apple's raw decoder and Apple's controls under Apple's own names, relabelled
   only in stops and Kelvin. Try what macOS provides built in (raw decoding, face detection)
   before anything bespoke.
5. Lean. No features or buttons the owner would never use.
6. Bridge is a fair starting point for desktop behaviour, except where a decision below says
   otherwise. Those exceptions are the reason the app exists; treat them as firm.

## Decisions

**Layout**
- Opening a folder lands on a thumbnail pane beside one large image. Only that folder is
  shown; subfolders are not entered.
- The left pane switches between Folders (recents, drives with Eject) and Thumbnails.
- No filmstrip on the desktop.
- Edit mode: an Edit button at the top right slides the thumbnail pane away and the editing
  pane in. A small top-left button brings thumbnails back for a quick look; that combination
  is a spot check, not a view to build around.
- The title bar is the plain thin one, with no toolbar. Edit is the word alone (never an icon
  beside it), in the accent colour so it is easy to spot, filled while edit mode is on.
- The bar under the image is one line: stars, reject and labels on the left, the camera
  settings centred in the space between, file name, position, state and zoom on the right.
  When the window is too narrow the settings give way first. Nothing is stacked there.
- Clicking a count at the bottom left (frames, rated, rejected) also scrolls the thumbnails to
  the current image and flashes its outline, so it is never lost.

**The large image**
- Fitted by default. No loupe, ever. Full screen is optional and never required for zooming
  or rating.
- A click goes to face zoom: the whole face framed with the eyes anchored, capped at 100%
  (`Framing.swift`). With no face found, the click zooms to 100% where it was clicked. A
  second click returns to fit.
- Two-finger drag is the only way to pan. Pinch reaches any other zoom, up to 200%.
- Going to a zoom and back is a short glide (about a fifth of a second), not a jump. It is
  skipped when the Mac is set to reduce motion.
- It always shows the raw rendered by Apple's decoder: the embedded preview first, replaced
  by the raw render once the frame has been still for a moment. Thumbnails stay embedded
  previews.

**Keys** (a zero-basis set: add a shortcut only when a core action needs one, never because
Bridge, Photoshop or Lightroom has it)
- Left / right: previous / next frame.
- 1–5: stars. 0: clear. Works in every view. The number row is never type-to-select.
- Up / down: raise or lower the rating, only where one large image fills the view. Up from
  unrated sets 1, up at 5 does nothing, down at 1 clears, never into reject. These two keys
  are the first to give up if another shortcut needs room.
- X: reject. 6 / 7 / 8 / 9: red / yellow / green / blue label.
- Tab: next face. Space: full screen. Esc: back one level (zoom, then full screen, then the
  side-by-side view).

**Ratings, labels, edits**
- `xmp:Rating` 1–5, 0 none, -1 reject. `xmp:Label` holds Bridge's label names: Select,
  Second, Approved, Review, To Do.
- Saved at once, crash-safely (temp file, then swap; leftovers repaired when a folder opens).
- Exposure, temperature and tint are saved in Camera Raw's fields so Photoshop can read
  them, uncalibrated for now. Other controls are saved under one TrainCull namespace.
- TrainCull is the first step and Camera Raw is a handoff: no two-way sync. Re-editing in
  TrainCull after Camera Raw is expected to be rare.

**Side-by-side compare (built in alpha 5)**
- Command-click a second thumbnail to show two images side by side. The image that was
  showing goes left, the clicked one right, and the right one is active.
- Zoom is linked. Panning is independent, with a possible toggle to link it (not built; wait
  until it is missed).
- The active image has a small coloured border. Ratings, labels, reject and left / right act
  on it alone: with 10 on the left and 20 active on the right, the right arrow shows 21 on the
  right and the left stays on 10. The arrows step over the frame on the other side, so the
  two sides never show the same photo.
- The first click on the inactive image only makes it active; a click on the active image
  zooms both: to the same percentage, each centred on its own face (the one sitting where the
  clicked face sits), or on the same spot of the frame when it has no face. Pinch zooms both.
- A zoomed active image stays zoomed, on the same spot, when the arrows move it to another
  frame, so a burst can be checked at one zoom.
- Tab switches the active image; a Next Face button on the image steps faces in this view.
  Faces are counted from left to right.
- While comparing, command-click a thumbnail replaces the active image; a plain click on a
  thumbnail does nothing. The other side's thumbnail has a quieter outline.
- Leaving takes Esc or the visible Single View button. Esc goes back one level at a time:
  zoom, full screen, the side-by-side view. The single view then shows the active image.
- Space makes the compare view full screen, with the same behaviour.
- Up / down do nothing here (they belong to the single view), and Edit leaves this view first.

**Exports**
- "Export" means two things: extract the embedded JPEG unchanged, or render from raw plus
  edits. Extract and a developed 16-bit TIFF are wanted now (TIFF: ProPhoto RGB, ZIP
  compression, named after the raw). Rendered JPEG and other formats wait for the owner's
  research.
- Both are built (alpha 5). They are in the File menu and a thumbnail's right-click menu; the
  TIFF is also at the bottom of the editing pane. No shortcuts.
- Exports are saved next to the raw, under its name (`.jpg`, `.tif`). An export never replaces
  a file: a taken name gets `-2`, `-3`.
- The File menu can also export "all frames shown", after asking. With a filter on, that is
  how the keepers are exported; choosing several frames by hand is still to design.
- The extracted JPEG's picture data is copied byte for byte. When the photo was taken on its
  side and the JPEG doesn't say so itself, a small note of the orientation is added so it
  opens upright.
- The TIFF also carries camera, lens, capture time and exposure settings.
- Send to Photoshop: at the bottom of the editing pane and in a thumbnail's right-click menu.

**Diagnostics**
- While in alpha, log freely: every session writes a plain-text log on the Mac
  (`~/Library/Logs/TrainCull`, the last ten kept) with what was opened, how long each step
  took, every save, export and error. Nothing leaves the Mac.
- Memory use is read every second (the figure Activity Monitor shows) and at heavy moments.
  Help → Diagnostics states it in plain language (now, average, peak) and reveals the log file.

**Cameras**
- Sony ARW is built in as a recipe (data describing where a format keeps its embedded
  previews). Other formats are imported recipes, later.

**Later, in the owner's words "a later option"**
- Subject stacks (grouping a shoot by person), true-burst stacking, companion app
  integrations, transfer and drive tools, controller support, batch rename, keywords, a
  folder tree, a calibration table mapping Apple's values to Camera Raw's.
- Subject, hair and skin masks: see "Masking" below.

## What is built (alpha 13)

Folder opening (button, File menu, drag and drop, recents, drives), resizable left pane,
thumbnails with rating, label and reject marks, the large image with raw render and face
zoom with a glide, ratings and labels, edit mode with 15 of Apple's raw controls saved to the
sidecar, Send to Photoshop, the one-line bar under the image, click-to-filter on the counts
at the bottom left (double-click the rated count to choose stars), side-by-side compare,
extracting the embedded JPEG, exporting a developed 16-bit TIFF, the diagnostics log and
memory report, an app icon, and the masking test (see "Masking").

Checked by tests on Linux (94): raw and recipe reading, the settings line, sidecar editing,
crash-safe saving, face-zoom maths, the TIFF writer, JPEG orientation, compare stepping,
memory figures. Checked by a test on the Mac build: an exported TIFF opens in Apple's reader
with the right pixels. Checked by the automated build's screenshots (made-up frames): the
window, the thumbnails, the single and side-by-side views. Checked by the owner on 1,523
Sony a7 IV frames (alpha 4): thumbnails, raw render, face zoom.

Used by the owner on real files in alpha 5, going by the log they sent: ratings, edit mode
(exposure, tint), saving edits, the TIFF export (148 MB, 1.2 s), the counts at the bottom
left, the zoom glide, side-by-side compare with stepping and Next Face. Not yet used by
anyone: Send to Photoshop, filtering by stars or rejects, extracting the JPEG, exporting all
frames shown.

## Measured (alpha 5, the owner's log)

1,523 Sony a7 IV frames on a MacBook Pro with 36 GB, four minutes of use:
- Memory averaged 952 MB and peaked at 2.6 GB (while a tint slider moved). Just after opening
  the folder it sat near 200 MB, later near 600 MB. Loading the 1,523 thumbnails took 2.0 s and
  1.4 GB for a moment. Each raw render pushed it to 1.4–2.1 GB for a few seconds.
- A glide normally drew 24 frames in 220 ms. The first zoom after a new image often drew 10,
  and in the side-by-side view only 1: a jump. The raw "render" took 0.04 s, too quick to be
  the real work, where the same render for a TIFF took 0.37 s. Reading: Core Image was handing
  back a picture it only worked out when first drawn, on the main thread, and worked out again
  after the system had dropped it. Alpha 6 renders at once in the background and keeps the
  pixels in memory of its own. Alpha 6's log should show a raw render near 0.3 s, glides at
  full frame count from the first, and any draw slower than 33 ms as a "slow" line.

## Measured (alpha 6, the owner's log)

Same folder and Mac, two and a half minutes of use:
- The reading above was right. A raw render now takes 0.38–0.40 s in the background (0.9 s
  for the very first, while thumbnails load) and the sharp image arrives about 0.55 s after
  landing on a frame. Every glide drew 17–25 frames, including the first zoom after a new
  image and in the side-by-side view. No draw took longer than 33 ms.
- Memory averaged 951 MB and peaked at 2.2 GB (again while sliders moved). Loading the
  thumbnails peaked at 0.8 GB, down from 1.4. Browsing sits at 1.3–1.4 GB just after each
  render and rests near 770 MB, up from about 600, because the kept renders now hold their
  memory.
- Stepping fast renders one frame at a time, so a frame already left can hold up the wanted
  one by up to 0.4 s. Not a complaint yet; cancel a render in flight if it becomes one.

## Next, in order

1. The owner tries alpha 13 (spec v4, Phase 1) in Background −3 EV at 100% on the eight test
   photos, and supplies two or three shots on a seamless or plain backdrop.
2. Spec v4, Phase 2: the Refine Edges box and the Refine Hair brush (see "Masking spec v4").
   Gaps are opened there, by the model at close range, not by an automatic colour test.
3. Spec v4, Phase 3, what is left of it: automatic hand and foot boxes, prop growth.
3. Soft-focus and closed-eyes flags from Apple's face landmarks.
4. A Settings window (label names, editor choice), Undo after reject.

## Masking (a test build of phases 1 and 2)

`docs/specs/masking-plan.md` is a plan the owner brought in for subject, hair-edge and skin masks.
It was written for a generic Mac raw editor, not for this app, and was audited here on
2026-11-15. Phases 1 and 2 are built as a test; see the end of this section.

**What it would mean for the app.** TrainCull has no local adjustments, and a mask is only
useful with them. Masked edits cannot reach Camera Raw (the handoff is one-way and Adobe's
masks are their own format), so they would exist only in TrainCull's own render and its TIFF
export. Building this turns TrainCull from the step before Camera Raw into a finishing
editor. That is the owner's decision and comes before any code.

**Checked and sound.**
- The maths: the fast alpha solve, the matrix-free matting Laplacian and its diagonal, and
  the foreground/background system all work out as written.
- Memory figures (482 MB for a 61 MP half-float decode, 120 MB for a full 16-bit mask).
- Vision: `generateMask(forInstances:)` is the low-resolution accessor; `instanceMask` is a
  label map, not a soft mask. `CIEdgePreserveUpsample` takes the guide as `inputImage` and
  the small image as `smallImage`, as the plan has it. `boostAmount = 0` is the linear decode.
- The macOS 27 items are real (tap-to-segment with include and exclude points, Core AI as
  Core ML's successor, SAM 3 export recipes). Apple's documentation names the initialiser
  `init(seedPoint:)`, not `init(seed:)`. None of it is needed: the owner is on macOS 15.

**Not checked.** Whether Vision's low-resolution mask is soft. The pymatting defaults. Every
timing in the plan's section 10. Whether Metal compute runs on the build machine.

**Where it collides with this project.**
- The app never uses the network and the owner has no Apple Developer account. Phase 3
  (downloaded models, Background Assets) is out as written; a model would have to ship
  inside the download.
- `swift build` does not compile Metal shaders and has nowhere to put the Core Image kernel
  flags. They would be compiled by `scripts/make-app.sh` on the build machine, or the
  compute kernels compiled from source when the app starts.
- Quality can only be judged by eye on real photos, which are never committed and which
  cannot be seen from here. The plan's test harness (Python, ground-truth masks) assumes a
  developer at a terminal. Tuning through build, download, try, report would be slow.
- The plan's cameras are a Nikon Z7 and a Sony a7CR. Only Sony ARW has a recipe today.
- "Native first" and "lean": the plan never measures what Apple already gives. Vision's own
  full-resolution mask (`generateScaledMaskForImage`) is the thing to beat, and may be most
  of the value.

**Verdict by phase.**
- Phase 1 (Vision mask, edge-preserving upsample, trimap, fast alpha, guided filter, skin by
  sampled colour): viable, and in keeping with the app. About as much work as alphas 5 and 6
  together, plus the local-adjustment feature it serves, which is the larger half.
- Phase 2 High tier: viable, several times Phase 1, and blind to verify. Only if Phase 1
  visibly fails on hair over decorations.
- Phase 2 Max tier (closed-form matting on the graphics card): technically sound, the
  riskiest thing to build without seeing it, and the least lean. Defer.
- Phase 3: blocked by the rules above and by licences. Defer.

**Built as a test (alpha 7), at the owner's request: phases 1 and 2.** The owner wants to
see early whether TrainCull is viable as a finishing editor. It lives in **Mask (Test)** at
the bottom of the editing pane: make a mask (Fast, High or Max), look at it (photo, red
overlay, mask, cut out on black or white), adjust Subject, Background or Skin (exposure,
saturation, warmth), save the mask pictures as PNG. Nothing is saved with the photo; masks
and local adjustments last until the folder is closed. The TIFF export includes them.

How it differs from the plan, and why:
- **Processor, not graphics card.** The whole matting engine is plain Swift in
  `Sources/TraincullCore/Matting`, run on all cores. That is what let it be tested on Linux
  and looked at before the owner ever saw it: on a made-up scene (dark hair strands over a
  two-colour backdrop with a bright stripe) the first-pass mask is off by 9.1% of full scale
  across the uncertain band, Fast by 1.5%, High by 0.95%, Max by 0.78%. The closed-form
  operator is checked against the textbook matrix entry by entry. Moving the hot loops to
  Metal is the plan's design and the next step only if this proves viable and too slow.
- **Works on the displayed picture, not linear light.** Masks are made from a neutral render
  (camera white balance, Apple's defaults, none of the frame's edits), 8-bit Display P3 as
  shown. That is what the matting literature and Vision both use, and it settles the plan's
  open question 3 for now.
- **No separate full-size first-pass mask.** Vision's mask goes straight to a quarter-size
  three-way split; the plan's edge-preserving upsample is replaced by a guided upsample used
  only where colour contrast is too low to solve for alpha.
- **Distances by an exact transform at quarter size,** not jump flooding at full size. The
  rays hold back a block's worth so they still never step over a certain pixel.
- **Max keeps each tile's middle** and discards its margin, with no cross-fade. Tiles are
  solved only for uncertain pixels and the two pixels around them, everything else held fixed.
- **No stored subject and background colours.** In their place each edge pixel stores how
  much of its red, green and blue light is the subject's ("shares"), worked out in linear
  light from the colours the High tier found. Blending by shares instead of by coverage is
  the plan's decontaminated compositing for exposure and warmth exactly, and near enough for
  saturation, and it survives any global edit. The plan's multi-level foreground estimation
  is not built; a per-pixel correction of the High tier's colours stands in for it.
- **Skin is sampled automatically** from the cheeks and nose of each face, not by clicking.
  Eyes, brows and lips are cut out from Apple's landmarks. No face, no skin mask.
- **Masks are 8-bit and whole-frame,** not 16-bit sparse tiles. Simpler; about 165 MB a
  frame at 33 megapixels (the last two frames' masks are kept).
- **Blending uses two small Core Image programs written in the old kernel language,** because
  `swift build` cannot compile Metal ones. If they fail to load, blending falls back to one
  number per pixel and the status line says "plain blending". A Mac test checks they load.

What to look for in the owner's log (`mask` lines): time per stage, megapixels of edge
refined, tiles and steps for Max, memory after each stage. What only the owner's eyes can
say: whether curls and strands hold up on real hair, whether darkening the background leaves
a halo, whether the skin mask is usable. Ask for the saved mask pictures when it goes wrong;
they can be looked at from here.

## Masking spec v2 and the logging recommendations (superseded by spec v3)

**This section is the record of alphas 8 to 11.** Spec v3 (further down) replaced it: SAM and
candidates B, B2 and C are no longer in the app, and the model now runs at 1024.

After trying alpha 7 the owner brought two more documents, written by another session from
their alpha 7 logs and screenshots (which were not seen here): `docs/specs/masking-spec-v2.md`
and `docs/specs/logging-recommendations.md`. What alpha 7 showed, by their account: Vision's
"all people" mask pulls in background people and misses props; the skin mask misses shadowed
skin and highlights; Max left a glow around out-of-focus hair and a straight seam
(`_DSC6372`, background at −3 EV). The owner shoots 85 mm at f/1.6 in crowded convention
halls: cosplay, props, other people in similar colours behind and overlapping the subject.

The spec's order of work, and where it stands:

1. **Debug bundle export and ground truth. Built (alpha 8).** "Export Debug Bundle" in the
   mask panel writes a folder next to the raw: the proxy, the body-box crop, the faces with
   outlines, the current first pass, and a note telling the owner how to paint the reference
   mask. The owner has to do that for 20 to 25 photos before step 2 can start.
2. **Bake-off of subject models. Done on eight bundles; see "The subject bake-off" below.**
   Run here, in Python on the processor, so its timings say nothing about the owner's Mac.
3. **Models in the app. Built (alpha 11), as a picker so the owner can test every candidate:**
   "Subject from" in the mask panel offers BiRefNet (A, the default), SAM (B), SAM + close-up
   (B2), Hybrid (C) and Vision (V). Not yet done from this step: caching of what the models
   return (each Make runs them again), prewarming, unloading under memory pressure, the
   no-face path (it falls back to Vision), the head-crop pass with the new models.
4. to 6. Refine tools and people picker, skin v2, acceptance: not started.

Done now because they don't depend on the bake-off (the spec's sections 4, 5.1, 5.2, 9, 13):
- **The seam.** Max tiles now overlap and fade into each other, and into the High answer
  where a neighbour was skipped. A check on every Max mask compares the mask's steps across
  tile boundaries with its steps elsewhere and logs "SEAM?" if they stand out.
- **The glow.** A sharpness map of the photo (how blurred each edge is) and the sharpness of
  the subject's face are measured; where the photo is well out of focus next to the subject,
  each tier trusts its colour arithmetic less and stays with the first-pass mask. Two guards
  keep the result near the first pass where that was sure; the background one tightens out
  of focus. Every mask logs how much of the sure background came out half-selected and
  flags "GLOW?" above 5%.
- **Straight lines in the Fast mask** were most likely the hard edge of the "hair zone"
  around each head; it now fades in. Not confirmed on the owner's photo.
- **Which face is the subject:** the large, sharp one (size over blur), not the largest.
  The sharpness map departs from the spec in one thing: the bar for what counts as an edge
  is capped at a 4% step. As specified (the steepest 15% of the picture), a photo full of
  crisp detail would count crisp edges only and never measure what is out of focus.
- **Band width** is a setting, with a "Narrow edge band" toggle to compare.
- **A plain render is no longer thrown away when a mask is made** (the reselect that
  re-rendered). The render cache is capped by size (900 MB), least recently shown out first.
- **The neutral render is kept** between a mask, a remake at another quality and a bundle.
- **Nothing that finishes in the background selects a frame.** That was already so; the log
  now gives the cause of every selection so the `_DSC6637` case can be told next time.

Logging added (the recommendations' 1, 3, 4, 5, 6, 7 in part, 9, 10 in part): the cause of
every selection; mask jobs numbered from request to completion, with whether their image was
still selected; cache hits and misses with reasons, and a summary every 15 s; memory per mask
job (read every 50 ms) and processor time; thermal state; the size, scale and trigger of
every render; the quality checks above; a `warn` category; a `.jsonl` copy of the log; the
camera settings of each image on first selection; twenty sessions kept.

Not done from the recommendations, and why: GPU time (the matting runs on the processor, so
there is none of ours to time); model load and compute-unit lines (no models yet); energy
in joules and the power-source line (left until there is something to compare); the
`powermetrics` scripts (they need the terminal and an administrator password).

### The subject bake-off (2026-11-15, eight bundles from the owner)

The owner sent eight debug bundles, each with Photoshop's one-click Select Subject mask
(`ps_mask-<number>.jpg`) as the reference: not the truth, but what they compare against. Five
are crowd or overlap shots (`_DSC6303`, `6465`, `6957`, `7006`, `7451`), three clean (`6372`,
`6378`, `7473`). `tools/bakeoff_subject.py` ran the models here (PyTorch, processor only) and
applied the selection rules; the same rules are in `SubjectSelect.swift`. Every bundle has
one face, so nothing here tests telling two people apart by their faces.

Agreement with Photoshop (IoU at the proxy's size; median of all eight, then of the five
crowd shots):

| Candidate | All | Crowd | Selected extra (crowd) | Missed (crowd) |
|---|---|---|---|---|
| V, Vision as in alpha 8 | 0.765 | 0.706 | 41% of the subject's area | 0.5% |
| A, BiRefNet_HR with the sharpness rules | 0.993 | 0.992 | 0.5% | 0.2% |
| B, SAM 2.1 large, roomy box, two points | 0.941 | 0.950 | 0.1% | 4.9% |
| B2, B plus a pass on the box crop | 0.755 | 0.757 | 0.1% | 24% |
| C, hybrid of A and B | 0.993 | 0.992 | 0.6% | 0.2% |

- **A is the choice** by the spec's rule (the simplest within 0.005 of the best). Its worst
  photo is 0.982. It drops the people behind without any help from faces: BiRefNet goes for
  what is in focus, and the sharpness rule removes what little else it picks up.
- **C adds nothing over A here.** It would matter with two people in focus, which this set
  doesn't have. SAM stays worth having for the click-to-fix tools.
- **SAM alone is not a base.** It selects parts: on `6372` and `6378` it leaves out the
  headpiece (a quarter of the subject). Apple's Core ML SAM always returns three answers, from
  whole object to part, and its own favourite is often a part. Taking the largest answer it
  rates nearly as well helped one photo and wrecked another, so it is not used.
- **The spec's body box was too tight** (two face-widths, six and a half face-heights): it cut
  off raised hands and, on full-length shots, the feet, and SAM inside it scored 0.10 to
  0.86. The app now uses three widths and ten heights. B2 above still used the tight box,
  because the crop in the bundles was cut with it; it should be re-run from new bundles.
- **Where A and Photoshop differ** is small and goes both ways. A fills some gaps that show
  background: between the legs (`6465`, `7451`), between arm and body (`6957`), between hair
  and headpiece (`6372`, `6378`). Photoshop takes a fringe of background around curls
  (`7473`) and under hems and between shoes. Neither is ahead on fine hair at this size;
  that is the refinement tiers' job.
- **Not measured:** speed on the owner's Mac. Here, on four processor cores, BiRefNet took
  two minutes a run and SAM large five seconds an image. Only the app can say what Core ML
  on the M3 Pro does; the log's `base` lines time every model call.
- BiRefNet's close-up run used the box cut from the proxy, not from the full-size photo as
  the app does, so the app's edges inside the box may be a little better than measured.

**In the app (alpha 11).** Both models are checked on the Mac build machine, in Core ML:
SAM finds a test disc from one point and from a box (IoU 0.995), and the converted BiRefNet
finds one too (IoU 0.99996), so the conversion did not damage it. On that machine, which has
three cores and no graphics card, BiRefNet took 109 s a run and SAM's encoder 21 s; those
say nothing about the owner's Mac. The download is 779 MB. Not yet run by anyone on a real
photo inside the app.

**How the models get into the build.** GitHub's standard Linux machine for a private
repository has about 7 GB of memory and the conversion needs more, so the job first deletes
tools it doesn't use and makes swap space on the disk; it then takes eight to nine minutes.
The result is kept between builds, keyed on `tools/convert_birefnet.py`. Since spec v3 the
model is converted at 1024 and its check is one of the ordinary Mac tests.

**Where spec v2 collides with this project. To settle before step 3:**
- It has models "downloaded on demand, never bundled". The app never uses the network and
  the build fails if networking code is linked. **Taken as decided for now: the models ship
  inside the download.** The owner asked for the candidates in the app without answering the
  question, so the default stood. The build fetches SAM 2.1 large from Apple's Hugging Face
  repository and converts BiRefNet itself (`tools/convert_birefnet.py`, on Linux), compiles
  both on the Mac and copies them into the app. The download is of the order of a gigabyte.
- Its bake-off harness assumes PyTorch on the owner's Mac. The owner doesn't use the
  terminal; it runs here instead, from the bundles they export.
- It blends the High tier towards the first pass when unsure (9.5); here High blends towards
  Fast, which itself falls back on the first pass. Left as it is.
- It expects masks as sparse 16-bit tiles and work on the graphics card. Still whole-frame
  8-bit on the processor, as in alpha 7.

## Masking spec v3 (alpha 12)

`docs/specs/masking-spec-v3.md`, written by another session from the owner's alpha 11
testing: BiRefNet picks the right subject, but hard edges (boots on asphalt, jeans in front
of a blue costume) had a speckled halo, the close-up pass never ran, BiRefNet held 8 to 9 GB,
and changing the tier ran it again.

**Measured here first, on the owner's eight bundles (photos stay out of the repository):**
- BiRefNet at **1024** selects the same subject as at 2048: the two masks agree to
  99.2–99.5%, agreement with Photoshop is 0.992 median either way, and a pass takes about a
  fifth of the time. Its edge is softer (3.4 against 2.3 proxy pixels); close-ups bring
  that back to 2.9 even when cut from the proxy.
- **Squash beats letterbox** for the square input on these 2:3 frames (edge agreement 0.968
  against 0.958, and a softer edge with letterbox). Squash stays. (Spec 12.1, answered.)
- The spec's sharpness rule (relative to the face, scaled by face size) keeps and drops
  exactly the same pieces as the old rule on all eight.
- The new edge engine run on three of the proxies: halo away from hair 0.009, 0.016 and
  0.028 (the spec's limit is 0.05); the boots and jeans edges are clean in Off, and High
  still brings the strands back in the hair zone.

**Measured by the automated build (alpha 12, a 3-core virtual Mac with no graphics card):**
the converted 1024 model finds a test disc at IoU 0.999; a pass takes 15 s there (109 s at
2048 in alpha 11); memory during a pass peaks at **1.1 GB** and rests at about 140 MB with
the model loaded; the whole pipeline test (whole frame, a close-up, High, a tier change with
no model call, the debug bundle) passes; the download is 411 MB (779 MB before). The mask
panel's new controls are compiled and exercised by those tests but are below the fold in
the build's screenshots, so nobody has looked at them yet. Real figures (the owner's M3 Pro,
with its graphics card) come from the owner's first log.

**Adopted and built:**
- **One model, at 1024, for everything** (2.2, 4.5): the whole frame, then square close-up
  tiles laid over the subject's box, each cut from the full-size photo. Tiles are as large
  as the box's shorter side, between 384 and 1152 proxy pixels, a quarter overlapping, at
  most eight; a tile with no edge in it is skipped. Their answers go onto a mask kept at
  half the photo's size and may only change it within 0.05 face heights + 6 px of the
  existing edge, so a close-up sharpens an edge and never adds a region.
- **The close-up bug** (3.2): the old box was the union with a roomy body box, which is why
  it was always "most of the frame". The box is now the kept mask's own bounds plus 10%.
  Skipped only over 80% of the frame, by area; the log gives the size, percentage and decision.
- **Off / Fast / High / Max** (5). Off is the first-pass edge scaled up, steepened a little
  where it is in focus and not hair, and snapped to the photo's brightness edge where the
  photo has one. Colour matting runs **only in the hair zone**. With no face there is no
  hair zone to go by, and the whole edge is treated as one (so the tiers still do something
  on a photo of a thing).
- **Adaptive band** (5): a crisp first-pass edge gets a band one to two quarter-size pixels
  wide; the full band is kept around edges wider than four.
- **Guards** (5): where the first pass was sure and the colours either side are not distinct
  (contrast confidence ≤ 0.6), refinement cannot move it.
- **Sharpness** (6): thresholds relative to the primary face's eye band; strictness from
  face height (1.0 at ≤ 5% of the frame to 0.2 at ≥ 20%) times **Focus strictness** (Loose
  0.6, Moderate 1.0, Strict 1.4) in the panel. The piece with the face is never cut.
- **Body pose** (4.1, 7): Apple's detector on the proxy, matched to the primary face; mask
  pieces along the subject's arms and legs (0.35 face heights either side) are kept however
  soft. Joints and confidences are logged. Another person's joints inside the mask raise an
  `OTHER-PERSON?` warning.
- **Model lifecycle** (2.3): made ready when Edit mode is entered, kept while it lasts,
  let go on leaving it and when macOS reports memory pressure. One call at a time.
- **Caching** (9): what is known about a photo's subject is kept for the last three photos,
  and the edge engine for the last one, so changing the tier only redoes the hair. Remake
  starts from scratch. Neutral renders are kept for three photos. A tier change or Remake
  while a job runs takes that job's place.
- **Shown as it comes** (1): the Off mask appears first, then the hair tier.
- **Logging** (10): each model call (size, time, memory before / peak / after, processors),
  the close-up decision, poses, one line per mask piece, and halo / erosion in a ring 3 to
  10 px either side of the snapped edge, split hair and elsewhere (`HALO?` over 0.05).
- **Views**: **Background −3 EV**, and **Zones (debug)**: hair zone blue, snapped edge
  green, matted edge pink, tiles yellow, subject box orange, poses white, face cyan.
- **Debug bundle** (10): `m0_birefnet.png`, `m0_final.png`, `final_alpha.png`,
  `sharpness.png`, `pose.json`, `regions.json`.
- **Removed**: SAM and candidates B, B2, C, with their models (the download drops by about
  330 MB). Vision's masks stay behind **Debug → Legacy Vision mask**. The build no longer
  fetches anything except BiRefNet's weights in the conversion job.
- **Debug → Run model on**: CPU + GPU (default), CPU + Neural Engine, All (2.2 item 2).

**Changed from the spec, and why:**
- 3.2 says one close-up of the union box merged with a 24 px feather. Tiles merged near the
  edge instead: one squashed crop of a tall person gains little, tiles keep the detail, and
  the near-edge rule is what kept the experiment from inventing regions.
- 4.2 (hand and feet crops): not separate passes. The tiles already reach the mask's own
  resolution on full-length shots (about half the photo's detail on `_DSC7451`), which is
  what the feet crop was for. Revisit if the logs show hands or feet still soft.
- 5 says a guided-filter snap of radius ~4. A plain guided filter blurs the edge wherever
  the photo shows none (that was the old halo). Here the snap (radius 6, twice) is applied
  only as far as brightness explains the mask locally; elsewhere the model's edge stands.
- 6.3 "drop disconnected components if softer than…": pieces further than 1% of the long
  edge from the subject are still dropped outright, sharp or not, as in alpha 11. Read
  literally the spec would keep a sharp stranger across the frame.
- 13 has the model downloaded on first use. **It still ships inside the download**: the app
  never uses the network. Flagged to the owner twice; no objection so far.

**Left for the next phase:** crop growth along props (4.3), the attached in-focus objects
pass (4.4), box add / subtract and the people picker (8), removing another person from the
primary piece (6.3, 7: only warned about), the sharpness and kept/dropped overlays, the
50 ms drag target (9), and the checks that need the owner's Mac: memory per pass against
3 GB, the time budget, the processors comparison, pose on heavy costumes.

## Masking spec v4 (alpha 13: Phase 1)

`docs/specs/masking-spec-v4.md` (its PDF, with nine annotated screenshots, was read here but
is not in the repository: it holds the owner's photos). From alpha 12 testing: selection is
right on all eight photos in Off; what is left is a 1–3 px fringe on every edge, background
trapped in enclosed gaps, automatic hair matting making hair worse, and no close-ups when
the subject fills the frame. The owner's Mac: about 0.87 s and 1.5–2 GB per model pass.

**Decisions the owner made in it:** Off is the mask. Phase 1 (fringe and halo) first. Then
their own design: a Refine Edges box and a Refine Hair brush instead of automatic hair
matting and the Fast/High/Max tiers. Colour matting is kept for clean backdrops, under the brush.

**Built in alpha 13 (Phase 1, with the cheap parts of Phases 2 and 3):**
- **Tiles always run** (1.1). The 80% skip is gone. A tile is at most half the box's longer
  side and never more than half the proxy's long edge (1024), so the model always sees at
  least twice the whole-frame pass's detail; still at most eight, still skipped when no
  edge is in them. Whole-frame subjects now get six tiles.
- **Tile seams** (1.2): the merge was already overlapped a quarter, faded and near-edge
  only. A seam ratio (steps across tile borders against steps half a tile in, 99th
  percentiles) is logged and warned about over 3 (`SEAM?`).
- **The colour snap** (1.3): in a ring ±4 px at 33 MP (scaled by √MP, at least 2), each
  pixel's colour, in linear light, says where it sits between the nearby background and
  subject colours (the quarter-size push-pull fields), gated by contrast 0.08–0.20, moved at
  most 0.6, then tidied by a 2 px guided pass as far as it acted. Not in the hair zone.
- **Decontamination** (1.4): every part-covered edge pixel gets its own colour shares, hair
  zone included. For exposure and warmth (plain gains) blending through the shares is
  exactly `α·Adj(F) + (1−α)·Adj(B)`; exports use the same path.
- **Two stair-step causes found and removed** (the spec's 1.2 and 2.3.2 "blockiness"):
  1. Where the model was 93–97% sure over a wide area, blocks of the quarter-size band
     were forced solid beside neighbours left at 95%: square steps on white. First-pass
     values within 0.06 of 0 or 1 are now taken as 0 or 1, which also joins the band to its
     surroundings without a step.
  2. Alpha 12's brightness snap switched on and off along an edge and left it jagged in
     steps of a few pixels. It is off; the colour snap does that job.
- **Pinhole filling** cut from 0.01% to 0.002% of the frame: small true gaps between leaves
  and fingers were being half filled (they came out at 51%).
- **Metrics** (1.7): halo and erosion in two rings (0–3 and 3–10 px), hair and elsewhere;
  the snap's pixels, mean move and share of the ring that passed the gate; decontaminated
  pixels and mean shift; the seam ratio. `HALO?` now warns over 0.02.
- **Off is the default; the tiers are under Debug** as "Hair tier" (2.1).
- **The model stays loaded for two minutes** after leaving Edit (Phase 3.1).
- **JSON log lines carry fields** (Phase 3.2) for model calls, mask jobs and mask results:
  image, job, tier, seconds, memory before/peak/after, each edge metric.

**Measured here on the eight proxies** (the engine run as the app runs it, on tiles made
with the new rule; alpha 12's edge against the new one; "elsewhere" = away from hair):

| Photo | Halo 3–10 px | Halo 0–3 px | Colour fringe |
|---|---|---|---|
| 6303 | 0.016 → 0.001 | 0.187 → 0.144 | 0.235 → 0.054 |
| 6372 | 0.029 → 0.014 | 0.223 → 0.177 | 0.256 → 0.048 |
| 6378 | 0.027 → 0.008 | 0.225 → 0.182 | 0.286 → 0.065 |
| 6465 | 0.018 → 0.001 | 0.213 → 0.168 | 0.349 → 0.088 |
| 6957 | 0.017 → 0.001 | 0.186 → 0.152 | 0.184 → 0.032 |
| 7006 | 0.015 → 0.001 | 0.199 → 0.162 | 0.238 → 0.053 |
| 7451 | 0.009 → 0.000 | 0.170 → 0.150 | 0.206 → 0.047 |
| 7473 | 0.017 → 0.002 | 0.269 → 0.191 | 0.244 → 0.156 |

- **3–10 px ring ≤ 0.02: met on all eight.**
- **0–3 px ring "50% lower": not met, and it can't be by this measure.** It falls 10–30%.
  Mean alpha within 3 px of an edge is mostly that edge's own one-to-two-pixel softness,
  which a correct edge also has; it does not see an edge that is in the wrong place.
- **Colour fringe** was added for that: away from hair and where the two colours can be
  told apart, how far the mask is from what each edge pixel's own colour says. It falls
  four to six times on seven photos (7473, mostly hair and low contrast, less).
- By eye, rendered as the app's Background −3 EV and On White: the pale rim round 6303's
  fingers, the orange rim round 6372's rose and hand, and the fringe on 6957's hand are
  gone or nearly; boots on 6957 and 7451 stay clean.

**The automated build (alpha 13):** compiled first time; the Mac tests pass, the pipeline
test now with four close-up tiles and a tier change that runs no model; the app starts in
Edit and loads the model (peak 1.1 GB on the build machine, as before). The download is
411 MB. Nothing in it has yet been seen on a real raw file.

**Changed from the spec, or not done, and why:**
- **The automatic gap check (1.5) is not built.** Prototyped on the proxies as specified
  (colour near the background's, far from the subject's, no sharp detail, enclosed), it
  flagged 17 regions on 6303 and 205 on 6372, among them 6303's white sash (3,900 px,
  "matches the background"). The defocus test cannot save it: the sharpness map is measured
  at edges, a gap's own edges are the subject's sharp outline, and plain costume has no
  detail either. Opening gaps is left to the Refine Edges box, where the model looks closer
  and the owner points.
- **7451's arm–waist gap was already open** in alpha 12's mask (the model cuts it in every
  pass; checked in the whole-frame answer at both sizes). It read as filled because that
  background is light grey, so three stops down it is still lighter than the black top, with
  the bright fringe round it. With the fringe gone it reads as background.
- **6372's rose area** was halo plus half-filled pinholes rather than one enclosed region;
  the tiles, the pinhole limit, the snap and the shares deal with most of it.
- 1.3 says to skip nothing but hair; an outright colour-difference floor (0.10–0.25) was
  added to its contrast gate. The spec's measure is proportional, and black boots on dark
  asphalt differ a lot in proportion: without the floor the snap acted there.
- 1.4 names multi-level foreground estimation; the colours come from the smooth push-pull
  fields nudged to reproduce each pixel exactly. Same idea, one level.
- Figure 4's cut on 6957 could not be located in the proxy to confirm; two causes of such
  steps are fixed (above) and the seam ratio will say if tiles are a third.
- **Timing:** a whole-frame subject is now seven model passes, about 6 s of model time at
  the owner's 0.87 s, before the edge work: over the 6 s target for those photos.
  Full-length shots (three to five tiles) stay under it. To be read off the owner's log.

**Phase 2, next build:** the Refine Edges box, the Refine Hair brush, edit ops with undo,
BiRefNet-matting (its licence to confirm, and it would ship inside the download like the
main model, not download on first use), colour matting recalibrated on the owner's
seamless shots, the tiers' own blockiness (2.3.2).

## Still to design

The owner will share screenshots of how they use Bridge. Until then these are open: where
folder navigation lives, whether there is a full-window grid, where rating and metadata are
shown, how several frames are selected for the editor, the font, the overall look.

## Known caveats

- Masking keeps more in memory than before while a folder is open: three neutral renders
  (131 MB each at 33 megapixels), and for the last photo masked the edge engine with its
  own copy of the photo (roughly 300 to 400 MB). All of it is let go when another folder is
  opened or macOS reports memory pressure.
- The hair zone is a box around each face (2.6 face widths by 3 face heights). Long hair
  that falls below it gets the Off edge, not strand matting. The Zones view shows the box.
- With no face found the whole edge counts as hair zone, so the colour snap (which skips
  hair) does nothing on such a photo; decontamination still applies.
- The colour snap goes by colour: where a thin sliver beside the edge is the subject's
  colour (a lit sole edge between two boots), it can add a one-to-two pixel line of mask.
- The model is unloaded two minutes after leaving Edit mode; entering it later loads it
  again in the background, a second or two during which Make waits.
- Edits in Camera Raw's fields are uncalibrated: Photoshop opens a photo close to, not
  identical to, what TrainCull showed. Whether Camera Raw honours a sidecar holding only
  exposure, temperature and tint is untested.
- The slider ranges are a best reading of Apple's controls, not verified.
- While a slider moves the image is a quick smaller render; the full one follows.
- Thumbnails do not show edits.
- Each downloaded build must be allowed once in System Settings, Privacy & Security. Only an
  Apple Developer account (paid yearly) removes that step.
- GitHub counts Mac build minutes at ten times the normal rate on a private repository.
- The download link only works for someone signed in to GitHub while the repository is private.
- Raw renders are kept for the last three frames, 131 MB each for a 33-megapixel frame, and
  from alpha 6 that memory is never handed back while they are kept. Resting memory may
  therefore sit a little higher than in alpha 5 even though the peaks should be lower.
- In the side-by-side view "the same percentage" assumes both frames are the same size until
  each has been measured; frames of different sizes can differ for a moment after loading.
- The zoom glide redraws the image on the processor. The log notes how many frames each glide
  drew; if that is low on large files the drawing should move to the graphics card.
- An exported TIFF has not yet been opened in Photoshop by anyone, only in Apple's reader.
- Exports land in the folder being browsed; they are not shown there (only raws are).
- An export that is interrupted leaves a hidden `.exporting` file, removed the next time the
  folder is opened.
