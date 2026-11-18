# v7.2.1: one edge rule for bright backgrounds (replaces v7.2 §2)

Build this on its own, as the next alpha. It supersedes any earlier v7.2.1 text. Everything not mentioned stays exactly as in alpha 22.

**Goal:** edges that read as natural under strong subject/background edits.

## What I see, and what we found
**What I see:** on 6303 at Subject +2.6 / Background −3, 297%, there are dark slivers and single dark pixels 1–4 px inside the finger edges. They're skin pixels that v7.2 §2 cut to alpha 0, which then follow the background's −3 EV.

**The cause is a lens fringe in the photo itself,** not the render. I sampled across the middle finger in neutral renders:
- **Boost 0:** skin (113,82,72) → edge (91,83,68) → (102,102,82) → (111,124,96) → background (158,202,167).
- **Boost 1:** the same shape.

The edge pixels have less red than both the skin and the background, so they can't be a blend of the two. It's longitudinal colour fringing, about 2 photo px wide, at f/1.6. Sharpness, colour noise reduction, moiré reduction and Boost don't change it. 7451's teal sleeve edge is the same thing.

**Why §2 failed:** it judged single pixels and cut them all or nothing. Fringe pixels (off the skin–background line) and noise were misjudged, and the cut punched holes.

## 1. Remove v7.2 §2
Remove the background-like cut, its notch case, and its B̂-based rim protection.

## 2. Where the new rule applies: bright-background edges
- Gate weight g_b per band pixel, from the Oklab lightness of B̂ and F̂ (both known): g_b = smoothstep(0.10, 0.20, L(B̂) − L(F̂)). So it's on where the background is clearly brighter than the subject next to it.
- Blur g_b 3 px so there are no seams where it switches.
- **Why:** lens fringe shows most at dark-subject/bright-background edges, and rim lights are almost always shot against darker backgrounds. So this keeps the rule away from rim lights without any rim test.
- **Where g_b = 0** (e.g. skin against a dark background, white on white): alpha 21's handling, unchanged. That's v7.1's repaint with the rim skip and the 40 px group rule.
- **Not in the hair zone** (except where F̂ is skin), and not under Refine Hair strokes.
- If F̂ or B̂ is unknown, g_b = 0.

## 3. The rule: decide on a blurred copy, keep the edge position at full resolution

**3.1 Blurred copy.** Gaussian blur of the neutral render, σ = 1.5 photo px, in linear light, computed over the band only (call it I_b). Also blur the current alpha the same way (α_b).

**3.2 Excess background.**
- t_b = position of I_b on the line from F̂ to B̂ (linear RGB, clamped 0–1).
- Confidence k = 1 − smoothstep(0.03, 0.08, Oklab distance from I_b to that line), so pixels far off the line count for less.
- What the current mask already explains is 1 − α_b.
- Excess e = max(0, t_b − (1 − α_b)) · k · g_b. This is background colour where the mask still says subject. Comparing against the blurred alpha stops the blur itself from eroding the edge.

**3.3 Cut.**
- α′ = α − e, clamped at 0.
- Apply a 3×3 median to e before using it, then a plain 1.5 px feather on the change. No "max with raw".
- **Reach:** only pixels with alpha < 0.98, or within 2 photo px inside the 0.5 contour. Never deeper.
- **No holes:** any enclosed group below alpha 0.5 smaller than 20 photo px that the cut created is restored.

**3.4 Repaint (both sides), for gated pixels.**
- **Subject side:** core w = 1 for every gated band pixel, with no rim skip in the gate.
- **Background side:** the v7.2 §3 repaint, unchanged.
- **Feathers:** both as in v7.1/v7.2 (smoothstep 2 px plus a 1.5 px blur, never weakening the core). Scale both cores by g_b, so the rule fades in and out smoothly.
- The edge position comes from the full-resolution alpha after the cut. The olive or teal colour in the full-resolution pixels is handled by the repaint, not by cutting.

**3.5 Where it runs.** At the end of the base mask, and inside every box operation (box plus 4 px margin): Refine Edges, Remove Colour, Edge Colour.

**3.6 Switch and log.**
- The Debug switch "Cut background-coloured edge pixels" now controls this rule (keep the name, or rename it "Bright-background edges").
- Log: gated pixels, mean excess cut, pixels cut, holes restored, repaint core counts.

## 4. Remove Colour uses the blurred copy for its decisions
- In both modes (automatic and eyedropper), the sample distance d and the mix t are read from I_b, not single pixels.
- The alpha change is still applied at full resolution.
- Everything else in v7.2 §4 stays.

## 5. Tests (synthetic; report the numbers)
**(p) Streak.** A 3-px pale green streak at a skin edge against bright green: reaches alpha ≤ 0.15. Skin 4 px away changes by ≤ 0.02.

**(p2) Noisy edge.**
- Setup: skin with 2% per-pixel noise and 10% green spill in the outer 3 px, against bright green.
- Pass:
  - no pixel with alpha ≥ 0.98 more than 2 px inside changes;
  - no new enclosed hole below alpha 0.5;
  - alpha changes by ≤ 0.3 between neighbouring pixels along the edge.

**(p3) Red-dip fringe (my measured 6303 values).**
- Setup: skin (113,82,72) → (91,83,68) → (102,102,82) → (111,124,96) → background (158,202,167), rendered through the real blend with Subject +2.6 / Background −3.
- Pass:
  - no edge pixel is more than 0.03 Oklab L darker than both its inner and outer neighbours;
  - no new hole;
  - the 0.5 contour moves ≤ 0.5 px compared with alpha 21.

**(s)** 7451's sleeve and teal case passes, with Subject +3 / Background −3.

**(r) Rim against dark background.** The gate is off, and the result is identical to alpha 21.

**(g0) White on white.** The gate is off, and the result is identical to alpha 21.

**(v) Invariants.**
- No local edits: pixel-identical to the photo.
- Edge switch off: byte-identical to alpha 16.

## 6. My acceptance check (300%)
- **6303, Subject +2.6 / Background −3:** no dark specks or slivers. The green streaks are gone or faint, and the finger edges read as natural.
- **7451, Subject +3 / Background −3:** no teal, no dark line, no notch cluster.
- **6957 box, 7006/7473 hair:** unchanged.
- **6372:** no new artifacts.

**Known trade-offs:**
- A rim light against a *brighter* background isn't protected (rare).
- A coloured detail at a bright-background edge thinner than about 3 px is treated more softly.

---

## Owner's answers during the build

1. **§4 left out (owner).** Remove Colour deciding on the blurred copy hurt small details in the existing tests: 3×3 specks kept about 60% coverage, a 2-px green fringe on skin 42%, the pink round a removed patch lost up to 27% in a ~3 px halo, an 8-px crescent kept up to 35% (only the diagonal gained). Taking the mix from the pixel instead left specks entirely. **Decision: Remove Colour keeps alpha 22's single-pixel decisions with cut by mix;** the blurred copy is used only in the bright-background rule.
2. **Test (p) (owner).** §3 as written leaves a streak on the mask's outer pixels faint, not gone: about 0.54 coverage on its inner pixel (the outer pixels 0.04 and 0), because the excess is what the blurred mask doesn't already explain. Laying the excess on each pixel's own colour reached only 0.38. **Decision: §3 exactly as written;** (p) is held to what the rule achieves (≤ 0.55) and the figure reported. The acceptance check allows "gone or faint".
