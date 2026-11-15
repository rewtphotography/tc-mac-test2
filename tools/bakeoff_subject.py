"""Subject-selection bake-off (docs/specs/masking-spec-v2.md, sections 2, 4, 5 and 6).

Compares ways of making the first-pass subject mask on TrainCull debug bundles:
  V   the app's current Vision mask (current_m0.png in each bundle)
  A   BiRefNet_HR: whole proxy, then again on the subject's box, kept by sharpness
  B   SAM 2.1 given a box and two points the app works out from the face
  B2  B, plus a second SAM pass on the high-resolution box crop
  C   hybrid: SAM says which subject, BiRefNet gives the shape

Usage, from a Python environment with torch, transformers, sam2, scipy and pillow:
  bakeoff_subject.py models <bundles> <work>     run the networks once and keep what they return
  bakeoff_subject.py report <bundles> <work>     apply the selection rules, score, draw the sheets

The reference in each bundle is ps_mask-*.jpg (Photoshop's Select Subject) or gt_subject.png.
Photos and results stay outside the repository.
"""
import glob
import json
import os
import sys
import time

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

CONFIG = {
    "reblur": 1.0, "sigma_max": 8.0, "edge_floor": 0.02, "edge_cap": 0.04,
    "box_side": 2.0, "box_above": 0.8, "box_below": 6.5, "box_expand": 0.10,
    "feather": 24, "speckle": 0.0002, "hole": 0.0001,
    "attach_distance": 0.01, "sharp_ratio": 1.6, "sharp_plus": 0.8, "unmeasured_area": 0.02,
    "hybrid_overlap": 0.3, "hybrid_dilate": 0.005, "low_iou": 0.85,
}
EIGHT = np.ones((3, 3), bool)


# ---- section 4: sharpness -------------------------------------------------------------

def sharpness(rgb):
    """Blur width at each edge pixel (small = sharp) and the edge mask."""
    y = (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]).astype(np.float32) / 255
    yb = ndi.gaussian_filter(y, CONFIG["reblur"], truncate=3.0, mode="nearest")
    def grad(a):
        return ndi.sobel(a, 1, mode="nearest") / 8, ndi.sobel(a, 0, mode="nearest") / 8
    gx, gy = grad(y)
    bx, by = grad(yb)
    g, gb = np.hypot(gx, gy), np.hypot(bx, by)
    t = min(max(np.percentile(g[::2, ::2], 85), CONFIG["edge_floor"]), CONFIG["edge_cap"])
    # Keep the crest of each edge: steeper than both neighbours along the slope.
    ang = (np.round(np.arctan2(gy, gx) / (np.pi / 4)) % 4).astype(int)
    e = np.zeros(g.shape, bool)
    for k, (dy, dx) in enumerate([(0, 1), (1, 1), (1, 0), (1, -1)]):
        a = np.roll(g, (-dy, -dx), (0, 1))
        b = np.roll(g, (dy, dx), (0, 1))
        e |= (ang == k) & (g >= a) & (g >= b)
    e &= g > t
    r = g / np.maximum(gb, 1e-6)
    sigma = np.where(r > 1.01, CONFIG["reblur"] / np.sqrt(np.maximum(r * r - 1, 1e-6)), CONFIG["sigma_max"])
    return np.clip(sigma, 0, CONFIG["sigma_max"]).astype(np.float32), e


def median_sharp(sigma, edges, where, least=50):
    v = sigma[edges & where]
    return float(np.median(v)) if v.size >= least else None


