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

## Version 0.2.0: a restart from alpha 6

Masking (alphas 7–23) is archived on branch `archive/masking`, tag `masking-final`.

0.2.0 alpha 1 is alpha 6's tree (restored as a new commit on top of alpha 23's history, so
every old tag still works) plus the few non-masking gains of alphas 7–23, re-made by hand:
- The log has a `.jsonl` twin (one JSON object per event, with named `fields`), info / warn /
  debug levels and keeps 20 sessions. A `JobMeter` gives each full raw render and each export
  its wall time, memory before / peak / after, processor time and thermal state (`job` lines).
  Each selection gives its cause (click, key, programmatic); renders give their trigger and
  drafts the requests coalesced; render cache hits and misses (cold, evicted, other edits);
  the camera settings the first time a frame is selected; display scale and thermal state
  at launch; a cache summary every 15 memory lines; a memory reading on entering Edit mode.
  The file-writing part is in the core library (`LogFiles`), so it is tested on Linux.
- The render cache keeps up to 900 MB of renders, least recently shown out first, instead of
  the last three frames; each eviction is logged. A 61 MP render is about 240 MB (three fit),
  45 MP about 180 MB (four), 33 MP about 131 MB (six). Core library: `RenderCache`.
- Zoom goes to 400% (was 200%).
- The status under the image says "Raw" again after the full render that follows an edit.
- The Mac build runs only the Mac tests; the core tests run on Linux.
- Only `main` and version tags publish. Releases are tagged `v0.2.0-alpha.N`; the app says
  "0.2.0 alpha N" in the log's first line, under the empty view and in the About panel.
