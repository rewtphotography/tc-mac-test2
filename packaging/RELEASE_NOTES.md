An alpha build of TrainCull for Mac (Apple silicon, macOS 15 or later).

**To install**

1. Download `TrainCull.dmg` below and double-click it. A window opens.
2. Drag `TrainCull` onto the `Applications` folder in that window. If asked, choose **Replace**.
3. Open TrainCull from Applications. The first time, macOS says it can't check the app. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to the message
   about TrainCull and click **Open Anyway**. This is needed once for each new build.

**New in this build: the fringe and halo fixes (masking spec v4, Phase 1)**

- **The rim along edges.** Where the subject and the background are clearly different
  colours, the edge now goes where each pixel's own colour puts it, and every edge pixel
  knows how much of its light is the subject's. Darkening the background no longer leaves a
  bright or coloured line round fingers, arms and sleeves. Black boots on dark ground are
  left as they were.
- **Closer looks on every photo**, including ones the subject fills (they were skipped).
- **No more square steps** in soft areas, and no jagged edge on soft-edged things: two
  causes found and removed.
- **Small gaps** between leaves and fingers are no longer half filled.
- **Make Mask** makes the mask; there is no tier to choose. The old hair tiers are under
  **Debug → Hair tier**, for comparison only.
- The model stays loaded for two minutes after you leave Edit.
- The log now gives, for every mask: halo in two rings (0–3 px and 3–10 px), a colour
  fringe figure, how much the snap moved, and a check for tile seams.

Not in this build: the **Refine Edges** box and the **Refine Hair** brush (next), and
automatic opening of enclosed gaps. Tested here as specified, the gap check would have cut
pieces out of costumes, so gaps wait for the box.

**The masking test:** open **Edit** and scroll to **Mask (Test)**. Click **Make Mask**.
**Show** switches between the photo, a red overlay, the mask, On Black, On White,
**Background −3 EV** and a debug view of zones. Pick **Subject**, **Background** or **Skin** and
move **Exposure**, **Saturation** or **Warmth**. Masks and local adjustments last until you
close the folder; **Export 16-bit TIFF** includes them. The app never uses the network: the
model is inside the download.

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
