#!/usr/bin/env python3
"""Turn the still cats into idle loops. Run from the repo root; needs Pillow,
numpy and scipy. Reads the stills out of the asset catalogue and writes
`Cadence/Resources/Cats/<mood>.apng`.

Bend one appendage of a still drawing, and leave the rest of it alone.

A whole cat bobbing up and down is the cheap way to fake life and it looks it.
What a resting cat actually moves is its tail, so that is the only thing that
moves here: the tail is found as the thin protrusion the body's own shape does
not account for, and swung about the point where it joins the body, with the
rotation ramped from nothing at the join to full at the tip. The join does not
move, so nothing tears.
"""
import numpy as np
from scipy import ndimage
from PIL import Image


def disk(r):
    y, x = np.ogrid[-r:r + 1, -r:r + 1]
    return x * x + y * y <= r * r


def tail_of(alpha, radius):
    """The largest thing left when the body is opened away."""
    body = alpha > 128
    opened = ndimage.binary_opening(body, disk(radius))
    residue = body & ~opened
    lab, count = ndimage.label(residue, np.ones((3, 3)))
    if count == 0:
        return None, None
    sizes = ndimage.sum(residue, lab, range(1, count + 1))
    tail = lab == int(np.argmax(sizes)) + 1

    # Where it joins: the pixels of the body it is touching.
    join = ndimage.binary_dilation(tail, disk(4)) & opened
    if not join.any():
        join = ndimage.binary_dilation(tail, disk(10)) & body
    ys, xs = np.nonzero(join)
    return tail, (float(xs.mean()), float(ys.mean()))


def weights(tail, pivot, feather=9.0):
    """0 at the join, 1 at the tip, 0 outside the tail — softly."""
    h, w = tail.shape
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.hypot(xx - pivot[0], yy - pivot[1])
    reach = d[tail].max() if tail.any() else 1.0
    ramp = np.clip(d / max(reach, 1.0), 0, 1)
    ramp = ramp * ramp * (3 - 2 * ramp)          # smoothstep: no kink at the join
    soft = ndimage.gaussian_filter(tail.astype(np.float32), feather)
    soft = np.clip((soft - 0.25) / 0.5, 0, 1)    # keep the core, fade the edge
    return ramp * soft


def bend(image, tail, pivot, w, degrees):
    """Rotate by `degrees * w(p)` about the pivot, sampling premultiplied."""
    rgba = np.asarray(image).astype(np.float32) / 255.0
    pm = rgba.copy()
    pm[..., :3] *= pm[..., 3:4]                  # premultiply, or edges halo

    h, wd = tail.shape
    yy, xx = np.mgrid[0:h, 0:wd].astype(np.float32)
    theta = np.deg2rad(degrees) * w
    cos, sin = np.cos(-theta), np.sin(-theta)
    dx, dy = xx - pivot[0], yy - pivot[1]
    sx = pivot[0] + cos * dx - sin * dy
    sy = pivot[1] + sin * dx + cos * dy

    out = np.empty_like(pm)
    for c in range(4):
        out[..., c] = ndimage.map_coordinates(
            pm[..., c], [sy, sx], order=1, mode="constant", cval=0.0
        )

    # Only the warped neighbourhood is taken from the warp; everywhere else is
    # the original pixel, so a rounding error near the ears cannot show up as a
    # shimmer twenty frames later.
    take = (w > 0.001)[..., None]
    out = np.where(take, out, pm)

    alpha = np.clip(out[..., 3:4], 1e-6, 1.0)
    out[..., :3] = np.clip(out[..., :3] / alpha, 0, 1)
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGBA")


def breathe(image, degrees_unused=None, amount=0.022):
    """For a cat with no tail out: the body rises and falls where it is soft.

    Scaled about the bottom of the shape rather than the centre, because what
    is touching the bed does not move.
    """
    rgba = np.asarray(image).astype(np.float32) / 255.0
    h, w = rgba.shape[:2]
    ys = np.nonzero(rgba[..., 3].max(1) > 0.5)[0]
    floor = float(ys.max()) if len(ys) else h - 1.0
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    sy = floor + (yy - floor) / (1.0 + amount)
    sx = (xx - w / 2) / (1.0 + amount * 0.35) + w / 2
    pm = rgba.copy()
    pm[..., :3] *= pm[..., 3:4]
    out = np.empty_like(pm)
    for c in range(4):
        out[..., c] = ndimage.map_coordinates(pm[..., c], [sy, sx], order=1,
                                              mode="constant", cval=0.0)
    a = np.clip(out[..., 3:4], 1e-6, 1.0)
    out[..., :3] = np.clip(out[..., :3] / a, 0, 1)
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGBA")


# MARK: - The five

if __name__ == "__main__":
    import math, os, sys

    CATALOGUE = "Cadence/Resources/Assets.xcassets"
    OUT = "Cadence/Resources/Cats"
    SIZE, FRAMES, MILLISECONDS = 176, 24, 110

    # `radius` is how much thicker the body is than the tail in that drawing —
    # the opening that finds the tail has to fit inside one and not the other,
    # so it is per-picture and found by trying. `degrees` is how far the tail
    # swings: a resting cat's is lazy, not a metronome.
    PLAN = {
        "cat-idle":    dict(radius=60, degrees=8),
        "cat-clear":   dict(radius=38, degrees=7),
        "cat-behind":  dict(radius=52, degrees=11),
        "cat-working": dict(radius=38, degrees=8),
        "cat-rest":    dict(radius=None, degrees=0),   # curled up: it breathes
    }

    os.makedirs(OUT, exist_ok=True)
    for name, plan in PLAN.items():
        source = f"{CATALOGUE}/{name}.imageset/{name}.png"
        if not os.path.exists(source):
            print(f"skipping {name}: no {source}", file=sys.stderr)
            continue
        still = Image.open(source).convert("RGBA")
        frames = []
        for i in range(FRAMES):
            if plan["radius"] is None:
                phase = (1 - math.cos(i / FRAMES * 2 * math.pi)) / 2
                frame = breathe(still, amount=0.030 * phase)
            else:
                if i == 0:
                    tail, pivot = tail_of(np.asarray(still)[..., 3], plan["radius"])
                    field = weights(tail, pivot)
                angle = plan["degrees"] * math.sin(i / FRAMES * 2 * math.pi)
                frame = bend(still, tail, pivot, field, angle)
            frames.append(frame.resize((SIZE, SIZE), Image.LANCZOS))

        path = f"{OUT}/{name}.apng"
        frames[0].save(path, save_all=True, append_images=frames[1:],
                       duration=MILLISECONDS, loop=0, format="PNG")
        print(f"{name}: {len(frames)} frames, {os.path.getsize(path) / 1024:.0f} KB")
