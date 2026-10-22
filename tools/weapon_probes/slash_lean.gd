extends SceneTree
# The swings' lean (PlayerBody.swing_lean_range, SWINGS "lean" / "lean_at"): plays each swing that
# has a "lean" at a row of leans, at 60 frames a second, looking level, and prints for each where
# the sword's tip crosses the picture's top edge, the middle's height and the bottom edge (degrees
# right of the middle), the lean of the line from the top crossing to the bottom one (+ = its top
# right), how far the tip strays from that line on the way (degrees), and how far the tip is at
# the swing's start and end from where it is unturned (m; the idle hold must not be tilted).
# The view's own nod / tilt during a swing (swing_head_follow) is left out, as in combat.gd.
# Run: Godot_v4.7.2-stable_win64_console.exe --headless --path herald-of-oblivion --script res://tools/weapon_probes/slash_lean.gd
# -- --leans=<deg>,<deg>,...: the leans tried (default -20,-10,0,10,20). -- --only=<text>: swings whose name contains it.
var player: Node3D
var body: PlayerBody
var sword_mesh: MeshInstance3D
var tip_local := Vector3.ZERO
var overreach := 0.0 ## the swing's wrist past the arm's reach at most (m)

const HALF_HIGH := 0.7673 # tan(37.5 deg): the picture is 75 deg high
const HALF_WIDE := 0.7673 * 16.0 / 9.0

func _init() -> void:
	_run.call_deferred()

func step() -> void:
	body.set_motion(Vector3.ZERO, true, false, false, 1.0 / 60.0)
	body.advance(1.0 / 60.0, 0.0)

## The tip from the eyes, the Player's axes (+X right, +Y up, -Z ahead).
func tip_seen() -> Vector3:
	var eye: Vector3 = body.get("_eye")
	return player.global_transform.affine_inverse() * (sword_mesh.global_transform * tip_local) - eye

## Plays `swing` turned to `lean`; returns the tip's place every frame.
func play(swing: StringName, lean: float) -> Array[Vector3]:
	body.call("_start_swing", swing, false)
	body.set("_swing_turn", lean - float((PlayerBody.SWINGS[swing] as Dictionary)["lean"]))
	var path: Array[Vector3] = [tip_seen()]
	overreach = 0.0
	for i in int(float((PlayerBody.SWINGS[swing] as Dictionary)["time"]) * 60.0) + 2:
		step()
		path.append(tip_seen())
		overreach = maxf(overreach, body.get("_swing_overreach") as float)
	for i in 30:
		step()
	return path

## Where the screen path crosses height `h` going down (screen units: x / -z): its x, or NAN.
static func crossing(screen: Array[Vector2], h: float) -> float:
	for i in range(1, screen.size()):
		var a := screen[i - 1]
		var b := screen[i]
		if a.y >= h and b.y < h:
			return lerpf(a.x, b.x, (a.y - h) / (a.y - b.y))
	return NAN

func _run() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Node3D
	root.add_child(player)
	body = player.get_node("Body") as PlayerBody
	player.set_physics_process(false)
	player.set_process(false)
	await process_frame
	body.fidgets_on = false
	var leans: Array[float] = [-20.0, -10.0, 0.0, 10.0, 20.0]
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--leans="):
			leans.clear()
			for v in arg.trim_prefix("--leans=").split(","):
				leans.append(v.to_float())
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	sword_mesh = (body.get("_weapon_node") as Node3D).find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	# The tip: the mesh's vertex furthest from its origin.
	var verts: PackedVector3Array = sword_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for v in verts:
		if v.length() > tip_local.length():
			tip_local = v
	body.weapon_raised = true
	body.set("_idle_mirrored", false)
	for i in 150:
		step()
	for swing: StringName in PlayerBody.SWINGS:
		if not (PlayerBody.SWINGS[swing] as Dictionary).has("lean") or (only != "" and not String(swing).contains(only)):
			continue
		var as_made := play(swing, float((PlayerBody.SWINGS[swing] as Dictionary)["lean"]))
		for lean in leans:
			var path := play(swing, lean)
			var screen: Array[Vector2] = []
			for p in path:
				screen.append(Vector2(p.x / -p.z, p.y / -p.z) if p.z < -0.05 else Vector2(NAN, 9.0))
			var top := crossing(screen, HALF_HIGH)
			var mid := crossing(screen, 0.0)
			var bottom := crossing(screen, -HALF_HIGH)
			var measured := rad_to_deg(atan2(top - bottom, 2.0 * HALF_HIGH))
			# The largest distance of the tip from the line top -> bottom while in the picture.
			var a := Vector2(top, HALF_HIGH)
			var along := (Vector2(bottom, -HALF_HIGH) - a).normalized()
			var stray := 0.0
			var going := false
			for s in screen:
				if is_nan(s.x):
					continue
				if s.y < HALF_HIGH and s.y > -HALF_HIGH and absf(s.x) < HALF_WIDE:
					going = true
					var off := (s - a) - along * (s - a).dot(along)
					stray = maxf(stray, rad_to_deg(atan(off.length())))
				elif going and s.y <= -HALF_HIGH:
					break
			var n := mini(as_made.size(), path.size())
			print("LEAN %s at %+.0f deg: crosses the top %+.1f deg, the middle's height %+.1f deg, the bottom %+.1f deg; the line leans %+.1f deg; the tip strays at most %.1f deg from it; start / end %.3f / %.3f m from unturned; the wrist at most %.3f m past reach"
					% [swing, lean, rad_to_deg(atan(top)), rad_to_deg(atan(mid)), rad_to_deg(atan(bottom)), measured, stray,
					path[0].distance_to(as_made[0]), path[n - 1].distance_to(as_made[n - 1]), overreach])
	quit()
