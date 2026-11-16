# TrainCull Masking — Spec v5: Colour Fix and Refine Tools

**Status:** implementation spec for the next build. **Everything here ships in one build.** There are no phases, and nothing should be deferred without asking the owner first.

**Builds on** `masking-spec-v4.md` and `masking-spec-v3.md`. Where they conflict, **this document wins**.

---

## 0. Context

**The base mask (Off) is baseline usable on all eight test images.** Selection is solved, footwear is clean, and the close-up tiles now run everywhere. 7473's hair against the bright window is near perfect; against the low-contrast brown background it is soft but usable.

**Owner testing established one bug:** **the masking adds colour at high-contrast edges that the photo doesn't have.**
- With Moiré and Colour NR at 0, the untouched photo at 200% shows virtually no fringe at 7451's waist. Darkening the whole photo to −2.7 EV still shows none.
- Background −3 EV with the mask shows:
  - a green line along both sides of the arm and a teal line along the skin edge of the arm–waist gap (7451);
  - a pink line on the waist edge where blonde hair sits behind it (6957).
- Changing Moiré or Colour NR doesn't affect the masked fringe, so it doesn't come from the decode the mask reads.
- **Prime suspect:** edge decontamination. Per-channel clamping against near-white or very bright backgrounds shifts hue. **Second suspect:** the edge snap, whose background estimate is unreliable next to clipped highlights.

**Decisions:**
- **No automatic Defringe / chromatic-aberration step.** The photos don't need one.
- **No automatic gap check.** Gaps are opened with the Refine Edges box. (The v4 prototype over-flagged costume regions.)
- **Off stays the default.** The Off / Fast / High / Max tier control goes away (see §2.1).

---

## 1. Colour fix (bug)

### 1.1 Hard rule: masking never adds colour
For every pixel the masking pipeline writes (snap, decontamination, any refine tool), compare output and original in a perceptual space such as Oklab or Lab:
- **Chroma:** output chroma ≤ max(original pixel chroma, max chroma of its 3×3 neighbourhood in the original) + a small tolerance.
- **Hue:** when output chroma exceeds a small threshold, its hue must stay within ±15° of the original pixel's hue, or the neighbourhood's dominant hue.
- **If either check fails:** keep the computed lightness and blend chroma back to the original's.

Apply this as a final guard pass over the edge band, after all edge steps. Log the number of pixels it corrects. In a correct pipeline that number should be near zero, so it doubles as a bug detector.

### 1.2 Decontamination must preserve hue
- **Remove per-channel clamping.** When the reconstructed background `B = (I − αF)/(1 − α)` falls outside the valid range, scale the whole vector toward the original pixel colour until it fits. Never clip channels independently.
- **Near clipped or very bright backgrounds** (any channel of B̂ ≥ 0.9 of clip, or B̂ luminance ≥ 0.85): decontaminate **lightness only**. Keep the original pixel's chroma, and adjust only how much the background edit affects its brightness.
- **For pixels with α ≥ 0.95 or ≤ 0.05:** no decontamination at all; use the plain blend. This removes amplification of `(1 − α)` near 0.
- Decontamination only ever uses colours from the **same render the user sees**. The neutral reference decode may decide alpha, but never supplies colours that get written back.

### 1.3 Edge snap near clipped highlights
- Skip the snap where B̂ is near clipping (same test as §1.2), or where B̂ was estimated from fewer than N real background pixels (narrow gaps between objects). This also fixes the 1–2 px line the snap added along 7451's boot sole.
- Keep the snap's ±0.6 move cap.

### 1.4 Debug toggles
Under **Debug**: separate on/off switches for **Edge snap**, **Decontamination** and **Colour guard**. The owner must be able to turn each off and see the effect at 400%.

### 1.5 Acceptance (owner checks in Background −3 EV at 200–400%)
1. **7451 waist and arm:** no green or teal line along the arm or the arm–waist gap.
2. **6957 waist by the hair:** no pink line.
3. **7473:** report what drives its "colour fringe" reading of 0.164 (others are 0.04–0.06). It should fall after the fix, or be shown to come from legitimate hair colour.
4. **All eight images:** the colour guard corrects ≈ 0 pixels once §1.2–1.3 are in. Report the counts.
5. **No regression** in halo values or in the clean footwear and edges seen in alpha 13.

---

## 2. Refine tools

### 2.1 UI
- **Remove** the Off / Fast / High / Max control from the main UI. Off is the base; keep the tiers under Debug only.
- Add three tools to the MASK panel:

| Tool | Gesture | ⌥ (Option) |
|---|---|---|
| **Refine Edges** | Drag a box | Box restores the base mask inside it |
| **Refine Hair** | Paint (size slider; [ / ] keys) | Paint restores the base mask |
| **Clean Edge** | Paint (size slider; [ / ] keys) | Paint restores the base mask |

- Every operation is a non-destructive edit op: undoable, replayed on Remake, and recomputed only where it touched.
- **Overlay:** faint boxes and strokes while a tool is active.
- **Show the fast result immediately**, then the full-quality result when ready.

### 2.2 Refine Edges (box)
For fingers, footwear, gaps and prop edges.

