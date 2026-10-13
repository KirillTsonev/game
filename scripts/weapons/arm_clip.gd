class_name ArmClip
extends RefCounted
## A first-person clip of the weapon arm: per frame, from the eyes and in the Player's axes
## (+X right, +Y up, -Z ahead), where the right shoulder, elbow and wrist are, how the hand is
## turned, and how the weapon lies in the hand. Made from a clip of another game's first-person
## arms by tools/skyrim_reference/export_arm_clip.py; PlayerBody solves the rogue's own arm to
## it every frame (WeaponHold.solve_arm), so the other skeleton never has to match the rogue's.

var length: float = 0.0
var fps: float = 30.0
var source: String = ""
var events: Array = [] ## [seconds, name] as the source clip has them
var _frames: Array = []

## null if the file is missing or not such a clip.
static func from_file(path: String) -> ArmClip:
	if not FileAccess.file_exists(path):
		return null
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary) or not (data as Dictionary).has("frames") or ((data as Dictionary)["frames"] as Array).is_empty():
		return null
	var clip := ArmClip.new()
	clip.fps = float(data.get("fps", 30.0))
	clip.source = String(data.get("source", ""))
	clip.events = data.get("events", [])
	for frame: Dictionary in data["frames"]:
		clip._frames.append({
			"shoulder": _vector(frame["shoulder"]), "elbow": _vector(frame["elbow"]), "wrist": _vector(frame["wrist"]),
			"hand": _basis(frame["hand"]).get_rotation_quaternion(), "grip": _basis(frame["grip"]).get_rotation_quaternion(), "grip_at": _vector(frame["grip_at"]),
		})
	clip.length = float(data.get("length", (clip._frames.size() - 1) / clip.fps))
	return clip

static func _vector(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

static func _basis(a: Array) -> Basis: # three columns
	return Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])).orthonormalized()

## The arm at a time in seconds (the clip goes round): "shoulder", "elbow", "wrist" (places from
## the eyes), "hand" (a Basis: -Z the way the fingers point, +Y the thumb's side, -X the palm's)
## and "grip" (a Transform3D in that hand's axes, from the wrist: +Y the blade, -Z the leading edge).
func sample(time: float) -> Dictionary:
	var at := fposmod(time, maxf(length, 0.001)) * fps
	var first := mini(int(at), _frames.size() - 1)
	var second := mini(first + 1, _frames.size() - 1)
	var part := at - first
	var a: Dictionary = _frames[first]
	var b: Dictionary = _frames[second]
	return {
		"shoulder": (a["shoulder"] as Vector3).lerp(b["shoulder"], part), "elbow": (a["elbow"] as Vector3).lerp(b["elbow"], part), "wrist": (a["wrist"] as Vector3).lerp(b["wrist"], part),
		"hand": Basis((a["hand"] as Quaternion).slerp(b["hand"], part)),
		"grip": Transform3D(Basis((a["grip"] as Quaternion).slerp(b["grip"], part)), (a["grip_at"] as Vector3).lerp(b["grip_at"], part)),
	}
