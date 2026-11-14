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

## What is built (alpha 6)

Folder opening (button, File menu, drag and drop, recents, drives), resizable left pane,
thumbnails with rating, label and reject marks, the large image with raw render and face
zoom with a glide, ratings and labels, edit mode with 15 of Apple's raw controls saved to the
sidecar, Send to Photoshop, the one-line bar under the image, click-to-filter on the counts
at the bottom left (double-click the rated count to choose stars), side-by-side compare,
extracting the embedded JPEG, exporting a developed 16-bit TIFF, the diagnostics log and
memory report, an app icon.

Checked by tests on Linux (64): raw and recipe reading, the settings line, sidecar editing,
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

1. Fix whatever the owner's use of alpha 6 shows; read the log and memory figures they send.
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
