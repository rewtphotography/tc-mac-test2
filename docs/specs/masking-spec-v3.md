# TrainCull Masking — Spec v3

**Supersedes** `masking-spec-v2.md` and `base-mask-birefnet-spec.md`. The refinement maths in `masking-implementation-plan.md` (trimap, Fast/High/Max, closed-form solver, foreground estimation) is still the reference implementation, but it now runs **only in the hair zone** (§5). `logging-recommendations.md` still applies, with the additions in §10.

**Context:**
- Machine: M3 Pro, 36 GB, macOS 15.7.9.
- Test files: 33 MP Sony a7 IV ARWs (7008×4672), mostly 85 mm at f/1.6 in crowded convention halls. Worst case: 61 MP Sony A7CR.
- What these shots have in common: busy backgrounds, but a clearly defined, in-focus subject, often with costumes and props.

---

## 0. Decisions and findings from alpha 11 testing

| Finding | Decision |
|---|---|
| BiRefNet (A) selects the right subject. It excluded the overlapping person in yellow on `_DSC7451`, and its subject areas match the Photoshop references (18.1 / 43.1 / 74.0 % vs 18.1 / 43.2 / 75.5 %). Hair results are good. | **BiRefNet is the subject model.** |
| SAM (B) punches holes in hair and clothing. SAM + close-up (B2) returns only a faint face outline. Hybrid (C) leaves haze across the floor and takes 18 s. | **Remove B, B2 and C** from the build and the picker. Vision stays only for faces, landmarks and body pose. Legacy Vision subject masks stay behind a debug toggle. |
| Hard edges are worse than Photoshop: a speckled halo around black shoes on dark asphalt, and a blue fringe on the jeans in front of a blue costume. The halo is the same width with the narrow or the standard band. | The **base edge itself is soft there**: BiRefNet sees the whole person squashed to 2048² and is upsampled ~3.4×. Colour matting then turns the soft zone into speckle. Fix: close-up BiRefNet passes for hard edges, and **no colour matting outside hair** (§4–§5). |
| The close-up pass was skipped on every image ("box is most of the frame"), even with the subject at 18 % of the frame. | Bug. Fix it (§3.2). |
| BiRefNet holds ~8–9 GB during each pass (peak 10.5 GB, target ≤ 3 GB). | Fix before chaining passes (§2.2). |
| Switching tiers reran BiRefNet. | Cache the base per image (§9). |
| Overall coverage numbers (IoU, area) looked fine while the edges were bad. | Judge edges with dedicated edge metrics and with Background −3 EV views (§10, §11). |

---

## 1. Pipeline overview

```
RAW → reference decode (linear, as-shot WB)
   ├─ proxy (2048 long edge, sRGB) ─► Vision faces + landmarks + body pose
   │                                ─► sharpness map (§6)
   │                                ─► BiRefNet full frame (§3.1)
   ├─ subject close-up crop (full-res) ─► BiRefNet (§3.2)
   ├─ merge + component selection with sharpness and pose rules (§6–§7)  → m0
   ├─ region passes, progressive:
   │     hands/props crops → BiRefNet, with growth (§4.2–§4.3)
   │     feet/legs crops   → BiRefNet, no growth (§4.2)
   │     attached in-focus objects → BiRefNet (§4.4)
   ├─ edge treatment by region (§5):
   │     hair zone   → trimap + Fast/High/Max colour matting
   │     elsewhere   → guided-filter snap only
   └─ MaskStack (proxy base + sparse full-res tiles) → compositing
Skin mask (§8) runs on the final subject mask.
```

Show results progressively: the base mask immediately, then each region pass as it finishes, then the hair matting.

---

## 2. BiRefNet model

### 2.1 Model and conversion
- `ZhengPeng7/BiRefNet_HR` (MIT), converted to Core ML, with the deformable convolution replaced by a `grid_sample` implementation (see v2 §3.2). The parity tests from v2 still apply.
- Normalization is baked into the graph. FP16.

### 2.2 Memory (blocker)
- Measure memory before and after each prediction.
- **Investigate in this order:**
  1. **Precision:** confirm FP16 weights and activations.
  2. **Compute units:** compare `.all`, `.cpuAndGPU` and `.cpuAndNeuralEngine`.
  3. **The `grid_sample` deform-conv rewrite:** check whether it materialises large per-tap tensors at 2048². If so, process taps in chunks or move the op to a custom Metal layer.
  4. **Input size:** run reduced-size inputs for crops (§4.5).
