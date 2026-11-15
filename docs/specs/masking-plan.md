# Masking Implementation Plan — macOS RAW Editor

**Purpose:** Hand-off spec for a future code session. It describes a proposed architecture for subject, hair-edge and skin masks in a native macOS RAW editor (Core Image / `CIRAWFilter` based). Written by Claude Opus 5.5 to be **audited** before implementation. Section 12 lists what is unverified and the decisions the auditor should weigh in on.

**Owner context**
- Portrait photographer building their own macOS editor.
- Typical files: Nikon Z7 (45.7 MP). Worst case: Sony A7CR (61 MP, 9504 × 6336).
- Hardest target scene: big curly hair on a studio backdrop, with some strands crossing differently colored set decorations.

---

## 0. Guiding principles

1. **On-device only.** Private Cloud Compute is not usable for this: third-party access in the OS 27 cycle is limited to Apple's Foundation Models (an LLM), not custom models. No server component is planned.
2. **Apple frameworks first, third-party models last.** Phases 1–2 ship with zero third-party runtime dependencies.
3. **Masks are a stack, not a single bitmap.** Keep the first-pass mask, every refinement result and their settings, so refinement can be toggled, re-run per region, and debugged.
4. **Separate "what is the subject" from "where exactly is the edge".**
   - ML or Vision models answer the first question at low resolution.
   - Matting math answers the second at native resolution, inside a thin uncertain band only.
5. **Cost scales with edge length, not image area.** Every refinement stage is restricted to the unknown band's bounding box (or tiles along it). Nothing runs full-frame at 61 MP except trivially cheap per-pixel kernels.
6. **Masks are computed from a fixed reference decode** (see §2.1), so later edits never move the mask.

---

## 1. Pipeline overview

```
RAW ──CIRAWFilter──► Reference decode (linear, as-shot WB, neutral)       [§2.1]
        │
        ├──► Display proxy (2048 px long edge, sRGB 8-bit) ──► Vision      [§3]
        │                                     │
        │                         first-pass soft mask (low res)
        │                                     │
        │               CIEdgePreserveUpsample (guide = full-res luma)
        │                                     │
        ├──► [Phase 2] Head-crop Vision pass (full-res crop) ──► merge     [§5.1]
        │                                     │
        │                            Trimap (fg / bg / unknown)            [§4.1]
        │                                     │
        │      ┌──────────────── refinement tier ─────────────────┐
        │      │ Fast  (always on): normalized-conv F/B + α solve  │       [§4]
        │      │ High  (default on strong machines): sampled F/B   │       [§5.2]
        │      │ Max   (background): tiled closed-form matting     │       [§5.3]
        │      └───────────────────────────────────────────────────┘
        │                                     │
        │      [Phase 3] "Refine Hair": ML matting tiles → prior for Max   [§6]
        │                                     │
        │                    Foreground/background color estimate          [§5.4]
        │                                     │
        └──────────────► MaskStack (sparse full-res tiles + proxy base)    [§7]
                                              │
                              Compositing (CIBlendWithMask or F/B-aware)   [§7.3]

Skin mask: sampled Lab chroma model × refined person mask − landmark exclusions  [§8]
```

---

## 2. Foundations

### 2.1 Reference decode

- Use `CIRAWFilter` with:
  - as-shot white balance and the default/baseline exposure;
  - `boostAmount = 0` (a linear response; verify the exact property behavior);
  - no local tone mapping, no sharpening, no noise reduction beyond the minimum.
- Working format: `RGBAh` (half float). Working color space: **linear**, with a fixed primaries choice such as extended linear sRGB/Rec.709 or linear Rec.2020. Pick one and use it everywhere. The Lab math in §8 must match whichever is chosen.
- **Do not hold the full-res reference decode in memory.** It is about 482 MB at 61 MP in RGBAh. Instead, render on demand with `CIContext.render(_:toBitmap:...)` / `startTask(toRender:...)` for:
  - the display proxy (long edge 2048, sRGB-encoded, tone-mapped like a normal default render);
  - full-res crops of the **head/band bounding box** only.
- **Cache key:** `(rawFileID, rawFilterParamsHash, maskAlgorithmVersion)`.

### 2.2 Minimum OS decision (open — see §12)

- **macOS 14:** Vision foreground and person instance masks. Enough for Phases 1–2.
- **macOS 27:** adds `GenerateIterativeSegmentationRequest` (tap-to-segment, with include points; exclusion is described as supported, so verify the exact API) and the Core AI framework / `apple/coreai-models` export recipes (relevant for SAM 3 in Phase 3).
- Suggestion: deployment target 14, with tap-to-segment behind `if #available(macOS 27, *)`.

### 2.3 Build setup for Metal Core Image kernels

- Put Core Image kernels in `.ci.metal` files (or a separate target).
- Build settings:
  - Other Metal Compiler Flags: `-fcikernel`
  - `MTLLINKER_FLAGS`: `-cikernel`
- Load kernels with `CIColorKernel(functionName:fromMetalLibraryData:)` / `CIKernel(...)`.
- Compute-heavy stages (High and Max tiers, JFA, CG) are **Metal compute pipelines**, wrapped in `CIImageProcessorKernel` so they slot into the Core Image graph and inherit tiling and ROI handling. Alternatively, drive them directly with `MTLCommandBuffer`s on cached crops.

### 2.4 Proposed module layout

