# TrainCull Masking — Spec v2

**Supersedes** `base-mask-birefnet-spec.md`. It **updates** `masking-implementation-plan.md`: the refinement tiers described there stay, with the fixes in §9.

**Written by** Claude Opus 5.5, for a code session to implement and audit.

**Context:**
- Machine: M3 Pro, 36 GB, macOS 15.7.9. Current test files are 33 MP Sony a7 IV ARWs (7008×4672). The 61 MP A7CR is the worst case.
- Typical shot: 85 mm at f/1.6 in crowded convention halls, cosplay with props. Background people often wear colors similar to the subject's and sometimes overlap the subject.

---

## 0. What changed and why

| Problem seen in alpha 7 | Response in this spec |
|---|---|
| Vision "all people" segmentation pulls in background people and ignores props | Vision segmentation is **removed**. A **three-way bake-off** (BiRefNet_HR, SAM 2.1, hybrid) picks the new base (§2, §5, §6). Vision is kept only for face rects and landmarks. |
| Photographers won't want to "prompt" | SAM's inputs are points and boxes the **app generates automatically**. One click on "Select Subject" with no text and no prompt editor (§5). |
| Need to fix selections quickly | **Refine tools:** click add/subtract, box add/subtract, and a people picker (§8). |
| Skin mask is conservative: misses shadowed skin and speculars | **Skin v2:** shading-invariant chroma, specular handling, hysteresis growth, a texture guard, plus a **skin bake-off** (§10). |
| Max left a glow around defocused hair and a straight seam (`_DSC6372`, background −3 EV) | Tile blending fix, defocus-aware refinement confidence, a background guard, and a High-tier cost brake (§9). |
| Recomputation and memory issues in the logs | Caching and the related fixes in §11 and §13. |

---

## 1. Order of work

1. **Debug bundle export and ground truth (§2.2).**
2. **Python bake-off** for subject (§2) and skin (§10.6). Report results, then **stop for owner review**.
3. **Integrate the winner in Swift:**
   - models (§3);
   - auto-selection (§5–§6);
   - caching (§11);
   - refinement fixes (§9). These are independent of the winner, so they can be done in parallel.
4. **Refine tools and people picker (§8).**
5. **Skin v2 (§10).**
6. **Acceptance (§12).**

---

## 2. Subject bake-off

### 2.1 Candidates

| ID | Pipeline |
|---|---|
| **V** | Current Vision all-people first pass (baseline only) |
| **A** | BiRefNet_HR: full-frame run + box rerun + sharpness selection (§6.1) |
| **B** | SAM 2.1 with automatic box and point inputs (§6.2). Test the `large` and `baseplus` sizes |
| **B2** | B plus a second SAM encoder pass on the subject-box crop (more resolution for full-length shots) |
| **C** | Hybrid: SAM decides *which* subject, BiRefNet decides *shape*, sharpness breaks ties (§6.3) |

### 2.2 Debug bundle and ground truth

Add **"Export mask debug bundle"** to TrainCull. For the selected image it writes:
- `proxy.png`: the exact proxy fed to models (sRGB display render, long edge 2048);
- `box_crop_hr.png`: a reference-decode crop of the face-derived box (§5.2) at up to 2048 long edge, plus `box.json` with its coordinates;
- `faces.json`: face rects and landmarks in proxy pixel coordinates;
- `current_m0.png`: the Vision first pass (candidate V).

The owner hand-masks `gt_subject.png` for each image: props included, other people excluded. Optionally also `gt_skin.png` for the skin set (§10.6).

### 2.3 Test set (20–25 images)

| Category | Examples / count |
|---|---|
| Crowd in similar colors | `_DSC6953` + 2 more |
| Person at the frame edge | `_DSC7006` + 1 |
| Large props / headpieces | `_DSC6372` + 2 |
| **Background people overlapping the subject** | owner to supply 4+ |
| Clean single subject, curly hair | `_DSC7473` + 1 |
| Group or two-person shots | 2+ |
| Face turned away or hidden | 2 |
| Previously logged | `_DSC6285`, `_DSC6303`, `_DSC6633`, `_DSC6637` |

### 2.4 Harness (`bakeoff_subject.py`)

- **Models:**
  - BiRefNet: `ZhengPeng7/BiRefNet_HR` via `transformers` with `trust_remote_code`.
  - SAM: `facebook/sam2.1-hiera-large` and `facebook/sam2.1-hiera-base-plus` through the official `sam2` image predictor.
  - Run all of them in PyTorch (MPS) for speed of iteration. Core ML parity is checked later (§3).
