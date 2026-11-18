> **Reverted (spec v7, alpha 19).** Everything below was built in alphas 17 and 18 and taken
> out again: the code went back to alpha 16 with git. Kept here as the record. See
> `docs/specs/masking-spec-v7.md` and `MASKING.md`, section 17.

# TrainCull Masking — Spec v6: Edge Colour, Smarter Box, Brushes, Hands, Hair Zone

**Status:** implementation spec for the next build. **Everything here ships in one build.** There are no phases. If anything can't be done, stop and ask the owner before deferring it.

**Builds on** alpha 15 (plus the follow-up build that fixed the overlay and added Show edits) and `MASKING.md`. Where this spec and `docs/specs/masking-spec-v5.md` disagree, **this spec wins**. Add it to `docs/specs/` and update `MASKING.md` when done.

**Guiding principle (owner's standing decision):** *least distracting to edit, not a perfect cut-out.* Clean, slightly conservative edges beat catching every strand. A tool must never make an area the base mask had right worse.

---

## 0. Where things stand (owner testing of alpha 15 on real photos)

- **The wide pale rim is gone.** Edge offset is +0.20 px on 6303 and +0.22 px on 7451. The re-centring works.
- **Refine Edges works well when the box is sized right.** It removed 6957's finger slivers and the out-of-focus hair in the arm–waist gap, and fixed the base result on 6957 in about 5 boxes.
- **Refine Hair is excellent on plain backgrounds** (7006). On 6303's fingers it gave the cleanest edge of any tool, and the alpha 14 dark seam is gone.
- **What is left:**
  1. A thin **green/teal line** at hard edges in Background −3 EV and On Black (§1).
  2. **Refine Edges re-decides whole areas**, so box size matters too much (§2).
  3. **Refine Hair adds flyaways** where the owner only wanted the edge tidied; **Clean Edge made 6303 worse** (§3).
  4. The owner keeps drawing boxes around **hands** (§4).
  5. The **hair zone is too big**, and becomes the whole outline when no face is found (§5).

---

## 1. Edge colour: the thin green/teal line (base mask, automatic)

**What the owner sees:**
- 6303: a thin green line along the fingers, the dark wrist cuff and the hand, and a **teal** line along the blue sleeve (blue + green bokeh).
- 7451: a green/teal line along the black sleeve and the waist in the arm–waist gap against the white wall.
- The line is invisible On White, worst On Black, and clear in Background −3 EV at 200–300%.
- In Photo view at 345%, 7451's sleeve shows a very faint green hairline: the lens's own fringe.

**Cause:** at edge pixels, light that belongs to the background (green bokeh on 6303, the lens's green fringe on 7451) is kept on the subject's side of the shares. When a pixel doesn't sit on the line between F̂ and B̂, `Matte.shares` lowers its trust and falls back to plain alpha (`return (plain, …)`), so a green pixel keeps about half its green when the background is darkened. The colour guard can't catch it, because the green exists in the photo.

### 1.1 Subject light bound (the main fix)

The subject can't give off light its own colour doesn't have.
- **Rule:** for every edge pixel with shares of its own, *and* for pixels that fall back to plain alpha in the band:
  `s_c ≤ min(1, (cover · F_c + τ_c) / I_c)` in linear light, per channel.
  - `F` is the edge-local subject colour (`fEdge`, else `fq`).
  - `cover` is the same coverage the guard's lightness bound uses (alpha, or the colour-implied coverage when larger and the colours are distinct).
  - `τ_c = 0.01 + 0.15 · F_c` (setting `lightBoundTolerance`) absorbs error in F̂.
- **The bound only lowers shares, never raises them.** Light it removes from the subject's side therefore follows the background.
- **Where it applies:**
  - every band pixel with alpha in (0.004, 1) within the inner tail's reach;
  - pixels that currently return early with plain shares;
  - only where F is trustworthy: an edge-local colour was measured (`known > 0`), or certain subject lies within ~10 px.
- **Where it does not apply:**
  - the hair zone of §5;
  - under Refine Hair strokes. Strands take their colour from the hair, and F̂ there is unreliable; leave as today.
- **Ordering:** the bound is final. The guard's lightness "raise" must not lift a share above it. Either run the bound after `guardColour`, or make the guard respect it.
- **Debug:** a new switch **Subject light bound** (default on).
- **Log:** `light bound: N pixels lowered, mean drop x`.
- **The photo itself is never changed.** With no adjustment and the Photo view, the output must be identical to today.

### 1.2 One colour space end to end (from the code audit)

The edge engine reads the neutral render's bytes, which are **Display P3**:
- `Imaging.pixels` renders to `displayP3`, and `Masking.photo(from:)` copies the bytes without converting them.
- The engine then treats those values as sRGB with a plain 2.2 gamma.
- `Oklab.from(linear:)` uses the sRGB matrix.

`Masking.apply` blends shares in Core Image's working space (linear sRGB by default). Per-channel shares computed in one basis and applied in another leave a tint at saturated edges.
- **Fix:** give the edge engine an sRGB copy of the neutral render: draw it into an sRGB `CGContext` in `photo(from:)`, or render the neutral in sRGB. The models' proxies are already drawn into sRGB.
- **Use the exact sRGB transfer curve** (a LUT) everywhere `pow(x, 2.2)` / `pow(x, 1/2.2)` is used now: `Matte.toLinear`, `Refine.toLinear`, `EdgePlace.colour`, `recentre`'s edge colours, and the debug bundle's `F.png`.
- **Confirm** the CIContext working space is linear sRGB.
- **Tag** the debug bundle's PNGs with their colour space.

### 1.3 No per-channel clipping in `Matte.shares` (from the code audit)

The doc comment says nothing is clipped channel by channel, but the code is `own = max(…, 0)` and `each = min(own / I, 1)`, both per channel.
- **Fix:** compute the share vector unclipped.
  - If any channel is above 1, scale the whole vector down by its maximum.
  - If any is below 0, blend towards the single `together` share by just enough to bring it to 0.
- Make the comment true.

### 1.4 Acceptance

Check each item in Background −3 EV and On Black at 300%, **using the base mask alone, with no tools**.
1. **6303:** no green line along the fingers, cuff or hand, and no teal line along the blue sleeve.
2. **7451:** no green/teal line along the sleeve or the waist in the arm–waist gap.
3. **No regression:**
   - 6957's hands and hair;
   - 7006's hair;
   - 7473's hair at the window;
   - all footwear;
   - colour-guard counts the same or lower.
4. **The Photo view with no adjustments is pixel-identical to before.**
5. **Report the light-bound counts for all eight photos.**

---

## 2. Refine Edges: refine the edge, don't re-decide the area

**What the owner sees:**
- A box that is **too tight around 6372's rose** drops the whole rose and leaves a visible rectangle.
- A box that is **too loose** cuts a hole in the palm.
- A well-sized box works.

**Cause:** `Refine.edges` replaces the mask inside the box with the model's kept answer (`keepTouching`). Nothing stops it deleting areas the base mask was confident about. With only 15% margin, a tight crop gives the model too little context to know the rose belongs to her.

### 2.1 More context for the model

- **Look area:** the box grown by the larger of:
  - 15% each side;
  - enough to make each side at least `max(1.0 × primary face height, 1024 photo px)`, clamped to the photo.
- One pass, or the existing tiling when it's large.
- The result is still applied **only inside the user's box**.

### 2.2 Limit what the box may change

Let `d` be the distance, in photo px, to the current mask's 0.5 contour, and let the **edge band** be `d ≤ max(1.5 × model pixel of this look, 6 px)`.

1. **Inside the edge band:** free, as today.
2. **Beyond the band, removals:** where the current mask is ≥ 0.5 and the model says < 0.5, take each connected region **R**. R may be removed only if one of these holds:
   - **R is out of focus.** Use the median blur of edge pixels **inside R**: R eroded by 3 px, using `SharpnessMap.sigma` at `edge` pixels only. That median must be ≥ the subject's sharpness + the Focus strictness allowance, with at least ~30 interior edge pixels (scaled with megapixels).
   - **R's focus can't be measured** (too few interior edge pixels) **and its colour says background.** Use the mean Oklab distance to the adjacent background colour and to the subject colour, with the thresholds `openGaps` uses: < 0.05 to background, > 0.2 from subject.
   - **R passes the existing `openGaps` test.**

   Otherwise R keeps its current values.
3. **Beyond the band, additions:** as today (`keepTouching`: attached pieces only).
4. **Never use `SharpnessMap.dense` to judge a region's focus.** It fills flat areas from the nearest measured edges, so a flat orange wall next to a sharp rose reads as sharp. Use edges inside the region, or "can't tell".
5. **Shift-drag** keeps today's behaviour: replace everything inside the box (still `keepTouching`). Mention it in the tool hint. Log `mode: replace`.
6. **Log per box:**
   - context size;
   - for each region R beyond the band: kept or removed, and why (out of focus / colour / gap / protected);
   - a `BOXSEAM?` warning if the mean change along the box border exceeds 0.15.

### 2.3 Acceptance

1. **6957, arm–waist gap:** one box still removes the out-of-focus hair.
2. **6957, hands:** a box still removes the dark slivers between the fingers.
3. **6372, tight box on the rose only:** the rose is kept, the orange wall behind it is removed, and no rectangle shows.
4. **6372, loose box over the rose and hand:** the palm is intact.
5. **Shift-drag** on the same loose box reproduces today's result.
6. **Footwear:** a box is never worse than the base.

---

## 3. Brushes

### 3.1 Refine Hair: Strength and Tightness

The matting model finds and keeps strands, so over loose flyaways it adds them (7006's left side). Add two sliders, as Clean Edge has:
- **Strength** (0–1, default 1): `α' = current + (matte − current) · strength`.
- **Tightness** (−1 to +1, default 0): a curve on the matte before it is laid in. Positive values raise the level below which alpha goes to 0 and steepen the rest, so faint flyaways drop out. Negative values do the opposite.

**Default settings must reproduce today's result exactly.**

**Acceptance:** on 7006's left hair edge, one stroke at Tightness ≈ +0.5 clears the grey haze without adding flyaways.

### 3.2 Edge Brush replaces Clean Edge in the tool menu

- **Clean Edge was the weakest tool in every test.** On 6303 it added a bright green sliver to the middle finger.
- **The matting model gave the best hard edges.**

The change:
- **Add an "Edge Brush":** the Refine Hair matting path for hard edges, with:
  - guards **not** relaxed;
  - the stroke **not** treated as hair zone, so the §1 light bound applies;
  - the matte laid in as Refine Hair does;
  - the same Strength and Tightness sliders.
- **Move Clean Edge under Debug.** Keep its code.
- **Tool menu:** Refine Edges (box), Refine Hair, Edge Brush. ⌥ restores the base, as for the others.

**Acceptance:** a stroke along 6303's middle finger gives a clean edge with no green sliver and no dark seam, and it's at least as good as Refine Hair there.

---

## 4. Automatic hand pass (part of Make Mask)

The owner drew four of five boxes on 6957 around hands or the waist gap.
- **When:** on Make Mask, for each wrist of the primary pose with confidence ≥ `poseConfidence`.
- **Where:** place a square of side `1.3 × primary face height`, centred `0.45 × face height` beyond the wrist along the elbow→wrist direction (or centred on the wrist if the elbow is unsure).
- **What:** run the §2 Refine Edges logic, with its limits, on that square.
- **Skip a hand when:**
  - the square holds no mask edge;
  - the wrist is out of focus by the Focus strictness rule;
  - the hand is mostly outside the frame.
- **It is part of the base mask, not a user operation.** It doesn't appear in Undo, the history, or Show edits, and it is replayed on Remake. ⌥ restore inside its square restores to the pre-hand-pass base.
- **Debug:** a switch **Automatic hands** (default on).
- **Log:** each hand's square, whether it ran or was skipped and why, pixels changed, and time.
- **Budget:** ≤ 1.2 s warm per hand.

**Acceptance:**
1. **6957:** both hands lose their dark slivers with no user boxes.
2. **6303:** the peace-sign hand is no worse, and better if anything.
3. **No regression elsewhere.**
4. **Report the time added to Make Mask** on all eight photos.

---

## 5. Hair zone: fit it to the hair

**Today** (`Matte.prepare`): the zone is a box of 2.6 face widths × 3 face heights around each face, minus the face oval.
- Inside it there's no colour snap, no re-centring and no inner tail, and the offset metric skips it.
- **With no face, the whole outline is treated as hair** and gets no edge clean-up anywhere.
- On 6303 the Zones view shows the zone's left border cutting through the peace sign's middle finger and top of the hand (in its fade-in strip) and covering the top of the left puffed sleeve. That weakens the clean-up there, so it's a contributing factor, not the main one.

**Changes:**
1. **Tighten the head box** to 2.0 face widths × 2.4 face heights (settings `hairBoxWidth`, `hairBoxHeight`), centred as now.
2. **Body is never hair.** Subtract `BodyPose.confirmed` for the primary pose (limbs and joints, radius ≈ 0.25 × face height) from the hair zone. Hands, forearms and shoulders near the face get normal edge clean-up.
3. **No face found:**
   - place the head box from the pose head (nose, else neck), sized from shoulder width (head width ≈ 0.45 × shoulder width);
   - if there is no pose head either, use **no hair zone**: a plain edge everywhere, not "all hair".
   - Refine Hair handles hair by hand.
4. **Long hair below the box** stays as today: a plain edge. No change.
5. **The Zones view outlines the hair zone** so the owner can check it.

**Acceptance:**
1. **6303:** in the Zones view, the peace-sign hand and both sleeves are fully outside the hair zone.
2. **7473:** the window-side hair is unchanged ("near perfect" must stay so).
3. **6372, 6465, 6957:** hair is not visibly worse.
4. **A no-face case gets edge clean-up.** Use a synthetic test, plus one test photo with face detection forced off via a Debug switch **Ignore faces**.

---

## 6. For every item

- **Debug switches** for each new behaviour: Subject light bound, Automatic hands, Ignore faces. Clean Edge moves under Debug.
- **Synthetic unit tests** in `Tests/TraincullCoreTests`:
  - the light bound: a black subject against white with a green fringe pixel loses its green;
  - no per-channel clipping (the hue of the shares is preserved);
  - region focus judged from interior edges, giving "can't tell" on a flat region beside a sharp edge;
  - box limits: an interior in-focus region is protected and an out-of-focus one removed;
  - hair zone geometry, including no face.
- **Before/after crops** (Background −3 EV and On Black, 300%) for every acceptance item, from the owner's photos when available. State clearly which crops are stand-ins.
- **Update `MASKING.md`:** the pipeline, the new settings, the metrics, the known issues, and anything not done.
- **Not this round:**
  - the history panel, edit stack and reorder mode (MASKING.md §16 b, d, e);
  - automatic defringe of the photo itself (still declined);
  - compressing the matting model.
