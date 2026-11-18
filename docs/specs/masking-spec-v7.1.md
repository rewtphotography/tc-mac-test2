# Masking spec v7.1: calibration fixes from alpha 19 testing

This is the complete v7.1 spec. It replaces the separate "Addition to §1" note, which is now built in here.

**One build, no phases.** If anything can't be done, stop and ask me before deferring it. Add this as `docs/specs/masking-spec-v7.1.md` and update `MASKING.md`. Everything not mentioned here stays exactly as in the current build.

**Names used below:** "The edge rule" = v7 §2, Edge colour from inside (the Debug switch of that name). F̂ = its inside colour. The band = its edge band. The rim skip = its rim-light skip, including your two confirmed changes: threshold 0.05, and half-covered pixels judged by their nearest fully covered neighbour.

## Where things stand (my testing of alpha 19)

- The rollback worked. The 6957 box is back to its alpha 16 behaviour, and the 6303 default peace sign is the cleanest it has ever been. Don't touch the box or the base mask pipeline.
- What's left: 1. A dark outline at recoloured edges when subject and background are edited differently (§1). 2. Leftover specks (§2). 3. Remove Colour can't reach enclosed patches and puts small specks back (§3). 4. Remove Colour leaves hard steps (§4).

## 1. Repaint the edge with the subject's colour (replaces the edge rule's share recolouring)

What I see: 7451, Subject +3 EV with Background −3 EV: a black 1–2 px line runs along the sleeve edge. It's faint but visible with Subject at 0. 6303, Subject +1.57 EV: a dark reddish hairline runs round the fingers, on the default mask and after Remove Colour.

Cause: the edge rule's k factor. Where a photo pixel has almost none of a channel the subject needs (the teal pixels have red = 0), k drops towards 0 and the whole pixel follows the background's edit, even at alpha 1. Shares can only split the photo's own light, so the choice was always teal or background, and background shows as a dark line.

Decision (mine, confirmed): at those edge pixels, the subject side of the render uses the subject's own colour instead of the photo's fringe colour, feathered so there's no seam. This is a deliberate, limited repaint. It only affects the subject side of the blend, and only when local edits are in use.

### 1.1 The repaint weight w

