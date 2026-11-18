# Masking spec v7.2: closing build for the masking chapter

This is the complete v7.2 spec. It supersedes any earlier v7.2 text and additions.

**One build, no phases.** If anything can't be done, stop and ask me before deferring it. Add this as `docs/specs/masking-spec-v7.2.md` and update `MASKING.md`. Everything not mentioned here stays exactly as in alpha 21.

**Context:** alpha 21 is the best so far. The default masks on 7451 and 6303 are the strongest we've had, the repaint removed the dark outline, and the Refine Edges box is right. This build finishes the edge work and settles the tool set. After it, masking is closed and the next chapter starts (saving tool work and local edits).

**Names:** "the edge rule", F̂, "the band", "the rim skip", w and C are as in v7.1. B̂ is new (§1).

## 1. Background colour B̂ (new, used by §2 and §3)
- Solid background: alpha ≤ 0.02 and at least 6 photo px outside the 0.5 contour.
- B̂ = its colour from the neutral render, in linear light, with a 3×3 median, pushed inward to cover the band and 4 px outside the contour (nearest-solid fill, as for F̂).
- Where no solid background lies within 30 px, B̂ is unknown, and §2 and §3 leave the pixel alone.

## 2. Automatic: cut edge pixels that clearly match the background
**What I see:**
- 6303 default mask: pale green streaks on the finger edges (index fingertip, both sides of the middle finger).
- 6372: orange specks next to the rose.
- 7451: a bright white/pink cluster at the fold notch.

They survive because the rim skip only checks brightness.

**Rule.** Applies to band pixels with alpha > 0.02 that are within 6 photo px inside the 0.5 contour or anywhere in the soft edge outside it, where F̂ and B̂ are both known. Compare in Oklab (a, b) only, ignoring lightness:
- dS = distance from the pixel's (a, b) to F̂'s;
- dB = distance to B̂'s.

The pixel is **background-like** if dS ≥ 0.04 **and** dB ≤ 0.5 · dS. For background-like pixels:
- **Cut it:** target alpha 0, with a soft weight — full at dB ≤ 0.25·dS, fading (smoothstep) to none at dB = 0.5·dS. Feather the alpha change 1.5 px, never weakening the raw change (max of the two).
- **No rim protection:** background-like pixels are never rim-skipped.
- **Where it doesn't run:** under Refine Hair strokes, or in the hair zone except where F̂ is skin.
- **Notch case:** where (a, b) can't separate subject and background (F̂ and B̂ themselves less than 0.04 apart in (a, b)), a bright pixel within 0.03 of B̂ in full Oklab (L, a, b) is background showing through: no rim protection, and it joins the repaint core.