- **Target:** ≤ 3 GB peak during a pass. If that's not reachable, evaluate `BiRefNet_lite-2K`.

### 2.3 Lifecycle
- Prewarm on entering Edit mode. The cold start was 4.3 s to load plus 8.6 s for the first inference.
- Keep the model loaded while in Edit mode, so region passes reuse it.
- Unload on memory pressure.
- One prediction at a time. Region passes are queued.

### 2.4 Input shape
- Currently aspect-squashed to 2048². **Test letterboxing** for tall 2:3 frames, and keep whichever gives cleaner edges on the test set.

---

## 3. Base subject mask

### 3.1 Full-frame pass
- BiRefNet on the proxy → `SA`.

### 3.2 Subject close-up pass (bug fix)
- Primary face: the sharpest prominent face (v2 §5.1).
- Box `B`: the union of the face-derived body box (v2 §5.2) and the bounding box of the kept `SA` components, expanded 10 % per side.
- **Skip only if `area(B) > 0.8 × frame area`** — the test must use **area**, not one dimension. Log the box size, the percent of the frame, and the decision.
- Render `B` from the reference decode at full resolution. Downscale to the model input only if larger. Run BiRefNet → `SB`, then merge into `SA` with a 24 px feather (v2 §6.1 step 3).

### 3.3 Component selection
This uses the sharpness rules in §6 and the pose rules in §7. The output is `m0` (soft, proxy resolution) plus `confidence`, the same contract as v2 §7.

---

## 4. Region passes (BiRefNet close-ups)

### 4.1 Body pose
- Run `VNDetectHumanBodyPoseRequest` on the proxy. Match the pose to the primary person by the face/nose keypoint nearest the primary face.
- Keep only keypoints with confidence ≥ 0.3. Log the keypoints and their confidences.

### 4.2 Crop placement
| Region | Crop | Growth (§4.3) |
|---|---|---|
| Hands / props | Centred on each wrist; side = max(2.5 × face height, 1.5 × forearm length). | **Yes** |
| Feet / footwear | Covers both ankles, from mid-shin down to the lowest subject-mask pixel plus 0.3 × face height. Full width of the subject mask at that height, plus 15 %. | **No** (the floor is in focus) |
| Legs (full-length shots only) | Hip-to-ankle strip per leg, used only if the subject close-up (§3.2) gave less than 1.5× the proxy pixel density. | No |

**If pose fails:**
- feet = the bottom 15 % of the subject mask's bounding box;
- hands = the left and right extremes of the subject mask in the upper half of the body.

### 4.3 Crop growth (staffs, swords, long props)
For hand/prop crops and box-add:
1. After the pass, find kept-mask pixels on a crop border that isn't the photo edge.
2. If they're present, extend the crop ~50 % in that direction (keeping ~25 % overlap), rerun BiRefNet on the new area, and keep only components connected to what's already found.
3. Repeat until:
   - the object no longer touches a crop border;
   - it reaches the photo edge;
   - 4 extensions have been made; or
   - a time budget of about 6 s per region runs out.
4. Every extended piece must pass the attached-object sharpness test (§6.3).
5. Log each extension: direction, size, and why growth stopped.

### 4.4 Attached in-focus objects (headpieces, worn and held pieces)
1. Using the sharpness map (§6), find sharp edge regions within `dAttach` (1 % of the long edge) of the subject mask that aren't in the mask.
2. For each candidate cluster near the **head or hands only**, run BiRefNet on a crop centred on the cluster, sized to about 2× its bounding box (minimum 1 × face height).
3. Keep components that pass §6.3 and connect to the subject.
4. **Never auto-grow from feet or legs.** **Never auto-include large planar surfaces:**
   - components wider than 1.5 × the subject's shoulder width with low internal edge density;
   - floor, walls and tables.
   These are left to box-add.
5. Log the candidates found, kept and rejected, each with a reason.

### 4.5 Merge and input size
- Keep only crop components that touch the current subject mask, or that are confirmed attachments.
- Merge only within `rMerge` = 0.05 × face height (full-res px) of the existing edge, feathered, so crops can't create seams or distant new regions. Grown and attached pieces are merged whole.
- **Input size:** test 1024 versus 2048 for crops. A 1024 run costs about ¼ as much and still exceeds the proxy pixel density for small crops. Choose per region by measured quality on the test set.

---

## 5. Edge treatment by region

