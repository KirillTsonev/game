# What makes the Stances mod's (raw-assets/animations/Skyrim - One handed sword) first-person sword attacks
# read as cuts: per clip, each stroke (a run of frames where the tip moves at 25 % or more of the
# clip's fastest), measured from the first-person camera in Skyrim's model axes (+X right, +Y ahead,
# +Z up; 1 unit = 1.428 cm). Directions and speeds only matter: the first-person arms stretch.
#
#   python attack_analysis.py [--table <substring of a clip path>] [--skeleton <skeletonfirst.hkx>]
#
# Per stroke:
#   time        start-end (s), its fastest moment, the tip's top speed (m/s, for a 0.95 m blade)
#   tip         where the tip is in the picture at start -> fastest -> end (deg right / up)
#   sweep       how far the blade turns over the stroke (deg), and the plane it turns in:
#               "tilt" 0 = a level cut, 90 = straight up/down; "falls" the way the tip goes down
#   edge        speed-weighted mean of how the blade meets the way it moves: +1 = the true edge
#               leads (the one facing the fingers' side), -1 the back edge, 0 the FLAT (a slap)
#   draw        speed-weighted share of the tip's speed along the blade (a slicing draw)
#   pivot       where the blade turns about, from the grip along the blade (m): about 0 = at the
#               hand (wrist and forearm), below 0 = behind it (elbow, shoulder), above = in the blade
#   hand/tip    the grip's travel against the tip's (m)
#   forearm     the blade's angle to the forearm at the fastest moment (deg; 90 = square to it)
#   wrist       the blade's turn relative to the forearm over the stroke (deg)
import sys, os, math, glob
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hkx import Skeleton, Animation, qrot

UNIT = 0.01428
BLADE = 0.95
MOD = os.path.normpath(os.path.join(HERE, "..", "..", "..", "raw-assets", "animations", "Skyrim - One handed sword", "meshes", "actors", "character", "_1stperson", "animations", "OpenAnimationReplacer", "mod"))
DEFAULT_SKELETON = r"C:\Users\Kirill\AppData\Local\Temp\claude\d--Downloads-Godot-v4-7-2-stable-win64-exe-herald-of-oblivion\92f90b49-4a38-4bc1-8246-353b8799566a\scratchpad\skyrim\meshes__actors__character___1stperson__characterassets__skeletonfirst.hkx"