def face_sharp(sigma, edges, face):
    x, y, w, h = face
    band = np.zeros(sigma.shape, bool)
    band[y + h // 4: y + h // 4 + max(h * 3 // 10, 1), x: x + w] = True
    return median_sharp(sigma, edges, band)


def edge_sharp(sigma, edges, region):
    rim = region & ~ndi.binary_erosion(region, EIGHT, iterations=4)
    return median_sharp(sigma, edges, rim)


# ---- section 5: what the app works out from the face ------------------------------------

def body_box(face, W, H):
    x, y, w, h = face
    cx = x + w / 2
    x0, x1 = cx - CONFIG["box_side"] * w, cx + CONFIG["box_side"] * w
    y0, y1 = y - CONFIG["box_above"] * h, y + h + CONFIG["box_below"] * h
    return clamp_box((x0, y0, x1, y1), W, H)


def roomy_box(face, W, H):
    """A more generous box, tried because the one above cuts off raised hands and, on
    full-length shots, the feet: three widths either side, ten heights below the chin."""
    x, y, w, h = face
    cx = x + w / 2
    return clamp_box((cx - 3.0 * w, y - 1.0 * h, cx + 3.0 * w, y + h + 10.0 * h), W, H)


def clamp_box(b, W, H):
    return (int(max(np.floor(b[0]), 0)), int(max(np.floor(b[1]), 0)), int(min(np.ceil(b[2]), W)), int(min(np.ceil(b[3]), H)))


def union(a, b):
    return (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))


def expand(b, W, H):
    dx, dy = (b[2] - b[0]) * CONFIG["box_expand"], (b[3] - b[1]) * CONFIG["box_expand"]
    return clamp_box((b[0] - dx, b[1] - dy, b[2] + dx, b[3] + dy), W, H)


def bbox(mask):
    ys, xs = np.nonzero(mask)
    return (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1) if xs.size else None


def face_points(face):
    x, y, w, h = face
    centre = (x + w / 2, y + h / 2)
    return centre, (centre[0], centre[1] + 2.0 * h)


# ---- section 6: selection rules -------------------------------------------------------

def tidy(mask):
    """Drop specks and fill pinholes."""
    n = mask.size
    lab, count = ndi.label(mask, EIGHT)
    if count:
        areas = ndi.sum(mask, lab, range(1, count + 1))
        mask = np.isin(lab, [i + 1 for i, a in enumerate(areas) if a >= CONFIG["speckle"] * n])
    holes, count = ndi.label(~mask)
    if count:
        areas = ndi.sum(~mask, holes, range(1, count + 1))
        border = set(np.unique(np.concatenate([holes[0], holes[-1], holes[:, 0], holes[:, -1]])))
        fill = [i + 1 for i, a in enumerate(areas) if a < CONFIG["hole"] * n and (i + 1) not in border]
        mask = mask | np.isin(holes, fill)
    return mask


def keep(soft, sigma, edges, face, extra_ok=None, must_keep=None):
    """Section 6.1 steps 4-6: the component with the face, plus what is attached and as sharp.
    extra_ok(component) can veto an attached component; must_keep(component) can force one in."""
    H, W = soft.shape
    hard = soft >= 0.5
    lab, count = ndi.label(hard, EIGHT)
    info = {"components": int(count), "kept": [], "dropped": {}}
    if count == 0:
        return np.zeros_like(soft), info
    cx, cy = face_points(face)[0]
    primary = lab[int(min(cy, H - 1)), int(min(cx, W - 1))]
    if primary == 0:
        x, y, w, h = face
        inside = lab[y:y + h, x:x + w]
        ids, counts = np.unique(inside[inside > 0], return_counts=True)
        primary = int(ids[np.argmax(counts)]) if ids.size else int(np.argmax(ndi.sum(hard, lab, range(1, count + 1))) + 1)
    sp = edge_sharp(sigma, edges, lab == primary) or face_sharp(sigma, edges, face) or 1.0
    info["sigmaP"] = round(sp, 2)
    limit = max(CONFIG["sharp_ratio"] * sp, sp + CONFIG["sharp_plus"])
    areas = ndi.sum(hard, lab, range(1, count + 1))
    kept = {int(primary)}
    info["kept"].append("primary")
    if must_keep:
        for i in range(1, count + 1):
            if i not in kept and must_keep(lab == i):
                kept.add(i); info["kept"].append("overlap")
    reach = CONFIG["attach_distance"] * max(W, H)
    why = {}
    for _ in range(3):
        dist = ndi.distance_transform_edt(~np.isin(lab, list(kept)))
        near = ndi.minimum(dist, lab, range(1, count + 1))
        added = False
        for i in range(1, count + 1):
            if i in kept:
                continue
            if areas[i - 1] < CONFIG["speckle"] * W * H:
                why[i] = "speckle"; continue
            if near[i - 1] > reach:
                why[i] = "disconnected"; continue
            comp = lab == i
            if extra_ok and not extra_ok(comp):
                why[i] = "other person"; continue
            s = edge_sharp(sigma, edges, comp)
            if (s is not None and s <= limit) or (s is None and areas[i - 1] < CONFIG["unmeasured_area"] * W * H):
                kept.add(i); info["kept"].append("attached"); added = True; why.pop(i, None)
            else:
                why[i] = "defocused"
        if not added:
            break
    for v in why.values():
        info["dropped"][v] = info["dropped"].get(v, 0) + 1
    keep_mask = tidy(np.isin(lab, list(kept)))
    out = np.where(ndi.binary_dilation(keep_mask, EIGHT, iterations=6) & ~(hard & ~keep_mask), soft, 0)
    return np.maximum(out, keep_mask * 0.51).astype(np.float32) * (out > 0), info


