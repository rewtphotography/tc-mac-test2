# TrainCull Masking — Spec v4: Fringe Fixes and Refine Tools

**Status:** implementation spec for the next build, based on alpha 12 testing (2026-11-15).

**Builds on** `masking-spec-v3.md`, which stays the reference for anything not changed here. Where the two conflict, **this document wins**. `logging-recommendations.md` still applies.

**Figures:** the PDF version of this document has annotated screenshots for every problem described. Figure numbers below refer to it.

---

## 0. Where alpha 12 stands

Alpha 12 is the best result so far. Every **selection** problem from the start is solved in **Off** across all eight test images:

| Previously failing | Alpha 12 (Off) |
|---|---|
| Crowds pulled into the mask (6957, 6303) | Excluded |
| Person at the frame edge (7006) | Excluded |
| Overlapping person in yellow (7451) | Excluded |
| Headpieces, props, bracelets (6372, 6303, 6465) | Included |
| Boots and shoes (7451, 6957, 7006, 6303) | Clean, including laces and black boots on dark asphalt (Fig. 9) |
| Memory and speed | ~1.5–2 GB per BiRefNet pass (was 8–9 GB); 0.87 s per pass; tier switches cached |

**What's left is edge quality:**

1. **Edge fringe and halo:** a 1–3 px rim along edges, bright or dark depending on the background. Seen on every image (Fig. 1–3).
2. **Enclosed background gaps** that are filled in: arm–waist (Fig. 1), between fingers (Fig. 3), around props (Fig. 5).
3. **Hair matting makes hair worse** on all five images where it was compared (Fig. 6–8). It removes real hair and leaves background blobs, because these busy, similarly coloured backgrounds defeat colour maths. It also applies to shoulders and collars inside the geometric "hair zone".
4. **Close-up tiles skipped** when the subject box is over 80% of the frame (6372, 6465, 7473). Those three have the highest halo readings (0.069–0.083, against 0.013–0.029 on images with tiles).

### Owner decisions
- **Off is the default.** Nothing refines automatically beyond the Phase 1 fixes.
- **Priority 1 is fixing the fringe and halo (Phase 1).**
- **Then the owner's refine-tool design (Phase 2):** a **Refine Edges box** and a **Refine Hair brush**, replacing automatic hair matting and the Fast/High/Max tiers.
- **Colour matting is kept**, recalibrated, for clean, high-contrast backgrounds such as a white seamless. It is used only where the user brushes, and only when the background suits it.

---

## Phase 1 — Fringe and halo (priority one)

Do these in order. Each is measurable with the metrics in §1.7.

### 1.1 Always run the close-up tiles
- **Remove the "box > 80% of frame → skip" rule.** At 1024 input, the whole-frame pass sees only ~15% of the photo's detail, so the close-up tiles are always worthwhile.
- **Tile the subject box** (or the whole frame when the box is the whole frame) so that each tile gives the model **at least 2× the whole-frame pass's detail**. In practice: tile side ≤ ½ of the box's long edge, rendered from the full-resolution reference decode.
- Keep skipping tiles that contain no edge.
- **Log the number of tiles and the detail ratio** per image, as now.
- **Expected effect:** 6372, 6465 and 7473 should drop to the halo levels of the full-length shots. 6372's flowing hair should also get sharper.

### 1.2 Check close-up tile seams
- A blocky, straight cut appears where hair behind the arm meets the arm on 6957 (Fig. 4). The stair-stepping on 7473 may be related.
- **Check:**
  - tile overlap (≥ 25%);
  - raised-cosine blending across the overlap;
  - that tiles are merged only near the edge.
- **Add a seam metric for the close-up merge**, like the Max seam ratio: alpha jumps across tile borders versus inside tiles. Log it and warn above 3.

### 1.3 Contrast-gated edge snap (fixes the 1–3 px fringe)
The fringe is the mask edge sitting a few pixels off the true boundary. On high-contrast edges it can be snapped into place.

**Band:** a narrow ring around the 0.5 contour of the upsampled base mask. Half-width is `rSnap` = 4 px at 33 MP, scaled by `sqrt(MP/33)`.

**Steps**, in linear RGB, at full resolution, inside the band:
1. **Local colour estimates.**
   - F̂ = push-pull fill from pixels with `m0 ≥ 0.97`, at least `rSnap + 2` px inside the edge.
   - B̂ = the same from pixels with `m0 ≤ 0.03`, at least `rSnap + 2` px outside.
   - Reuse the Fast tier's push-pull at ¼ resolution.
