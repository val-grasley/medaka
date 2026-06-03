#!/usr/bin/env python3
"""Generate the Medaka file icons (medaka-light.svg / medaka-dark.svg).

The icon is a top-down, mid-swim medaka: one smooth single-curve body (no head),
pectoral fins sweeping off the sides, and a flowing forked caudal fin. The shape is
built parametrically — an S-curve spine, a width profile swept along it, plus fins —
then fit to a 16x16 viewBox. Each SVG is a few flat-filled <path>s in one colour.

Run it (no dependencies beyond the stdlib):

    python3 editors/vscode-medaka/icons/generate.py

It overwrites medaka-light.svg and medaka-dark.svg next to this script. To preview a
result on macOS:  qlmanage -t -s 320 -o /tmp medaka-light.svg

--- Tuning guide (all the knobs are in the CONFIG block below) ---
  SPINE          the gentle S the body follows (4 cubic-Bezier control points, head->tail)
  WMAX / WIDTH   body thickness. WIDTH is a sine bump along t in [0,1]:
                   sin(pi*(A + B*t)) — larger A => wider/blunter front;
                   A+B nearer 1.0 => thinner peduncle (tail stalk). Lower WMAX => slimmer.
  PECTORAL_T     where the side fins attach (0=front .. 1=tail); OUT/BACK = size & sweep
  CAUDAL         tail fin: LF length, SP half-spread, deeper fork = smaller NOTCH_FRAC
  COLORS         light = explorer light themes, dark = dark themes
"""
import math
import os

# ============================ CONFIG ============================
# Gentle S-curve spine (head at top facing up -> peduncle at bottom).
SPINE = [(8.0, 2.6), (8.9, 5.9), (5.5, 9.2), (8.9, 12.6)]

WMAX = 1.66                       # max body half-width
WIDTH_A, WIDTH_B = 0.27, 0.68     # width(t) = WMAX * sin(pi*(A + B*t))

PECTORAL_T = 0.27                 # fin attach point along the body (0..1)
PECTORAL_OUT, PECTORAL_BACK = 3.0, 2.7   # how far the fins reach out / sweep back

CAUDAL_LF, CAUDAL_SP = 3.8, 1.95  # tail length / half-spread
CAUDAL_NOTCH_FRAC = 0.40          # fork depth (smaller = deeper fork)

COLORS = {"light": "#1565C0", "dark": "#5BB8F5"}

N = 44                            # body outline sampling resolution
FIT_LO, FIT_HI = 0.7, 15.3        # body is fit into this box inside the 16x16 viewBox
# ===============================================================

P0, P1, P2, P3 = SPINE


def bez(t):
    mt = 1 - t
    return (mt**3*P0[0] + 3*mt*mt*t*P1[0] + 3*mt*t*t*P2[0] + t**3*P3[0],
            mt**3*P0[1] + 3*mt*mt*t*P1[1] + 3*mt*t*t*P2[1] + t**3*P3[1])


def dbez(t):
    mt = 1 - t
    return (3*mt*mt*(P1[0]-P0[0]) + 6*mt*t*(P2[0]-P1[0]) + 3*t*t*(P3[0]-P2[0]),
            3*mt*mt*(P1[1]-P0[1]) + 6*mt*t*(P2[1]-P1[1]) + 3*t*t*(P3[1]-P2[1]))


def norm(v):
    L = math.hypot(*v) or 1.0
    return (v[0]/L, v[1]/L)


def add(a, b): return (a[0]+b[0], a[1]+b[1])
def mul(a, s): return (a[0]*s, a[1]*s)


def width(t):
    # one smooth spindle — rounded front, slimmer mid-body, tapering to a thin peduncle
    return WMAX * math.sin(math.pi*(WIDTH_A + WIDTH_B*t))


def frame(t):
    p = bez(t); tx, ty = norm(dbez(t))
    return p, (tx, ty), (-ty, tx)   # point, tangent, left-normal


# ===== build every component in MODEL space (points only) =====

# body edges, sampled down the right side and (later, reversed) up the left side
right = []; left = []
for i in range(N+1):
    t = i/N
    p, T, n = frame(t); w = width(t)
    right.append(add(p, mul(n, w)))
    left.append(add(p, mul(n, -w)))

# rounded front cap: a semicircle (radius = front width) closing left edge -> front -> right edge
hp, hT, hn = frame(0.0)
w0 = width(0.0)


def cappt(deg):
    a = math.radians(deg)
    return (hp[0] + math.cos(a)*w0*hn[0] - math.sin(a)*w0*hT[0],
            hp[1] + math.cos(a)*w0*hn[1] - math.sin(a)*w0*hT[1])


cap = [cappt(135), cappt(90), cappt(45)]


