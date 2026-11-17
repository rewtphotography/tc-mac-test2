An alpha build of TrainCull for Mac (Apple silicon, macOS 15 or later).

**To install**

1. Download `TrainCull.dmg` below and double-click it. A window opens.
2. Drag `TrainCull` onto the `Applications` folder in that window. If asked, choose **Replace**.
3. Open TrainCull from Applications. The first time, macOS says it can't check the app. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to the message
   about TrainCull and click **Open Anyway**. This is needed once for each new build.

**New in this build: masking spec v6, and a fix for lost masks**

- **Masks are no longer lost.** Until now only the last two photos kept their masks: a third
  photo quietly dropped the first one's mask, its tool boxes and strokes, and its Subject /
  Background / Skin adjustments stopped showing and were left out of its TIFF. Now a photo
  with tools or adjustments keeps its mask until you close the folder, and an export either
  includes its adjustments or says it couldn't.
- **No green or teal line at hard edges** in Background −3 EV and On Black: at the edge the
  subject keeps no light its own colour doesn't have. Debug: **Subject light bound**.
- **Refine Edges refines the edge** and no longer re-decides the whole box: it only takes out
  what is out of focus or plainly background, and the model sees more round a small box.
  **Hold Shift** while dragging for the old behaviour.
- **Refine Hair** has **Strength** and **Tightness** (raise Tightness to leave flyaways out).
- **Edge Brush** replaces Clean Edge in the tool menu: paint along a hard edge (fingers, a
  sleeve). Clean Edge is under Debug.
- **Hands are refined automatically** when you click Make Mask. Debug: **Automatic hands**.
- **The hair zone** is smaller and never covers hands or arms; the Zones view outlines it.
  A photo with no face now gets its edges cleaned. Debug: **Ignore faces** to try that.
- Small see-through spots inside the subject are filled solid.
- A tool used while a mask is being remade now waits for it; the first Refine Hair stroke no
  longer waits for the model to load.

Checked here only on made-up pictures: please try 6303, 7451 and 6957 with the base mask
alone (Background −3 EV and On Black at 300%), a few boxes and strokes, and send the log.

**The masking test:** open **Edit** and scroll to **Mask (Test)**. Click **Make Mask**.
**Show** switches between the photo, a red overlay, the mask, On Black, On White,
**Background −3 EV** and a debug view of zones. Pick **Subject**, **Background** or **Skin** and
move **Exposure**, **Saturation** or **Warmth**. Masks and local adjustments last until you
close the folder; **Export 16-bit TIFF** includes them. The app never uses the network: both
models are inside the download.

**Since alpha 4**

- **Side by side:** command-click a second thumbnail. The active image has a yellow border;
  stars, labels, reject and ← → act on it alone. Click the other image to make it active (or
  press Tab). Click the active image to zoom both to the face; pinch zooms both; two-finger
  drag pans one. Command-click another thumbnail to replace the active image. **Esc** or the
  **Single View** button goes back.
- **Exports:** right-click a thumbnail, or use the File menu, for **Extract Embedded JPEG** and
  **Export 16-bit TIFF** (ProPhoto RGB, ZIP). They are saved next to the raw. The File menu can
  also export every frame shown, so filter to your keepers first.
- **Help → Diagnostics** says in plain words how much memory TrainCull is using (now, average,
  peak) and shows the log file to send when something goes wrong.
- A thinner title bar, **Edit** as a yellow word, a one-line bar under the image, a short glide
  when zooming, and the counts at the bottom left scroll the thumbnails to the current image.

**Keys:** ← → step frames · 1–5 stars, 0 clears · ↑ ↓ raise or lower the rating · X reject ·
6 7 8 9 red, yellow, green, blue label · Tab next face (the other image when side by side) ·
Space full screen · Esc back one level.

Click the large image to zoom to the face; click again to go back. Two-finger drag pans,
pinch zooms.

**Editing:** the **Edit** button at the top right swaps the thumbnails for Apple's raw controls.
Click a value to return it to its default. The small button at the top left brings the thumbnails
back while editing. Edits are saved to the photo's `.xmp` sidecar.

**Filtering:** click **★ n rated** at the bottom left to show only rated frames; double-click it
to choose how many stars. Click **n frames** to show everything again.
