#!/usr/bin/env python3
"""Turn the still cats into idle loops.

Run from the repo root; needs Pillow, numpy and scipy. Reads the stills out of
the asset catalogue and writes `Cadence/Resources/Cats/<mood>.apng`.

The rule the whole file follows: **move the part that moves, and nothing else.**
Scaling or bobbing the whole animal was the first attempt and it reads as
exactly what it is. A cat at rest lies still and swings its tail; a cat washing
holds the paw and brings its head to it; a cat asleep breathes and the Zs drift
off. Each of those is one region of one drawing, warped on its own, so several
can be applied in sequence without any of them knowing about the others.

Regions are soft-edged. A hard mask shows up as a moving seam.
"""
import math
import os
import sys

import numpy as np
from scipy import ndimage
from PIL import Image


# MARK: - Finding the parts

def disk(r):
    y, x = np.ogrid[-r:r + 1, -r:r + 1]
    return x * x + y * y <= r * r


def ellipse(shape, cx, cy, rx, ry, feather=10.0):
    """1 inside, fading to 0 just outside."""
    h, w = shape
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.sqrt(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2)
    return ndimage.gaussian_filter(np.clip(1.6 - 1.6 * d, 0, 1).astype(np.float32), feather)


def tail_of(alpha, radius):
    """The largest thing left when the body is opened away, and where it joins.

    A tail is thinner than the torso, so an opening with a disc that fits inside
    the body and not inside the tail leaves the body behind and drops every thin
    protrusion. `radius` is per-drawing for that reason.
    """
    body = alpha > 128
    opened = ndimage.binary_opening(body, disk(radius))
    residue = body & ~opened
    lab, count = ndimage.label(residue, np.ones((3, 3)))
    if count == 0:
        return None, None
    sizes = ndimage.sum(residue, lab, range(1, count + 1))
    tail = lab == int(np.argmax(sizes)) + 1
    join = ndimage.binary_dilation(tail, disk(4)) & opened
    if not join.any():
        join = ndimage.binary_dilation(tail, disk(10)) & body
    ys, xs = np.nonzero(join)
    return tail, (float(xs.mean()), float(ys.mean()))


def hinge(mask, pivot, feather=9.0):
    """0 at the pivot, 1 at the far end, 0 outside the mask.

    This is what keeps a swinging part attached: the rotation is ramped to
    nothing where it meets the body, so the join does not move and nothing
    tears.
    """
    h, w = mask.shape
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.hypot(xx - pivot[0], yy - pivot[1])
    reach = d[mask].max() if mask.any() else 1.0
    ramp = np.clip(d / max(reach, 1.0), 0, 1)
    ramp = ramp * ramp * (3 - 2 * ramp)
    soft = ndimage.gaussian_filter(mask.astype(np.float32), feather)
    soft = np.clip((soft - 0.25) / 0.5, 0, 1)
    return ramp * soft


def loose_pieces(alpha, inside_box=None):
    """Marks drawn apart from the animal: speed lines, a sleeping Z."""
    body = alpha > 128
    lab, count = ndimage.label(body)
    if count <= 1:
        return np.zeros_like(body)
    sizes = ndimage.sum(body, lab, range(1, count + 1))
    loose = body & (lab != int(np.argmax(sizes)) + 1) & (lab != 0)
    if inside_box:
        x0, y0, x1, y1 = inside_box
        window = np.zeros_like(loose)
        window[y0:y1, x0:x1] = True
        loose &= window
    return loose


