# TrainCull Logging Recommendations

**Purpose:** additions to TrainCull's logging, based on the alpha 7 session log (2026-11-14) and the screenshots. Each item names the gap it closes. Example lines follow the existing log style.

**Companion documents:** `masking-spec-v2.md` (base-mask decision logging, §11) and `masking-implementation-plan.md`.

---

## Priority order

| # | Area | Gap in the alpha 7 logs |
|---|---|---|
| 1 | Selection changes and job lifecycle | Couldn't tell whether the `_DSC6637` re-select 96 ms after its Max job finished was a click or a completion handler |
| 2 | Wall versus GPU time, cold versus warm | Couldn't separate slow work from waiting in a queue or contention |
| 3 | Cache hits, misses and invalidations | The neutral render was redone on every request; the raw render wasn't reused on one re-select |
| 4 | Memory per job and per render | Only process-wide numbers; peaks of 3–4 GB couldn't be attributed |
| 5 | Render path details | "Render with local adjustments" at 0.29–0.44 s, with no size, scale or trigger info |
| 6 | Refinement quality signals | Seams and hair glow were only visible by eye |
| 7 | Base-mask decisions | Needed for the bake-off and for diagnosing bad selections |
| 8 | Refine tool operations | New tools; latency and effect need measuring |
| 9 | Fallbacks and anomalies | Silent fallbacks (Neural Engine to GPU, skipped runs) are invisible today |
| 10 | CPU / GPU / Neural Engine load and power | No way to see how hard a mask or refine pass works the machine, or whether it throttles |

---

## 1. Selection changes and job lifecycle

**Selection:** log every selection change with its cause.
- `cause`: `user.click`, `user.key`, `programmatic`.
- For `programmatic`, include the calling component and job ID.

```
select   _DSC6637.ARW (456 of 1523) · cause: programmatic (MaskJob#41.completion)
select   _DSC6640.ARW (459 of 1523) · cause: user.key (→)
```

**Jobs:** every background job gets an ID. Log each state change: `queued → started → (cancelled | superseded | completed | failed)`. Include the trigger, the image, the time spent queued, and whether the job's image is still selected when it completes.

```
job      #41 Max _DSC6637 · trigger: user (Max button) · queued 0.00 s
job      #41 started · queue depth 1
job      #41 completed in 10.38 s · image selected at completion: no (_DSC6640)
```

**Rule to enforce, then verify through logging:** job completion never changes the selection.

---

## 2. Timing: wall time, GPU time, cold versus warm

- **Per stage:** log wall time **and** GPU time (`MTLCommandBuffer.gpuEndTime − gpuStartTime`, summed per stage). A large gap means queueing or contention.
- **Model calls:** mark the first prediction after load as `cold`, and log load time separately.
- **Once per model load:** log the compute units Core ML actually assigned, via `MLComputePlan` (macOS 14.4+). Summarize the count of operations on ANE, GPU and CPU.
- **Concurrency:** when two GPU-heavy jobs overlap (for example a Max job and a raw render), log `contention` on both.

```
model    SAM2.1-large encoder loaded in 1.42 s · plan: ANE 812 ops, GPU 37, CPU 4
base     _DSC6303: SAM encode 1024² wall 0.612 s · gpu 0.583 s · warm
mask     _DSC6303: max wall 8.17 s · gpu 7.94 s
image    _DSC6640: raw render wall 0.480 s · gpu 0.301 s · contention: MaskJob#41
```

---

## 3. Caches

Log one line per lookup for each cache: `render`, `neutral/reference`, `proxy`, `samEmbedding`, `birefnet`, `baseMask`, `refinedTiles`.
- On a miss, give the reason: `cold`, `evicted (LRU)`, `invalidated (<cause>)`, `keyChanged (<field>)`.
- Every 15 s alongside the memory summary, log each cache's entries, bytes and evictions since the last summary.

```
cache    neutral _DSC6303 · hit
cache    render _DSC6637 · miss: invalidated (MaskJob#41.completion)   ← would expose the bug
cache    summary · render 3 / 786 MB · samEmbedding 4 / 92 MB · baseMask 6 / 40 MB · evictions 1
```

---

## 4. Memory per job and per render

- **Per mask job and per render:** physical footprint (`task_vm_info.phys_footprint`) before and after, and the peak during. Sample every 50 ms while the job runs.
- **GPU side:** `MTLDevice.currentAllocatedSize` at the same points.
- **Memory pressure:** log each event (`warning` or `critical`) and what was released in response.

```
memory   MaskJob#41 · before 1.10 GB · peak 1.62 GB · after 1.18 GB · GPU alloc peak 0.71 GB
memory   pressure: warning · released: SubjectModel (452 MB), render cache 2 entries (524 MB)
```