```
Masking/
  MaskStack.swift              // storage, tiles, invalidation, CIImage provider (§7)
  ReferenceDecode.swift        // proxy + crop rendering, caching (§2.1)
  FirstPass/
    VisionSubject.swift        // foreground / person / instance / tap-to-segment (§3)
    HeadRegion.swift           // face rects, head crop, hair zone (§5.1)
  Refine/
    Trimap.swift + Trimap.ci.metal          (§4.1)
    FastRefine.swift + FastRefine.ci.metal  (§4.2–4.4)
    GuidedFilter.swift + GuidedFilter.ci.metal (§4.5)
    HighRefine.swift + HighRefine.metal     (§5.2)  // compute
    ClosedForm/ (Solver.swift, ClosedForm.metal, CPUReference.swift) (§5.3)
    ForegroundEstimate.swift + .metal       (§5.4)
    Tiling.swift                            (§5.5)
  Skin/
    SkinMask.swift + SkinMask.ci.metal      (§8)
    LandmarkExclusion.swift
  ML/ (Phase 3)
    MattingModel.swift, ModelDelivery.swift (§6)
  Scheduler.swift              // tiers, background tasks, cancellation, memory budget (§9)
```

---

## 3. First pass (Phase 1, Apple only)

**Input:** the display proxy CGImage (long edge 2048, sRGB). The models expect display-referred images, not scene-linear data.

| Purpose | API (min OS) | Notes |
|---|---|---|
| Select subject (any class) | `VNGenerateForegroundInstanceMaskRequest` (14) | Prefer the low-res mask accessor over `generateScaledMaskForImage`, so the upsample is done by our own edge-preserving step. Verify the accessor name and whether its output is soft. |
| People, as one mask | `VNGeneratePersonSegmentationRequest`, `.accurate` (12) | Request a float or half output format. Check the actual output resolution per quality level. |
| Pick one person in a group | `VNGeneratePersonInstanceMaskRequest` (14) | Up to 4 instances. |
| Add / subtract by tapping | `GenerateIterativeSegmentationRequest(seed:)` (27) | Call `downloadAssets()` before first use. `addIncludedPoint(_:)`; verify the exclusion API. |
| Faces | `VNDetectFaceRectanglesRequest`, `VNDetectFaceLandmarksRequest` | Used for the head crop, band width and skin exclusions. |

**Instance selection default:** all instances for "Select Subject". For "Select Person", use the instance with the largest face, with the others available in a picker.

**Upsample to full res,** restricted to the region of interest:

```swift
let up = CIFilter.edgePreserveUpsample()
up.inputImage      = fullResGuide        // full-res reference crop (luma is what's used)
up.smallImage      = lowResMask          // Vision output as CIImage
up.spatialSigma    = 3                   // tune
up.lumaSigma       = 0.15                // tune
let firstPass = up.outputImage!          // soft mask at full res (lazily evaluated)
```

The result is called **`m0`**, the first-pass soft mask, in what follows.

---

## 4. Fast refinement tier (Phase 1, always on)

The goal is fractional alpha on clean, high-contrast edges (flyaways against sky, curls on seamless) in roughly 0.1–0.3 s at 61 MP.

### 4.1 Trimap

The trimap is computed at **¼ resolution** of the band bounding box (cheaper morphology), then upsampled.

**Band widths in full-res pixels:**
- `rIn  = clamp(0.02 * faceHeight, 4, 64)` — erosion, giving "definitely foreground".
- `rOut = clamp(0.06 * faceHeight, 8, 160)` — dilation, giving "definitely background".
- Inside the **hair zone** (§5.1), use `rIn × 2`. Curly hair masks from Vision tend to fill the gaps between curls, and a narrow erosion would mark those gaps as definite foreground.
- If no face is found, use `0.006 × longEdge` as the base unit.

**Morphology:** use `CIMorphologyRectangleMinimum` / `Maximum`, which are separable and fast at large radii, at ¼ res with radii divided by 4. Then classify:

```metal
// Trimap.ci.metal
#include <CoreImage/CoreImage.h>
extern "C" float4 trimapClassify(coreimage::sample_t eroded,
                                 coreimage::sample_t dilated,
                                 float fgT, float bgT) {     // fgT 0.97, bgT 0.03
    float fg = step(fgT, eroded.r);
    float bg = 1.0 - step(bgT, dilated.r);
    float unk = clamp(1.0 - fg - bg, 0.0, 1.0);
    return float4(fg, bg, unk, 1.0);                         // r=FG g=BG b=unknown
}
```

Upsample the trimap with nearest sampling (or linear followed by re-thresholding). Compute the **band bounding box** as the bbox of `unknown > 0`, dilated by `rOut`. All later stages work in that crop.

### 4.2 Local foreground/background color estimate (push-pull)

This runs at ¼ res of the band crop on linear RGB.

For F, the weight is `w = trimap.r` (definite FG). For B, it is `w = trimap.g`.

- **Push (down):** at each level build `C = Σ I·w` and `W = Σ w` with a 2×2 box downsample. Clamp `W` to at most 1 after normalization. Stop when the coarsest level is 16 px or smaller.
- **Pull (up):** going coarse → fine:
  - `C'ₗ = Cₗ + (1 − Wₗ) · up(C'ₗ₊₁)`
  - `W'ₗ = Wₗ + (1 − Wₗ) · up(W'ₗ₊₁)`
- **Estimate:** `F̂ = C'₀ / max(W'₀, 1e-4)`.

