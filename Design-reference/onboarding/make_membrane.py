"""Draws the Membrae logo with its cell pattern carried outward: radial, thinning, with holes at the edge."""
import math, random, sys

LOGO = [
"M204.19 185.719C210.049 185.517 214.115 188.607 218.137 192.598C233.443 207.789 248.238 223.927 263.226 239.462L296.2 273.721C300.736 278.451 321.232 298.556 320.653 303.108C318.404 320.782 310.119 343.011 304.752 360.226L284.449 425.859C280.251 439.28 276.742 452.978 272.05 466.22C268.996 474.842 261.571 478.338 252.987 478.585C238.485 479.002 224.01 478.762 209.508 478.714L204.982 478.718C197.575 478.725 190.161 478.042 182.989 476.19C102.563 455.426 38.186 394.742 12.253 316.531C11.83 315.257 12.24 313.841 13.334 313.063C30.564 300.811 48.429 289.355 65.909 277.445L147.892 221.449C156.963 215.265 193.717 188.873 203.146 185.883C203.491 185.774 203.828 185.733 204.19 185.719Z",
"M359.851 317.674C395.834 318.328 431.967 317.504 467.903 319.104C471.83 319.278 473.933 323.314 472.527 326.984C444.534 400.033 382.487 456.22 305.815 476.116C304.77 476.387 303.666 476.4 302.634 476.084C297.638 474.555 298.51 463.131 299.94 458.269C306.046 437.525 313.37 416.584 319.998 395.954C327.865 372.764 333.684 348.353 343.444 325.993C345.338 321.703 352.295 318.695 356.982 317.804C357.915 317.723 358.908 317.658 359.851 317.674Z",
"M286.94 0.034C290.672 -0.021 294.41 0.313 298.052 1.131C398.453 23.686 475.481 108.032 487.107 212.139L487.113 217.057C487.118 233.871 487.195 250.751 487.041 267.582C486.619 271.276 486.115 274.945 485.53 278.588C484.981 282.003 484.216 285.703 481.471 287.808C470.697 296.07 444.296 292.401 431.051 291.904C418.809 291.739 405.061 291.155 392.617 290.565C379.651 289.355 360.244 291.052 348.127 286.836C340.538 284.194 324.77 266.569 318.856 260.411L281.456 221.011L253.182 191.745C219.616 157.422 225.399 161.507 236.172 115.655L250.938 52.176C253.497 41.478 255.484 30.53 258.274 19.83C262.966 1.832 269.489 0.655 286.94 0.034Z",
"M186.169 2.135C193.096 0.447 200.237 -0.29 207.355 0.105C210.724 0.292 214.132 0.6 217.667 1.102C232.243 3.174 231.637 13.23 228.972 25.463C222.338 55.917 215.835 86.031 208.244 116.341C206.177 124.595 204.273 136.482 200.977 146.243C198.842 152.564 194.814 158.036 189.617 162.219C181.702 168.59 171.16 175.241 164.418 179.847C152.693 188.025 140.886 196.086 129.001 204.03C115.353 213.808 22.96 279.899 15.721 280.673C12.219 281.046 7.929 279.11 5.322 276.891C2.366 274.376 1.755 270.201 1.335 266.343C0.645 260.009 0.197 253.603 0 247.134C0 240.28 0.2 233.4 0.22 226.644C5.907 117.446 83.279 27.221 186.169 2.135Z",
]

def clip(poly, nx, ny, c):
    """Keep the part of poly where nx*x + ny*y <= c."""
    out = []
    for i in range(len(poly)):
        a, b = poly[i], poly[(i + 1) % len(poly)]
        da, db = nx * a[0] + ny * a[1] - c, nx * b[0] + ny * b[1] - c
        if da <= 0: out.append(a)
        if (da < 0) != (db < 0) and da != db:
            t = da / (da - db)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out

def rounded(poly, radius):
    n = len(poly)
    d = ""
    for i in range(n):
        p0, p1, p2 = poly[i - 1], poly[i], poly[(i + 1) % n]
        def toward(p, q):
            L = math.hypot(q[0] - p[0], q[1] - p[1]) or 1
            r = min(radius, L * 0.45)
            return (p[0] + (q[0] - p[0]) * r / L, p[1] + (q[1] - p[1]) * r / L)
        a, b = toward(p1, p0), toward(p1, p2)
        d += ("M" if i == 0 else "L") + f"{a[0]:.1f} {a[1]:.1f}Q{p1[0]:.1f} {p1[1]:.1f} {b[0]:.1f} {b[1]:.1f}"
    return d + "Z"

