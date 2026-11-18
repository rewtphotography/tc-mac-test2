# Masking spec v7: roll back to alpha 16, then two colour tools

**One build, no phases.** If anything here can't be done, stop and ask me before deferring it. Add this as `docs/specs/masking-spec-v7.md`, mark spec v6 as reverted, and update `MASKING.md` when done.

**Guiding principle (my standing decision):** least distracting to edit, not a perfect cut-out. Blunt and predictable beats clever.

## Why
Alpha 16 is the last good build. Its box removed 6957's finger slivers and the blurry hair in the gap, and its default masks were strong. Alphas 17 and 18 made things worse:
- the box regressed on 6957 and 6372;
- 4-px coloured squares appeared along edges on 6303 and 7451;
- a grey halo appeared around 6372's prop;
- the green/teal fringe was not visibly reduced.

The three remaining problems from alpha 16 are blunt colour problems:
1. the green bokeh on 6303's peace-sign edges;
2. the teal fringe on 7451's black sleeve and the olive on the skin in the arm–waist gap;
3. bits of orange wall included around 6372's rose.

## 1. Roll back to alpha 16
- Restore all masking code to the alpha 16 commit with git (revert or reset those files). Don't undo changes by hand.
- This removes all of spec v6 and the alpha 18 follow-up:
  - the subject light bound and hue rule;
  - the colour-space change and the share-clipping change;
  - the box limits and extra context;
  - the Refine Hair Strength/Tightness sliders;
  - the Edge Brush (Clean Edge goes back to the tool menu as in alpha 16);
  - automatic hands;
  - the hair-zone changes;
  - the Ignore faces switch.
- Keep alpha 16's Show edits checkbox and the marks fix.
- **Check:** with both new switches below turned off, the alpha, shares and debug bundle output must be byte-identical to alpha 16 on the same photo. The Refine Edges box must behave exactly as in alpha 16.

## 2. Edge colour from inside (automatic, Debug switch "Edge colour from inside", default on)
This works like Photoshop's Decontaminate Colors. It never looks at the background: each edge pixel's subject colour is taken from the solid subject just inside it.

**Inside colour F̂:**
- **Solid subject:** alpha ≥ 0.98 and at least 6 photo px inside the 0.5 contour.
- Take its colour from the neutral render, in linear light, with a 3×3 median to ignore pores and texture.
- Push that colour outward to cover the edge band, using nearest-solid fill. The push-pull fill in `Sharpness.dense` can be reused.
- Where no solid subject lies within 30 photo px (thin straps, strands), F̂ is unknown: leave the pixel alone.

**Edge band:** pixels with alpha > 0.004, from the outer end of the soft edge to 4 photo px inside the 0.5 contour. Convert to mask pixels as the engine does.

**Per pixel:**
1. Let α be the alpha, I the photo colour and P = s·I the subject's current portion.
2. **Rim-light skip:** if α ≥ 0.1 and Oklab L(P/α) > L(F̂) + 0.03, leave the pixel as is. A rim light (warm, gelled, any colour) adds light, so it is brighter than the inside. Every fringe I measured was the same lightness or darker.
3. Otherwise set P′ = k·α·F̂, where k = min(1, min over channels of I_c / (α·F̂_c)).
   - k is one number for the whole vector, so the subject's portion keeps F̂'s hue and never exceeds the photo in any channel.
   - Never clip channels separately.
   - New shares: s′ = P′ / I (0 where I_c = 0).
4. Alpha is unchanged, so the edge stays where alpha 16 put it. Light taken off the subject's side goes to the background.

**Amendments (owner, after the first test results):**
- **Rim-light threshold 0.05**, not 0.03, in Oklab L, with the engine's pow-2.2 curve (back in
  use since the rollback). On test (a) the sleeve's teal pixel (0,39,33) is 0.034 lighter
  than the sleeve (29,26,25) on that curve; a real rim (test (d)) is about 0.08 lighter.
- **A part-covered pixel is judged by its nearest fully covered neighbour** (alpha ≥ 250/255,
  within 3 px): that neighbour's subject part ÷ alpha, from the shares before this step. Its
  own part still holds some background light, and against a white wall a fringe read lighter
  than a real rim.
- **Accepted trade-off:** a rim thinner than the soft edge, or less than about 10% brighter
  than the inside, isn't protected in the outer few pixels. Wider rims keep their colour
  anyway, through the inside sample.

**Expected behaviour (owner):** where a fringe is far from the inside colour (a strong green
such as (88,118,70) beside skin (155,113,85)), k is small (about 0.3) and the subject's part
comes out skin-hued but much darker. That is correct: the pixel is mostly background light,
and putting light back would bring the green line back. Such a case is tested on colour with
lightness factored out, not held to 0.015 in absolute (a, b). The olive-strength case and
tests (b) and (c) keep 0.015 including lightness.

**Expected side effect:** where k < 1, the subject's side is slightly darker than α·F̂. On White can show such a pixel a touch darker. That's correct, because the pixel contains background light. Don't compensate.