This can be implemented with Core Image transforms and a small combine kernel, or as a Metal compute push-pull (simpler to make exact). Upsample `F̂` and `B̂` to full res with bilinear sampling.

**Known Fast-tier limitation (accepted):** near the hairline, `F̂` can pick up forehead skin instead of hair. For dark hair on a bright background the luminance difference still dominates the projection, so α stays reasonable. The High tier fixes the hue error.

### 4.3 Alpha solve with contrast fallback

This runs at full res over the band crop, in linear RGB.

```metal
// FastRefine.ci.metal
#include <CoreImage/CoreImage.h>
extern "C" float4 fastAlpha(coreimage::sample_t I,      // linear RGB
                            coreimage::sample_t F,      // F̂ (upsampled)
                            coreimage::sample_t B,      // B̂ (upsampled)
                            coreimage::sample_t base,   // m0
                            coreimage::sample_t tri,    // trimap
                            float c0, float c1) {       // contrast ramp, e.g. 0.02, 0.10
    float3 d = F.rgb - B.rgb;
    float dd = dot(d, d);
    float a  = clamp(dot(I.rgb - B.rgb, d) / (dd + 1e-6), 0.0, 1.0);

    // Exposure-invariant contrast: normalize by the colors' energy.
    float cn = dd / (dot(F.rgb, F.rgb) + dot(B.rgb, B.rgb) + 1e-6);   // in [0, 2]
    float conf = smoothstep(c0, c1, cn);

    float m  = mix(base.r, a, conf);           // low contrast: keep the first pass
    m = mix(base.r, m, tri.b);                 // only change unknown pixels
    m = mix(m, 1.0, tri.r);                    // definite FG -> 1
    m = mix(m, 0.0, tri.g);                    // definite BG -> 0
    return float4(m, conf, 0.0, 1.0);          // g carries confidence for later tiers
}
```

### 4.4 Noise and highlights

- High-ISO noise in linear shadows makes α noisy. That is handled by the guided filter in §4.5. Do not denoise `I` itself.
- **Clipped backdrops** (an overexposed white seamless) are fine: B is about (1,1,1). In highlight-reconstruction regions the colors are unreliable, so lower `conf` where any channel of `I` or `B̂` is at or above the clip level.

### 4.5 Guided filter cleanup

This is restricted to the band, with grayscale guide `g = luma(I)` and input `p = α`.

- **Pack and blur once:** build `(g, p, g², g·p)` as one RGBA image and apply `CIBoxBlur(radius r)`. That yields `(μg, μp, E[g²], E[gp])` in a single blur.
- **Coefficients kernel:**
  - `var = E[g²] − μg²`
  - `cov = E[gp] − μg·μp`
  - `a = cov / (var + eps)`
  - `b = μp − a·μg`
  - output `(a, b)`
- **Blur again:** `CIBoxBlur(r)` on `(a, b)`.
- **Final:** `q = ā·g + b̄`, clamped to [0,1] and re-masked by `tri.b` so definite regions are untouched.
- **Defaults:** `r = 4` full-res px, `eps = 1e-4` on luma normalized by the crop's 99.5th percentile. Tune both on the test set.

**Output of the Fast tier:** `αFast` and `confFast`, written to the MaskStack (§7).

---

## 5. Quality tiers (Phase 2, Apple only)

### 5.1 Head-crop pass and hair zone

This pass is automatic, cheap and Vision-based. It runs before the High and Max tiers.

**Head crop per face:**
1. Take the face rect `f`, in full-res pixels, from `VNDetectFaceRectanglesRequest` on the proxy, scaled up.
2. Build the crop rect:
   - width = `2.6 · f.width`, height = `3.0 · f.height`;
   - centered on the face center, then shifted **up** by `0.25 · f.height`;
   - intersected with the bbox of `m0 > 0.03` dilated by `rOut`, and clamped to the image.
3. Render that crop at full res from the reference decode, in display-referred sRGB for Vision.
4. Run `VNGeneratePersonSegmentationRequest(.accurate)` on the crop. Use person segmentation, not foreground/saliency, which degrades when the scene is cropped tight.
5. Upsample with `edgePreserveUpsample`, guided by the crop.
6. Merge only inside the unknown band: `m0' = mix(m0, mCrop, tri.b · featherToCropEdge)`.
7. Recompute the trimap from `m0'`.

**Hair zone:** inside the head crop, excluding a face oval built from the landmark face contour with the forehead extended by `0.35 · f.height`. The hair zone is used for:
- the wider erosion (§4.1);
- High-tier priority;
- tile placement in Max and Refine Hair.

### 5.2 High tier — sampled F/B (shared-matting style)

The goal is to correctly handle **multiple background colors** (backdrop plus decorations) and hair-versus-skin foreground confusion. Estimated cost is about 1–4 s at 61 MP for big curly hair (see §10).

It runs as Metal compute over the band crop at full res.

**Step 1: distance fields with the jump flood algorithm (JFA).** These are computed on the band crop:
- `seedFG`: the nearest definite-FG pixel for every pixel. `seedBG` is the same for definite BG.
- The standard process: about ⌈log₂ N⌉ passes with step sizes N/2 … 1, plus one extra pass at step 1. Store seed coordinates as `ushort2`.
- `distFG(p) = |p − seedFG(p)|`, and likewise `distBG`.

**Step 2: gather candidates, select a pair, write out (one fused kernel, no candidate storage).**