def eye_of(image, box):
    """The dark oval inside `box`, and the picture with it painted out."""
    x0, y0, x1, y1 = box
    rgba = np.asarray(image).astype(np.float32) / 255.0
    window = np.zeros(rgba.shape[:2], bool)
    window[y0:y1, x0:x1] = True
    dark = (rgba[..., :3].max(2) < 0.34) & (rgba[..., 3] > 0.5) & window

    lab, count = ndimage.label(dark)
    if count == 0:
        return None, None
    sizes = ndimage.sum(dark, lab, range(1, count + 1))
    eye = lab == int(np.argmax(sizes)) + 1
    # Closed before filling: the pale crescent of reflection sits at the rim of
    # the oval and opens onto the fur, so a plain fill leaves it out — and what
    # is left out becomes a source for the paint, which is how a blinking orange
    # cat ends up with a lavender patch on its face.
    eye = ndimage.binary_closing(ndimage.binary_fill_holes(eye), disk(13))
    eye = ndimage.binary_dilation(ndimage.binary_fill_holes(eye), disk(3))
    return eye, Image.fromarray((_fill(rgba, eye) * 255).astype(np.uint8), "RGBA")


def _fill(rgba, mask, rounds=500, margin=14):
    """Grow the surrounding colour inwards until it meets in the middle.

    Nearest-neighbour was the first attempt and it patches: an eye this big
    straddles orange fur and a white muzzle, and copying the closest pixel
    leaves the two meeting along a seam. Averaging lets them blend the way the
    fur does. Solved in the eye's own neighbourhood, not over the whole picture,
    which is the difference between a second and a minute.
    """
    ys, xs = np.nonzero(mask)
    y0, y1 = max(ys.min() - margin, 0), min(ys.max() + margin + 1, mask.shape[0])
    x0, x1 = max(xs.min() - margin, 0), min(xs.max() + margin + 1, mask.shape[1])

    patch = rgba[y0:y1, x0:x1].copy()
    hole = mask[y0:y1, x0:x1]
    seed = ndimage.distance_transform_edt(hole, return_indices=True)[1]
    patch[hole] = patch[seed[0][hole], seed[1][hole]]          # a starting guess
    kernel = np.array([[0.0, 0.25, 0.0], [0.25, 0.0, 0.25], [0.0, 0.25, 0.0]])
    for _ in range(rounds):
        blurred = np.dstack([ndimage.convolve(patch[..., c], kernel, mode="nearest")
                             for c in range(patch.shape[2])])
        patch[hole] = blurred[hole]

    out = rgba.copy()
    out[y0:y1, x0:x1] = patch
    return out


# MARK: - Moving them

def _premultiplied(image):
    rgba = np.asarray(image).astype(np.float32) / 255.0
    rgba[..., :3] *= rgba[..., 3:4]
    return rgba


def _image(pm):
    alpha = np.clip(pm[..., 3:4], 1e-6, 1.0)
    out = pm.copy()
    out[..., :3] = np.clip(out[..., :3] / alpha, 0, 1)
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGBA")


def _resample(pm, sy, sx, take):
    out = np.empty_like(pm)
    for c in range(4):
        out[..., c] = ndimage.map_coordinates(pm[..., c], [sy, sx], order=1,
                                              mode="constant", cval=0.0)
    return np.where(take[..., None], out, pm)


def swing(image, weight, pivot, degrees):
    """Rotate about a pivot, by an angle that ramps up with `weight`."""
    pm = _premultiplied(image)
    h, w = weight.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    theta = np.deg2rad(degrees) * weight
    cos, sin = np.cos(-theta), np.sin(-theta)
    dx, dy = xx - pivot[0], yy - pivot[1]
    return _image(_resample(pm, pivot[1] + sin * dx + cos * dy,
                            pivot[0] + cos * dx - sin * dy, weight > 0.001))