def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def mul(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def length(a): return math.sqrt(dot(a, a))
def unit(a):
    n = length(a) or 1.0
    return (a[0] / n, a[1] / n, a[2] / n)
def angle(a, b): return math.degrees(math.acos(max(-1.0, min(1.0, dot(unit(a), unit(b))))))
def view(v): return "%+4.0f/%+4.0f" % (math.degrees(math.atan2(v[0], v[1])), math.degrees(math.atan2(v[2], math.hypot(v[0], v[1]))))

def frames_of(sk, b, edge_axis, path):
    anim = Animation(path)
    out = []
    for f in range(anim.frames):
        w = sk.world(anim.pose(sk, f))
        cam = w[b["cam"]][0]
        at = lambda k: mul(sub(w[b[k]][0], cam), UNIT)
        grip = at("weapon")
        blade = unit(qrot(w[b["weapon"]][1], (0, 1, 0)))
        edge = qrot(w[b["weapon"]][1], edge_axis)
        edge = unit(sub(edge, mul(blade, dot(edge, blade))))
        out.append(dict(grip=grip, blade=blade, edge=edge, tip=add(grip, mul(blade, BLADE)), hand=at("hand"), fore=at("fore"), upper=at("upper")))
    return anim, out

class Loaded:  # a swing of ours, dumped by tools/weapon_probes/combat.gd -- --dump=<file>
    def __init__(self, data):
        self.frame_duration = data["dt"]
        self.frames = len(data["frames"])
        self.duration = self.frames * self.frame_duration
        self.events = []

def analyse(sk, b, edge_axis, path, table, ours=None):
    if ours is not None:
        anim = Loaded(ours)
        fr = [dict(grip=tuple(f["grip"]), blade=unit(tuple(f["blade"])), edge=unit(tuple(f["edge"])), hand=tuple(f["hand"]), fore=tuple(f["fore"]), upper=tuple(f["upper"])) for f in ours["frames"]]
        for f in fr:
            f["tip"] = add(f["grip"], mul(f["blade"], BLADE))
    else:
        anim, fr = frames_of(sk, b, edge_axis, path)
    dt = anim.frame_duration
    n = len(fr)
    for i in range(n):
        j0, j1 = max(i - 1, 0), min(i + 1, n - 1)
        span = (j1 - j0) * dt or dt
        fr[i]["vt"] = mul(sub(fr[j1]["tip"], fr[j0]["tip"]), 1.0 / span)
        fr[i]["vg"] = mul(sub(fr[j1]["grip"], fr[j0]["grip"]), 1.0 / span)
        fr[i]["speed"] = length(fr[i]["vt"])
    top = max(f["speed"] for f in fr) or 1.0
    name = path if ours is not None else os.path.relpath(path, MOD)
    hits = [(round(t, 2), e) for t, e in anim.events if e in ("HitFrame", "WeaponSwing", "preHitFrame")]
    print("\n== %s  %.2f s  top %.1f m/s  events %s" % (name, anim.duration, top, hits))
    # strokes: runs at >= 25 % of the top speed, split where it dips below that
    strokes, start = [], None
    for i in range(n):
        fast = fr[i]["speed"] >= 0.25 * top
        if fast and start is None:
            start = i
        if (not fast or i == n - 1) and start is not None:
            end = i if fast else i - 1
            if end - start >= 2:
                strokes.append((start, end))
            start = None
    for s, e in strokes:
        peak = max(range(s, e + 1), key=lambda i: fr[i]["speed"])
        wsum = edge_sum = draw_sum = piv_sum = piv_w = 0.0
        sweep = 0.0
        for i in range(s, e + 1):
            f = fr[i]
            v = f["vt"]
            sp = f["speed"]
            perp = sub(v, mul(f["blade"], dot(v, f["blade"])))
            if length(perp) > 1e-6:
                edge_sum += dot(f["edge"], unit(perp)) * sp
            draw_sum += abs(dot(v, f["blade"])) * sp / max(sp, 1e-6)
            wsum += sp
            # pivot along the blade: the point of the blade line whose velocity across it is zero
            d = unit(perp) if length(perp) > 1e-6 else (0, 0, 0)
            vg = dot(f["vg"], d)
            vt = dot(v, d)
            if abs(vt - vg) > 0.5:
                piv_sum += (-BLADE * vg / (vt - vg)) * sp
                piv_w += sp
            if i > s:
                sweep += angle(fr[i - 1]["blade"], f["blade"])
        normal = cross(fr[s]["blade"], fr[e]["blade"])
        tilt = math.degrees(math.asin(min(1.0, abs(dot(unit(normal), (0, 0, 1)))))) if length(normal) > 1e-6 else 0.0
        tilt = 90.0 - tilt
        falls = fr[e]["tip"][2] - fr[s]["tip"][2]
        hand_travel = sum(length(sub(fr[i]["grip"], fr[i - 1]["grip"])) for i in range(s + 1, e + 1))
        tip_travel = sum(length(sub(fr[i]["tip"], fr[i - 1]["tip"])) for i in range(s + 1, e + 1))
        fa = lambda i: angle(sub(fr[i]["hand"], fr[i]["fore"]), fr[i]["blade"])
        wrist_turn = abs(fa(e) - fa(s))
        print("   stroke %.2f-%.2f (fastest %.2f, %.1f m/s): tip %s -> %s -> %s | sweep %3.0f deg, tilt %2.0f, tip %s %.2f m | edge %+.2f draw %.2f pivot %+.2f m | hand %.2f / tip %.2f m | forearm %3.0f deg, wrist turn %3.0f" % (
            s * dt, e * dt, peak * dt, fr[peak]["speed"], view(fr[s]["tip"]), view(fr[peak]["tip"]), view(fr[e]["tip"]), sweep, tilt,
            "falls" if falls < 0 else "rises", abs(falls), edge_sum / max(wsum, 1e-6), draw_sum / max(wsum, 1e-6), piv_sum / max(piv_w, 1e-6),
            hand_travel, tip_travel, fa(peak), wrist_turn))
    if table and table in name:
        print("   time  grip (r a u)          tip view   blade dir             speed  edge  pivot  forearm")
        for i in range(0, n, 2):
            f = fr[i]
            v = f["vt"]
            perp = sub(v, mul(f["blade"], dot(v, f["blade"])))
            al = dot(f["edge"], unit(perp)) if length(perp) > 1e-6 else 0.0
            d = unit(perp) if length(perp) > 1e-6 else (0, 0, 0)
            vg, vt = dot(f["vg"], d), dot(v, d)
            piv = -BLADE * vg / (vt - vg) if abs(vt - vg) > 0.5 else float("nan")
            print("   %.2f  (%+.2f %+.2f %+.2f)  %s  (%+.2f %+.2f %+.2f)  %5.1f  %+.2f  %+5.2f  %3.0f" % (i * dt, f["grip"][0], f["grip"][1], f["grip"][2], view(f["tip"]), f["blade"][0], f["blade"][1], f["blade"][2], f["speed"], al, piv, angle(sub(f["hand"], f["fore"]), f["blade"])))

def main():
    args = sys.argv[1:]
    table = args[args.index("--table") + 1] if "--table" in args else None
    skeleton = args[args.index("--skeleton") + 1] if "--skeleton" in args else DEFAULT_SKELETON
    sk = Skeleton(skeleton)
    b = {k: sk.index(v) for k, v in dict(cam="Camera1st", hand="R Hand", fore="R Forearm [", upper="R UpperArm [", middle="RF20").items()}
    b["weapon"] = [i for i, nm in enumerate(sk.bones) if nm == "Weapon"][0]
    rest = sk.world(sk.rest)
    fingers = unit(sub(rest[b["middle"]][0], rest[b["hand"]][0]))
    edge_axis, best = None, -2.0
    for axis in ((1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)):
        d = dot(qrot(rest[b["weapon"]][1], axis), fingers)
        if d > best:
            edge_axis, best = axis, d
    print("true edge = the Weapon bone's %s (%.2f along the fingers)" % (edge_axis, best))
    # The hold at rest, for comparing the blade-to-forearm angle and the edge's way.
    for idle in ("S_N", "S_M", "S_H", "S_L"):
        p = os.path.join(MOD, idle, "1hm_idle.hkx")
        if os.path.exists(p):
            _, fr = frames_of(sk, b, edge_axis, p)
            f = fr[0]
            print("IDLE %s: grip (%+.2f %+.2f %+.2f) blade (%+.2f %+.2f %+.2f) true edge (%+.2f %+.2f %+.2f) tip %s, blade to forearm %.0f deg" % ((idle,) + f["grip"] + f["blade"] + f["edge"] + (view(f["tip"]), angle(sub(f["hand"], f["fore"]), f["blade"]))))
    if "--ours" in args:
        import json
        with open(args[args.index("--ours") + 1]) as fh:
            for swing in json.load(fh):
                analyse(sk, b, edge_axis, "OURS " + swing["name"], table, swing)
        return
    clips = []
    for stance in ("S_N_C", "S_L_C", "S_M", "S_M_C", "S_H_C"):
        clips += sorted(p for p in glob.glob(os.path.join(MOD, stance, "**", "1hm_attack*.hkx"), recursive=True))
    clips += sorted(glob.glob(os.path.join(MOD, "S_M_P", "1hm_attack*.hkx")))
    for path in clips:
        analyse(sk, b, edge_axis, path, table)

if __name__ == "__main__":
    main()