```metal
// HighRefine.metal (sketch)
#include <metal_stdlib>
using namespace metal;

struct HighParams { uint K; uint maxSteps; float maxLen; float wd; float eps; };

kernel void highGatherSelect(
    texture2d<float, access::read>  I       [[texture(0)]],   // linear RGB (band crop)
    texture2d<float, access::read>  tri     [[texture(1)]],   // r=FG g=BG b=unknown
    texture2d<float, access::read>  distFG  [[texture(2)]],
    texture2d<float, access::read>  distBG  [[texture(3)]],
    texture2d<half,  access::write> outF    [[texture(4)]],   // rgb = F, a = alpha
    texture2d<half,  access::write> outB    [[texture(5)]],   // rgb = B, a = cost
    constant HighParams& P [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= I.get_width() || gid.y >= I.get_height()) return;
    if (tri.read(gid).b < 0.5) return;                       // unknown pixels only

    float3 Ip = I.read(gid).rgb;
    float2 p  = float2(gid) + 0.5;
    // Per-pixel angular offset (4x4 pattern) so neighbors probe different directions.
    float rot = float((gid.x & 3) + 4 * (gid.y & 3)) / 16.0 * (2.0 * M_PI_F / P.K);

    float3 Fc[8], Bc[8]; float dF[8], dB[8]; uint nF = 0, nB = 0;
    for (uint k = 0; k < P.K; ++k) {
        float th = rot + k * 2.0 * M_PI_F / P.K;
        float2 dir = float2(cos(th), sin(th));
        // Sphere-trace toward FG: a step of distFG can never jump over a FG pixel.
        float t = 0;
        for (uint s = 0; s < P.maxSteps && t < P.maxLen; ++s) {
            int2 q = int2(p + dir * t);
            if (any(q < 0) || q.x >= int(I.get_width()) || q.y >= int(I.get_height())) break;
            float d = distFG.read(uint2(q)).r;
            if (d < 1.0) { Fc[nF] = I.read(uint2(q)).rgb; dF[nF] = t; nF++; break; }
            t += max(d, 1.0);
        }
        t = 0;                                                // same toward BG
        for (uint s = 0; s < P.maxSteps && t < P.maxLen; ++s) {
            int2 q = int2(p + dir * t);
            if (any(q < 0) || q.x >= int(I.get_width()) || q.y >= int(I.get_height())) break;
            float d = distBG.read(uint2(q)).r;
            if (d < 1.0) { Bc[nB] = I.read(uint2(q)).rgb; dB[nB] = t; nB++; break; }
            t += max(d, 1.0);
        }
    }
    // Evaluate all F×B pairs; keep the best.
    float best = INFINITY; float3 bF = 0, bB = 0; float bA = 0;
    for (uint i = 0; i < nF; ++i) for (uint j = 0; j < nB; ++j) {
        float3 d  = Fc[i] - Bc[j];
        float  dd = dot(d, d);
        float  a  = clamp(dot(Ip - Bc[j], d) / (dd + P.eps), 0.0, 1.0);
        float3 r  = Ip - (a * Fc[i] + (1 - a) * Bc[j]);
        float  Mp = dot(r, r) / (dd + P.eps);                 // normalized chromatic distortion
        float  c  = Mp * (1.0 + P.wd * (dF[i] + dB[j]) / P.maxLen);
        if (c < best) { best = c; bF = Fc[i]; bB = Bc[j]; bA = a; }
    }
    outF.write(half4(half3(bF), half(bA)), gid);
    outB.write(half4(half3(bB), half(best)), gid);
}
```

Defaults: `K = 8`, `maxSteps = 24`, `maxLen = 2.5 · rOut`, `wd = 0.5`, `eps = 1e-6`. Tune all of these.

**Step 3: neighborhood refinement.** A second kernel, for each unknown pixel:
- read the best (F, B) pairs from its 5×5 neighbors;
- re-evaluate each pair against its own color `Ip`;
- average F and B over the top 3 by cost;
- recompute α;
- compute confidence `confHigh = exp(−λc · cost)` with `λc ≈ 50` (tune), and multiply by the normalized-contrast ramp from §4.3.

**Step 4:** apply the guided filter (§4.5) to `αHigh`, then blend: `α = mix(αFast, αHigh, confHigh)` on unknown pixels.

The output is `αHigh`, `confHigh`, and per-pixel F and B, which can be reused by §5.4 as its initial value.

**Why this fixes the decorations case:** different ray directions reach the backdrop and the decoration separately, and the pair selection picks the background color that actually explains each pixel.

### 5.3 Max tier — tiled closed-form matting (Levin et al.)

The goal is strand-level recovery at native resolution. It runs in the background with progressive tile updates.

**Energy:**

```
αᵀ L α + (α − α̂)ᵀ Λ (α − α̂)
```

Here `L` is the matting Laplacian over 3×3 windows, and `Λ` is diagonal:
- definite FG/BG: `λ_hard = 100`, with `α̂` set to 1 or 0;
- unknown pixels: `λ_soft · conf`, with `α̂ = αHigh` (or the ML alpha from Phase 3) and `λ_soft ≈ 0.05` (tune);
- `conf` is `confHigh`, or a constant for ML priors.

This leads to the linear system `(L + Λ) α = Λ α̂`. The matrix is symmetric positive definite, so it is solved with preconditioned conjugate gradient (PCG).

**Matrix-free application of L.** Never build the sparse matrix.