| Region | Treatment |
|---|---|
| **Hair zone** (head crop minus the face oval, from v1 §5.1) | Trimap + Fast / High / Max colour matting, as built. Seam and guard fixes stay. |
| **Everything else** | **No colour matting.** Edge-preserving upsample of `m0` and region results, then a guided-filter snap to the full-res luma (radius ~4 px, small eps). |
| **Defocused edges in the hair zone** | Blend toward the model edge using `fDefocus` (v2 §9.2). |

**Adaptive band inside the hair zone:**
- Where `m0` goes from ~0 to ~1 within 2 proxy px, use a 1–2 proxy-px band.
- Use the full band only where `m0` is genuinely soft.
- Debug overlay: show the band.

**Guards (all regions):**
- **Background guard:** where `m0 < 0.1`, refinement may only raise alpha where contrast confidence is above 0.6; otherwise clamp to `m0`.
- **Subject guard:** the mirror image of the background guard (v2 §9.3).

**Tier control:** **Off / Fast / High / Max**.
- **Off** shows the snapped base and region results with no colour matting. It's the reference for judging every tier.
- Fast / High / Max only change what happens inside the hair zone.

---

## 6. Sharpness as a primary filter

### 6.1 Measurement
- Edge-based defocus map on the proxy, as in v2 §4. Measured only at edges.
- Regions with no measurable edges (smooth fabric, skin) are **unknown**, never "soft".
- **Reference:** `σP` = `faceSharp` of the primary face (eye band). All thresholds are **relative to `σP`**, never absolute values.

### 6.2 Strictness scaling
- Let `fh` = primary face height ÷ frame height.
- Strictness `s` runs from 1.0 (strict) at `fh ≤ 0.05` down to 0.2 (very loose) at `fh ≥ 0.20`, interpolated linearly in between.
- Multiply by the user's **Focus strictness** setting: loose 0.6, moderate 1.0 (default), strict 1.4.
- Rationale: an extreme sharpness falloff implies a large, close subject, where dropping pieces for softness is rarely wanted.