- **Logic:** port §5 (automatic inputs) and §6 (pipelines) to numpy exactly. Thresholds are read from one shared config file, which the Swift code will also use.
- **Metrics** per image and candidate, at proxy resolution:
  - IoU versus `gt_subject`;
  - boundary F-score (3 px tolerance);
  - **leakage**: false-positive area as a percent of GT area;
  - **misses**: false-negative area as a percent;
  - warm wall time per stage.
- **Post-refinement check:** for the top two candidates, also run the existing Fast and High refinement in Python (or export `m0` to the app) and render a **background −3 EV** composite.
- **Report:**
  - a contact sheet per image (proxy | V | A | B | B2 | C | GT, red overlay, with leakage areas highlighted);
  - a CSV;
  - a summary table per category.

### 2.5 Decision rule

- **Primary metric:** median IoU on the crowd + edge-person + overlap categories.
- **Pick the simplest candidate** (order: A, B, B2, C) whose primary metric is within 0.005 of the best, has **no category with a worse median leakage than V**, and meets the timing budget: base stage ≤ 4 s warm on the M3 Pro at 33 MP.
- **Clean-subject regression:** the chosen candidate must not lose more than 0.005 median IoU versus the best on the clean category.
- Report everything to the owner before integrating.

---

## 3. Models

### 3.1 SAM 2.1 (Core ML conversions already exist)

- Apple publishes Core ML conversions on Hugging Face: `apple/coreml-sam2.1-{tiny,small,baseplus,large}`, FLOAT16, Apache-2.0.
- Each repo holds three packages: `…ImageEncoderFLOAT16`, `…PromptEncoderFLOAT16` and `…MaskDecoderFLOAT16`.
- **Reference integration:** Hugging Face's `sam2-studio` Swift app. Follow its preprocessing (input size, resize/pad, normalization) and its coordinate mapping exactly. Verify:
  - the input resolution (expected 1024²);
  - point label conventions (expected: 1 = positive, 0 = negative, 2 and 3 = box corners, −1 = padding);
  - low-res mask size (expected 256²) and the IoU-score outputs.
- **Encoder:** run once per image (and once per box crop in B2). **Cache the embeddings** (§11).
- **Decoder:** cheap. Rerun freely for refine clicks and boxes.
- **Upsampling masks:** apply sigmoid to the logits, then edge-preserving upsample to proxy resolution, guided by the proxy.

### 3.2 BiRefNet_HR (needed for A and C)

**Known obstacle:** the decoder uses modulated deformable convolution, which `coremltools` doesn't convert natively. Replace it before tracing:

```python
# deform_conv_gs.py — drop-in for torchvision.ops.deform_conv2d (modulated, offset_groups=1)
import torch, torch.nn.functional as F
def deform_conv2d_gs(x, offset, weight, bias=None, stride=(1,1), padding=(0,0),
                     dilation=(1,1), mask=None):
    N, Cin, H, W = x.shape; Cout, _, kh, kw = weight.shape
    sh, sw = stride; ph, pw = padding; dh, dw = dilation
    Ho = (H + 2*ph - dh*(kh-1) - 1)//sh + 1; Wo = (W + 2*pw - dw*(kw-1) - 1)//sw + 1
    ys = torch.arange(Ho, device=x.device, dtype=x.dtype)*sh - ph
    xs = torch.arange(Wo, device=x.device, dtype=x.dtype)*sw - pw
    gy, gx = torch.meshgrid(ys, xs, indexing="ij")
    out = x.new_zeros(N, Cout, Ho, Wo); k = 0
    for i in range(kh):
        for j in range(kw):
            dy, dx = offset[:, 2*k], offset[:, 2*k+1]        # VERIFY layout via parity test
            py, px = gy + i*dh + dy, gx + j*dw + dx
            grid = torch.stack(((px+0.5)/W*2-1, (py+0.5)/H*2-1), dim=-1)
            s = F.grid_sample(x, grid, mode="bilinear", padding_mode="zeros", align_corners=False)
            if mask is not None: s = s * mask[:, k:k+1]
            out = out + F.conv2d(s, weight[:, :, i, j, None, None]); k += 1
    return out if bias is None else out + bias.view(1, -1, 1, 1)
```