- Core: w = 1 on every band pixel the edge rule recolours today, i.e. not rim-skipped (after §2's change), not lacking an inside colour, not in the hair zone (except where F̂ is skin), and not under a Refine Hair stroke.
- Feather: around the core, w fades smoothly (smoothstep) from 1 to 0 over 2 photo px on both sides: inward into the solid subject, and outward to the end of the soft edge. Blur this feathered w with a 1.5 photo px radius.
- The feather never weakens the core: final w = max(blurred w, core). The fringe is only 1–2 px wide, and a blur that lowered w there would bring the fringe colour back.
- Excluded pixels (rim-skipped, no inside colour, hair zone, Refine Hair strokes) get w only from a neighbouring core's feather, never a core value of their own.

### 1.2 The clean colour image C

- C = mix(photo, F̂, w), per pixel, in linear light. Where w = 0, C is exactly the photo.
- Store C (or just w plus the F̂ field) with the mask, so tool operations and Remake replay it like the rest of the mask.
- After a Refine Edges box or Remove Colour box, recompute w and C inside that box (plus a 4 px margin) from the new alpha.

### 1.3 Shares

- Where w > 0, shares = alpha, the same value in every channel. Remove the k factor and the per-channel share recolouring from the edge rule entirely. Where w = 0, shares are exactly as today.

### 1.4 Where C is used (your questions)

- Subject side only. The render is out = mix(background-adjusted photo, subject-adjusted C, shares). The background side always uses the unmodified photo. C does not replace the photo before adjustments in general. It's only the input to the subject's adjustments.
- Photo view with local edits: yes. That is the edited image, and it uses the same `Masking.apply` path.
- Photo view with no local edits: unchanged. The mask isn't used, so the render is pixel-identical to the photo.
- TIFF export and Send to Photoshop: yes, same path, so the export matches what's on screen.
- On White, On Black and Background −3 EV views: use C on the subject side too, so they show what an edit will show.
- The Skin target keeps using the photo (no change).
- The "Edge colour from inside" switch off: w = 0 everywhere, so the build is byte-identical to alpha 16.

Accepted trade-offs (note in MASKING.md): On a patterned or stitched edge, the outer few pixels take the colour from just inside, so they can look slightly smoothed when local edits are on. Where the subject changes colour right at its edge (sleeve meeting skin), a pixel or two can take the neighbouring colour.

## 2. Specks: rim protection only for real rims

What I see: 7451: a few single teal pixels on the sleeve edge, and a bright white/pink cluster at the notch where the sleeve folds meet. 6303: bright green specks where the thumb meets the folded finger. 6372: bright orange specks next to the rose. All are brighter than the subject beside them, so the rim skip keeps them.

Fix: A real rim light runs along the outline. Measure each connected group of rim-skipped pixels (8-connected, photo px). If it's smaller than 40 photo px, don't skip it: it joins the core of §1.1. Longer runs stay protected. Inside colour unknown (no solid subject within 30 px): search up to 60 px before giving up. Log: small rim groups un-skipped (count and pixels), pixels left with no inside colour, and core / feathered pixel counts for w.

## 3. Remove Colour: reach enclosed patches, stop putting specks back

What I see on 6372: I sampled the orange patch above the rose directly. At every tolerance it stayed fully subject, and the orange specks next to the rose stayed too.

Causes (all from my v7 spec): the 40-px reach; at an enclosed patch the inside colour is the patch itself, so F̂ = B and nothing is removed; the clean-up refills holes under 50 px; the rim skip protects bright orange next to dark petals.

Fixes:
1. A pixel that matches a sample (weight w_s > 0 in §4) is removed anywhere inside the box. The 40-px reach still applies to partly matching pixels on the line between F̂ and B.
2. For Remove Colour, compute F̂ only from solid subject pixels that are not within 2× tolerance of any sample, and push it outward over the matched areas.
3. The hole-filling clean-up never refills a pixel that matched a sample. Removing loose pieces under 50 px stays.
4. Pixels that match a sample get no rim protection.

## 4. Remove Colour: soft tolerance instead of on/off

What I see on 6303 at 200–300%: stair-steps along the edge after a Remove Colour box. Neighbouring pixels fall just inside or just outside the tolerance.

Fix: let d be the Oklab distance to the nearest sample (or to the F̂–B segment for partial pixels). Sample weight w_s = 1 for d ≤ tolerance, falling smoothly (smoothstep) to 0 at 2 × tolerance. New alpha: α′ = min(α, 1 − w_s·t), where t = 1 for a direct match. Keep the 1.5 px feather on the alpha change. The slider still re-runs the last box live.

## 5. Tests (synthetic, in `Tests/TraincullCoreTests`; report numbers in the build notes)

Keep all v7 tests, adjusted for the removal of k. Replace (g) with (n). Add:

(j) Black sleeve, rendered. Setup: test (a)'s sleeve (29,26,25) and teal edge, through the real `Masking.apply` blend with Subject +3 EV and Background −3 EV. Pass: every pixel the edge rule recolours has w = 1; no edge pixel at alpha ≥ 0.9 is more than 0.03 Oklab L darker than the brightened sleeve 6 px inside; every edge pixel's subject side has chroma ≤ 0.012; across the repainted band's inner and outer limits, no step between neighbouring pixels is larger than 0.03 Oklab L or 0.015 in (a, b). Also with Subject 0 and Background −3: chroma ≤ 0.012 at alpha ≥ 0.9.

(k) Strong green on skin, rendered. Setup: skin with a (88,118,70) fringe at alpha 1, Subject +1.5 EV. Pass: the fringe pixel renders within 0.03 Oklab L of the brightened skin and within 0.015 in (a, b).

(l) Specks versus rim. An isolated bright green 3×3 speck at a skin edge gets w = 1 and is repainted. A 3-px-wide warm rim running 300 px along the edge keeps w = 0 and its colour.

(m) Enclosed patch. Setup: a pink disc containing a 40×20 px orange patch, fully enclosed and more than 40 px from the outline, plus orange 3×3 specks touching the pink, with orange sampled. Pass: patch and specks reach alpha ≤ 0.05; the pink changes by ≤ 0.02 alpha anywhere more than 2 px from the patch.

(n) Soft tolerance. Along an edge with a smooth colour gradient across the tolerance limit, alpha changes by ≤ 0.25 between neighbouring pixels.

(o) Invariants. No local edits: the render is pixel-identical to the photo. Edge switch off: byte-identical to alpha 16. The background side of the blend never reads C.

## 6. My acceptance check (all at 300%)

7451: Subject +3 and Background −3 show no dark line, no teal and no visible seam on the sleeve edge; no specks; no bright cluster at the notch. 6303: default mask with Subject +1.5 shows no dark hairline round the fingers. A Remove Colour box shows no stair-steps and no green specks in the thumb corner. 6372: the same box I drew before, with orange sampled, removes the enclosed patch and the specks next to the rose. Petal loss is controllable with the slider. 6957: box unchanged. 7006, 7473: hair unchanged.

## Not this round

Everything else, including the code-audit items and any photo-level defringe.

---

## Owner's answers to the four build defaults (before the build)

1. **Accepted.** A protected rim run (40 px or more) gets w = 0 with no feather into it. Everything else is feathered as written.
2. **Accepted.** Check the subject side's chroma before the subject's exposure, and report the brightened figures alongside. The thing to show is that the edge matches the sleeve: report the edge's brightened chroma next to the brightened sleeve's own.
3. **Accepted.** The blurred alpha change never weakens the raw change (max of the two), as in §1.1.
4. **Changed.** Don't switch the whole render to the single blend when the switch is on. Alpha 16's sequential path (subject edit, then background edit on top) and the single blend differ wherever shares are fractional, so that default would change how hair and every soft edge look under edits. Use the single blend only where the repaint is, weighted by w:

   out = mix(alpha16_result, single_blend, w)

   Where w = 0, the result is alpha 16's path exactly, even with the switch on. Where w = 1 (the repaint core), it's the single blend. The feather gives a smooth transition between them.

   Add to (o): with the switch on, every pixel with w = 0 renders identically to alpha 16 under any subject and background edits. Test with Subject +3 / Background −3 on a soft hair-like edge.

### Owner's decision after the first Mac build (rounding)

The check above fails only by Core Image's rounding: on the soft hair edge, 260 of 6,300 pixels with w = 0 differ from alpha 16's render by 1/255, and none differ when Core Image keeps its in-between pictures at full precision. **Accepted:** at w = 0 the render matches alpha 16 to at most 1/255; renders stay at the usual precision, so with the switch off the render is alpha 16's byte for byte.