def blink(image, eye, painted, closed, ink=(0.23, 0.13, 0.09)):
    """A lid comes down over an eye. 0 open, 1 shut.

    Warping the eye was tried twice — squashed about its centre, then compressed
    under a descending lid — and both are wrong the same way: a big glossy
    cartoon eye is a *drawn shape*, and resampling it smears the highlight and
    drags the eyebrow stripe down with it.

    A drawing blinks by being drawn differently. The covered part of the eye is
    replaced with the fur that would be behind it, and the lid is a stroke in
    the same ink as every other line — which is what the rest of this set
    already does: the sleeping cats' eyes are one arc.
    """
    if eye is None or closed <= 0:
        return image
    rows, cols = np.nonzero(eye.any(1))[0], np.nonzero(eye.any(0))[0]
    top, bottom = float(rows.min()), float(rows.max())
    lid = top + (bottom - top) * min(closed, 1.0)

    base = np.asarray(image).astype(np.float32) / 255.0
    over = np.asarray(painted).astype(np.float32) / 255.0
    yy = np.mgrid[0:base.shape[0], 0:base.shape[1]][0]
    out = np.where((eye & (yy <= lid))[..., None], over, base)

    xs = np.arange(base.shape[1], dtype=np.float32)
    centre = (cols.max() + cols.min()) / 2.0
    across = np.clip((xs - centre) / max((cols.max() - cols.min()) / 2.0, 1.0), -1, 1)
    curve = lid - (bottom - top) * 0.12 * (1 - across ** 2) * closed
    band = np.clip(1 - np.abs(yy - curve[None, :]) / (2.2 + 2.0 * closed), 0, 1)
    reach = ndimage.binary_dilation(eye, disk(4)).astype(np.float32)
    stroke = (band * reach * np.clip(1 - across[None, :] ** 6, 0, 1) * closed)[..., None]
    out[..., :3] = out[..., :3] * (1 - stroke) + np.array(ink, np.float32) * stroke
    out[..., 3] = np.maximum(out[..., 3], stroke[..., 0])
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGBA")


def press(image, weight, dy, dx=0.0):
    """Move a region, dragging what is under its edge rather than cutting it."""
    pm = _premultiplied(image)
    h, w = weight.shape
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    return _image(_resample(pm, yy - dy * weight, xx - dx * weight, weight > 0.001))


def float_away(image, mask, dx, dy, fade):
    """Lift a detached mark off the picture: it drifts and thins as it goes.

    Cut and repasted rather than warped, because what is behind these is
    nothing — they are drawn in the empty space around the animal, so moving
    them can leave a hole without leaving a mark.
    """
    pm = _premultiplied(image)
    layer, rest = pm * mask[..., None], pm * (1 - mask[..., None])
    moved = np.empty_like(layer)
    for c in range(4):
        moved[..., c] = ndimage.shift(layer[..., c], (dy, dx), order=1,
                                      mode="constant", cval=0.0)
    return _image(np.clip(rest + moved * fade, 0, 1))


def breathe(image, amount):
    """Rise and fall about whatever the shape is resting on.

    Scaled about the bottom of the silhouette rather than its centre: what is
    touching the bed does not move.
    """
    pm = _premultiplied(image)
    h, w = pm.shape[:2]
    rows = np.nonzero(pm[..., 3].max(1) > 0.5)[0]
    floor = float(rows.max()) if len(rows) else h - 1.0
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    return _image(_resample(pm, floor + (yy - floor) / (1.0 + amount),
                            (xx - w / 2) / (1.0 + amount * 0.35) + w / 2,
                            np.ones((h, w), bool)))


# MARK: - The five

CATALOGUE = "Cadence/Resources/Assets.xcassets"
OUT = "Cadence/Resources/Cats"
SIZE, FRAMES, MILLISECONDS = 176, 30, 90

# Coordinates are in the 512px still. `radius` is how much thicker the body is
# than the tail in that particular drawing, found by trying.
PLAN = {
    "cat-idle":    dict(tail=60, degrees=8,
                        eyes=[(40, 170, 115, 250), (165, 172, 250, 254)]),
    "cat-clear":   dict(tail=38, degrees=7,
                        head=dict(centre=(320, 195), radii=(118, 96), neck=(300, 318),
                                  degrees=3.4)),
    "cat-behind":  dict(tail=52, degrees=11,
                        ear=dict(centre=(138, 58), radii=(56, 52), base=(150, 118),
                                 degrees=-7)),
    "cat-working": dict(tail=38, degrees=8,
                        paw=dict(centre=(339, 312), radii=(40, 26), travel=2.6)),
    "cat-rest":    dict(tail=None, zs=(300, 0, 460, 120)),   # curled up: it breathes
}