**Parity test:** original versus patched model, float32 on CPU, 5 images. Require max |Δ sigmoid| < 1e-3 and IoU at 0.5 above 0.999.

**Wrap and convert:**

```python
class BaseNet(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m
        self.register_buffer("mean", torch.tensor([0.485,0.456,0.406]).view(1,3,1,1))
        self.register_buffer("std",  torch.tensor([0.229,0.224,0.225]).view(1,3,1,1))
    def forward(self, x):                       # 0..1 RGB, 1x3x2048x2048
        y = self.m((x - self.mean) / self.std)
        y = y[-1] if isinstance(y, (list, tuple)) else y
        return torch.sigmoid(y)
```

- Use `torch.jit.trace`, then `ct.convert(convert_to="mlprogram", compute_precision=FLOAT16, minimum_deployment_target=macOS14)`.
- Inputs: `ImageType(shape=(1,3,2048,2048), scale=1/255, RGB)`. Normalization is baked into the graph.
- Verify that `grid_sample` converts. Then check Core ML versus PyTorch: IoU above 0.995.
- **Fallback:** ONNX Runtime with the Core ML execution provider (MIT) and the upstream ONNX export.
- **Speed fallback:** `BiRefNet_lite-2K`.
- **Input handling:** aspect-squash to 2048², as the reference code does. The bake-off also tests letterboxing.

### 3.3 Swift wrappers

```swift
actor SAMModel {            // encoder + prompt encoder + decoder
    func prewarm() async throws
    func embed(_ image: CIImage, key: EmbeddingKey) async throws -> SAMEmbedding  // cached
    func decode(_ e: SAMEmbedding, points: [SAMPoint], box: CGRect?,
                multimask: Bool) async throws -> [SAMMask]   // soft masks + predicted IoU
}
actor SubjectModel {        // BiRefNet_HR
    func prewarm() async throws
    func segment(_ image: CIImage) async throws -> CIImage   // soft mask at image extent
}
```

- **Prewarm** both models on entering Edit mode. Load lazily and unload on memory pressure (`DispatchSource.makeMemoryPressureSource`).
- **Concurrency:** one prediction per model at a time. SAM decodes can interleave with BiRefNet runs.
- **Delivery:** models are downloaded on demand with pinned SHA-256, never bundled. Licenses go in the acknowledgements.

---

## 4. Sharpness map (shared)

This is gradient-ratio defocus estimation (Zhuo & Sim 2011), computed on proxy luma `Y`.

1. Re-blur: `Yb = Gaussian(Y, σ0 = 1.0 px)`.
2. Sobel magnitudes: `G = |∇Y|` and `Gb = |∇Yb|`.
3. Edge pixels `E`: `G > T`, where `T` = the 85th percentile of `G` over the frame, floored at 0.02. Thin with non-max suppression.
4. On `E`: `R = G / max(Gb, 1e-6)`. Where `R > 1.01`, `σ = σ0 / sqrt(R² − 1)`; otherwise `σ = σmax = 8`. Clamp to `[0, 8]`. Small `σ` means sharp.
5. **Dense map `D`:** push-pull fill of `σ` with weights `E`. Used by §6.1 rule 4, §9.2 and §9.4.

**Region scores** (median `σ` over at least 50 edge pixels, else `nil`):
- `faceSharp(f)`: the eye band of face `f` (top 25–55% of the face rect, or the eye landmark boxes dilated by 0.15·faceWidth).
- `edgeSharp(C)`: edge pixels within 4 proxy px of region `C`'s boundary, inside `C`.

**Implementation:** Core Image kernels rendered once into a float buffer, plus vDSP for percentiles. Target ≤ 40 ms.

---

## 5. One-click "Select Subject": automatic inputs

The user never sees or edits these. They're visible only in the debug overlay (§8.5).

### 5.1 Primary person

- **Candidate faces:** Vision faces with width ≥ 1.5% of the proxy long edge.
- **Score:** `score(f) = sqrt(area(f)) / (faceSharp(f) + 0.25)`. Faces with `faceSharp == nil` rank last.
- **Primary** = the highest score. The rest are **others**, sorted by score.
- **"All in focus" mode** (people picker, §8.3): also promote others with `faceSharp ≤ 1.25·faceSharp(primary)` and width ≥ 0.6× the primary's.
- **No usable face:** see §6.4.

### 5.2 Body box `Bf` (from the primary face `f`)

