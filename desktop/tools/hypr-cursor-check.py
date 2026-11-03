#!/usr/bin/env python3
"""Does a take's cursor.json say where Hyprland's pointer was, and does that
line up with the picture?

  hypr-cursor-check.py <take folder> <moves.txt> <out prefix>

moves.txt (from hypr-check.sh): "<epoch> <x> <y> <hyprctl cursorpos>" per
`hyprctl dispatch movecursor x y`, and "<epoch> click". The first spot is the
top-left corner of a window ("mover"); the frame at that moment must show the
window's edge there. Writes <prefix>-corner.png (the frame, the logged point
marked) and exits non-zero on a mismatch.
"""
import json, subprocess, sys

take, moves_path, prefix = sys.argv[1:4]
meta = json.load(open(f"{take}/meta.json"))
cur = json.load(open(f"{take}/cursor.json"))
W, H, s = meta["pixelWidth"], meta["pixelHeight"], meta.get("pointScale", 1) or 1
LW, LH = W / s, H / s  # logical size of what was recorded
video = f"{take}/{meta.get('video', 'screen.mp4')}"

spots, clicked = [], False
for line in open(moves_path):
    p = line.split()
    if len(p) >= 3 and p[1] != "click":
        spots.append((float(p[0]), float(p[1]), float(p[2])))
    elif len(p) == 2 and p[1] == "click":
        clicked = True

samples, clicks = cur["samples"], cur["clicks"]
print(f"     {len(samples)} pointer samples over {samples[-1]['t'] if samples else 0:.2f} s, {len(clicks)} click(s); "
      f"recorded area {W}x{H} px at scale {s} = {LW:g}x{LH:g} logical")
bad = 0

def near(smp, x, y, tol=1.0):
    return abs(smp["x"] * LW - x) <= tol and abs(smp["y"] * LH - y) <= tol

plateaus = []
after = -1.0  # each spot is looked for after the previous one (the pointer may start on the last)
for (_, x, y) in spots:
    hit = [m for m in samples if near(m, x, y) and m["t"] > after]
    if hit:
        after = hit[0]["t"]
    if hit:
        plateaus.append((x, y, hit[0]["t"], hit[-1]["t"]))
        print(f"     spot {x:g},{y:g}: {len(hit)} samples at t {hit[0]['t']:.2f}–{hit[-1]['t']:.2f}")
    else:
        bad += 1
        closest = min(samples, key=lambda m: (m["x"] * LW - x) ** 2 + (m["y"] * LH - y) ** 2) if samples else None
        print(f"     spot {x:g},{y:g}: NOT in cursor.json"
              + (f" (closest {closest['x'] * LW:.1f},{closest['y'] * LH:.1f} at t {closest['t']:.2f})" if closest else ""))
order_ok = all(plateaus[i][2] < plateaus[i + 1][2] for i in range(len(plateaus) - 1))
print(f"     spots in order: {order_ok}")
bad += not order_ok

if clicked:
    lx, ly = spots[-1][1], spots[-1][2]
    hit = [c for c in clicks if near(c, lx, ly, 2)]
    print(f"     uinput click at {lx:g},{ly:g}: {'logged at t %.2f' % hit[0]['t'] if hit else 'NOT logged'} "
          f"(clicks: {[(round(c['x'] * LW), round(c['y'] * LH), round(c['t'], 2)) for c in clicks]})")
    bad += not hit

# The picture: the frame in the middle of the first spot's plateau.
if plateaus:
    x, y, t0, t1 = plateaus[0]
    t = (t0 + t1) / 2
    raw = subprocess.run(["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", video, "-frames:v", "1",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    vw, vh = W - W % 2, H - H % 2
    if len(raw) < vw * vh * 3:
        print(f"     frame at {t:.2f}: couldn't decode")
        bad += 1
    else:
        px = lambda X, Y: raw[(Y * vw + X) * 3:(Y * vw + X) * 3 + 3]
        X, Y = round(x * s), round(y * s)
        # The mover's inside is magenta (foot's background): its first magenta
        # pixel on a row and on a column inside it is its corner.
        magenta = lambda c: c[0] > 180 and c[1] < 90 and c[2] > 180
        row, col = Y + round(30 * s), X + round(60 * s)
        ex = next((i for i in range(X - 20, X + 21) if magenta(px(i, row))), None)
        ey = next((j for j in range(Y - 20, Y + 21) if magenta(px(col, j))), None)
        if ex is None or ey is None:
            ex, ey = ex if ex is not None else -1, ey if ey is not None else -1
        dx, dy = ex - X, ey - Y
        ok = abs(dx) <= 2 and abs(dy) <= 2
        print(f"     frame at t {t:.2f}: window corner seen at {ex},{ey} px, cursor.json says {X},{Y} px "
              f"(off by {dx},{dy}) {'ok' if ok else 'MISMATCH'}")
        bad += not ok
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.3f}", "-i", video, "-frames:v", "1",
                        "-vf", f"drawbox=x={X - 12}:y={Y}:w=24:h=1:color=red,drawbox=x={X}:y={Y - 12}:w=1:h=24:color=red,"
                               f"crop={min(400, vw)}:{min(300, vh)}:{max(0, min(vw - 400, X - 200))}:{max(0, min(vh - 300, Y - 150))}",
                        f"{prefix}-corner.png"])
sys.exit(1 if bad else 0)
