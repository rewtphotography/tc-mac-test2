An alpha build of TrainCull for Mac (Apple silicon, macOS 15 or later).

**To install**

1. Download `TrainCull.dmg` below and double-click it. A window opens.
2. Drag `TrainCull` onto the `Applications` folder in that window. If asked, choose **Replace**.
3. Open TrainCull from Applications. The first time, macOS says it can't check the app. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to the message
   about TrainCull and click **Open Anyway**. This is needed once for each new build.

**New in this build: back to alpha 16, plus two colour tools (masking spec v7)**

- **Everything from alphas 17 and 18 is gone.** Masks, Refine Edges and the tool menu are
  alpha 16's again. That includes the fix for lost masks: once more, only the last two
  photos keep their masks, tool edits and Subject / Background / Skin adjustments.
- **Edge colour from inside** (automatic): each edge pixel's colour is taken from the solid
  subject just inside it, as Photoshop's Decontaminate Colors does. Aimed at the teal on
  7451's sleeve, the olive on its skin in the arm–waist gap, and the green on 6303's peace
  sign. Rim light (an edge brighter than the inside) is left alone. Debug: **Edge colour from
  inside** (on).
- **Remove Colour** (tool menu): click the background colour the mask took in (Shift-click
  to add more), then drag a box over the place. Only the edge, up to 40 px in, is touched.
  **Tolerance** sets how close a colour must be; moving it redoes the last box.

Please check, at 300% in On Black and Background −3 EV: 7451's sleeve and the skin in the
gap; 6303's fingers, cuff and sleeve (no green, no small squares); 6957 with a box over the
fingers and the gap, as in alpha 16; 6372 with the orange wall picked and a box round the
rose; and that hair on 7006 and 7473 looks as in alpha 16. Then send the log.

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