- Horizontal: face center ± 2.0·f.width.
- Vertical: from `f.top − 0.8·f.height` to `f.bottom + 6.5·f.height`.
- Clamp to the image. In C, the final box is `B = expand(Bf ∪ bbox(kept BiRefNet regions), 10%/side)`, clamped.

### 5.3 SAM inputs for the primary subject

- **Box:** `Bf` for B and B2; `B` for C.
- **Positive points:**
  - the primary face center;
  - a torso point at `face center + (0, 2.0·f.height)`, if it's inside the image and, in C, inside the BiRefNet mask.
- **Negative points:** the centers of up to 6 other faces that are not promoted (§5.1).
- **Output:** with a box plus points, request a single mask (`multimask = false`). If the result doesn't contain the primary face center, retry with `multimask = true` and pick the candidate that contains the face center with the highest predicted IoU.

### 5.4 SAM masks for other people (used to remove them)

For each of up to 6 non-promoted other faces:
- positive point at its face center;
- negative point at the primary face center;
- `multimask = true`. Pick the candidate containing its face center with the highest predicted IoU and an area under 60% of the frame.

The result is `O_k`. These are decoder-only runs, so they're cheap.

---

## 6. Candidate pipelines

Every pipeline outputs `m0` (a soft mask at proxy resolution) and `confidence`, the same contract as §7.

### 6.1 Candidate A: BiRefNet_HR + sharpness

1. **Run A:** full proxy → `SA`.
2. **Run B:** the box crop (`Bf ∪ bbox` of the components kept from `SA`, expanded 10%), rendered from the reference decode at up to 2048 long edge → `SB`. Skip if the box is over 80% of the frame.
3. **Merge:** `S = w·SB + (1−w)·SA` inside the box, where `w` feathers over the outer 24 proxy px. Outside the box, `S = SA`.
4. **Components:** 8-connected labeling of `S ≥ 0.5`.
   - **Speckle:** drop components under 0.02% of the frame unless kept below.
   - **Holes:** fill holes under 0.01% of the frame.
5. **Primary component:** the one containing the primary face center. `σP = edgeSharp(primary)`, or `faceSharp(primary face)` if that's `nil`.
6. **Keep rules:**
   - **Rule 1:** keep the primary.
   - **Rule 2:** keep components within 1.0% of the long edge from kept regions with `edgeSharp ≤ max(1.6·σP, σP + 0.8)`, or with `edgeSharp == nil` and area under 2%. Chain up to 3 iterations.
   - **Rule 3:** drop disconnected components, except promoted others in all-in-focus mode.
   - **Rule 4 (experimental, off by default):** inside kept regions, attenuate where defocus is high far from the face: `r = smoothstep(σP+1.5, σP+3.0, D) · smoothstep(2.5·fh, 4.0·fh, dist to face center)`, applied as `S' = S·(1−r)`.

### 6.2 Candidate B / B2: SAM 2.1

1. Encode the proxy, then decode the primary subject (§5.3) → `P` (soft).
2. Decode others (§5.4) → `O_k`.
3. `m0 = P · (1 − max_k O_k · (1 − P))`. This removes other people's pixels only where SAM doesn't already claim them for the subject.
4. **B2 only:** also encode the box crop `Bf`, map the inputs into crop coordinates, and decode → `Pc`. Inside `Bf`, blend `Pc` over `P` with the same 24 px feather.
5. **Components and keep rules:** same as A, steps 4–6, applied to `m0`.
6. **Confidence:** a ramp on `|m0 − 0.5|`. Reduce it to 0.5 where SAM's predicted IoU for `P` is below 0.85.

### 6.3 Candidate C: hybrid

Inputs: `S` from A (steps 1–3), and `P` and `O_k` from B (using box `B`, §5.2).

1. `Pd` = `P ≥ 0.5`, dilated by 0.5% of the long edge.
2. For each component `C` of `S ≥ 0.5`:
   - `ov = |C ∩ Pd| / |C|`
   - `ovO = max_k |C ∩ O_k| / |C|`
