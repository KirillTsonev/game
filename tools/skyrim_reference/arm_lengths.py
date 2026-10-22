# How long the first-person right arm is through a clip of the Stances mod, frame by frame:
# shoulder (R UpperArm) to elbow (R Forearm), elbow to wrist (R Hand), wrist to the middle knuckle,
# shoulder to the weapon's grip -- to see whether a clip stretches the arm, and how its arm
# compares with ours (tools/weapon_probes/stance_numbers.gd prints ours).
#
#   python arm_lengths.py <clip path relative to the mod folder> [...]
import sys, os, math
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hkx import Skeleton, Animation
import attack_analysis as aa  # MOD, DEFAULT_SKELETON, UNIT

def main():
    sk = Skeleton(aa.DEFAULT_SKELETON)
    b = {k: sk.index(v) for k, v in dict(cam="Camera1st", upper="R UpperArm [", fore="R Forearm [", hand="R Hand", middle="RF20").items()}
    b["weapon"] = [i for i, n in enumerate(sk.bones) if n == "Weapon"][0]
    rest = sk.world(sk.rest)
    d = lambda w, x, y: math.dist(w[b[x]][0], w[b[y]][0]) * aa.UNIT
    print("REST: upper %.3f  forearm %.3f  hand %.3f  (m)" % (d(rest, "upper", "fore"), d(rest, "fore", "hand"), d(rest, "hand", "middle")))
    for rel in sys.argv[1:]:
        anim = Animation(os.path.join(aa.MOD, rel))
        rows = []
        for f in range(anim.frames):
            w = sk.world(anim.pose(sk, f))
            rows.append((f * anim.frame_duration, d(w, "upper", "fore"), d(w, "fore", "hand"), d(w, "hand", "middle"), d(w, "upper", "weapon")))
        print("\n== %s  %.2f s" % (rel, anim.duration))
        for i, name in ((1, "upper arm"), (2, "forearm"), (3, "hand"), (4, "shoulder-grip")):
            vals = [r[i] for r in rows]
            print("   %-13s %.3f .. %.3f m" % (name, min(vals), max(vals)))
        print("   time  upper  forearm  hand  shoulder-grip")
        for r in rows[::3]:
            print("   %.2f  %.3f  %.3f    %.3f  %.3f" % r)

main()
