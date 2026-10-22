# Where the sword hand and the blade are, from the first-person camera, through a clip.
# Skyrim's model space: +X the character's right, +Y ahead, +Z up; 1 unit = 1.428 cm.
import sys, math, os
from hkx import *

UNIT = 0.01428
MOD = r"D:\Downloads\Godot_v4.7.2-stable_win64.exe\raw-assets\animations\Skyrim - One handed sword\meshes\actors\character\_1stperson\animations\OpenAnimationReplacer\mod"
sk = Skeleton("meshes__actors__character___1stperson__characterassets__skeletonfirst.hkx")
B = {k: sk.index(v) for k, v in dict(cam="Camera1st", hand="R Hand", fore="R Forearm [", upper="R UpperArm [", clav="R Clavicle", index="RF10", little="RF40",
                                     middle="RF20", lhand="L Hand", shield="Shield", head="NPC Head [", spine2="Spine2").items()}
B["weapon"] = [i for i, n in enumerate(sk.bones) if n == "Weapon"][0]


def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def unit(a):
    n = math.sqrt(sum(c * c for c in a)) or 1.0
    return (a[0] / n, a[1] / n, a[2] / n)
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def fmt(v, scale=1.0): return "(%+.2f %+.2f %+.2f)" % (v[0] * scale, v[1] * scale, v[2] * scale)
def angles(v):  # in the picture: degrees right, degrees up (camera looking along +Y)
    return "%+4.0f/%+4.0f" % (math.degrees(math.atan2(v[0], v[1])), math.degrees(math.atan2(v[2], math.hypot(v[0], v[1]))))


def blade_axis():
    """Which of the Weapon bone's own axes the blade runs along: the one nearest the fist's
    thumb side (little knuckle to forefinger knuckle), in the rest pose."""
    w = sk.world(sk.rest)
    thumb = unit(sub(w[B["index"]][0], w[B["little"]][0]))
    best = None
    for i, axis in enumerate(((1, 0, 0), (0, 1, 0), (0, 0, 1))):
        d = dot(qrot(w[B["weapon"]][1], axis), thumb)
        if best is None or abs(d) > abs(best[1]):
            best = (axis, d, "xyz"[i])
    sign = 1 if best[1] > 0 else -1
    print("BLADE AXIS: the Weapon bone's %s%s (%.2f along the fist's thumb side); the other two: %s" % (
        "+" if sign > 0 else "-", best[2], abs(best[1]), [round(dot(qrot(w[B["weapon"]][1], a), thumb), 2) for a in ((1, 0, 0), (0, 1, 0), (0, 0, 1))]))
    return tuple(sign * c for c in best[0])


BLADE = blade_axis()
GUARD, TIP = 0.13, 0.947  # m from the grip's middle on our sword


def at(anim, frame):
    w = sk.world(anim.pose(sk, frame))
    cam = w[B["cam"]][0]
    rel = lambda k: tuple(c * UNIT for c in sub(w[B[k]][0], cam))
    blade = unit(qrot(w[B["weapon"]][1], BLADE))
    grip = rel("weapon")
    return dict(cam=cam, camq=w[B["cam"]][1], hand=rel("hand"), elbow=rel("fore"), shoulder=rel("upper"), grip=grip, blade=blade,
                guard=tuple(g + b * GUARD for g, b in zip(grip, blade)), tip=tuple(g + b * TIP for g, b in zip(grip, blade)),
                lhand=rel("lhand"), head=rel("head"),
                palm=unit(sub(w[B["middle"]][0], w[B["hand"]][0])))


def report(label, path, step=None, table=True):
    a = Animation(path)
    print("\n== %s: %.2f s, %d frames, events %s" % (label, a.duration, a.frames, [(t, e) for t, e in a.events if e and ("Hit" in e or "Swing" in e or "attackStop" in e or "Win" in e)]))
    rows = [at(a, f) for f in range(a.frames)]
    for key in ("grip", "shoulder", "elbow"):
        print("   %-8s from the camera (m: right, ahead, up): %s .. %s" % (key, fmt(tuple(min(r[key][i] for r in rows) for i in range(3))), fmt(tuple(max(r[key][i] for r in rows) for i in range(3)))))
    ups = [math.degrees(math.asin(max(-1, min(1, r["blade"][2])))) for r in rows]
    print("   blade above level %.0f .. %.0f deg; camera bone moves %.3f m, turns %.1f deg" % (min(ups), max(ups),
          max(math.dist(r["cam"], rows[0]["cam"]) for r in rows) * UNIT, max(2 * math.degrees(math.acos(min(1.0, abs(dot(r["camq"], rows[0]["camq"]))))) for r in rows)))
    if not table:
        r = rows[0]
        print("   frame 0: grip %s blade %s (right, ahead, up) | picture right/up: guard %s tip %s | left hand %s" % (fmt(r["grip"]), fmt(r["blade"]), angles(r["guard"]), angles(r["tip"]), fmt(r["lhand"])))
        return
    step = step or max(1, a.frames // 22)
    speed = [0.0] + [math.dist(rows[i]["tip"], rows[i - 1]["tip"]) / a.frame_duration for i in range(1, len(rows))]
    print("   time   grip (right ahead up)   blade direction        guard r/u  middle r/u  tip r/u   tip speed m/s  elbow deg")
    for f in range(0, a.frames, step):
        r = rows[f]
        mid = tuple(g + b * 0.55 for g, b in zip(r["grip"], r["blade"]))
        elbow = math.degrees(math.acos(max(-1, min(1, dot(unit(sub(r["shoulder"], r["elbow"])), unit(sub(r["hand"], r["elbow"])))))))
        print("   %.2f  %s  %s  %s  %s  %s  %6.1f  %5.0f" % (f * a.frame_duration, fmt(r["grip"]), fmt(r["blade"]), angles(r["guard"]), angles(mid), angles(r["tip"]), speed[f], elbow))


V = "meshes__actors__character___1stperson__animations__"
report("VANILLA idle", V + "1hm_idle.hkx", table=False)
report("VANILLA attack right", V + "1hm_attackright.hkx")
for stance in ("S_M", "S_H", "S_L", "S_N"):
    report("MOD %s idle" % stance, os.path.join(MOD, stance, "1hm_idle.hkx"), table=False)
report("MOD S_M run forward", os.path.join(MOD, "S_M", "1hm_runforward.hkx"), table=False)
report("MOD S_M attack right", os.path.join(MOD, "S_M", "1hm_attackright.hkx"))
report("MOD S_M_C attack right, combat variant", os.path.join(MOD, "S_M_C", "_variants_1hm_attackright", "1hm_attackright_combat.hkx"))
report("MOD S_M_C attack left", os.path.join(MOD, "S_M_C", "_variants_1hm_attackleft", "1hm_attackleft.hkx"))
report("MOD S_M_P power attack", os.path.join(MOD, "S_M_P", "1hm_attackpower.hkx"))