3. **Keep `C`** if `ov ≥ 0.3`, **or** if it's within 1.0% of the long edge from kept regions, passes the sharpness rule (A, rule 2), **and** `ovO < 0.5`. That second branch is what keeps props.
4. **Drop `C`** if `ovO ≥ 0.5` and `ov < 0.3`.
5. `m0 = S_kept · (1 − max_k O_k · (1 − P))`. This removes a background person that BiRefNet merged into the subject's blob.
6. **SAM-only areas:** where `P ≥ 0.5` and `S_kept < 0.5`, set `m0 = max(m0, P)` and `confidence = 0.4` there, so refinement treats them as uncertain.
7. Speckle and hole cleanup as in A.

### 6.4 No usable face (all candidates)

- **Primary region:** the component (BiRefNet in A and C, or the SAM automatic-mask region in B) that maximizes `area · 1/(edgeSharp + 0.25)` among regions larger than 1% of the frame, with ties broken by distance to the frame center.
- **SAM inputs** (B and C): a box from that region's bbox, plus one positive point at the region's sharpest-edge centroid.

---

## 7. Output contract and integration

```swift
struct BaseMaskResult {
    let m0: CIImage            // proxy res, OneComponent16Half, 0...1
    let confidence: CIImage    // proxy res, 0...1
    let primaryFace: CGRect?
    let promotedFaces: [CGRect]
    let otherPeople: [CIImage] // O_k (proxy res), reused by the refine tools
    let subjectBox: CGRect?
    let diagnostics: BaseMaskDiagnostics   // scores, component table, timings, inputs used
}
protocol BaseMaskProvider {
    func makeBase(image: ImageID, proxy: CIImage, faces: [FaceObservation],
                  reference: ReferenceDecode, settings: BaseMaskSettings,
                  edits: [MaskEditOp]) async throws -> BaseMaskResult
}
```

- Downstream is unchanged: `m0` → `CIEdgePreserveUpsampleFilter` (full-res guide) → trimap → Fast/High/Max → finish.
- `confidence` is upsampled the same way and consumed by §9.
- **Head-crop pass:** replace the Vision call with the winning model on the full-res head crop:
  - BiRefNet `segment(crop)` for A and C;
  - for B, a SAM encode of the crop plus the mapped primary inputs.
  - Merge only inside the unknown band, as now.
  - Skip it if the box crop (A's run B, or B2's crop) already gives at least the same pixel density.
- **Legacy Vision provider:** keep it behind a debug toggle until acceptance.

---

## 8. Refine tools and people picker

### 8.1 Interactions

| Gesture | Default | With ⌥ (Option) |
|---|---|---|
| Click | Add at point | Subtract at point |
| Drag rectangle | Add box | Subtract box |

The cursor shows + or −. While processing, the box outline stays visible with a spinner. Every operation is undoable.

### 8.2 Operation semantics

All operations are stored as `MaskEditOp { kind, geometry (normalized image coords), seq }` in MaskStack provenance. They're non-destructive and replayed in order on Remake or on a tier change.

- **Point add / subtract (SAM decode only, encoder cached):**
  - Append to the primary input set as a positive or negative point, then re-decode `P`.
  - Recompute the candidate's combination (§6.2 or §6.3).
  - For candidate A (no SAM): run a SAM decode with only this point (multimask, pick highest IoU), then add or subtract that region.
- **Box subtract** (for example, the background person in `_DSC7006`):
  - SAM decode with the box and no points, `multimask = true`. Pick the candidate with the highest predicted IoU whose area is ≥ 20% of the box → `M`.
  - `m0 ← m0 · (1 − M · boxMask)`, where `boxMask` is the box expanded 5% with a 4 px feather. Removal never reaches beyond the box.
  - If `M` covers more than 50% of the primary face rect, apply it anyway (it's the user's explicit intent) but log it.
- **Box add / reassess** (for example, the boots in `_DSC7006`):
  1. SAM decode with the box → `M`, as above.
  2. Run BiRefNet on a **high-res crop** of the box (expanded 15%) from the reference decode, at up to 2048 long edge → `Sc`. Keep the components of `Sc` that overlap `M ∪ m0`.
  3. Inside the box (feathered 4 px): `m0 ← max(m0, Sc_kept)`, then replace `m0` with `Sc_kept` wherever `Sc_kept` and `m0` disagree by less than 0.5. This brings in the **better local edges** even where the region was already selected.
  4. Set `confidence = 1` inside the box for regions present in both `M` and `Sc_kept`.
  - For B-only builds without BiRefNet: run a SAM encode of the box crop and decode with the box mapped to crop coordinates.
