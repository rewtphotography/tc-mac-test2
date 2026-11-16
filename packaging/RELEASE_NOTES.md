An alpha build of TrainCull for Mac (Apple silicon, macOS 15 or later).

**To install**

1. Download `TrainCull.dmg` below and double-click it. A window opens.
2. Drag `TrainCull` onto the `Applications` folder in that window. If asked, choose **Replace**.
3. Open TrainCull from Applications. The first time, macOS says it can't check the app. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to the message
   about TrainCull and click **Open Anyway**. This is needed once for each new build.

**New in this build: where the mask's edge sits (the final masking round)**

- **The pale rim.** The mask's edge is now moved onto the photo's own edge and made as
  wide as it, the colours either side are read right beside it, and the few pixels just
  inside the edge have the background's light taken out of them too. That is aimed at the
  3–4 px pale rim round fingers, arms and waists in **Background −3 EV**.
- **Less colour added.** The colour guard had been catching one mistake over and over at
  bright-on-dark edges; that mistake is gone, and the guard now also stops an edge coming
  out darker than the subject beside it (the log counts those separately).
- **Tools.** Refine Edges and Refine Hair no longer leave a ragged edge on small areas;
  Clean Edge is smoother; the Refine Hair "contrast" figure is no longer always 1.00.
  If a large Refine Edges box ever reports "0 px changed" again, the log now says why and
  the first, quicker result is kept.
- **The log** has a new line for every mask, `edge placement`: how far the mask's edge is
  from the photo's (positive is outside the subject), and how wide each is.
- **Export Debug Bundle** now includes full-size pieces of the photo with the mask over
  them, round wherever a tool was last used. To have an edge looked into, drag a
  **Refine Edges** box over it, then export.
- **Debug** has one more switch, **Edge re-centre**. Off is alpha 14's edge.

This has been checked here on enlarged copies of your eight test photos, not on the photos
themselves: please look at 6303, 7451 and 6957 with the base mask alone, and send the log.

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
