An alpha build of TrainCull for Mac (Apple silicon, macOS 15 or later).

**To install**

1. Download `TrainCull.dmg` below and double-click it. A window opens.
2. Drag `TrainCull` onto the `Applications` folder in that window. If asked, choose **Replace**.
3. Open TrainCull from Applications. The first time, macOS says it can't check the app. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to the message
   about TrainCull and click **Open Anyway**. This is needed once for each new build.

**New in this build: one edge rule for bright backgrounds (masking spec v7.2.1)**

- **No more dark specks inside finger edges.** Alpha 22's cut of background-coloured pixels
  is gone. In its place, where the background is clearly brighter than the subject beside
  it, the lens's colour fringe is judged on a slightly blurred copy of the photo, so single
  pixels and noise no longer punch holes. Only coverage the colours clearly don't support is
  taken off, softly, and both sides of the edge are repainted. Green streaks come out faint
  rather than gone.
- **Everywhere else (skin against a dark background, white on white, rim light) edges are
  alpha 21's.**
- Debug: the switch is now **Bright-background edges** (on).
- Remove Colour, Edge Colour and Refine Hair are as in alpha 22.

Please check at 300%: 6303 with Subject +2.6 / Background −3 (no dark specks or slivers; green
streaks gone or faint); 7451 with Subject +3 / Background −3 (no teal, no dark line, no notch
cluster); 6372 for anything new; 6957's box and the hair on 7006 and 7473 as before. Then send
the log.

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