- **Regional recompute:**
  - Changed region = the bbox of `|Δm0| > 0.05`, dilated by `rOut`.
  - Rebuild the trimap only there, and rerun refinement only for the tiles touching it.
  - Show the Fast tier immediately, then upgrade to the selected tier in the background.
- **Latency targets** (warm, M3 Pro, 33 MP):
  - point operation: ≤ 0.3 s until the overlay updates (Fast);
  - box operation: ≤ 2.5 s including the BiRefNet crop;
  - higher tiers follow progressively.

### 8.3 People picker

- A row of face thumbnails (crops from the proxy) under the MASK panel, ordered by §5.1 score. The primary is preselected.
- **Click a face** to make it the primary. This reruns §5.3, §5.4 and §6 from cached embeddings; no encoder or BiRefNet rerun is needed unless the subject box changes. Then regional recompute.
- **Shift-click** to add more people.
- **"All in focus"** chip: promotes the faces described in §5.1.

### 8.4 Wording

The UI never says "prompt." The labels are "Select Subject", "Add", "Subtract", "People" and "All in focus."

### 8.5 Debug overlay (developer only)

Draws the automatic box, positive and negative points, `O_k` outlines, kept/dropped components (with reasons), the sharpness map `D`, and the Max tile grid.

---

## 9. Refinement fixes

These apply to all candidates, and address the `_DSC6372` artifacts.

### 9.1 Tile seams

- Never hard-switch tiers at a tile edge.
- Max tile results blend into the High result with the overlap's raised-cosine weights, normalized by the summed weights. That includes edges next to **skipped tiles**: a skipped tile contributes the High result with weight 1.
- Discard aprons. Use identical prior construction across tiles.
- **Test:** a synthetic gradient image must show no seams in the "Background −3 EV" view.

### 9.2 Defocus-aware refinement confidence

The true transition on a blurred edge is a blur, and color math adds noise there. Multiply each tier's confidence by:

```
fDefocus = 1 − smoothstep(σP + 1.0, σP + 2.5, D_up(p))
```

Here `D_up` is the upsampled `D` and `σP` is the primary's sharpness. Blend toward the base `m0` as the confidence drops.

### 9.3 Subject guard (unchanged from v1)

In the unknown band, where `m0 ≥ 0.9` and `confidence ≥ 0.8`:

```
α ≥ m0 − (0.3 + 0.7 · contrastConf)
```

### 9.4 Background guard (new mirror case)

In the unknown band, where `m0 ≤ 0.1` and `confidence ≥ 0.8`:

```
α ≤ m0 + (0.3 + 0.7 · contrastConf) · fDefocus
```

### 9.5 High-tier cost brake

- `α_high = mix(m0, α_high, confHigh)`, where `confHigh = exp(−λc·cost) · contrastConf`.
- Log a histogram of `confHigh` per image. On the `_DSC6372` hair glow, confidence should come out low.

### 9.6 Band widths

Make the band widths settings. A/B test the current `0.02/0.06·fh` against narrow `0.012/0.04·fh`, and log uncertain pixels for both.

---

## 10. Skin v2

Inputs: the linear reference decode (white-balanced), the refined subject mask, and face landmarks.

### 10.1 Sampling

- **Zones,** per promoted face:
  - forehead (between brows and hairline, 0.3·fh tall);
  - left and right cheek (below the eyes, beside the nose);
  - chin;
  - neck (0.6–1.0·fh below the chin).
- Take 7×7 patches at about 15 points per zone, skipping pixels inside landmark exclusion polygons.
- **Robust fit:** compute the mean and covariance in log-chromaticity (§10.2). Drop the 15% of samples furthest by Mahalanobis distance and refit. Floor the covariance at `diag(0.0025, 0.0025)`.
- Record the luma range `[Ylo, Yhi]` as the 10th–90th percentiles of the kept samples.

### 10.2 Skin score kernel (Core Image, linear RGB)