**Where it runs:**
- as the **last step** of the base mask (after decontamination and the colour guard);
- as the last step **inside every Refine Edges box result**;
- inside the new Remove Colour box (§3).

**Where it doesn't run:**
- under Refine Hair strokes;
- in the hair zone, **except** where the skin model says F̂ is skin. Hands, fingers, neck and shoulders near the face are skin; hair isn't. This replaces any hair-zone geometry change: leave the zone's shape as in alpha 16.

**Log:** `edge colour from inside: N pixels recoloured, M skipped as brighter (rim light), U with no inside colour, mean Oklab ΔE x`.

**The photo itself is never changed.** In Photo view with no adjustments, the output must be identical to alpha 16.

## 3. Remove Colour box (new tool, "Remove Colour" in the tool menu)
This is for places where the mask actually includes background, like the orange wall at the rose. Recolouring can't fix those.

**Eyedropper:**
- Selecting the tool shows an eyedropper. A click samples a 5×5 median from the neutral render. Shift-click adds more samples (for example the lit and shadowed parts of a wall).
- Show the sampled colours as swatches, with a clear button.

**Tolerance slider:** Oklab distance, range 0.01–0.15, default 0.05.

**Box:**
- Drag a box. It acts only inside the box and only within 40 photo px of the mask outline. The deeper interior is never touched.
- For each pixel there, with B the nearest sampled colour and F̂ the inside colour from §2:
  - **Background fraction:** t = clamp(dot(I − F̂, B − F̂) / |B − F̂|², 0, 1) in linear light.
  - **Act only if** the pixel lies within the tolerance of the segment F̂–B (Oklab distance to the segment). A pixel within the tolerance of B itself gets t = 1.
  - **New alpha:** α′ = min(α, 1 − t).
  - **New subject portion:** P′ = k·α′·F̂, with k as in §2. Shares s′ = P′/I.

**Smoothing, then clean-up:**
- Blur the alpha change (not the alpha) inside the box with a 1.5 photo px radius.
- Remove pieces under 50 px that the operation cut loose from the subject.
- Fill holes under 50 px that it opened inside the subject.
- Blend at the box border the same way as the other box operations.

**Live tolerance:** moving the slider re-runs the last Remove Colour box in place (replaces that operation, no new undo step).

**Like the other box operations:** undoable, stored as an operation (box, samples, tolerance), replayed after Remake Mask, and Option-drag restore still works.

**Log:** `remove colour: N px changed, mean alpha removed x, samples k, tolerance y`.

## 4. Tests you can run yourself (synthetic, in `Tests/TraincullCoreTests`)
The real photos never enter the repo, so build these from my measured pixel values (7451 debug bundle, alpha 17):

**(a) Black sleeve.** Setup: a flat subject of (29,26,25) sRGB against white, with a 6-px edge of (26,31,29) (18,33,30) (0,32,28) (0,39,33) at alpha 255, then (19,44,36) at alpha 0.84 and (41,51,46) at 0.49. Pass: the subject's portion P/α of every edge pixel has Oklab chroma ≤ 0.012 (the sleeve's is 0.005; the teal is 0.04).

**(b) Skin.** Setup: skin (155,113,85) with edge pixels (107,107,91) at alpha 0.56, then (113,107,79) and (126,96,70) at alpha 255. Pass: P/α's Oklab (a, b) is within 0.015 of the skin's.

**(c) Waist.** Setup: skin (127,87,63) with an edge of (122,85,54) (117,84,47) (124,87,45). Pass: same test as (b).

**(d) Rim light kept.** Setup: skin with a 3-px edge band that is warm orange and 20% brighter than the skin. Pass: unchanged. Also: with a 20-px warm rim band, the outer pixels keep the rim's colour.

**(e) Hair zone.** No pixel changes in the hair zone where F̂ isn't skin.

**(f) Photo view.** Identical output with no adjustments.

**(g) No per-channel clipping.** No share vector written by §2 or §3 has one channel at 0 while another is above 0.1, except where I_c itself is 0.

**(h) Remove Colour.** Setup: a pink disc with an included 8-px orange crescent outside it on a green background, and orange sampled. Pass: the crescent is removed, the disc's radius changes by less than 1 px, and orange-ish pixels deeper than 40 px inside are untouched.

**(i) Rollback.** With both switches off, a fixture's output is byte-identical to alpha 16's.

Report each test's numbers in the build notes.

## 5. My acceptance check on real photos
All at 300%, in On Black and Background −3 EV.
- **7451:** no teal on the sleeve edges, no olive on the skin in the arm–waist gap. The yellow on the right waist may stay or go; either is fine.
- **6303:** no green along the fingers, cuff or sleeve, and no 4-px squares anywhere.
- **6957:** the Refine Edges box removes the finger slivers and the blurry hair in the gap, as in alpha 16.
- **6372:** with the orange wall sampled, a box around the rose removes the orange without eating petals or the hand.
- **7006, 7473:** hair unchanged from alpha 16.

## Not this round
- Everything from spec v6.
- The code-audit items: kept masks, saving local edits, sliders.
- Lens or defringe correction of the photo itself.
- Any hair-zone geometry change.
