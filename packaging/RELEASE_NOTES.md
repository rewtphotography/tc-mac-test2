An alpha build of TrainCull for Mac (Apple silicon, macOS 15 or later).

**To install**

1. Download `TrainCull.dmg` below and double-click it. A window opens.
2. Drag `TrainCull` onto the `Applications` folder in that window. If asked, choose **Replace**.
3. Open TrainCull from Applications. The first time, macOS says it can't check the app. Click
   **Done**, then open **System Settings → Privacy & Security**, scroll down to the message
   about TrainCull and click **Open Anyway**. This is needed once for each new build.

**New in this build (0.2.0 alpha 3): debug tools (alpha only)**

- A **Debug** menu. **Export Debug Package** saves the photo you're looking at, with its
  edits, as a small zip for testing the raw engine: the full picture, what the screen shows,
  and a report of every setting. If you're zoomed in, the zoomed part is included at full
  quality. **Run Test Script…** reads a test script (a .json file) and makes one zip per test.
- Everything goes in **Pictures ▸ TrainCull Debug**, in a new folder each time; nothing is
  ever overwritten, and your photos and sidecars are never changed.

**In 0.2.0 alpha 2: the RAW panel**

- The editing controls follow Apple's own order in five sections: **Raw & Detail**, **Light**,
  **Tone curve**, **Colour** and **Output**. Click a section's name to fold it away; the app
  remembers which are folded.
- Four controls show a new name with Apple's in brackets: **Local contrast (Contrast)**,
  **Blacks (Shadow bias)**, **Tone curve (Boost)**, **Shadows (Shadow boost)**. Nothing else
  about the existing sliders changed.
- New: **Lens correction**, **Baseline exposure**, **Gamut mapping**, the **Decoder** line
  (RAW 8), and **White balance by point**: click **Pick**, then something neutral grey in the
  image; Temperature and Tint follow. **Esc** cancels.
- A control Apple can't use for a photo is greyed out with a small **red dot**; hover over it
  to see why.
- **Reset All** returns every control, old and new, to Apple's default for the photo.
- The log records every change with its effect and timing, and Apple's defaults for each photo.

**Since 0.1.0 alpha 4**

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