```metal
#include <CoreImage/CoreImage.h>
extern "C" float4 skinScore(coreimage::sample_t I,
                            float2 mu, float4 invCov,      // (s00, s01, s10, s11)
                            float tol0, float tol1,        // Mahalanobis ramp, e.g. 2.0, 3.5
                            float specTol0, float specTol1,// segment distance, e.g. 0.04, 0.10
                            float Yhi, float Yfloor) {     // e.g. Yfloor = 0.25*Ylo
    float3 c3 = max(I.rgb, 1e-4);
    float2 c  = float2(log(c3.r / c3.g), log(c3.b / c3.g));   // shading invariant; neutral = (0,0)
    float2 d  = c - mu;
    float m   = sqrt(max(d.x*(invCov.x*d.x + invCov.y*d.y) + d.y*(invCov.z*d.x + invCov.w*d.y), 0.0));
    float diffuse = 1.0 - smoothstep(tol0, tol1, m);

    // Specular = skin + white light: chroma lies on the segment from mu to the origin.
    float t   = clamp(dot(c, mu) / max(dot(mu, mu), 1e-6), 0.0, 1.0);
    float dl  = length(c - t * mu);
    float Y   = dot(c3, float3(0.2126, 0.7152, 0.0722));
    float spec = (1.0 - smoothstep(specTol0, specTol1, dl)) * smoothstep(Yhi, Yhi * 2.5, Y);

    float lumOK = smoothstep(Yfloor * 0.5, Yfloor, Y);          // loose floor only
    float s = max(diffuse, spec) * lumOK;
    return float4(s, s, s, 1.0);
}
```

### 10.3 Texture guard (protects against brown hair)

- `tex = stdDev(Y, 1.5 px) / (stdDev(Y, 6 px) + 1e-3)`, computed with box or Gaussian blurs of `Y` and `Y²`.
- `skin *= 1 − smoothstep(t0, t1, tex)`, with `t0 ≈ 0.6` and `t1 ≈ 0.9` (tune).
- Hair has high fine-scale variance and skin is smooth.

### 10.4 Hysteresis growth (proxy resolution)

1. **Seeds:** `skin ≥ τhi` (0.7) **and** inside the subject mask **and** inside sample zones dilated by 0.5·fh.
2. **Grow:** a flood fill (8-connected) from the seeds through pixels with `skin ≥ τlo` (0.35), inside the subject mask.
3. **Result:** `skinMask = skin · grown`. Ungrown pixels are 0.
4. **Hole filling:** fill holes in `grown` under 0.05% of the frame. This catches remaining specular blotches.

### 10.5 Exclusions and finishing

- **After** hole filling, subtract the landmark polygons (eyes, brows, outer lips). Dilate them by 0.01·fh and feather.
- Guided filter with the full-color image as guide, radius 4 full-res px, `eps` 1e-3.
- Then multiply by the refined subject alpha.
- **Controls:** Skin tolerance (scales `tol0`/`tol1` and `τlo`), Include shadows (sets `Yfloor`), Include highlights (enables `spec`).

### 10.6 Skin bake-off

The owner hand-masks `gt_skin.png` for about 10 images:
- close-ups with mixed light (`_DSC7473`);
- full-body cosplay with exposed skin (`_DSC6372`, `_DSC7006`);
- skin-toned costume fabric;
- brown, blonde and red hair against skin;
- shadowed and backlit faces.

| ID | Method |
|---|---|
| **K0** | Current skin mask (baseline) |
| **K1** | Skin v2 color model (§10.1–10.5) |
| **K2** | K1, with growth constrained to SAM part regions: SAM decodes with positive points at the zone centers (`multimask = true`, keep the **smallest** candidate containing the point, i.e. the part-level mask). Grow only inside the union of those parts |
| **K3** | Face-parsing model (SegFormer, CelebAMask-HQ classes) on face crops, K1 for the body. **Reference only:** these weights are typically non-commercial, so it measures the gap, it doesn't ship |

- **Metrics:** skin IoU, **hair false-positive rate** (skin-mask pixels inside a hand-marked hair region), and shadow-side recall (on a hand-marked shadow-skin region).
- **Expectation, stated honestly:** neither BiRefNet nor SAM is a skin model. K1 should do most of the work. K2 tests whether SAM's part boundaries help separate hair from face. K3 shows how much a dedicated model would add, which informs whether training an in-house skin model is worthwhile later.

---

## 11. Caching and performance

**Cache key:** `(rawFileID, proxyRenderParamsHash, modelVersions, baseSettingsHash)`.

**What's cached:**

| Item | Where | Notes |
|---|---|---|
| Proxy, neutral reference crops | memory LRU + disk | Removes the repeated 0.29–0.35 s neutral render per request |
| SAM embeddings (full + crops) | memory LRU (cap 256 MB) | Needed for instant refine clicks |
| BiRefNet outputs (`SA`, `SB`, crops) | disk, 16-bit | |
| Sharpness `σ`, `E`, `D` | memory | |
| `BaseMaskResult` + edit ops | disk | |
| Per-tier refined tiles | MaskStack | |