def feather_in(box, shape):
    """1 inside a box, fading to 0 over the outer `feather` pixels."""
    w = np.zeros(shape, np.float32)
    x0, y0, x1, y1 = box
    yy, xx = np.mgrid[y0:y1, x0:x1]
    d = np.minimum(np.minimum(xx - x0, x1 - 1 - xx), np.minimum(yy - y0, y1 - 1 - yy))
    w[y0:y1, x0:x1] = np.clip(d / CONFIG["feather"], 0, 1)
    return w


# ---- the networks ---------------------------------------------------------------------

def load_birefnet():
    import torch
    from transformers import AutoModelForImageSegmentation
    model = AutoModelForImageSegmentation.from_pretrained("ZhengPeng7/BiRefNet_HR", trust_remote_code=True)
    return model.eval().float()


def birefnet(model, image, size=2048):
    """A soft mask the size of `image` (a PIL RGB picture), squashed to a square as the reference code does."""
    import torch
    x = np.asarray(image.resize((size, size), Image.BILINEAR), np.float32) / 255
    x = (x - np.array([0.485, 0.456, 0.406], np.float32)) / np.array([0.229, 0.224, 0.225], np.float32)
    with torch.no_grad():
        y = model(torch.from_numpy(x.transpose(2, 0, 1))[None])
        y = (y[-1] if isinstance(y, (list, tuple)) else y).sigmoid()[0, 0].numpy()
    return np.asarray(Image.fromarray((y * 255).astype(np.uint8)).resize(image.size, Image.BILINEAR), np.float32) / 255


def sam_decode(predictor, points, labels, box, need=None, prefer_whole=False):
    """One soft mask and SAM's own score for it. SAM always gives three answers here, as the
    Core ML models the app uses do; the one kept contains `need` (a point) and scores highest."""
    args = dict(point_coords=np.array(points, np.float32) if points else None,
                point_labels=np.array(labels, np.int32) if points else None,
                box=np.array(box, np.float32) if box is not None else None, return_logits=True)
    m, s, _ = predictor.predict(multimask_output=True, **args)
    ok = list(range(len(s)))
    if need is not None:
        ok = [i for i in ok if m[i][int(need[1]), int(need[0])] > 0] or ok
    i = max(ok, key=lambda k: s[k])
    if prefer_whole:
        # SAM's three answers run from a whole object to its parts, and it often rates a part
        # highest. Take the largest answer that it rates nearly as well as its favourite.
        near = [k for k in ok if s[k] >= s[i] - 0.15]
        i = max(near, key=lambda k: (m[k] > 0).sum())
    return (1 / (1 + np.exp(-np.clip(m[i], -30, 30)))).astype(np.float32), float(s[i])


