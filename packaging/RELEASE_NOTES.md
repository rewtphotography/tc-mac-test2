An alpha build of TrainCull for Mac (Apple silicon, macOS 15 or later).

**To install**

1. Download `TrainCull.dmg` below and double-click it. A window opens.
2. Drag `TrainCull` onto the `Applications` folder in that window. If asked, choose **Replace**.
3. Open TrainCull from Applications. The first time, macOS says it can't check the app. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to the message
   about TrainCull and click **Open Anyway**. This is needed once for each new build.

**New in this build: the masking chapter closed (masking spec v7.2)**

- **Background-coloured edge pixels are cut** automatically: green streaks on fingers,
  orange specks by the rose, the bright notch cluster. Real rim light is kept. Debug: **Cut
  background-coloured edge pixels** (on).
- **The background side is repainted too:** with Background darkened, the fringe just
  outside an edge (7451's dark green line) takes the wall's own colour.
- **Remove Colour: drag the box straight away.** The colour to remove is guessed from the
  box (swatches marked "auto"). If it guesses wrong, click the colour with the tool: the box
  is done again with it (Shift-click adds one; Clear goes back to the guess). Edges stay
  smooth, without stair-steps.
- **Edge Colour** (tool menu): drag a box where an edge keeps a bright or coloured rim it
  shouldn't; inside it every edge pixel takes the colour from just inside.
- **Refine Hair: Strength**, 0 by default, only tidies the edge; raise it to let a stroke
  add strands. Moving it redoes the last stroke. The hair model is loaded ahead, so the
  first stroke doesn't wait.
- **Clean Edge is gone.**

Please check: 7451 with Subject +3 / Background −3 at 300% (no dark green line outside the
gap, no notch cluster, no yellow outline); 6303 default at 300% (no green streaks), then one
Remove Colour box over the fingers without picking a colour; 6372 default (fewer orange
specks), then one Remove Colour box over the rose without picking; 7006 with Refine Hair at
Strength 0; 6957's Refine Edges box and the hair on 7006 and 7473 as before. Then send the log.

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