**Behavior:**
- Switching tiers reruns **only** refinement.
- Remake clears the base cache for the image, but keeps the edit ops unless the user clears them.
- White balance and exposure edits never invalidate masks.

**Log lines** (same style as existing logs):

```
base     <img>: candidate C · SAM encode 1024² in 0.000 s (cached) · BiRefNet A 2048² in 0.000 s · B box 812×1890 in 0.000 s
base     <img>: faces 5 → primary #1 (faceSharp 0.42 px), negatives 3, others decoded 3 in 0.000 s
base     <img>: components 37 → kept 3 (ov/attached), dropped 34 (others 2, disconnected 29, speckle 3)
edit     <img>: box subtract 412×980 → removed 0.84 MP in 0.000 s, recompute 6 tiles
mask     <img>: guards: subject 12,431 px, background 88,210 px · defocus-attenuated 1.1 MP
memory   peak during base: 0.0 GB
```

---

## 12. Acceptance

- **Subject:** the chosen candidate meets §2.5 in-app (with Core ML), not just in Python.
- **Named cases:**
  - `_DSC6953` and `_DSC7006`: no background people after one click.
  - `_DSC7006`: one subtract box removes the edge person; one add box around the boots improves their edges.
  - `_DSC6372`: the headpiece is kept, and there's **no seam and no hair glow** in the Background −3 EV view at Max.
  - `_DSC7473`: no regression in the curls.
- **Overlap category:** report results per image to the owner. There's no pass threshold until a baseline exists.
- **Skin:** K1 (or K2) beats K0 on skin IoU and shadow-side recall, with a hair false-positive rate ≤ K0's.
- **Review views:** acceptance reviews use **Background −3 EV**, **Subject −3 EV**, On Black and On White.
- **Timing** (warm, M3 Pro, 33 MP):
  - one-click base ≤ 4 s;
  - point operation ≤ 0.3 s;
  - box operation ≤ 2.5 s;
  - cached tier switch ≤ 0.1 s plus refinement.
  - Report 61 MP separately.
- **Memory:** peak process memory during the base stage ≤ 3 GB at 33 MP. Report 61 MP separately.

---

## 13. Related fixes (from the alpha 7 logs and screenshots)

1. **Rectangular seams in the `_DSC6953` Fast overlay:** audit general `CIKernel` `roiCallback`s and band-bbox clipping.
2. **Background job changed the selection** (`_DSC6637` re-selected 96 ms after its Max job finished). Completion handlers must never navigate.
3. **Raw render cache:** a reselect re-rendered instead of reusing. Check whether mask completion invalidates the cache. Cap the cache by bytes with an LRU (memory grows by about 200–300 MB per opened image).
4. **Interactive render path** (0.29–0.44 s per change, 3–4 GB peaks): render at view resolution while a slider is moving, and at full resolution on release or zoom.
5. **Vision cold start (1.8 s):** covered by prewarm. The same applies to SAM and BiRefNet.

---

## 14. Open questions

1. Does B2 (a SAM encode of the box crop) close most of the gap between B and C on full-length shots?
2. Should the box-add "reassess" step (§8.2) run BiRefNet even when the winner is B? It's more detail at the cost of one more model.
3. Aspect-squash versus letterbox for BiRefNet on 2:3 portraits.
4. Should overlapping background people default to removal (`O_k` subtraction) only when their face is notably blurrier than the primary, to avoid removing a second intended subject?
5. Is K2's SAM part-level masking stable enough to constrain skin growth, or does it fragment faces?

---

## 15. Dependencies

| Item | Ships? | License |
|---|---|---|
| SAM 2.1 Core ML (`apple/coreml-sam2.1-*`) | Downloaded on demand | Apache-2.0 ✅ |
| BiRefNet_HR weights (converted) | Downloaded on demand (if A or C wins) | MIT ✅ |
| ONNX Runtime (only if the §3.2 fallback is needed) | Yes | MIT ✅ |
| PyTorch, transformers, sam2, coremltools | No (evaluation and conversion only) | BSD / Apache ✅ |
| Face-parsing weights (K3) | **No** (evaluation only) | Typically non-commercial ⚠️ |

System frameworks: Vision (faces and landmarks only), Core ML, Core Image, Accelerate/vDSP, Metal.