- Left out: the masking launch lines (model, blending), every `mask` / `tool` line and the
  memory-pressure handler (it only let go of masking's memory).
- Not carried over from the alpha 23 notes: everything about masking. The alpha 6
  measurements are below.

## Debug export and test scripts (0.2.0 alpha 3, alpha only)

The owner's spec (2026-11-21, with three amendments): a debug package of the current image and a
JSON test-script runner, so RAW engine tests with another chat need no screenshots.
- **Adopted:** Debug ▸ Run Test Script… (strict validation, a dialog with the index, errors,
  warnings and size estimates, Run / Cancel, progress with Cancel), Debug ▸ Export Debug
  Package (script 00, counter 01–99 kept across launches, warning at 99), Debug ▸ Reset
  Manual Export Counter. Output in `~/Pictures/TrainCull Debug/`, a new `script-NN_date-time`
  folder per run (a `-2` suffix if two land in one second): baselines outside the zips, one
  `TC-test-NNCC.zip` per test, `run-manifest.json`, the folder shown in Finder at the end. One
  `debug` log line per test (id, file, status, zip, zipSize, renderMs). Amendments: cases
  setting `isHighlightRecoveryEnabled` are "skipped: requires macOS 27"; screen.png waits
  for the settled full-resolution preview and takes its Display P3 pixels before any
  display conversion; "min"/"max" are the slider's ends, "default" is Apple's true default,
  and every control's slider range is in report.json.
- **How it is built:** everything in `Sources/TrainCull/AlphaDebug/` (see its README for
  removal), compiled only with `TC_ALPHA_DEBUG` (Package.swift; on unless built with
  `TC_ALPHA_DEBUG=0`). It can't be a separate Swift module, because it uses the app's
  render and export code; the app references nothing in it except the one Debug menu line.
  Small general helpers it reads: `Export.render16`, `Imaging.developedReading`,
  `Session.settledPreview`, `Session.singleView`, `HeroNSView.visibleSpaceRect`,
  `RenderCache.peek`.
- **One render:** every picture comes from the TIFF export's render (16-bit ProPhoto,
  full resolution). frame.png is that render drawn at 3000 px long edge into 8-bit Display
  P3 by Core Graphics; crops are cut from it unchanged (16-bit ProPhoto PNG); fullResTIFF
  adds `frame.tif` (the export's own TIFF writer) to the zip.
- **Defaults chosen:** zips store their files as they are (PNGs are compressed already),
  written in code, no outside tool. A manual export's report holds its case as the script
  would have written it (the current edits under Apple's names), and is allowed out-of-range
  values. Toggles take true / false / "default" only; neutralLocation can't be combined with
  neutralTemperature or neutralTint. On macOS 27 or later, highlight-recovery cases are still
  skipped ("not yet supported by this build") until it is added.
- **Size estimates** are made before anything renders, from the frame size and PNG rates
  measured on the made-up DNG (1.7 bytes per pixel at 8 bits, 4.5 at 16); real ARWs may differ.
  The manifest gives estimate and actual for every zip.
- `-TCDebugScript`, `-TCDebugExports`, `-TCDebugZoomedExports` and `-TCDebugResetCounter` are
  launch-check settings for B3, B12 and B13 (no dialogs, no Finder window).

## RAW panel spec (0.2.0 alpha 2)

The owner's spec (pasted in, 2026-11-21): the RAW panel in pipeline order, new Apple
controls, red dots for unsupported ones, a structured change log, and self-tests T1–T13.
Audited against the code first; what was adopted, changed or left out:
- **Adopted:** five sections that fold away (remembered per section), in the spec's order,
  with "New name (Apple name)" for Local contrast (Contrast), Blacks (Shadow bias), Tone curve
  (Boost) and Shadows (Shadow boost). New: Decoder line, Lens correction, White balance by
  point, Baseline exposure, Gamut mapping. Existing sliders keep their keys, ranges, defaults,
  what they send to Apple and their sidecar fields. Controls with an is…Supported flag that
  Apple reports false are greyed out with a red dot ("Not supported for this file") and
  nothing is sent for them (`RawPanel.sendable`, and again in `Adjust.apply`). Every change
  logs one `change` line (file, control, appleProperty, old/new, appleDefault, readBackValue,
  renderMs, peakMemoryMB, zoom, isDragEnd, cause) when the full render showing it is on
  screen; a drag logs once at its end; Reset All logs one line per control it resets; each
  selected file logs one `raw` line with every Apple default and supported flag.
- **Left out:** Highlight recovery (`isHighlightRecoveryEnabled`): not in Apple's raw filter
  on macOS 15 (no such property, no mention of highlights in any Core Image header). No row,
  nothing saved; the owner chose this. `CIHighlightShadowAdjust` is a different control and
  may come later under its own name.
- **Defaults chosen:** the decoder line reads "RAW 8 (DNG)" for a DNG decoder. White balance
  by point stores Apple's read-back as Temperature and Tint (the existing fields, so
  `WhiteBalance=Custom`); the point itself is not saved. New controls are saved under
  TrainCull's namespace, toggles as True / False, only when moved. Baseline exposure's
  slider is −3…+3 EV (Apple gives no range). Gamut mapping has no is…Supported property, so
  it never gets a red dot. Saturation and Vibrance are Core Image filters: their read-back
  is the value asked for. T9's "5×5 patch" is judged on the patch's mean colour (the DNG has
  noise by design).
- **Tests:** no raw file may be kept in the repository, so the decoder tests run on a
  made-up DNG built in code (`SyntheticDng`: gradient, neutral grey patch, blocks clipped in
  one and two channels, noise; also stored on its side, orientation 6). Its results are DNG
  results, not ARW findings. The ARW figures (Shadow bias true defaults, Shadow boost
  read-backs, red dots) come from the owner's log. The launch check opens the DNG
  (`-TCListDNG`, launch check only: no recipe lists DNGs) and drives the panel with a script
  (`-TCScript`, T12).
- **Minimum macOS:** every property used is part of `CIRAWFilter`, macOS 12.0; the header
  marks availability on the class only (the build prints it, step "Raw filter API").

## How the preview is rendered (0.2.0 alpha 2; for the later performance build)

- A new `CIRAWFilter` is made, and the raw file re-decoded, for every render: each selection
  render, each draft, each full render after an edit, each export, and once more on selection
  to read Apple's defaults. Nothing is reused between slider changes.
- Draft mode (`isDraftModeEnabled`) is never set, so it stays Apple's default (off) in every
  case. While a slider moves, drafts use `scaleFactor` sized to the view (0.1–1); once the
  sliders are still for 0.4 s, a full-resolution render (scale 1) follows. The selection
  render is always full resolution, at fit and at 100% alike; fit only shrinks it on screen.
- Selecting a frame shows its thumbnail at once, then the camera's large embedded JPEG
  (status "Preview"), then 0.15 s later TrainCull's full raw render (status "Raw"). If
  Apple's decoder can't develop the file, the full embedded JPEG stays ("Embedded JPEG").
  "Raw · Fit" means the image is TrainCull's own full render of the raw with the edits, shown
  whole in the view; drafts during a drag are shown while the label still says "Raw".
- Core Image works in 16-bit half float, linear, extended sRGB primaries (the context's
  defaults; caching of intermediates off). The preview is rendered to 8-bit RGBA in Display
  P3; the TIFF export to 16-bit in ProPhoto RGB.
- Renders run off the main thread: drafts one at a time on their own queue (requests while
  one runs are coalesced into the next); full renders on another queue. A render not yet
  started is skipped if newer edits arrived; one already running is not cancelled; its result
  is kept in the cache but not shown.
- Saturation (`CIColorControls`) then Vibrance (`CIVibrance`) are applied to Apple's
  output image, in Core Image's linear working space, before any clamp (the clamp is the
  final render into 8- or 16-bit); only when moved.
- Other differences from the export: drafts are smaller renders; the preview is 8-bit and
  P3, so smooth gradients can band where the 16-bit ProPhoto TIFF won't; macOS converts the
  P3 preview to the display's own profile.

## What is built (0.2.0 alpha 1; alpha 6 plus the list above)

Folder opening (button, File menu, drag and drop, recents, drives), resizable left pane,
thumbnails with rating, label and reject marks, the large image with raw render and face
zoom with a glide, ratings and labels, edit mode with 15 of Apple's raw controls saved to the
sidecar, Send to Photoshop, the one-line bar under the image, click-to-filter on the counts
at the bottom left (double-click the rated count to choose stars), side-by-side compare,
extracting the embedded JPEG, exporting a developed 16-bit TIFF, the diagnostics log and
memory report, an app icon.