**Rim protection** (replaces the brightness-only skip and v7.1's 40 px group rule): a bright edge pixel is protected as rim light only if it is **not** background-like and not within 0.03 of B̂ in full Oklab.

**Switch:** Debug "Cut background-coloured edge pixels", default on.

**Log:** pixels cut, mean alpha removed, rim-protected pixels.

**Runs** at the end of the base mask and inside every box operation (box plus 4 px margin), before §3's repaint is computed.

## 3. Background-side repaint (mirror of v7.1 §1)
**What I see on 7451, with Subject +3 and Background −3 at 138%:**
- A thin dark green line just outside the sleeve, down the left side of the arm–waist gap.
- A faint yellow-orange outline at the right gap.

The lens fringe spreads over both sides of the edge. v7.1 repainted the subject side, but the background-side fringe is darker than the wall around it, so darkening the background leaves a line.

**Fix:** a background clean image Cb = mix(photo, B̂, wb).
- **Core:** wb = 1 on pixels with alpha < 0.5 within 3 photo px outside the 0.5 contour, where B̂ is known; not in the hair zone (except skin edges) and not under Refine Hair strokes.
- **Feather:** as in v7.1 §1.1. Smoothstep to 0 over 2 px each side, then a 1.5 px blur. Final wb = max(blurred, core).
- **Render:** the background side uses Cb where wb > 0: single blend = mix(background-adjusted Cb, subject-adjusted C, shares). Weight it against alpha 16's sequential path by max(w, wb) instead of w. Where both are 0, the result is alpha 16's path, as before.
- No local edits: unchanged, the mask is not used.
- The edge rule switch off: wb = 0.

## 4. Remove Colour box: box first, automatic guess, eyedropper override

**What I see:**
- 6303: a jagged, stepped edge and tiny green bits.
- 6372: the enclosed patch and most of the wall are gone, but a jagged bright orange outline is left round where they were and along the rose's right side.

**New order:** select Remove Colour and drag a box straight away. No sample is needed first.

### 4.1 Automatic mode (no eyedropper picks)
1. **Outside palette:** pixels in the box with alpha ≤ 0.02. Cluster them into up to 4 colours (k-means in Oklab, on the neutral render).
2. **Inside palette:** pixels in the box with alpha ≥ 0.98. Cluster them the same way, with each cluster's share of the inside pixels.
3. **An outside colour is removable** when either:
   - it's at least 2× tolerance (Oklab) from every inside cluster; or
   - the inside pixels within tolerance of it make up less than 15% of the inside pixels.

   The second test catches a wrongly included patch, like the orange above the rose, which sits inside the mask and would otherwise count as subject colour.
4. The removable colours become the samples, and the removal (§4.3) runs with them.
5. If no outside colour qualifies, change nothing and say so in the status line: "No clear background colour in the box — click one with the eyedropper."
6. The guessed colours appear as swatches marked "auto", next to the tolerance slider.

### 4.2 Eyedropper = manual override
- **A click** replaces the automatic guess and re-runs the last box in place (one operation, no new undo step).
- **Shift-click** adds a colour and re-runs.
- **Clear** returns to the automatic guess.
- **With picked colours, skip every automatic judgement inside the box:**
  - no inside/outside palette or share checks;
  - no 40 px reach;
  - no rim protection;
  - no hole refilling for matched pixels.
- Any pixel in the box within tolerance of a picked colour is removed, wherever it is in the mask. Only the box and the tolerance slider limit it. Undo and Option-drag are the safety net.

### 4.3 Removal (both modes)
- **Soft tolerance:** d = Oklab distance to the nearest sample. Weight w_s = 1 for d ≤ tolerance, falling smoothly (smoothstep) to 0 at 2× tolerance. New alpha α′ = min(α, 1 − w_s).
- **Partly matching pixels:** pixels on the line between F̂ and a sample (v7 §3's t, with F̂ taken only from inside pixels not within 2× tolerance of any sample) get α′ = min(α, 1 − w_s·t).
  - In automatic mode, these are processed within 40 px of the mask outline, or within 3 px of a removed pixel.
  - In eyedropper mode, they are processed anywhere in the box.
- **Anti-alias:** compute the alpha change per photo pixel, at full resolution, then write it into the half-size mask by area-averaging (2×2), not point sampling. First confirm in a test that the steps are 2 photo px (one mask pixel). If they aren't, tell me what you find before changing anything.
- **Feather:** blur the alpha change 1.5 photo px, never weakening the raw change (max of the two).
- **Clean-up:** remove loose pieces under 50 px. In automatic mode, fill holes under 50 px except where pixels matched a sample. In eyedropper mode, never refill.
- **Afterwards:** §2 runs inside the box, which cleans up any leftover background-coloured bits. Then w, C, wb and Cb are recomputed in the box plus a 4 px margin.

### 4.4 Stored operation, live slider, log
- **Stored:** the box, the samples actually used and whether they were automatic, and the tolerance, so Remake replays it exactly.
- **The tolerance slider** re-runs the last box live (replaces that operation).
- **Log:** outside and inside clusters with their shares, which were chosen and why (distance or share), manual or automatic, and pixels changed.

## 5. New tool: Edge Colour box
- In the tool menu as **"Edge Colour"**. Drag a box: inside it, the rim skip is switched off. Every band pixel with a known F̂ joins the repaint core (v7.1 §1), and §2's cut runs with rim protection off.
- Option-drag restores the automatic result inside the box.
- Undoable, stored and replayed like the other box operations.
- Log: pixels repainted and cut.

## 6. Refine Hair: Strength slider and prewarm
**What I see on 7006:** strokes on the left side added flyaways when I only wanted the edge tidied.

**Slider "Strength", 0 to 1, default 0 ("tidy only").**
- Let Δ = model alpha − current alpha.
- Decreases (Δ < 0) are always applied in full.
- Increases are scaled: within 2 photo px of the existing 0.5 contour, apply them in full. Further out, apply strength × Δ.
- At 0, the stroke can tidy and fill the existing edge but never adds strands beyond it. At 1, it behaves as today.
- The slider re-applies the last stroke live.

**Prewarm:** load the matting model when Refine Hair is selected (and after Make Mask in Edit mode), so the first stroke doesn't wait 7–8 s.

## 7. Remove Clean Edge
Remove it from the tool menu, the Debug section and the code. Keep any shared helpers other tools use.

## 8. Tests (synthetic; report numbers in the build notes)
Keep all existing tests. Add:

**(p) Green streak.**
- Setup: skin with a 3-px pale green streak (lighter than the skin) along a 60 px stretch of edge, against green bokeh.
- Pass: the streak reaches alpha ≤ 0.05, and the skin edge 4 px away changes by ≤ 0.02 alpha.

**(q) Same-colour safety.**
- A black sleeve on a dark background: §2 cuts nothing.
- A green subject on green foliage: §2 cuts nothing.

**(r) Real rim kept.** A 3-px warm rim, brighter than the skin, along 300 px of edge against a neutral grey background is protected and keeps its colour.

**(s) Background-side line.** Test (a)'s sleeve against white with a 2-px teal fringe on the background side, Subject +3 / Background −3: no pixel within 3 px outside the edge is more than 0.03 Oklab L darker than the darkened wall 6 px out.

**(t) Anti-aliasing.** A Remove Colour box on a diagonal edge: alpha along the edge changes by ≤ 0.3 between neighbouring photo pixels.

**(u) Hair strength.** At strength 0, a stroke on a hair edge adds no alpha more than 2 px outside the previous 0.5 contour. At 1, it matches today's output.

**(w) Automatic guess, enclosed patch.**
- Setup: test (m)'s pink disc with the enclosed orange patch and specks, plus orange outside the mask in the box; no eyedropper.
- Pass: the patch and specks reach alpha ≤ 0.05, and the pink changes by ≤ 0.02 alpha more than 2 px from the patch.

**(x) Automatic guess, green fringe.** Skin with a green fringe against green bokeh, no eyedropper: the green is removed and the skin edge moves by less than 1 px.

**(y) Automatic guess, nothing clear.** A box where the outside colour also makes up more than 15% of the inside and is within tolerance of it: nothing is removed, and the status message appears.

**(z) Eyedropper override.** A picked colour that makes up 40% of the inside of the box is still removed everywhere in the box.

**(v) Invariants.**
- No local edits: pixel-identical to the photo.
- Edge switch off: byte-identical to alpha 16.
- Pixels with w = wb = 0 match alpha 16's path within 1/255.

## 9. My acceptance check (fit size, plus 300% where noted)
- **7451, Subject +3 / Background −3:** no dark green line outside the gap, no notch cluster, no yellow outline (300%).
- **6303 default:** no green streaks on the fingers (300%). One Remove Colour box over the fingers, no eyedropper, gives a smooth edge with no green bits.
- **6372 default:** fewer orange specks by the rose without any box. One Remove Colour box over the rose, no eyedropper, removes the enclosed patch and leaves no orange outline. If it guesses wrong, the eyedropper fixes it.
- **7006:** Refine Hair at strength 0 tidies the left side without adding flyaways. The first stroke is instant.
- **6957:** Refine Edges box unchanged.
- **7006, 7473:** default hair unchanged.
- Clean Edge is gone; Edge Colour is in the menu.

## Not this round
- Saving tool work and local edits, masks dropped after two photos, exports leaving out local edits. That's the next chapter, first item.
- Code-audit items.
- Photo-level defringe.

---

## Owner's answers before the build

1. **§4.3 anti-aliasing.** The test found the mask is at full photo resolution (only BiRefNet's first guess is half-size) and the Remove Colour steps were 1 photo px, not 2: a pixel part subject, part sampled colour was still within tolerance, so it was cut fully, and "the blur never weakens the raw change" kept that hard border. **Decision: cut by mix.** Every pixel's cut follows how much of the sampled colour it holds, α′ = min(α, 1 − w_s·t), with t = 1 only for the pure sample colour and fractional for mixed pixels on the F̂–sample line; then the 1.5 px feather. No area-averaging (there is no half-size mask). Test (t) checks it.
2. **§2 rim rule.** v7.1's "rim-skipped groups under 40 px are specks" rule is kept alongside §2's: a bright pixel is rim-protected only if it is not background-like, not within 0.03 of B̂, and in a group of 40 px or more. (Replacing it outright would fail existing test (l).)