def read_bundle(d):
    proxy = Image.open(os.path.join(d, "proxy.png")).convert("RGB")
    faces = json.load(open(os.path.join(d, "faces.json")))["faces"]
    ref = glob.glob(os.path.join(d, "ps_mask-*.jpg")) + glob.glob(os.path.join(d, "gt_subject.png"))
    return {
        "name": os.path.basename(d).replace("-maskdebug", ""), "dir": d, "proxy": proxy,
        "face": [f["rect"] for f in faces if f.get("primary")][0] if faces else None,
        "others": [f["rect"] for f in faces if not f.get("primary")],
        "ref": np.asarray(Image.open(ref[0]).convert("L")) >= 128 if ref else None,
        "vision": np.asarray(Image.open(os.path.join(d, "current_m0.png")).convert("L"), np.float32) / 255,
        "crop": Image.open(os.path.join(d, "box_crop_hr.png")).convert("RGB") if os.path.exists(os.path.join(d, "box_crop_hr.png")) else None,
        "crop_box": json.load(open(os.path.join(d, "box.json")))["box_proxy"] if os.path.exists(os.path.join(d, "box.json")) else None,
    }


def save(work, name, key, array):
    np.save(os.path.join(work, f"{name}.{key}.npy"), array.astype(np.float16))


def load(work, name, key):
    p = os.path.join(work, f"{name}.{key}.npy")
    return np.load(p).astype(np.float32) if os.path.exists(p) else None


def run_models(bundles, work, which):
    os.makedirs(work, exist_ok=True)
    times = json.load(open(os.path.join(work, "times.json"))) if os.path.exists(os.path.join(work, "times.json")) else {}
    items = [read_bundle(d) for d in sorted(glob.glob(os.path.join(bundles, "*-maskdebug")))]
    if "birefnet" in which:
        model = load_birefnet()
        for it in items:
            W, H = it["proxy"].size
            rgb = np.asarray(it["proxy"])
            sigma, edges = sharpness(rgb)
            if load(work, it["name"], "SA") is None:
                t = time.time(); sa = birefnet(model, it["proxy"]); times[f"{it['name']}.SA"] = time.time() - t
                save(work, it["name"], "SA", sa)
            sa = load(work, it["name"], "SA")
            # Run B: the face's body box joined with what run A kept, a little enlarged.
            kept, _ = keep(sa, sigma, edges, it["face"])
            box = body_box(it["face"], W, H)
            kb = bbox(kept >= 0.5)
            box = expand(union(box, kb) if kb else box, W, H)
            json.dump(box, open(os.path.join(work, f"{it['name']}.boxB.json"), "w"))
            if (box[2] - box[0]) * (box[3] - box[1]) <= 0.8 * W * H and load(work, it["name"], "SB") is None:
                t = time.time(); sb = birefnet(model, it["proxy"].crop(box)); times[f"{it['name']}.SB"] = time.time() - t
                full = np.zeros((H, W), np.float32); full[box[1]:box[3], box[0]:box[2]] = sb
                save(work, it["name"], "SB", full)
            print(it["name"], "BiRefNet done", flush=True)
            json.dump(times, open(os.path.join(work, "times.json"), "w"))
    for size, repo in (("large", "facebook/sam2.1-hiera-large"), ("baseplus", "facebook/sam2.1-hiera-base-plus")):
        if f"sam-{size}" not in which:
            continue
        from sam2.sam2_image_predictor import SAM2ImagePredictor
        predictor = SAM2ImagePredictor.from_pretrained(repo, device="cpu")
        for it in items:
            W, H = it["proxy"].size
            face, torso = face_points(it["face"])
            pts = [face] + ([torso] if torso[1] < H else [])
            t = time.time(); predictor.set_image(np.asarray(it["proxy"])); times[f"{it['name']}.{size}.encode"] = time.time() - t
            scores = {}
            t = time.time()
            # B: the face's body box and the two points.
            box = body_box(it["face"], W, H)
            p, scores["B"] = sam_decode(predictor, pts, [1] * len(pts), box, need=face); save(work, it["name"], f"{size}.P", p)
            # The same without a box, and with a roomier one, to see what a tight box costs.
            p, scores["Bpoints"] = sam_decode(predictor, pts, [1] * len(pts), None, need=face); save(work, it["name"], f"{size}.Ppoints", p)
            p, scores["Broomy"] = sam_decode(predictor, pts, [1] * len(pts), roomy_box(it["face"], W, H), need=face); save(work, it["name"], f"{size}.Proomy", p)
            p, scores["Bwhole"] = sam_decode(predictor, pts, [1] * len(pts), roomy_box(it["face"], W, H), need=face, prefer_whole=True); save(work, it["name"], f"{size}.Pwhole", p)
            # C: the box joined with what BiRefNet kept.
            bb = os.path.join(work, f"{it['name']}.boxB.json")
            if os.path.exists(bb):
                p, scores["C"] = sam_decode(predictor, pts, [1] * len(pts), json.load(open(bb)), need=face); save(work, it["name"], f"{size}.Pwide", p)
            times[f"{it['name']}.{size}.decode3"] = time.time() - t
            # B2: again on the high-resolution crop of the body box.
            if it["crop"] is not None:
                cx, cy, cw, ch = it["crop_box"]
                k = it["crop"].size[0] / cw
                mapped = [((x - cx) * k, (y - cy) * k) for x, y in pts]
                mapped = [m for m in mapped if 0 <= m[0] < it["crop"].size[0] and 0 <= m[1] < it["crop"].size[1]]
                t = time.time(); predictor.set_image(np.asarray(it["crop"])); times[f"{it['name']}.{size}.encode_crop"] = time.time() - t
                pc, scores["B2"] = sam_decode(predictor, mapped, [1] * len(mapped), (0, 0, it["crop"].size[0], it["crop"].size[1]), need=mapped[0])
                small = np.asarray(Image.fromarray((pc * 255).astype(np.uint8)).resize((cw, ch), Image.BILINEAR), np.float32) / 255
                full = np.zeros((H, W), np.float32); full[cy:cy + ch, cx:cx + cw] = small[:min(ch, H - cy), :min(cw, W - cx)]
                save(work, it["name"], f"{size}.Pc", full)
            json.dump(scores, open(os.path.join(work, f"{it['name']}.{size}.scores.json"), "w"))
            print(it["name"], size, "SAM done", scores, flush=True)
            json.dump(times, open(os.path.join(work, "times.json"), "w"))