def build(width, height, unit, reach, seed, color="#16151A", logo_color="#16151A", highlights=()):
    """unit: the logo's radius in px. reach: how far the pattern runs, in logo radii."""
    rnd = random.Random(seed)
    # A ring of hidden seeds just inside the logo keeps a round gap around it.
    seeds = [(0.8 * math.cos(a), 0.8 * math.sin(a)) for a in [i * math.tau / 20 for i in range(20)]]
    hidden = len(seeds)
    tries = 0
    while tries < 60000:
        tries += 1
        r = math.sqrt(rnd.uniform(1.45 ** 2, (reach + 0.6) ** 2)); a = rnd.uniform(0, math.tau)
        p = (r * math.cos(a), r * math.sin(a))
        # Cells shrink further out, so the pattern goes from bold at the logo to fine at the edge.
        need = max(0.36, 0.82 - 0.17 * (r - 1.4))
        if all(math.hypot(p[0] - q[0], p[1] - q[1]) >= need for q in seeds[hidden:]):
            seeds.append(p)
    cells = []
    for i in range(hidden, len(seeds)):
        s = seeds[i]
        r = math.hypot(*s)
        t = min(max((r - 1.4) / (reach - 1.4), 0), 1)          # 0 beside the logo, 1 at the edge
        if r > reach: continue
        # Holes: none close in, most cells missing at the edge.
        if rnd.random() < max(0, (t - 0.3) / 0.7) ** 1.4 * 0.9: continue
        gap = 0.085 + 0.05 * t                                    # the gaps widen a little as it thins out
        B = reach + 3
        poly = [(-B, -B), (B, -B), (B, B), (-B, B)]
        for j, q in enumerate(seeds):
            if j == i: continue
            dx, dy = q[0] - s[0], q[1] - s[1]
            L = math.hypot(dx, dy)
            if L > 6: continue
            nx, ny = dx / L, dy / L
            mid = nx * (s[0] + q[0]) / 2 + ny * (s[1] + q[1]) / 2
            poly = clip(poly, nx, ny, mid - gap / 2)
            if len(poly) < 3: break
        if len(poly) < 3: continue
        # Nothing pokes past the edge, so the outline stays round and ragged rather than cut flat.
        if max(math.hypot(*p) for p in poly) > reach: continue
        opacity = 0.2 * (1 - t) ** 1.2 + 0.03
        cells.append((poly, opacity, s))
    cx, cy = width / 2, height / 2
    # Highlights: (angle in degrees, ring distance, color). The nearest cell to each takes that color.
    tinted = {}
    for angle, distance, tint in highlights:
        target = (distance * math.cos(math.radians(angle)), distance * math.sin(math.radians(angle)))
        best = min(range(len(cells)), key=lambda k: math.hypot(cells[k][2][0] - target[0], cells[k][2][1] - target[1]))
        tinted[best] = tint
        poly = cells[best][0]
        mx = sum(p[0] for p in poly) / len(poly); my = sum(p[1] for p in poly) / len(poly)
        print(f"  {tint} centre at {cx + mx * unit:.0f},{cy + my * unit:.0f}")
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">']
    for index, (poly, opacity, _) in enumerate(cells):
        pts = [(cx + x * unit, cy + y * unit) for x, y in poly]
        if index in tinted:
            out.append(f'<path d="{rounded(pts, unit * 0.13)}" fill="{tinted[index]}"/>')
        else:
            out.append(f'<path d="{rounded(pts, unit * 0.13)}" fill="{color}" fill-opacity="{opacity:.3f}"/>')
    k = 2 * unit / 488
    out.append(f'<g transform="translate({cx - unit:.1f} {cy - 479 * k / 2:.1f}) scale({k:.4f})" fill="{logo_color}">')
    out += [f'<path d="{d}"/>' for d in LOGO]
    out.append('</g></svg>')
    return "\n".join(out)

if __name__ == "__main__":
    world = [(200, 1.9, "#4A55D8"), (330, 1.9, "#E8643A"), (90, 1.9, "#1F5E63")]
    open("membrane-hello.svg", "w").write(build(820, 250, 30, 4.1, seed=7))
    open("membrane-small.svg", "w").write(build(820, 170, 21, 3.95, seed=7))
    print("world"); open("membrane-world.svg", "w").write(build(820, 250, 30, 4.1, seed=7, highlights=world))
    open("membrane-square.svg", "w").write(build(900, 900, 70, 6.0, seed=3))