---

## 5. Render path

Per render: output size, scale (`view` or `full`), the control and gesture that triggered it, requests coalesced or dropped while it ran, wall time, GPU time, and transient memory.

```
image    _DSC6633: render local-adj 4672×7008 (full) · trigger: Background.Exposure drag
         · coalesced 3 · wall 0.382 s · gpu 0.341 s · +1.6 GB transient
```

**Goal to verify with these logs:** during slider drags, renders are `view`-scaled and fast (target ≤ 50 ms). A `full` render only happens on release or zoom.

---

## 6. Refinement quality signals (automatic artifact detection)

**Seam detector (per Max run):**
- The 99th-percentile |Δα| across tile-boundary pixel pairs, versus the same statistic for interior pixel pairs.
- Flag `SEAM?` when the boundary/interior ratio is above 3.

**Band alpha histogram (per tier):** fraction of unknown-band pixels in each bucket: `0 | (0,0.2) | [0.2,0.8] | (0.8,1) | 1`.
- Also log the middle-bucket fraction **inside confident background** (`m0 ≤ 0.1`, `confidence ≥ 0.8`).
- A high value is the hair-glow signature seen on `_DSC6372`. Flag `GLOW?` when it exceeds 5%.

**Max tile table** (one compact line per tile, at debug level only): tile ID, unknown pixels, iterations, final relative residual, `converged` / `cap`, time.

**Guards, brakes and confidence:**
- pixels clamped by the subject guard and by the background guard;
- defocus-attenuated pixels;
- a `confHigh` histogram (5 buckets).

**Tier agreement:** IoU between the Fast result and the selected tier's result over the band.

```
mask     _DSC6372: max tiles 32 · converged 31 · cap 1 · seam ratio 1.4 · OK
mask     _DSC6372: band α 0:41% · low:9% · mid:18% · high:7% · 1:25% · mid-in-confident-bg 7.2% GLOW?
mask     _DSC6372: guards subject 12,431 px · background 88,210 px · defocus-attenuated 1.1 MP
mask     _DSC6372: confHigh 0–.2:31% .2–.4:12% .4–.6:9% .6–.8:14% .8–1:34% · fast↔max IoU 0.962
```

---

## 7. Base-mask decisions

Required for the bake-off; see also `masking-spec-v2.md` §11.

- **Faces:** count, the score and `faceSharp` for each, which face became primary, and which were promoted (all-in-focus mode).
- **Automatic inputs:** box rect, positive and negative point counts, multimask retry yes/no.
- **SAM:** predicted IoU per decode (primary and each `O_k`).
- **BiRefNet:** runs performed (A, B, head crop) and skipped (with reason).
- **Components:** total, kept (by reason: primary, overlap, attached), dropped (by reason: other person, disconnected, defocused, speckle).
- **Result:** mask area as a percent of the frame, and the bake-off candidate ID.

```
base     _DSC7006: candidate C · faces 3 → primary #1 (score 41.2, faceSharp 0.38 px), others 2 (neg)
base     _DSC7006: SAM primary IoU 0.94 · others [0.91, 0.88] · BiRefNet A ✓ B ✓ head ✓
base     _DSC7006: components 22 → kept 4 (primary 1, overlap 1, attached 2) · dropped 18 (other 1, disconnected 14, speckle 3)
base     _DSC7006: subject area 18.4% of frame · total 3.42 s
```

---

## 8. Refine tool operations

Per operation: the kind (point or box, add or subtract), geometry (normalized coordinates), masked area added or removed, the SAM predicted IoU used, whether BiRefNet "reassess" ran, tiles recomputed, latency until the overlay updated (Fast), and latency until the selected tier finished.

```
edit     _DSC7006: box subtract (0.71,0.22)-(0.98,0.81) · removed 0.84 MP · SAM IoU 0.90
         · recompute 6 tiles · overlay 0.21 s · max 2.9 s
edit     _DSC7006: box add (0.42,0.78)-(0.63,1.00) · added 0.03 MP · reassessed 0.41 MP (BiRefNet crop 1.1 s)
```

---

## 9. Fallbacks and anomalies

Log at warning level:
- **Fallback paths taken:** Neural Engine → GPU/CPU, ONNX Runtime instead of Core ML, Run B or head crop skipped (with reason), no usable face (§6.4 path).
- **Numerics:** NaN or infinity in any model output or solver output (count and stage), and any Max tile that hit the iteration cap.
- **Models:** load failures, download failures, SHA-256 mismatches, version mismatches between cache and model.
- **Unexpected states:** a job completing for an image no longer in the folder, or a cache entry whose key fails validation.