1. **Crop:** the box expanded by 15%, from the full-resolution reference decode. Tile it at the model input size (1024) with ≥ 25% overlap, so the model sees ≥ 4× the base pass's detail.
2. **Run BiRefNet** → `Sc`. Keep only components that touch the current subject mask or overlap it by ≥ 30%. A box can never pull in a passer-by.
3. **Replace the mask inside the box** with `Sc_kept`, feathered 6 px at the box border.
4. **Open enclosed gaps inside the box:** background-coloured, defocused pockets enclosed by subject. Use the v4 §1.5 criteria, with the minimum area scaled to the crop so finger gaps qualify. This runs **only inside a user box**.
5. **Then, inside the box:** the edge snap (§1.3), decontamination (§1.2) and the colour guard (§1.1).
6. **Crop growth:** if kept pixels touch a box border that isn't the photo edge, extend in that direction (v3 §4.3; up to 4 times).
7. **Target:** ≤ 1.5 s warm on 33 MP.
8. **Log:** box size, tiles, detail ratio, components kept and dropped, gaps opened, time.

### 2.3 Refine Hair (brush)
For curls and flowing hair.

**Trimap from the stroke:**
- **Unknown** = the painted area.
- **Definite subject** = `m0 ≥ 0.97` outside the stroke, plus the face oval.
- **Definite background** = `m0 ≤ 0.03` outside the stroke.

**Inside the stroke:** relax the subject and background guards. The stroke is the user's permission to remove translucent blobs and recover strands.

**Method, chosen per stroke and logged:**
- Compute `contrast` = median contrast confidence between F̂ and B̂ in the stroke, and `bgTexture` = normalised local variance of B̂.
- **Clean, contrasting background** (`contrast ≥ 0.5` and low `bgTexture`): use **colour matting** (High, plus the closed-form solve when the region is small enough).
- **Otherwise:** use **BiRefNet-matting** (`ZhengPeng7/BiRefNet-matting` or `BiRefNet_HR-matting`; confirm the MIT licence). Run it on the stroke's bounding box, expanded 20%, at full resolution, and merge it only inside the stroke. Use the same deformable-convolution rewrite and parity tests as the main model, with ≤ 2 GB per pass. Bundle it like the main model.
- **Expose the thresholds as settings.** Colour matting gets tuned when the owner sends seamless-backdrop shots; don't wait for them.

**Then:** decontamination (§1.2) and the colour guard (§1.1) inside the stroke.

**Fix the colour-matting blockiness bug** (stair-stepped, rectangular artefacts, likely a reduced-resolution trimap or F/B estimate upsampled without smoothing) as part of this work.

**Target:** ≤ 1.5 s warm for a head-sized stroke.

### 2.4 Clean Edge (brush)
For hard, high-contrast edges with a residual rim: fingers against bokeh, a dark top against a bright background. It makes a per-pixel decision rather than estimating transparency.

Inside the stroke, at full resolution:
1. **Samples:**
   - **subject colours** from pixels with `m0 ≥ 0.97`, 4–20 px inside the edge, near the stroke;
   - **background colours** from pixels with `m0 ≤ 0.03`, 4–20 px outside.
   - Cluster each into up to 3 colours.
2. **Sharpness first:**
   - A pixel whose local defocus is close to the subject's (`D ≤ σP + 0.7`) leans subject.
   - A clearly defocused pixel (`D ≥ σP + 2.0`) leans background.
   - In between is neutral.
3. **Colour second:** compute Oklab distance to the nearest subject cluster versus the nearest background cluster. Pixels much closer to background lean background, and the reverse.
4. **Combine** into a score:
   - `score = w_s · sharpnessTerm + w_c · colourTerm`, with default weights 0.6 / 0.4.
   - Map it to alpha with a narrow smoothstep (default 0.4–0.6), giving a near-binary decision with a 1–2 px anti-aliased transition.
   - Apply a light guided filter (radius 1–2 px).
   - Merge only inside the stroke, feathered at its border.
5. **Then:** decontamination (§1.2) and the colour guard (§1.1).
6. **Brush settings:** **Strength** (scales how far alpha may move from the base) and **Tightness** (shifts the smoothstep centre, to tighten or loosen the edge).
7. **Target:** ≤ 0.5 s warm per stroke.

### 2.5 Acceptance
- **Refine Edges:** a box around 6957's outstretched hand opens the finger gaps and removes the dark slivers. A box on any footwear never makes it worse.
- **Refine Hair:**
  - **7473:** one stroke over the left shoulder area clears the soft mush and keeps the curls; one stroke on the window side doesn't degrade the near-perfect result there.
  - **6465:** braid loops stay whole.
  - **6372:** the flowing hair improves.
- **Clean Edge:** strokes along 6303's peace-sign fingers remove the green rim and keep the fingers whole; along 7451's waist and arm they remove any remaining rim.
- **Every tool:** the colour guard passes, and ⌥ restores the base exactly.

---

## 3. Small items
1. **Keep BiRefNet** (and BiRefNet-matting once loaded) in memory for ~2 minutes after leaving Edit mode.
2. **Structured JSONL:** fields for image, job id, stage, timings, memory and metrics.
3. **Debug bundle:** add `m0_birefnet`, `m0_final`, `final_alpha`, `F`, `sharpness`, `pose.json`, `regions.json` (tiles, boxes, strokes, gaps), plus the per-step toggle states.
4. **Log per tool operation:** method chosen and why, pixels changed, colour-guard corrections, and time.

## 4. Deferred (do not build this round)
- Automatic hand and foot boxes from pose (they'll reuse Refine Edges).
- Automatic long-prop growth beyond what Refine Edges does.
- Automatic gap check.
- Automatic Defringe.

## 5. Test images and views
- **Images:** 6303, 6372, 6378, 6465, 6957, 7006, 7451, 7473, plus 2–3 seamless-backdrop shots when the owner supplies them.
- **Views:** Background −3 EV, On White and On Black, at 100–400%.
- **Before handing over the build,** include before/after crops for every §1.5 and §2.5 item.