# ---- the candidates -------------------------------------------------------------------

def candidates(it, work, size="large"):
    W, H = it["proxy"].size
    rgb = np.asarray(it["proxy"])
    sigma, edges = sharpness(rgb)
    face = it["face"]
    out, notes = {"V": it["vision"]}, {}
    sa, sb = load(work, it["name"], "SA"), load(work, it["name"], "SB")
    S = None
    if sa is not None:
        S = sa
        bb = os.path.join(work, f"{it['name']}.boxB.json")
        if sb is not None and os.path.exists(bb):
            w = feather_in(json.load(open(bb)), sa.shape)
            S = w * sb + (1 - w) * sa
        out["A"], notes["A"] = keep(S, sigma, edges, face)
    for size in ("large", "baseplus"):
        tag = "" if size == "large" else "+"
        P = load(work, it["name"], f"{size}.P")
        if P is None:
            continue
        out["B" + tag], notes["B" + tag] = keep(P, sigma, edges, face)
        for key, stored in (("Bp", "Ppoints"), ("Br", "Proomy"), ("Bw", "Pwhole")):
            Pv = load(work, it["name"], f"{size}.{stored}")
            if Pv is not None:
                out[key + tag], notes[key + tag] = keep(Pv, sigma, edges, face)
        Pc = load(work, it["name"], f"{size}.Pc")
        if Pc is not None and it["crop_box"]:
            cx, cy, cw, ch = it["crop_box"]
            w = feather_in((cx, cy, min(cx + cw, W), min(cy + ch, H)), P.shape)
            out["B2" + tag], notes["B2" + tag] = keep(w * Pc + (1 - w) * P, sigma, edges, face)
        Pw = load(work, it["name"], f"{size}.Pwide")
        if S is not None and Pw is not None:
            # C: BiRefNet's shapes, kept where SAM agrees they are the subject, or attached and sharp.
            pd = ndi.binary_dilation(Pw >= 0.5, EIGHT, iterations=max(int(CONFIG["hybrid_dilate"] * max(W, H)), 1))
            agrees = lambda comp: (comp & pd).sum() / max(comp.sum(), 1) >= CONFIG["hybrid_overlap"]
            m, info = keep(S, sigma, edges, face, must_keep=agrees)
            # Areas only SAM claims are added (the app marks them uncertain for refinement).
            only = (Pw >= 0.5) & (m < 0.5)
            out["C" + tag], notes["C" + tag] = np.where(only, np.maximum(m, Pw), m), info
    return out, notes