Checked by tests on Linux (77): the RAW panel's layout, red dots, decoder line and sidecar round trip, the made-up DNG, the log files and their JSON twin, the render cache, raw and recipe reading, the settings line, sidecar editing,
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
- A raw render takes 0.38–0.40 s in the background (0.9 s for the very first, while
  thumbnails load) and the sharp image arrives about 0.55 s after landing on a frame. Every
  glide drew 17–25 frames, including the first zoom after a new image and in the side-by-side
  view. No draw took longer than 33 ms.
- Memory averaged 951 MB and peaked at 2.2 GB (while sliders moved). Loading the thumbnails
  peaked at 0.8 GB, down from 1.4. Browsing sits at 1.3–1.4 GB just after each render and
  rests near 770 MB, because the kept renders hold their memory.
- Stepping fast renders one frame at a time, so a frame already left can hold up the wanted
  one by up to 0.4 s. Not a complaint yet; cancel a render in flight if it becomes one.

## Waiting for a newer macOS

- RAW 9 (the newer raw decoder): requires macOS 27; add when the Mac is updated.
- Highlight recovery (`isHighlightRecoveryEnabled`): requires macOS 27; add when the Mac is updated.

## Next, in order

0. The owner runs the alpha 3 checklist on real ARWs (B11's Local tone map, B12's manual
   export) and sends the zips and log. Before that, from alpha 2: the owner opens their four
   a7 IV test ARWs and sends the log: its `raw`
   lines give Shadow bias's true default, Apple's other defaults and the red dots per file;
   its `change` lines give the Shadow boost read-backs. Then the next note: debug export and
   the JSON test-script runner; after that, performance (informed by the section above).
1. The owner's next spec (after 0.2.0 alpha 1): Nikon Z7 NEF files don't open (only Sony ARW
   has a recipe); the Shadow bias slider (−1…1) can't hold the photo's own default of 3.00;
   Send to Photoshop writes Apple's numbers into `Exposure2012`, `Temperature` and `Tint`
   (forcing `WhiteBalance=Custom`); the XMP field pattern fails on an apostrophe inside a
   double-quoted value and can add a duplicate attribute; memory and speed with 61 MP A7CR files.
2. Soft-focus and closed-eyes flags from Apple's face landmarks.
3. A Settings window (label names, editor choice), Undo after reject.

## Still to design

The owner will share screenshots of how they use Bridge. Until then these are open: where
folder navigation lives, whether there is a full-window grid, where rating and metadata are
shown, how several frames are selected for the editor, the font, the overall look.

## Known caveats

- Edits in Camera Raw's fields are uncalibrated: Photoshop opens a photo close to, not
  identical to, what TrainCull showed. Whether Camera Raw honours a sidecar holding only
  exposure, temperature and tint is untested.
- The slider ranges are a best reading of Apple's controls, not verified.
- While a slider moves the image is a quick smaller render; the full one follows.
- Thumbnails do not show edits.
- Each downloaded build must be allowed once in System Settings, Privacy & Security. Only an
  Apple Developer account (paid yearly) removes that step.
- The repository is public (since alpha 21): anyone can read the code and notes.
- Shadow bias's default can lie far outside its slider (5.00 on the made-up DNG, 3.00 the
  owner saw on ARWs): the thumb sits at the end while Apple's true value is used; touching the
  slider then jumps the image. The slider's range is unchanged in this build (spec).
- The status under the image says "Raw" while a slider moves, though a smaller draft is shown.
- White balance by point is saved as Temperature and Tint, which Camera Raw then reads as
  Apple's numbers in Adobe's fields (the issue already listed for the next spec).
- A change made and then left before its full render (another frame chosen within 0.4 s)
  logs its line without a render time.
- Kept renders hold up to 900 MB, and that memory is not handed back while they are kept
  (until another folder is opened). With 33 MP files that is six frames, where alpha 6 kept
  three, so resting memory can sit up to about 400 MB higher than alpha 6's.
- The automated build keeps the app as an artifact for 14 days. If GitHub's artifact storage
  is ever full, that upload fails and so nothing is published; the launch pictures never stop
  a build.
- The launch check enters Edit mode for 15 seconds on the made-up frames, to read Edit mode's
  memory; the spec asked to drop alpha 23's longer Edit-mode check, which waited for the model.
- The About panel and the log say "0.2.0 alpha N (build B)"; B is GitHub's run number and
  only ever goes up.
- In the side-by-side view "the same percentage" assumes both frames are the same size until
  each has been measured; frames of different sizes can differ for a moment after loading.
- The zoom glide redraws the image on the processor. The log notes how many frames each glide
  drew; if that is low on large files the drawing should move to the graphics card.
- An exported TIFF has not yet been opened in Photoshop by anyone, only in Apple's reader.
- Exports land in the folder being browsed; they are not shown there (only raws are).
- An export that is interrupted leaves a hidden `.exporting` file, removed the next time the
  folder is opened.
