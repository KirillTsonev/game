# Turns one first-person Skyrim clip (.hkx) into an "arm clip" for PlayerBody: per frame, from
# the camera and in the Player's axes (+X right, +Y up, -Z ahead), where the right shoulder,
# elbow and wrist are, how the hand is turned, and how the weapon lies in the hand. The game
# solves the rogue's own arm to those (WeaponHold.solve_arm), so nothing of Skyrim's skeleton
# or rest pose has to match the rogue's.
#
#   python export_arm_clip.py <clip.hkx> <out.json> [<skeletonfirst.hkx>]
#
# The clips of the mod in raw-assets/animations/All in one ... may be converted with credit to
# their author (docs/weapons.md). Skyrim's own clips are Bethesda's: measure them, do not ship them.
import sys, os, json, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hkx import Skeleton, Animation, qrot

UNIT = 0.01428  # metres in one Skyrim unit
ROGUE_HAND = 0.0977  # the rogue's hand bone to its middle knuckle (m): the weapon's place in the hand is scaled by it


def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def scale(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def unit(a):
    n = math.sqrt(dot(a, a)) or 1.0
    return (a[0] / n, a[1] / n, a[2] / n)
def square_to(a, b):  # a with its part along b (unit) taken out
    return unit(sub(a, scale(b, dot(a, b))))
def player(v):  # Skyrim's (right, ahead, up) -> the Player's (right, up, back)
    return (v[0], v[2], -v[1])
def in_frame(frame, v):  # a vector in the axes of a frame given as three columns
    return (dot(frame[0], v), dot(frame[1], v), dot(frame[2], v))


def main(clip, out, skeleton_path):
    sk = Skeleton(skeleton_path)
    bone = lambda part: sk.index(part)
    names = dict(cam="Camera1st", hand="R Hand", fore="R Forearm [", upper="R UpperArm [", index="RF10", little="RF40", middle="RF20")
    b = {k: bone(v) for k, v in names.items()}
    b["weapon"] = [i for i, n in enumerate(sk.bones) if n == "Weapon"][0]
    anim = Animation(clip)

    # Which of the Weapon bone's axes is the leading edge: the one nearest the way the fingers
    # point, in the rest pose (the blade is its +Y: tools/skyrim_reference/measure.py).
    rest = sk.world(sk.rest)
    fingers_rest = unit(sub(rest[b["middle"]][0], rest[b["hand"]][0]))
    edge_axis, best = None, 0.0
    for axis in ((1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)):
        d = dot(qrot(rest[b["weapon"]][1], axis), fingers_rest)
        if d > best:
            edge_axis, best = axis, d
    hand_length = math.dist(rest[b["middle"]][0], rest[b["hand"]][0]) * UNIT

    frames = []
    for f in range(anim.frames):
        w = sk.world(anim.pose(sk, f))
        cam = w[b["cam"]][0]
        at = lambda key: player(scale(sub(w[b[key]][0], cam), UNIT))
        wrist = at("hand")
        fingers = unit(sub(at("middle"), wrist))
        thumb = square_to(sub(at("index"), at("little")), fingers)
        palm = cross(thumb, fingers)
        # The Hand marker's axes: -X the palm, +Y the thumb's side, -Z the fingers.
        marker = (scale(palm, -1.0), thumb, scale(fingers, -1.0))
        blade = unit(player(qrot(w[b["weapon"]][1], (0, 1, 0))))
        edge = square_to(player(qrot(w[b["weapon"]][1], edge_axis)), blade)
        # The Grip marker's axes: +Y the blade, -Z the leading edge.
        grip_z = scale(edge, -1.0)
        grip = (cross(blade, grip_z), blade, grip_z)
        frames.append({
            "shoulder": at("upper"), "elbow": at("fore"), "wrist": wrist,
            "hand": [c for column in marker for c in column],
            "grip": [c for column in grip for c in in_frame(marker, column)],
            "grip_at": scale(in_frame(marker, sub(at("weapon"), wrist)), ROGUE_HAND / hand_length),
        })
    data = {"source": os.path.basename(os.path.dirname(clip)) + "/" + os.path.basename(clip), "fps": round(1.0 / anim.frame_duration, 3), "length": anim.duration,
            "events": [[t, e] for t, e in anim.events], "frames": frames}
    with open(out, "w", newline="\n") as fh:
        json.dump(data, fh, separators=(",", ":"))
    first = frames[0]
    print("WROTE %s: %d frames, %.2f s, leading edge = Weapon bone's %s (%.2f along the fingers), their hand %.3f m to the knuckle" % (out, len(frames), anim.duration, edge_axis, best, hand_length))
    print("  frame 0: shoulder %s elbow %s wrist %s blade %s grip_at %s" % tuple(tuple(round(c, 3) for c in v) for v in (first["shoulder"], first["elbow"], first["wrist"], tuple(first["hand"][i] * first["grip"][3] + first["hand"][3 + i] * first["grip"][4] + first["hand"][6 + i] * first["grip"][5] for i in range(3)), first["grip_at"])))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "skeletonfirst.hkx"))