2. **Snapped alpha:** `αc = clamp(dot(I − B̂, F̂ − B̂) / |F̂ − B̂|², 0, 1)`. This is the Fast kernel.
3. **Contrast confidence:** `conf = smoothstep(0.08, 0.20, cn)`, where `cn` is the normalised contrast from the Fast kernel. This is stricter than the Fast tier (0.02 / 0.10), so it only acts on clearly separable edges.
4. **Result:** `α = mix(m0_up, αc, conf × bandWeight)`, where `bandWeight` falls smoothly to 0 at the band edge. Outside the band, nothing changes.
5. **Cleanup:** a guided filter, radius 2 px, small eps, inside the band only.
6. **Guards:**
   - Don't let `α` move more than 0.6 from `m0_up` at any pixel, so a wrong colour estimate can't punch holes.
   - Skip the hair zone; Phase 2 handles hair.

**Expected effect:** the bright rim on 7451's waist and arms, the dark rim on 6957's sleeve and hand, and the pale rim on 6303's fingers should go. Low-contrast edges (black boots on asphalt) are left as they are, which is correct.

### 1.4 Edge decontamination
Even with alpha correct, the edge pixels contain background colour (the blue tint on 7451's jeans, the warm outline on 6372's leaves). Under heavy background edits this shows as a rim.

1. Compute the foreground colour `F` in the edge band (and in partial-alpha pixels anywhere) using multi-level foreground estimation (Germer et al. 2020, as in pymatting; see spec v1 §5.4). Use F̂ and B̂ from §1.3 as the starting point.
2. **Composite with the decontaminated colours** wherever `0 < α < 1`:
   `out = α · Adj_subject(F) + (1 − α) · Adj_background(B)`, with `B = clamp((I − α·F) / max(1 − α, 1e-3))`.
   Use the simple blend elsewhere.
3. Apply the same to exports (TIFF, Send to Photoshop) so the result matches the screen.
4. **Cache F per image** (16-bit, band tiles only).

### 1.5 Gap check (enclosed background inside the mask)
Pockets of background inside the mask: between arm and waist (7451, Fig. 1), between fingers (6957, Fig. 3), around the rose and hand (6372, Fig. 5).

A pixel is a **gap candidate** if all of these hold:
- `m0 ≥ 0.5`;
- its colour is close to the local **background** estimate and far from the local **subject** estimate. Use B̂ / F̂ from §1.3, with B̂'s reach extended so it can fill inside the mask from nearby outside pixels: `dB < 0.5 × dF`, with contrast confidence ≥ 0.4;
- it is **defocused** compared with the subject. Use the sharpness map: `D ≥ σP + 1.0`. At f/1.6 the background seen through gaps is blurred, while the subject's edges are sharp. This is the strongest discriminator and protects smooth subject areas.

**Then:**
1. Take connected components of candidates with an area of at least 0.002% of the frame (proxy resolution) that are mostly enclosed by the subject or connect to the outside only through a narrow neck.
2. **Exclude:**
   - the face oval;
   - anything inside pose-confirmed limb capsules, except the space *between* limbs and torso;
   - components touching the hair zone (Phase 2 handles hair).
3. **Set `m0 = 0`** in accepted components, with a 2 px feather. Then rerun §1.3 on their edges.
4. **Log** each gap: area, location, mean `dB/dF`, mean defocus, and whether it was accepted (with reason).
5. **Debug overlay:** draw accepted and rejected gaps.

**Expected effect:** opens the arm–waist gap on 7451 and the rose area on 6372. Finger gaps on 6957 may be too small at proxy resolution; the Phase 2 box handles those.

### 1.6 Hair zone during Phase 1
- No colour matting runs by default (Off).
- §1.3 and §1.5 **skip the hair zone**.
- §1.1 and §1.4 still apply there: tiles everywhere, decontamination in all partial-alpha pixels.

### 1.7 Metrics and logging
- **Halo** (mean alpha outside the base edge) and **erosion** (mean `1 − alpha` inside it), in **two rings: 0–3 px and 3–10 px**, split into hair zone and elsewhere. The existing 3–10 px ring missed the fringe.
- **Snap:** pixels changed, mean |Δα|, and the percentage of the band that passed the contrast gate.
- **Decontamination:** pixels affected and mean colour shift.
- **Gaps:** count found, accepted and rejected.
- **Close-up merge:** the seam metric.
- Log all of these for **Off** as the baseline.

