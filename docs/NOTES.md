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

**The large image**
- Fitted by default. No loupe, ever. Full screen is optional and never required for zooming
  or rating.
- A click goes to face zoom: the whole face framed with the eyes anchored, capped at 100%
  (`Framing.swift`). With no face found, the click zooms to 100% where it was clicked. A
  second click returns to fit.
- Two-finger drag is the only way to pan. Pinch reaches any other zoom, up to 200%.
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
- Tab: next face. Space: full screen. Esc: back one level.

**Ratings, labels, edits**
- `xmp:Rating` 1–5, 0 none, -1 reject. `xmp:Label` holds Bridge's label names: Select,
  Second, Approved, Review, To Do.
- Saved at once, crash-safely (temp file, then swap; leftovers repaired when a folder opens).
- Exposure, temperature and tint are saved in Camera Raw's fields so Photoshop can read
  them, uncalibrated for now. Other controls are saved under one TrainCull namespace.
- TrainCull is the first step and Camera Raw is a handoff: no two-way sync. Re-editing in
  TrainCull after Camera Raw is expected to be rare.

**Side-by-side compare (decided, not built)**
- Command-click a second thumbnail to show two images side by side.
- Zoom is linked. Panning is independent, with a possible toggle to link it.
- The active image has a small coloured border. Ratings, labels, reject and left / right act
  on it alone. The first click on the inactive image only makes it active; a click on the
  active image zooms both.
- Tab switches the active image; a clear on-screen button steps faces in this view.
- While comparing, command-click a thumbnail replaces the active image; a plain click on a
  thumbnail does nothing.
- Leaving takes Esc or a visible back button. Esc goes back one level at a time: full-screen
  compare, windowed compare, single view. The single view then shows the active image.
- Space makes the compare view full screen, with the same behaviour.

**Exports**
- "Export" means two things: extract the embedded JPEG unchanged, or render from raw plus
  edits. Extract and a developed 16-bit TIFF are wanted now (TIFF: ProPhoto RGB, ZIP
  compression, named after the raw). Rendered JPEG and other formats wait for the owner's
  research.
- Send to Photoshop: at the bottom of the editing pane and in a thumbnail's right-click menu.

**Cameras**
- Sony ARW is built in as a recipe (data describing where a format keeps its embedded
  previews). Other formats are imported recipes, later.

**Later, in the owner's words "a later option"**
- Subject stacks (grouping a shoot by person), true-burst stacking, companion app
  integrations, transfer and drive tools, controller support, batch rename, keywords, a
  folder tree, a calibration table mapping Apple's values to Camera Raw's.

## What is built (alpha 4)

Folder opening (button, File menu, drag and drop, recents, drives), resizable left pane,
thumbnails with rating, label and reject marks, the large image with raw render and face
zoom, ratings and labels, edit mode with 15 of Apple's raw controls saved to the sidecar,
Send to Photoshop, the camera settings line under the image, click-to-filter on the counts
at the bottom left (double-click the rated count to choose stars), an app icon.

Checked by tests (42): raw and recipe reading, the settings line, sidecar editing, crash-safe
saving, face-zoom maths. Checked by the owner on 1,523 Sony a7 IV frames: thumbnails, raw
render, face zoom. Not yet used by anyone on real files: edit mode, saving edits, Send to
Photoshop, filtering.

## Next, in order

1. Fix whatever the owner's use of alpha 4 shows.
2. Side-by-side compare.
3. Extract embedded JPEG; developed 16-bit TIFF.
4. Soft-focus and closed-eyes flags from Apple's face landmarks.
5. A Settings window (label names, editor choice), Undo after reject, a diagnostics log.

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
- Each downloaded build must be allowed once in System Settings, Privacy & Security.
- GitHub counts Mac build minutes at ten times the normal rate on a private repository.