Per window `k` (a 3×3 neighborhood centered on pixel k):
- `μₖ` = mean of `I` over the window;
- `Σₖ = E[IIᵀ] − μₖμₖᵀ`;
- `Mₖ = (Σₖ + (ε/9)·Id₃)⁻¹`, a symmetric 3×3 stored as 6 floats.

Then:

```
(Lx)ᵢ = nᵢ·xᵢ − Σ_{k∋i} cₖ − Iᵢ · Σ_{k∋i} vₖ
  where uₖ = (1/9)Σ_{j∈k} Iⱼxⱼ − μₖ·(1/9)Σ_{j∈k} xⱼ
        vₖ = Mₖ uₖ
        cₖ = (1/9)Σ_{j∈k} xⱼ − μₖ·vₖ
        nᵢ = number of valid windows containing i (9 in the interior)
```

This takes two passes per operator application:

```metal
// ClosedForm.metal (sketch) — float32 throughout
kernel void cfWindowStats(device const float4* I [[buffer(0)]],    // xyz = linear RGB, normalized
                          device float4* mu [[buffer(1)]],          // xyz
                          device float4* Ma [[buffer(2)]],          // m00 m01 m02 m11
                          device float2* Mb [[buffer(3)]],          // m12 m22
                          constant uint2& dim [[buffer(4)]], constant float& eps [[buffer(5)]],
                          uint2 g [[thread_position_in_grid]]) {
    if (g.x == 0 || g.y == 0 || g.x >= dim.x - 1 || g.y >= dim.y - 1) return;  // window center must be interior
    float3 s = 0; float3x3 S = float3x3(0);
    for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
        float3 c = I[(g.y + dy) * dim.x + (g.x + dx)].xyz;
        s += c; S += float3x3(c * c.x, c * c.y, c * c.z);              // outer product
    }
    float3 m = s / 9.0;
    float3x3 C = S / 9.0 - float3x3(m * m.x, m * m.y, m * m.z);
    C[0][0] += eps / 9.0; C[1][1] += eps / 9.0; C[2][2] += eps / 9.0;
    float3x3 inv = /* symmetric 3x3 inverse via adjugate / determinant */ ;
    uint k = g.y * dim.x + g.x;
    mu[k] = float4(m, 0);
    Ma[k] = float4(inv[0][0], inv[0][1], inv[0][2], inv[1][1]);
    Mb[k] = float2(inv[1][2], inv[2][2]);
}

kernel void cfAccumulate(device const float* x [[buffer(0)]], device const float4* I [[buffer(1)]],
                         device const float4* mu [[buffer(2)]], device const float4* Ma [[buffer(3)]],
                         device const float2* Mb [[buffer(4)]], device float4* cv [[buffer(5)]],
                         constant uint2& dim [[buffer(6)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x == 0 || g.y == 0 || g.x >= dim.x - 1 || g.y >= dim.y - 1) return;
    float sx = 0; float3 sIx = 0;
    for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
        uint j = (g.y + dy) * dim.x + (g.x + dx);
        sx += x[j]; sIx += I[j].xyz * x[j];
    }
    uint k = g.y * dim.x + g.x;
    float3 m = mu[k].xyz; float4 a = Ma[k]; float2 b = Mb[k];
    float3x3 M = float3x3(float3(a.x, a.y, a.z), float3(a.y, a.w, b.x), float3(a.z, b.x, b.y));
    float3 u = sIx / 9.0 - m * (sx / 9.0);
    float3 v = M * u;
    cv[k] = float4(v, sx / 9.0 - dot(m, v));
}

kernel void cfApply(device const float* x [[buffer(0)]], device const float4* I [[buffer(1)]],
                    device const float4* cv [[buffer(2)]], device const float* lam [[buffer(3)]],
                    device float* Ax [[buffer(4)]], constant uint2& dim [[buffer(5)]],
                    uint2 g [[thread_position_in_grid]]) {
    if (g.x >= dim.x || g.y >= dim.y) return;
    float4 S = 0; float n = 0;
    for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
        int2 k = int2(g) + int2(dx, dy);
        if (k.x < 1 || k.y < 1 || k.x >= int(dim.x) - 1 || k.y >= int(dim.y) - 1) continue;
        S += cv[k.y * dim.x + k.x]; n += 1;
    }
    uint i = g.y * dim.x + g.x;
    Ax[i] = n * x[i] - S.w - dot(I[i].xyz, S.xyz) + lam[i] * x[i];
}
```

**Jacobi preconditioner:**

```
diagᵢ = Σ_{k∋i} [1 − (1/9)(1 + (Iᵢ−μₖ)ᵀ Mₖ (Iᵢ−μₖ))] + Λᵢᵢ
```

It is computed once per tile in a kernel that loops over the 9 windows containing each pixel.

**PCG loop:**
- Initial guess `x₀ = αHigh`, which greatly reduces iterations.
- Vector kernels for axpy and elementwise operations.
- Dot products via a two-stage threadgroup reduction.
- Keep α/β scalars on the GPU in a tiny buffer, computed by a 1-thread kernel, so there is no CPU round-trip per iteration.
- Check convergence every 16 iterations: relative residual below `1e-4`, or `maxIter = 300`.

**Input normalization:** the matting Laplacian's ε (default `1e-7` in the literature) assumes data in [0,1]. Normalize each tile's linear RGB by the crop's 99.5th-percentile value and clamp to [0,1]. **Open question:** linear versus gamma-encoded input for the color-line model (§12).