### 1.8 Phase 1 acceptance
On all eight test images (6303, 6372, 6378, 6465, 6957, 7006, 7451, 7473), in Off:
- **Halo away from hair, 3–10 px ring:** ≤ 0.02 on every image.
- **0–3 px ring:** at least 50% lower than the alpha 12 baseline (log the baseline first).
- **Visual check, Background −3 EV at 100%:** no visible fringe on 7451 (waist, arms), 6957 (sleeve, hand) or 6303 (fingers, arm).
- **Gaps open:** 7451 arm–waist and the 6372 rose area.
- **No regressions:** footwear stays as clean as Fig. 9, and selection is unchanged on all eight.
- **Timing:** the base mask including Phase 1 stays ≤ 6 s warm on 33 MP; report 61 MP separately.

---

## Phase 2 — Refine tools (owner design)

The base mask is the automatic result. Refinement happens only where the user asks for it, so it can be aggressive there without risking the rest of the mask.

### 2.1 UI changes
- **Remove the Off / Fast / High / Max tier control** from the main UI. Off is the base. High and Max produced identical results in testing. Keep the tiers under Debug only, for comparison.
- **New tools** in the MASK panel:

| Tool | Gesture | ⌥ (Option) variant |
|---|---|---|
| **Refine Edges** | Drag a box | Box restores the base mask inside it |
| **Refine Hair** | Paint a brush stroke (size slider, [ / ] keys) | Paint restores the base mask |

- Each operation is a non-destructive edit op, replayed on Remake, undoable, and recomputed only where it touched.
- **Overlay:** show boxes and brush strokes faintly while the tool is active.

### 2.2 Refine Edges (box)
Purpose: hands and fingers, footwear, enclosed gaps, prop edges. Any area where the base edge is slightly off or too coarse.

1. **Crop** the box (expanded 15%) from the full-resolution reference decode. If the crop's long edge is larger than the model input (1024), run it as tiles with ≥ 25% overlap. Target: the model sees ≥ 4× the base pass's detail inside the box.
2. **Run BiRefNet** on the crop or tiles → `Sc`.
3. **Keep** only components of `Sc` that touch the existing subject mask, or overlap it by ≥ 30%. A box can't pull in a passer-by.
4. **Inside the box** (feathered 6 px at the box border): replace `m0` with `Sc_kept`. Then run the gap check (§1.5, with the minimum area scaled to the crop, so finger gaps qualify), the edge snap (§1.3) and decontamination (§1.4) inside the box.
5. **Crop growth:** if kept pixels touch a box border that isn't the photo edge, offer growth (spec v3 §4.3) in that direction. A long prop leaving the box is then followed automatically, up to 4 extensions.
6. **⌥-box:** restore the base mask inside the box.
7. **Target:** ≤ 1.5 s warm per box on 33 MP.
8. **Log:** box size, tiles, detail ratio, components kept and rejected, gaps opened, time.

**Acceptance:**
- a box around 6957's outstretched hand opens the finger gaps and removes the dark slivers (Fig. 3);
- a box on 7451's waist opens the arm–waist gap if Phase 1 didn't;
- boxes on any footwear never make it worse.

### 2.3 Refine Hair (brush)
Purpose: curly or flowing hair where the base edge is too soft or holds background blobs (7473, 6372, 6465).

**Trimap from the stroke:**
- **Unknown** = the painted area.
- **Definite subject** = `m0 ≥ 0.97` outside the stroke, plus the face oval.
- **Definite background** = `m0 ≤ 0.03` outside the stroke.

Inside the stroke, the subject and background guards are **relaxed**. The stroke is the user's permission to remove translucent blobs (the shoulder area on 7473) and to recover strands.

**Method chosen per stroke** from the painted area:
- `contrast` = median contrast confidence between local F̂ and B̂;
- `bgTexture` = local variance of B̂, normalised;
- If `contrast ≥ 0.5` and `bgTexture` is low (a clean backdrop such as a seamless, sky or plain wall): use **colour matting** (High, then the closed-form solve when the region is small enough; see spec v1 §5.2–5.3).
- Otherwise (busy or similarly coloured backgrounds, as in all eight current test images): use **BiRefNet-matting** on a crop of the stroke's bounding box (expanded 20%), at full resolution, merged only inside the stroke.
- Log which method ran and why.

**Then:** decontaminate (§1.4) inside the stroke.