```
warn     SubjectModel: computeUnits .all → ANE rejected 14 ops, running GPU
warn     _DSC6372: max tile 17 hit cap (300) · residual 3.1e-3
warn     model download: birefnet_hr_fp16 SHA-256 mismatch · retrying
```

---

## 10. CPU, GPU and Neural Engine load and power

These are two layers: cheap in-app measures that are always on, and a developer-only power capture for real wattage.

### 10.1 In-app (public APIs, always on)

Sample alongside the existing 50 ms memory sampler while a mask job or render runs.

- **CPU:**
  - Process CPU time (user + system) from `proc_pid_rusage(getpid(), RUSAGE_INFO_V6, …)` or `getrusage`.
  - Derive the average and peak **cores in use** = ΔCPU time / Δwall time per sample (the M3 Pro has 11 cores).
  - Also log the job's total CPU-seconds.
- **GPU:**
  - There's no public per-process GPU utilization API. Use the app's own `MTLCommandBuffer` GPU timestamps instead.
  - **GPU busy %** = Σ GPU time of the job's command buffers / job wall time.
  - Also report the peak over a sliding 250 ms window.
  - Core ML work running on the GPU isn't counted here. Report it separately as model wall time.
- **Energy (if available):**
  - `rusage_info_v6` exposes process energy counters on Apple silicon (`ri_energy_nj`; verify the field names on the SDK).
  - Log the job's energy in joules and the average watts (energy / wall time).
  - If the fields aren't available, omit this; don't estimate.
- **Thermal state:**
  - Log `ProcessInfo.thermalState` at job start and end, and every change (`nominal`, `fair`, `serious`, `critical`).
  - A Max pass that pushes the machine to `serious` matters on laptops.

```
load     MaskJob#41 Max _DSC6303 · cpu 9.8 core-s · avg 1.0 / peak 6.3 cores · gpu busy avg 78% / peak 99%
         · energy 142 J (≈14 W avg) · thermal nominal → fair
load     render local-adj _DSC6633 · cpu 0.9 core-s · peak 4.1 cores · gpu busy 85% · 0.382 s
```

### 10.2 Developer-only power capture (real watts per component)

`powermetrics` (built into macOS, requires sudo) reports CPU, GPU and **Neural Engine** power, which no in-app API can.

- **Sidecar script** `tools/powercapture.sh`. It runs alongside a test session and writes timestamped samples:

```bash
sudo powermetrics --samplers cpu_power,gpu_power,ane_power,thermal \
  -i 100 --format plist -o "$HOME/Library/Logs/TrainCull/power-$(date +%Y%m%d-%H%M%S).plist"
```

- **Correlation script** `tools/power_report.py`:
  - joins the power samples to the JSONL log by timestamp;
  - for each job, outputs peak and average CPU, GPU and ANE milliwatts and energy (J);
  - plots power over time with job start/end markers.
- **Use cases:**
  - the bake-off (energy per candidate, not just time);
  - confirming whether SAM and BiRefNet actually run on the Neural Engine (ANE power above ~0) or fall back to the GPU;
  - spotting thermal throttling during back-to-back Max passes.
- **Instruments** (Metal System Trace, CPU Profiler, Power Profiler) remains the tool for deep dives on a single job.

### 10.3 Questions these logs should answer

- Is a Fast/High pass a brief spike, and how big?
- Is a Max pass a sustained GPU load, and does it throttle on a laptop?
- Do model runs use the Neural Engine (low power) or the GPU (high power)?
- How hard does the interactive render path hit the machine during a slider drag?
- **Battery versus AC:** log the power source (`IOPSCopyPowerSourcesInfo`) in the session header, and consider defaulting to a lower tier on battery.

---

## Format and infrastructure

- **Readable log:** keep the current human-readable format.
- **JSON Lines log:** write a `.jsonl` file in parallel, with the same events: `{ts, category, image, jobID, event, fields{...}}`. This makes sessions machine-parseable for scripts or analysis.
- **Image header** on first selection of each image in a session: camera, dimensions, ISO, aperture, focal length, and face count. This lets results be grouped by camera and conditions.
- **Session header:** app build, model versions and hashes, mask settings (tier, band widths, candidate), and the display scale factor.
- **Log levels:** `info` (the current lines plus §1–5 and §7–8 summaries), `debug` (per-tile tables and per-lookup cache lines), `warn` (§9).
- **Debug bundle link:** when "Export mask debug bundle" runs, write its path into the log against the image.
- **Rotation:** one file per session, keeping the last 20 sessions.