**Tiling (§5.5):** tile 1024² = 896² core + 64 px apron. Skip tiles whose core has fewer than 1% unknown pixels. Discard the apron, and blend overlaps with raised-cosine weights.

**CPU reference implementation:** the same matrix-free operator in Swift with vDSP and a hand-written PCG, used only for correctness tests against pymatting. (`SparseSolve` in Accelerate may accept a matrix-free operator; verify. A hand-written PCG is fine either way.)

**Known weak spot:** a 3×3 window containing hair plus *two* background colors (a strand crossing the backdrop/decoration boundary) violates the two-color model and can produce faint seam artifacts. Seeding from the High result and keeping `λ_soft` above 0 mitigates this. An ML prior (§6) fixes it best.

### 5.4 Foreground/background estimation (decontamination)

Multi-level foreground estimation (Germer et al. 2020, as implemented in pymatting) runs on the band crop given the final α.

**Per level, coarse → fine:**
- Upsample F and B from the coarser level.
- Run `n` Jacobi-style iterations: 10 at coarse levels, 2 at the finest (pymatting defaults; verify).
- In each iteration, every pixel solves a 2×2 system per channel:

```
[α² + Σw     α(1−α)    ] [F]   [α·I + Σ wⱼFⱼ    ]
[α(1−α)      (1−α)² + Σw] [B] = [(1−α)·I + Σ wⱼBⱼ]
wⱼ = ε_r + γ·|αᵢ − αⱼ|   over 4-neighbors   (ε_r ≈ 5e-3, γ ≈ 0.1; verify)
```

The output is F and B (RGBh) for band pixels only.

### 5.5 Tiling utility (shared by Max and Refine Hair)

- **Inputs:** band bbox, hair-zone mask, tile size and apron.
- **Layout:** a grid over the band bbox with stride = core size. Order tiles by unknown-pixel count, hair zone first.
- **Merge:** per-tile result × raised-cosine weight over the overlap, normalized by the summed weights. Results are written only where `tri.b > 0`.
- **Progress:** publish each finished tile to the MaskStack immediately; the UI re-renders that region.

---

## 6. Phase 3 — third-party ML

### 6.1 "Refine Hair" button

The flow is coarse → fine: global mask → head crop → tiles along the hair band, using the §5.5 tiling at the model's native input size (about 1024).

- **Model per tile: a trimap-conditioned matting network.** ViTMatte is the reference candidate. ⚠️ Its weights are typically trained on research-only matting datasets, so the license must be verified before shipping. The trimap carries the context the tile lacks, so the model does not need to see the face.
- **Alternative: BiRefNet** (MIT license) on tiles or on the head crop. It is easier to license, but tiles can disagree with each other.
- **Final step:** feed the ML alpha into the Max solver as `α̂` with a constant confidence, giving the best combined result. Then run §5.4.

### 6.2 Skin v2

- A face-parsing model (SegFormer or BiSeNet, CelebAMask-HQ-style classes) on face crops. ⚠️ Most public weights derive from non-commercial data.
- The preferred path for a paid app is to **fine-tune a small in-house model** on the owner's own portraits, with labels bootstrapped from Phase 1–2 masks plus manual correction.

### 6.3 Optional: SAM 3 text-prompted masks

- Export with Apple's `apple/coreai-models` recipe and run via Core AI (macOS 27).
- About 1.6 GB, so download it on demand rather than bundling it.
- ⚠️ Licensed under Meta's SAM License; review before shipping.

### 6.4 Model delivery

- Convert with `coremltools` / `coreai-torch` at **build time**; nothing from those tools ships in the app.
- Deliver models with the Background Assets framework or a self-hosted download pinned by SHA-256. Load lazily.

---

## 7. MaskStack, storage and compositing

### 7.1 Data model

```swift
struct MaskStack {
    var base: MaskPlane          // proxy-res (long edge 2048) soft mask, 16-bit, whole frame
    var refined: SparseTiles     // 256×256 full-res tiles, 16-bit single channel, band only
    var fb: SparseTiles?         // optional F/B (RGBh) tiles for decontaminated compositing
    var confidence: SparseTiles? // for debugging and for blending later passes
    var provenance: [Stage]      // first pass, head crop, fast, high, max, ML, brush strokes
    var settings: MaskSettings   // tier, band widths, softness, thresholds
    var key: CacheKey            // reference decode hash + algorithm version
}
```

- **Memory at 61 MP:** a full-frame 16-bit mask is about 120 MB. A sparse band-only set of tiles plus the proxy base is typically a small fraction of that. **Never use RGBA for masks.**
- **Rendering:** a `CIImageProcessorKernel` (or `CIImageProvider`) composes `upsample(base)` and overlays refined tiles where present. Use edge-preserving upsampling for the base outside the tiles.
- **Invalidation:** a brush stroke marks the touched tiles dirty. Only those tiles re-run their refinement tier.

### 7.2 User controls

- Mask quality: **Fast / High / Max**. The default comes from the machine (§9).
- Edge softness: 0 gives a hard cutout (threshold plus a slight feather); 1 gives full matting.
- Refine Hair (Phase 3).
- Tap add/subtract (macOS 27) and a manual brush.
- Debug overlays: trimap, confidence, and the subject composited over red or green to expose halos.

### 7.3 Compositing