**⌥-paint** restores the base mask.

**Target:** ≤ 1.5 s warm per stroke for a typical head-sized stroke.

#### 2.3.1 BiRefNet-matting
- Use the BiRefNet matting variant from the same repository (`ZhengPeng7/BiRefNet-matting` or `BiRefNet_HR-matting`; choose by quality and speed). **Confirm the licence is MIT before shipping.**
- Convert it with the same deformable-convolution rewrite and parity tests as the main model.
- Download it on first use of Refine Hair, not at launch.
- Memory target: ≤ 2 GB per pass, like the main model.

#### 2.3.2 Colour matting fixes (required before it's used in the brush)
1. **Blockiness bug:** stair-stepped, rectangular artefacts in High/Max (7473, 6957, 7473's shoulder notch, Fig. 7). Something computed at reduced resolution (the ¼-res trimap or the F/B push-pull) is upsampled without smoothing, or is snapped to tile boundaries. Find and fix it.
2. **Recalibrate on clean backgrounds.** The owner will supply 2–3 shots on a seamless or plain backdrop. Tune the contrast thresholds, guards and closed-form parameters so colour matting clearly beats both Off and BiRefNet-matting on those shots.
3. Never run colour matting on shoulders, collars or other hard edges. The brush keeps it where the user paints.

**Acceptance:**
- **7473:** one stroke over the lower-left curls and the left shoulder keeps the backlit blue-white curls **and** clears the translucent blob over the shoulder (Fig. 7). Erosion and halo in the stroke must both beat Off.
- **6465:** a stroke over the braids keeps the braid loops whole (Fig. 8).
- **6372:** a stroke over the flowing hair improves the washed-out patches.
- **Seamless shots:** colour matting is chosen automatically and beats Off visibly.

---

## Phase 3 — Remaining items

1. **Keep BiRefNet loaded** for ~2 minutes after leaving Edit mode. Reloading and warm-up cost 1.2–1.7 s each time.
2. **Structured JSONL:** fields for image, job id, stage, timings, memory and metrics, not just the message text.
3. **Debug bundle:** add `m0_birefnet`, `m0_final`, `final_alpha`, `F` (decontaminated foreground), `sharpness`, `pose.json`, `regions.json` (tiles, boxes, strokes, gaps) and `ps_mask` passthrough.
4. **Automatic hand and foot refinement:** reuse the Refine Edges box. Place boxes from pose (wrists, ankles) and run them after the base. Off by default until validated.
5. **Crop growth for long props** (staffs, swords): spec v3 §4.3, via the box.
6. **Attached-object pass:** lower priority. BiRefNet already includes worn props in all test images. Keep it for detached or long props only.

---

## Test set and views

**Images:**

| Image | What it tests |
|---|---|
| 7451 | Arm–waist gap, waist and arm fringe, boots on asphalt, overlapping person |
| 6957 | Crowd, finger gaps, sleeve fringe, armpit hair seam, black boots |
| 6303 | Finger fringe, spiked bracelet, shoes and laces |
| 6372 | Props, rose-area gap, flowing hair, tiles previously skipped |
| 6378 | Props held overhead |
| 6465 | Braids, tiara, tiles previously skipped |
| 7006 | Edge person, yellow boots |
| 7473 | Big curly hair on a low-contrast background, backlit curls, shoulder blob, tiles previously skipped |
| **New: 2–3 seamless / plain backdrop shots (owner to supply)** | Colour matting under good conditions |

**Views for every acceptance check:** Background −3 EV, On White and On Black, at 100% and above.

---

## Figure list (PDF)

| Figure | Content |
|---|---|
| 1 | 7451, Off, Background −3 EV: arm–waist gap (left ring) and bright fringe on the waist (right ring) |
| 2 | 6303, Off, Background −3 EV: pale rim around fingers and arm |
| 3 | 6957, Off, On White: dark slivers between fingers, edge fringe |
| 4 | 6957, Off: blocky cut where hair behind the arm meets the arm (possible tile seam) |
| 5 | 6372, Off, Background −3 EV: trapped background around the rose and hand |
| 6 | 7473, Off vs High: matting punches holes and adds grey smears |
| 7 | 7473, Off vs Max: backlit curls removed, shoulder blob kept, blocky notch |
| 8 | 6465, Off vs Max: braid loops cut, white haze |
| 9 | Successes: 6957 boots, 7006 boots, 6372 props (all Off) |