### 6.3 Where it applies
| Decision | Rule |
|---|---|
| **Disconnected components** | Drop if `edgeSharp > σP + 1.0 / s` (strict), regardless of BiRefNet saliency. |
| **Additions** (crop growth, attached objects, box-add results) | Keep only if `edgeSharp ≤ σP + (1.5 + 0.5 × d/fh_px) / s`, where `d` is the distance from the face centre. This is a generous threshold that loosens with distance, to allow for depth falloff at f/1.6. |
| **Primary connected component** (already in BiRefNet's mask) | **Never removed for sharpness.** Exception: a region containing another person's face or pose keypoints may be removed. |
| **Refinement** | Defocused edges in the hair zone fall back to the model edge (§5). |
| **Box tools** | Pick the sharpest component (§8). |

---

## 7. Pose-confirmed body parts

- Any mask region along the primary person's **shoulder → elbow → wrist** or **hip → knee → ankle** segments counts as **confirmed body**, as does any region containing those keypoints. Test the segments with a capsule of radius 0.35 × face height.
- Confirmed body is **always kept**, however soft it is. This covers hands and arms reaching toward the lens.
- Confirmed hands seed the hand/prop crops (§4.2) and growth (§4.3).
- Regions containing **another** person's keypoints are marked "other person". This is the one case where pixels may be removed from the primary component.

---

## 8. Refine tools (SAM-free)

| Gesture | Behaviour |
|---|---|
| **Drag box (add)** | BiRefNet on the box crop (expanded 15 %). Choose the **sharpest component that touches the subject** ("most in-focus object in this area"). Apply growth (§4.3) if it touches the box border. Merge it, and replace the existing edge inside the box with the crop result where they agree to within 0.5 (edge reassessment). |
| **⌥-drag box (subtract)** | BiRefNet on the box crop. Remove the most prominent component, **limited to the box**. If nothing is found, clear the subject mask inside the box. No sharpness test, since the intent is explicit. |
| **Single click add/subtract** | **Dropped for now** (it needs a promptable model). |

- Operations are stored as non-destructive edit ops and replayed on Remake.
- Only the touched region is recomputed.
- **Latency target:** ≤ 2.5 s per box operation, warm.

**People picker:** face thumbnails ordered by score. Clicking one makes it the primary and reruns §3.3 and §4–§7 from cached model outputs where possible.

---

## 9. Caching and performance

- **Cache per image:** `SA`, `SB`, region crop results, the sharpness map, pose, and the final `m0`. Key: `(rawFileID, proxyRenderParams, modelVersion, settingsHash)`.
- **Changing Off / Fast / High / Max reruns only the hair-zone matting.** BiRefNet must not rerun.
- **Remake** clears the image's base cache. Edit ops are kept.
- Neutral/reference decode cache: hold at least the last 3 images.
- **Interactive renders:** draft renders currently take 0.13–0.23 s; the target is ≤ 50 ms while dragging.

**Time budget** (warm, M3 Pro, 33 MP):

| Stage | Target |
|---|---|
| Base (full frame + close-up + selection) | ≤ 4 s |
| Each region crop at 1024 input | ≤ 1 s |
| Hair Max | as now (~2–5 s) |
| Total for a full-length shot with 2 hands + feet | ≤ 10 s, shown progressively |

---

## 10. Logging additions

These are on top of `logging-recommendations.md`.

- **Close-up decision:** box size, percent of frame, run or skipped (with reason).
- **Model call:** input size, wall time, memory before / peak / after, compute units.
- **Pose:** keypoints and confidences; whether the primary person was matched.
- **Per region pass:** region type, crop rect, input size, components kept and rejected (with reasons), growth extensions and stop reason, time.
- **Per component:** edge sharpness, effective threshold after scaling, distance from face, confirmed-body flag, kept or dropped (with reason).
- **Edge-quality signals,** split into hair zone versus elsewhere:
  - **halo:** mean alpha in a ring 3–10 px **outside** the snapped base edge;
  - **erosion:** mean (1 − alpha) in a ring 3–10 px **inside** it.
- **Debug bundle export:** add `m0_birefnet.png` (before region passes), `m0_final.png` (after region passes, before matting), `final_alpha.png`, `sharpness.png`, `pose.json` and `regions.json` (crop rects, growth steps).
- **Debug overlays:** hair zone, matting band, crop boxes (including growth steps), pose skeleton, sharpness map, kept/dropped components coloured by reason.

---

## 11. Test plan

**Images:**
| Image | What to check |
|---|---|
| `_DSC7451` | Boots on asphalt, jeans in front of the blue costume, the overlapping person in yellow. **Feet must not grow into the floor.** |
| `_DSC6372`, `_DSC6378` | Headpiece pieces (attached-object pass), arms and props held overhead. |
| `_DSC6957`, `_DSC6303`, `_DSC7006`, `_DSC6465` | Crowds and edge people: disconnected soft components dropped. |
| `_DSC7473` | Curly hair close-up: no regression; very loose strictness (large face). |
| Any shot with a staff or sword | Crop growth follows the prop to its end or to the frame edge. |
| A shot with a hand reaching toward the lens | The soft hand is kept via pose. |

**Views:** Off vs Fast vs High vs Max, in **Background −3 EV**, On White and On Black.

**Pass criteria:**
- Hard edges (shoes, jeans, arms) in **Off** are at least as clean as the Photoshop one-click reference by eye, with no speckled halo.
- Hair in High/Max is at least as good as alpha 11.
- No background people. Props and headpieces included.
- Edge-quality log: halo outside the hair zone ≤ 0.05 mean alpha.
- Memory ≤ 3 GB per BiRefNet pass. Timing within §9.

**Photoshop references:** the existing `ps_mask-<n>.jpg` set is used for overall coverage only. Edges are judged by eye and by the edge-quality signals.

---

## 12. Open questions

1. Letterbox versus squash for BiRefNet input on 2:3 frames.
2. 1024 versus 2048 input for region crops: the quality/time trade-off.
3. Can BiRefNet memory reach ≤ 3 GB, or is `BiRefNet_lite-2K` needed?
4. Is pose detection reliable on heavy costumes (armour, capes, masks)? How often do the fallbacks fire?
5. Does the attached-object pass pick up unwanted neighbours (bags held by others, a crowd member's prop next to the subject)? If so, tighten `dAttach` or require pose proximity.

---

## 13. Dependencies

| Item | Ships? | License |
|---|---|---|
| BiRefNet_HR weights (Core ML) | Downloaded on first use, SHA-256 pinned | MIT ✅ |
| BiRefNet_lite-2K (only if §2.2 requires it) | Same | MIT ✅ |
| PyTorch, transformers, coremltools | No (conversion only) | BSD / Apache ✅ |

**Removed:** SAM 2.1 Core ML models.

**System frameworks:** Vision (faces, landmarks, body pose), Core ML, Core Image, Metal, Accelerate.