- **Simple:** `CIBlendWithMask(adjusted, original, α)`.
- **Decontaminated, in the band only, when F and B exist:** `out = α·A_fg(F) + (1−α)·A_bg(B)`, where `A_fg` and `A_bg` are the subject and background adjustment chains. This removes color halos (for example, blue sky fringing on brown hair when the background is darkened). Outside the band, use the simple blend.

---

## 8. Skin mask

### 8.1 Phase 1 (Apple only)

1. **Sample.** The user clicks one or more skin points. Take 7×7 patches and compute, in CIE Lab:
   - the mean chroma `μ = (a*, b*)`;
   - the 2×2 covariance `Σ` (plus a floor such as `diag(4, 4)` to avoid a degenerate ellipse);
   - the L* range `[Lmin, Lmax]`.
2. **Color model kernel.** It takes linear RGB in the working primaries, converts to XYZ (D65) and then to Lab, and outputs a soft mask:

```metal
// SkinMask.ci.metal
#include <CoreImage/CoreImage.h>
inline float labf(float t) { return t > 0.008856 ? pow(t, 1.0/3.0) : 7.787 * t + 16.0/116.0; }
extern "C" float4 skinChroma(coreimage::sample_t I,
                             float2 mu, float3 invCov,      // invCov = (s00, s01, s11) of Σ⁻¹
                             float2 Lrange, float Lmargin,
                             float tol0, float tol1) {      // Mahalanobis ramp, e.g. 2.0, 3.5
    float3 c = max(I.rgb, 0.0);
    // Linear sRGB/Rec.709 primaries -> XYZ (D65). Change the matrix if the working space differs.
    float3 X = float3(dot(c, float3(0.4124, 0.3576, 0.1805)),
                      dot(c, float3(0.2126, 0.7152, 0.0722)),
                      dot(c, float3(0.0193, 0.1192, 0.9505)));
    float fx = labf(X.x / 0.95047), fy = labf(X.y), fz = labf(X.z / 1.08883);
    float L = 116.0 * fy - 16.0;
    float2 ab = float2(500.0 * (fx - fy), 200.0 * (fy - fz));
    float2 d = ab - mu;
    float m2 = d.x * (invCov.x * d.x + invCov.y * d.y) + d.y * (invCov.y * d.x + invCov.z * d.y);
    float chroma = 1.0 - smoothstep(tol0, tol1, sqrt(m2));
    float lum = smoothstep(Lrange.x - Lmargin, Lrange.x, L) * (1.0 - smoothstep(Lrange.y, Lrange.y + Lmargin, L));
    float s = chroma * lum;
    return float4(s, s, s, 1.0);
}
```

3. **Constrain:** multiply by the refined person mask (after the Fast/High tier, so the hair edges are already good).
4. **Exclude:**
   - Rasterize the landmark polygons (eyes, eyebrows, outer lips) with Core Graphics at proxy res.
   - Dilate by about `0.01·faceHeight` and feather.
   - Upsample and subtract.
5. **Clean up:** a light guided filter, guided by luma, to follow skin edges.

**Known limits:**
- Blonde or red hair, and warm clothing worn against the body, can fall inside the skin chroma ellipse.
- Neck and hands rely entirely on the color model.
- Phase 3 face parsing or an in-house model addresses both.

---

## 9. Scheduling, resources and defaults

- **Execution:** Swift concurrency. One `MaskJob` per mask, with stages as child tasks.
- **Cancellation:** honored between tiles and every 16 PCG iterations.
- **Priority order:** the first pass and the Fast tier run immediately (user-visible). The head crop and High tier follow. Max runs at background priority with tiles streamed in.
- **Memory budget:**
  - Query `MTLDevice.recommendedMaxWorkingSetSize` and `ProcessInfo.physicalMemory`.
  - Max tier: cap the number of concurrent tiles so that tiles × ~100 MB stays below budget.
  - Reuse `MTLHeap` buffers across tiles.
- **Default tier:**
  - Fast everywhere.
  - High when the GPU working set is at least 16 GB (proxy for Pro/Max-class chips; tune).
  - Max is opt-in, or automatic in the background on machines with 32 GB or more.
- **Never hold** more than one full-res reference-decode crop per active job.

---

## 10. Performance estimates (UNVERIFIED — order of magnitude only)

**Scenario:**
- 61 MP A7CR frame, big curly hair on a studio backdrop, some strands crossing decorations.
- Hair bbox about 16 MP; unknown band about 5–8 MP.
- An M-series Pro-class Mac with 18–24 GB.
- Excludes the RAW decode itself (about 1–2 s, about 0.5–1 GB).

| Stage / tier | Time | Peak extra RAM | CPU | GPU |
|---|---|---|---|---|
| Vision first pass + upsample | ~0.2–0.6 s | ~0.2–0.4 GB | low | Neural Engine / GPU brief |
| Head-crop pass | ~0.2–0.5 s per face | ~0.2 GB | low | brief |
| **Fast** | ~0.1–0.3 s | ~0.3–0.6 GB | negligible | brief spike |
| **High** | ~1–4 s | ~0.5–1 GB | low | heavy, seconds |
| **Max** (tiled, Metal PCG) | ~8–25 s | ~0.5–1 GB | low | heavy, sustained |
| **Max** (tiled, CPU reference) | ~30–90 s | ~0.5–1 GB | saturates P-cores | idle |
| Foreground estimation | ~0.5–1.5 s | ~0.3 GB | low | moderate |

Base M1/M2 with 8–16 GB: expect 2–3× longer, and keep Max strictly tiled to avoid swapping. Unified memory means GPU buffers count against system RAM.