def score(mask, ref):
    m = mask >= 0.5
    inter, uni = (m & ref).sum(), (m | ref).sum()
    def rim(a):
        return a & ~ndi.binary_erosion(a, EIGHT)
    bm, br = rim(m), rim(ref)
    near_ref, near_m = ndi.binary_dilation(br, EIGHT, iterations=3), ndi.binary_dilation(bm, EIGHT, iterations=3)
    precision = (bm & near_ref).sum() / max(bm.sum(), 1)
    recall = (br & near_m).sum() / max(br.sum(), 1)
    return {"iou": inter / max(uni, 1), "boundary_f": 2 * precision * recall / max(precision + recall, 1e-9),
            "leak": 100 * (m & ~ref).sum() / max(ref.sum(), 1), "miss": 100 * (~m & ref).sum() / max(ref.sum(), 1)}


def panel(rgb, mask, ref, title, sub):
    """Agreement in green, selected-but-not-in-reference in red, in-reference-but-missed in blue."""
    a = rgb.astype(np.float32)
    m = mask >= 0.5
    for where, colour in (((m & ref), (40, 200, 60)), ((m & ~ref), (255, 30, 30)), ((~m & ref), (40, 90, 255))):
        a[where] = a[where] * 0.35 + np.array(colour) * 0.65
    im = Image.fromarray(a.astype(np.uint8)).resize((rgb.shape[1] // 3, rgb.shape[0] // 3))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, im.size[0], 30], fill=(0, 0, 0))
    d.text((6, 3), title, fill=(255, 255, 255))
    d.text((6, 16), sub, fill=(200, 200, 200))
    return im


def report(bundles, work):
    out_dir = os.path.join(work, "report")
    os.makedirs(out_dir, exist_ok=True)
    rows, order = [], []
    for d in sorted(glob.glob(os.path.join(bundles, "*-maskdebug"))):
        it = read_bundle(d)
        if it["ref"] is None or it["face"] is None:
            continue
        masks, notes = candidates(it, work)
        rgb = np.asarray(it["proxy"])
        tiles = [Image.fromarray(rgb).resize((rgb.shape[1] // 3, rgb.shape[0] // 3))]
        for key, m in masks.items():
            s = score(m, it["ref"])
            rows.append({"image": it["name"], "candidate": key, **{k: round(float(v), 4) for k, v in s.items()}, "notes": json.dumps(notes.get(key, {}))})
            if key not in order:
                order.append(key)
            tiles.append(panel(rgb, m, it["ref"], f"{key}  IoU {s['iou']:.3f}", f"extra {s['leak']:.1f}%  missed {s['miss']:.1f}%"))
        sheet = Image.new("RGB", (sum(t.size[0] for t in tiles), tiles[0].size[1]))
        x = 0
        for t in tiles:
            sheet.paste(t, (x, 0)); x += t.size[0]
        sheet.save(os.path.join(out_dir, f"{it['name']}.jpg"), quality=88)
    import csv
    with open(os.path.join(out_dir, "scores.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
    images = sorted({r["image"] for r in rows})
    print("IoU against the Photoshop mask")
    print("image     " + "".join(f"{k:>8}" for k in order))
    for im in images:
        print(f"{im:<10}" + "".join(f"{next((r['iou'] for r in rows if r['image'] == im and r['candidate'] == k), float('nan')):8.3f}" for k in order))
    for label, key in (("extra (% of reference)", "leak"), ("missed (% of reference)", "miss"), ("boundary F", "boundary_f")):
        print(label)
        for im in images:
            print(f"{im:<10}" + "".join(f"{next((r[key] for r in rows if r['image'] == im and r['candidate'] == k), float('nan')):8.2f}" for k in order))


if __name__ == "__main__":
    mode, bundles, work = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode == "models":
        run_models(bundles, work, sys.argv[4:] or ["birefnet", "sam-large", "sam-baseplus"])
    else:
        report(bundles, work)