def compose(name, still, alpha, cache, t):
    """One frame at phase `t` in [0, 1)."""
    plan = PLAN[name]
    out = still
    sway = math.sin(t * 2 * math.pi)

    if plan.get("tail"):
        tail, pivot = cache["tail"]
        out = swing(out, cache["tail_weight"], pivot, plan["degrees"] * sway)

    if "eyes" in plan:
        # Sharp shut, slower open, once a cycle. Twice is a nervous cat.
        shut = max(0.0, 1 - abs((t - 0.30) / 0.07)) if t < 0.45 else 0.0
        for eye, painted in cache["eyes"]:
            out = blink(out, eye, painted, shut)

    if "head" in plan:
        # The lick. The paw is held and the head goes to it, twice a cycle with
        # a pause between — a cat washing is a rhythm, not a wave.
        lick = max(0.0, math.sin(t * 4 * math.pi)) ** 0.7
        out = swing(out, cache["head"], plan["head"]["neck"],
                    plan["head"]["degrees"] * lick)

    if "ear" in plan:
        # Once, briefly. An ear that waves is a rabbit.
        flick = max(0.0, 1 - abs((t - 0.62) / 0.07))
        out = swing(out, cache["ear"], plan["ear"]["base"], plan["ear"]["degrees"] * flick)

    if "paw" in plan:
        out = press(out, cache["paw"], dy=plan["paw"]["travel"] * max(0.0, math.sin(t * 8 * math.pi)))

    if name == "cat-rest":
        out = breathe(out, 0.030 * (1 - math.cos(t * 2 * math.pi)) / 2)
        # Rising and thinning, with an envelope that is zero at both ends of the
        # cycle so the loop joins without the Zs snapping back to the mouth.
        out = float_away(out, cache["zs"], 6 * t, -30 * t, math.sin(math.pi * t) ** 0.7)

    if cache["marks"] is not None:
        # Speed lines are drawn as if the tail were already moving, so they
        # belong to the swing rather than sitting at a constant strength.
        out = float_away(out, cache["marks"], 0, 0, 0.35 + 0.65 * abs(sway))

    return out


def prepare(name, still, alpha):
    plan = PLAN[name]
    cache = {"marks": None}
    if plan.get("tail"):
        tail, pivot = tail_of(alpha, plan["tail"])
        cache["tail"] = (tail, pivot)
        cache["tail_weight"] = hinge(tail, pivot)
        marks = loose_pieces(alpha)
        cache["marks"] = marks.astype(np.float32) if marks.any() else None
    for key in ("head", "ear", "paw"):
        if key in plan:
            spec = plan[key]
            cache[key] = ellipse(alpha.shape, *spec["centre"], *spec["radii"],
                                 feather=14 if key == "head" else 7)
    if "eyes" in plan:
        cache["eyes"] = [eye_of(still, box) for box in plan["eyes"]]
    if "zs" in plan:
        cache["zs"] = loose_pieces(alpha, inside_box=plan["zs"]).astype(np.float32)
    return cache


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name in PLAN:
        source = f"{CATALOGUE}/{name}.imageset/{name}.png"
        if not os.path.exists(source):
            print(f"skipping {name}: no {source}", file=sys.stderr)
            continue
        still = Image.open(source).convert("RGBA")
        alpha = np.asarray(still)[..., 3]
        cache = prepare(name, still, alpha)

        frames = [compose(name, still, alpha, cache, i / FRAMES).resize((SIZE, SIZE), Image.LANCZOS)
                  for i in range(FRAMES)]
        path = f"{OUT}/{name}.apng"
        frames[0].save(path, save_all=True, append_images=frames[1:],
                       duration=MILLISECONDS, loop=0, format="PNG")
        print(f"{name}: {len(frames)} frames, {os.path.getsize(path) / 1024:.0f} KB")