---

## 11. Validation plan

- **Test set,** 10–20 frames from the owner's Z7 and A7CR shoots:
  - sky flyaways;
  - curly hair on white and grey seamless;
  - hair crossing colored decorations;
  - dark hair on a dark backdrop (the low-contrast fallback case);
  - backlit, flared hair;
  - group shots;
  - high-ISO frames.
- **Ground truth:** hand-refined masks from Photoshop or Lightroom for each frame, evaluated on the band only.
- **Metrics:** SAD, MSE, gradient error and connectivity (the standard alpha-matting metrics), plus visual composites over red, green and black.
- **Reference parity:** pymatting (MIT) implementations of closed-form matting and multi-level foreground estimation serve as the oracle for the Max tier and §5.4. Run them in Python on the same crops and compare.
- **Performance:**
  - Instruments (Metal System Trace, Allocations).
  - `os_proc_available_memory()` and `MTLDevice.currentAllocatedSize` logged per stage.
  - Record numbers for both cameras on the slowest and fastest Macs available.
- **Regression:** golden masks per test image, stored with `maskAlgorithmVersion`.

---

## 12. Audit checklist (for the reviewing session)

### Unverified claims to check first
1. **Vision API details:**
   - the exact low-res mask accessor on `VNInstanceMaskObservation` and whether its output is soft;
   - person segmentation output resolution per quality level;
   - the `GenerateIterativeSegmentationRequest` exclusion API and asset download flow (macOS 27, from WWDC26 session 237).
2. **`CIEdgePreserveUpsampleFilter`:** parameter semantics (which input is the guide) and quality at large scale factors such as 4–8×.
3. **`CIRAWFilter`:** properties for a truly linear, neutral reference decode (`boostAmount`, baseline exposure, and so on).
4. **Accelerate:** whether `SparseSolve` iterative methods accept a matrix-free operator.
5. **Parameter defaults** taken from the literature or pymatting: ε, ε_r, γ, iteration counts.
6. **Licenses:** BiRefNet (MIT), pymatting (MIT), ViTMatte weights, face-parsing weights, SAM 3 (SAM License).
7. **All timings in §10** are estimates, not measurements.

### Design decisions to evaluate
1. **Minimum macOS:** 14 with optional 27 features, or require 27?
2. **Push-pull in Core Image or Metal compute** (exactness versus graph simplicity)?
3. **Closed-form matting input:** linear versus gamma-encoded RGB. The color-line model and ε calibration may favor the gamma-encoded data most published results use. Settle this empirically on the test set.
4. **High tier:** is the sphere-traced JFA sampling worth it over a simpler multi-radius normalized convolution with several background clusters (k-means of B samples)?
5. **Curly-hair gaps:** is doubling the erosion in the hair zone enough to open up gaps that Vision filled, or should gaps get an explicit detector (for example, pixels inside `m0` whose color is close to `B̂`)?
6. **Decontaminated compositing (§7.3):** worth doing in Phase 2, or defer?
7. **Max solver:** Jacobi PCG versus a multigrid preconditioner. Iteration counts on real 61 MP tiles will decide this.
8. **Skin color space:** Lab with a Mahalanobis ellipse versus a simpler YCbCr ellipse. Check robustness across skin tones and mixed lighting.

### Suggested proceed order if the audit is positive
1. Phase 0 harness: test set, ground truth, pymatting prototypes of Fast, High and Max on real A7CR crops. This confirms the quality gaps and timing **before** writing Metal.
2. Phase 1 (first pass, Fast tier, skin v1, MaskStack).
3. Phase 2 in order: head crop → High → Max → foreground estimation.
4. Phase 3 only after licensing review.

---

## 13. Third-party dependency summary

| Item | Phase | Ships in app? | License |
|---|---|---|---|
| pymatting | 0 | No (prototype/oracle) | MIT ✅ |
| BiRefNet weights | 3 | Yes | MIT ✅ |
| Matting model (e.g. ViTMatte) | 3 | Yes | Weights often research-only ⚠️ |
| Face-parsing weights | 3 | Yes | Usually non-commercial ⚠️ (prefer in-house) |
| SAM 3 weights (optional) | 3 | On-demand download | SAM License ⚠️ |
| coremltools / coreai-models | 3 | No (build-time) | BSD ✅ |

Everything else is Apple frameworks: Vision, Core Image, Core ML / Core AI, Metal, Accelerate, Core Graphics, Background Assets.

---

## 14. References (verify citations)

- Levin, Lischinski, Weiss — *A Closed-Form Solution to Natural Image Matting* (CVPR 2006 / TPAMI 2008).
- Gastal, Oliveira — *Shared Sampling for Real-Time Alpha Matting* (Eurographics 2010).
- He, Sun, Tang — *Guided Image Filtering* (ECCV 2010 / TPAMI 2013).
- He, Sun, Tang — *Fast Matting Using Large Kernel Matting Laplacian Matrices* (CVPR 2010).
- Germer et al. — *Fast Multi-Level Foreground Estimation* (ICPR 2020).
- Rong, Tan — *Jump Flooding in GPU with Applications to Voronoi Diagram and Distance Transform* (I3D 2006).
- Apple WWDC26 session 237 — *What's new in image understanding* (tap-to-segment).
- `github.com/apple/coreai-models` — Core AI export recipes (macOS/iOS 27).
- pymatting — `github.com/pymatting/pymatting`.