def pectoral(t_p, side):
    """Side fin petal: emerges flush from the body edge and sweeps back."""
    p, T, n = frame(t_p); n = mul(n, side); w = width(t_p)
    out, back = PECTORAL_OUT, PECTORAL_BACK
    p2, _, n2 = frame(t_p+0.18); n2 = mul(n2, side); w2 = width(t_p+0.18)
    base_f = add(p,  mul(n,  w*0.92))                      # flush to body edge
    base_b = add(p2, mul(n2, w2*0.92))
    tip = add(add(p, mul(n, out)), mul(T, back))          # out and back
    c1 = add(add(p,  mul(n, out*0.50)), mul(T, back*0.45))  # leading edge swept BACK (no forward bump)
    c2 = add(add(p2, mul(n2, out*0.34)), mul(T, back*0.85))  # trailing edge
    return [base_f, c1, tip, c2, base_b]


def caudal():
    """Tail fin: long flowing lobes, deep fork, pointed tips (fish-fin, not whale fluke)."""
    B, T, _ = frame(1.0); perp = (-T[1], T[0]); wped = width(1.0)
    Lf, sp = CAUDAL_LF, CAUDAL_SP
    pedR = add(B, mul(perp, wped)); pedL = add(B, mul(perp, -wped))
    tipR = add(add(B, mul(T, Lf)), mul(perp, sp))
    tipL = add(add(B, mul(T, Lf)), mul(perp, -sp))
    notch = add(B, mul(T, Lf*CAUDAL_NOTCH_FRAC))
    ocR = add(add(B, mul(T, Lf*0.28)), mul(perp, sp*1.02))  # outer edge bulges then tapers to a point
    ocL = add(add(B, mul(T, Lf*0.28)), mul(perp, -sp*1.02))
    icR = add(add(B, mul(T, Lf*0.90)), mul(perp, sp*0.40))  # inner edge sweeps in to the deep notch
    icL = add(add(B, mul(T, Lf*0.90)), mul(perp, -sp*0.40))
    return [pedR, ocR, tipR, icR, notch, icL, tipL, ocL, pedL]


pecR = pectoral(PECTORAL_T, +1); pecL = pectoral(PECTORAL_T, -1); caud = caudal()

# ===== fit everything into the viewBox =====
allpts = right + left + cap + pecR + pecL + caud
xs = [p[0] for p in allpts]; ys = [p[1] for p in allpts]
minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
s = min((FIT_HI-FIT_LO)/(maxx-minx), (FIT_HI-FIT_LO)/(maxy-miny))
ox = FIT_LO + ((FIT_HI-FIT_LO) - (maxx-minx)*s)/2 - minx*s
oy = FIT_LO + ((FIT_HI-FIT_LO) - (maxy-miny)*s)/2 - miny*s


def TR(p): return (p[0]*s+ox, p[1]*s+oy)


right = [TR(p) for p in right]; left = [TR(p) for p in left]; cap = [TR(p) for p in cap]
pecR = [TR(p) for p in pecR]; pecL = [TR(p) for p in pecL]; caud = [TR(p) for p in caud]


def f(p): return f"{p[0]:.2f} {p[1]:.2f}"


# ===== emit path strings =====
def closed_catmull_rom(P):
    """Body as ONE smooth closed curve through the outline loop, so there are no kinks/notches."""
    M = len(P); seg = [f"M {f(P[0])}"]
    for i in range(M):
        p0 = P[(i-1) % M]; p1 = P[i]; p2 = P[(i+1) % M]; p3 = P[(i+2) % M]
        c1 = (p1[0] + (p2[0]-p0[0])/6.0, p1[1] + (p2[1]-p0[1])/6.0)
        c2 = (p2[0] - (p3[0]-p1[0])/6.0, p2[1] - (p3[1]-p1[1])/6.0)
        seg.append(f"C {f(c1)} {f(c2)} {f(p2)}")
    seg.append("Z")
    return " ".join(seg)


# loop: right edge down -> left edge back up -> rounded front cap
body = closed_catmull_rom(right + list(reversed(left)) + cap)


def petal(P):
    bf, c1, tip, c2, bb = P
    return f"M {f(bf)} Q {f(c1)} {f(tip)} Q {f(c2)} {f(bb)} Z"


pecRp = petal(pecR); pecLp = petal(pecL)

pedR, ocR, tipR, icR, notch, icL, tipL, ocL, pedL = caud
caudp = (f"M {f(pedR)} Q {f(ocR)} {f(tipR)} Q {f(icR)} {f(notch)} "
         f"Q {f(icL)} {f(tipL)} Q {f(ocL)} {f(pedL)} Z")


def svg(fill):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16">\n'
            f'  <path fill="{fill}" d="{pecLp}"/>\n'
            f'  <path fill="{fill}" d="{pecRp}"/>\n'
            f'  <path fill="{fill}" d="{caudp}"/>\n'
            f'  <path fill="{fill}" d="{body}"/>\n'
            '</svg>\n')


here = os.path.dirname(os.path.abspath(__file__))
for name, fill in COLORS.items():
    path = os.path.join(here, f"medaka-{name}.svg")
    with open(path, "w") as fh:
        fh.write(svg(fill))
    print(f"wrote {path}")
