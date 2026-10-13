@tool
class_name WeaponStance
extends Node3D
## How the right arm holds a weapon while no clip poses it, SET BY HAND IN THE EDITOR. A direct
## child of a body (a node with a `weapon` property and a humanoid Skeleton3D below it). THIS
## NODE ITSELF STANDS WHERE THE EYES ARE: its markers are places from the eyes, so the stance
## keeps its place in the picture whatever the body's clip does. Leave the node where it is and
## unturned; move its children:
##
##   Shoulder  where the shoulder is put (the upper arm's bone is moved there bodily: on the
##             body it is 0.36 m behind the eyes, too far back to hold a weapon in view).
##             THE HAND LEADS: dragged further from the shoulder than the arm reaches, it
##             draws the shoulder after it, and this marker follows when the mouse is let go.
##   Hand      where the middle of the fist is held, AND HOW THE HAND IS TURNED: rotate the
##             marker (its -Z is the way the fingers point, +Y the thumb's side, -X the way the
##             palm faces). The forearm rolls and the wrist bends to suit.
##   Elbow     the elbow. Dragged in the editor it carries the forearm along: the Hand marker
##             moves by as much, unturned, and the shoulder comes after at the upper arm's
##             length. (Kirill: "pushing the elbow should push the hand as well ... along the z
##             axis not rotate it".) To the game it is only the side the elbow bends to.
##   Hand/Grip how the weapon sits in the hand: move and rotate it and the weapon moves in the
##             fist while the hand stays. Its +Y is the way the blade runs, its -Z the way the
##             leading edge faces; unmoved and unturned the handle lies square in the fist
##             (blade out of the thumb's side, edge toward the knuckles).
##
## Drag the markers in the 3D view: the editor shows the arm solved to them, the fist closed
## and the body's weapon in it, with the same code the game runs (WeaponHold.solve_arm).
##
## THE FINGERS: under Fingers there is one small marker on each of the right hand's fifteen
## finger joints, named as the joint (IndexProximal is the forefinger's knuckle, and so on).
## Select one and ROTATE it: the joint turns with it. Or MOVE it: the part of the finger that
## ends at it swings to point there (the joint before it turns; the marker stays at the bone's
## length, so it follows the mouse only in direction). A knuckle is part of the hand and
## cannot go anywhere, so dragging a FIRST joint's marker swings the finger from it instead, by
## as much as the drag would move its next joint; the marker goes back when the mouse is let
## go. The fifteen turns are kept in `finger_pose`; until one is changed the fist is the plain
## one WeaponHold works out. (Godot's own bone tool also works,
## on Rogue/GeneralSkeleton, but only through numbers in the Inspector: Kirill wanted gizmos.)
##
## Nothing of the shown pose is saved with the scene (the skeleton is put back to rest for the
## moment of saving); the markers' places and `finger_pose` are, and the game reads them every
## frame (so they can also be changed in the Remote tree while it runs).
##
## The first values were the "neutral" stance of the Skyrim mod measured in docs/weapons.md.

## Which arm this stance is for. For the LEFT the Hand marker is the mirror image: its +X is
## the way the palm faces (unturned: fingers ahead, thumb up, palm to the right, inward).
@export_enum("Right", "Left") var side: String = "Right"
## The body's property with the WeaponData this arm holds: `weapon`, or `shield` for the node
## that stands for the shield arm. For what is carried on the forearm (WeaponData.on_forearm,
## a shield) the Hand/Grip marker works as for a weapon -- move and rotate it and the shield
## moves on the arm by as much, about the fist, while the arm stays -- only its own axes mean
## nothing: unmoved and unturned the shield sits on the forearm as its data says.
@export var holds: StringName = &"weapon"
## Editor only. Off: the body in its rest pose and no weapon shown.
@export var preview: bool = true
## The furthest the fist is held from the shoulder (m). The arm is 0.56 m long.
@export_range(0.2, 0.56, 0.005) var max_reach: float = 0.54
## The right hand's fifteen finger joints as posed in the editor (each bone's own rotation):
## thumb, forefinger, middle, ring, little finger, three joints each from the hand outward.
## Empty: the plain fist.
@export var finger_pose: Array[Quaternion] = []
## Back to the plain fist.
@export_tool_button("Reset the fingers to the plain fist") var reset_fingers: Callable:
	get: return _reset_fingers # read each time: a script reloaded in the open editor leaves a plain value empty
## FIT THE HAND TO THE SWORD: the weapon stays exactly where it is shown, and the arm is found
## anew behind it -- the handle laid across the palm as a hand holds one (the Grip marker back
## to the plain grip, the Hand marker turned to suit), then the elbow and the shoulder put where
## the wrist bends least and the shoulder is nearest the body's own, within what a wrist, a
## forearm and an elbow do (FIT_* below). The fingers go back to the plain fist. What it found
## is printed to the Output panel. (For a weapon placed by turning the hand and then the weapon
## in the hand, which leaves the hand with whatever turn was over.)
@export_tool_button("Fit the hand to the sword") var fit_hand: Callable:
	get: return _fit_pressed # read each time: a script reloaded in the open editor leaves a plain value empty
## The markers and fingers as they were before the last fit; pressed again, the fit before that (kept until the scene is closed).
@export_tool_button("Put back the stance from before the fit") var unfit_hand: Callable:
	get: return _put_back_before_fit # read each time: a script reloaded in the open editor leaves a plain value empty
## Where the body's own right shoulder is from the eyes, standing in the game (measured on the
## rogue in its idle: +X right, +Y up, +Z behind). The fit keeps the placed shoulder as near
## it as it can, and reports how far off it still is.
@export var body_shoulder: Vector3 = Vector3(0.085, -0.144, 0.359)

## A socket's axes (+X the leading edge, +Y the blade) in the Grip marker's (-Z, +Y).
const SOCKET_IN_GRIP := Basis(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0), Vector3(1.0, 0.0, 0.0))
## What the fit allows (degrees): the wrist bent toward the palm or the back of the hand, toward
## the thumb, toward the little finger; the forearm rolled either way from thumb-up; the elbow's
## bend (0 = straight). Well inside what a joint can do, so that the hold looks at ease.
const FIT_WRIST_FLEX := 45.0
const FIT_WRIST_TO_THUMB := 15.0
const FIT_WRIST_TO_LITTLE := 30.0
const FIT_FOREARM_ROLL := 80.0
const FIT_ELBOW_BEND := Vector2(35.0, 140.0)
## How much a wrist bent to its allowance counts against the fit, as metres of shoulder off the body.
const FIT_WRIST_WEIGHT := 0.25
var _before_fit: Array[Dictionary] = [] ## the stance before each fit made since the scene was opened, oldest first
var _skeleton: Skeleton3D
var _shown: Array = []
var _preview: Node3D
var _finger_bones: PackedInt32Array = []
var _finger_bones_of: Skeleton3D
var _fingers_put: Array[Quaternion] = [] ## the joints as this script last set them: anything else was posed by hand
var _joints_put: Array[Transform3D] = [] ## where this script last put the Fingers markers: one turned since was turned by hand
var _first_joint_drag: Dictionary = {} ## a first joint's marker being dragged -> how far off its joint it was last frame
var _elbow_seen: Vector3 = Vector3.ZERO ## where the Elbow marker was last frame
var _elbow_tracked: bool = false ## _elbow_seen holds a place (false is also what a reloaded script starts with)

func _ready() -> void:
	if not Engine.is_editor_hint():
		set_process(false)

func _notification(what: int) -> void:
	if what != NOTIFICATION_EDITOR_PRE_SAVE or not Engine.is_editor_hint() or _skeleton == null or not is_instance_valid(_skeleton):
		return
	# The shown pose is not the scene's: keep what was posed by hand, then let this arm be
	# saved at rest. The next frame shows the hold again. ONLY THIS STANCE'S OWN ARM: with a
	# second stance node for the other arm, the first to be told of the save reset the whole
	# skeleton, and the second then took the other hand's rest pose for fingers posed by hand
	# and kept that -- every save (F5 saves too) opened the shield hand (Kirill, 2026-10-13).
	_keep_posed_fingers()
	_reset_own_arm()
	_shown = []
	_fingers_put = []
	_joints_put = []

func _place(marker: String) -> Vector3:
	var node := get_node_or_null(marker) as Node3D
	return node.position if node else Vector3.ZERO

## The fist's place, the shoulder's, from the eyes; and the side the elbow goes to.
func hand_from_eyes() -> Vector3:
	return _place("Hand")

func shoulder_from_eyes() -> Vector3:
	return _place("Shoulder")

func elbow_toward() -> Vector3:
	return _place("Elbow") - _place("Shoulder")

## How the hand is turned: the Hand marker's rotation (see the header).
func hand_turn() -> Basis:
	var node := get_node_or_null("Hand") as Node3D
	return node.basis.orthonormalized() if node else Basis.IDENTITY

## The middle of the closed fist in the hand bone's axes, for a handle of this thickness: the
## point of the hand that is held at the Hand marker.
func fist_in_hand(skeleton: Skeleton3D, grip_radius: float) -> Vector3:
	return WeaponHold.socket(skeleton, side, grip_radius, 0.0).origin

## Where the weapon's grip goes in the hand bone's axes: the fist's middle, moved and turned as
## the Hand/Grip marker is in the Hand marker.
func socket(skeleton: Skeleton3D, grip_radius: float) -> Transform3D:
	var grip := get_node_or_null("Hand/Grip") as Node3D
	if grip == null:
		return WeaponHold.socket(skeleton, side, grip_radius)
	var axes := WeaponHold.hand_axes(skeleton, side)
	# The Hand marker's axes in the hand bone's: -X the palm (+X on the left hand), +Y the
	# thumb's side, -Z the fingers.
	var palm_side := -1.0 if (axes["fingers_out"] as Vector3).cross(axes["palm_out"] as Vector3).dot(axes["thumb_side"] as Vector3) > 0.0 else 1.0
	var marker := Basis((axes["palm_out"] as Vector3) * palm_side, axes["thumb_side"] as Vector3, -(axes["fingers_out"] as Vector3))
	return Transform3D(marker * grip.basis.orthonormalized() * SOCKET_IN_GRIP, fist_in_hand(skeleton, grip_radius) + marker * grip.position)

## For what is carried on the forearm: where it sits in the LOWER ARM bone's axes, with the
## arm AS IT IS POSED JUST NOW (call it right after pose()). It is the forearm's own socket
## (WeaponHold.forearm_socket), moved and turned as the Hand/Grip marker is in the Hand marker:
## the marker's move is the shield's move in the picture, and its turn a turn about the fist.
func forearm_socket(skeleton: Skeleton3D, grip_radius: float) -> Transform3D:
	var plain := WeaponHold.forearm_socket(skeleton, side)
	var grip := get_node_or_null("Hand/Grip") as Node3D
	if grip == null or grip.transform.is_equal_approx(Transform3D.IDENTITY):
		return plain
	var axes := WeaponHold.hand_axes(skeleton, side)
	var palm_side := -1.0 if (axes["fingers_out"] as Vector3).cross(axes["palm_out"] as Vector3).dot(axes["thumb_side"] as Vector3) > 0.0 else 1.0
	var hand := skeleton.get_bone_global_pose(skeleton.find_bone(side + "Hand"))
	var lower := skeleton.get_bone_global_pose(skeleton.find_bone(side + "LowerArm"))
	# The Hand marker's axes in the skeleton's space, and the fist's middle there.
	var marker := hand.basis.orthonormalized() * Basis((axes["palm_out"] as Vector3) * palm_side, axes["thumb_side"] as Vector3, -(axes["fingers_out"] as Vector3))
	var fist := hand * fist_in_hand(skeleton, grip_radius)
	var turn := marker * grip.basis.orthonormalized() * marker.inverse()
	var moved := Transform3D(turn, fist - turn * fist + marker * grip.position)
	return lower.affine_inverse() * moved * lower * plain

## Poses the arm (not the fingers) outright. `eye` and the stance are in the space that
## `to_skeleton` brings into the skeleton's.
func pose(skeleton: Skeleton3D, to_skeleton: Transform3D, eye: Vector3, grip_in_hand: Vector3) -> void:
	WeaponHold.solve_arm(skeleton, side, to_skeleton, eye + shoulder_from_eyes(), eye + hand_from_eyes(), elbow_toward(), hand_turn(), grip_in_hand, max_reach)

## The right hand's finger joints, in the order of finger_pose.
func finger_bones(skeleton: Skeleton3D) -> PackedInt32Array:
	if _finger_bones_of != skeleton or _finger_bones.is_empty():
		_finger_bones = PackedInt32Array()
		for finger: String in WeaponHold.FINGERS:
			for joint: String in (["Metacarpal", "Proximal", "Distal"] if finger == "Thumb" else ["Proximal", "Intermediate", "Distal"]):
				_finger_bones.append(skeleton.find_bone(side + finger + joint))
		_finger_bones_of = skeleton
	return _finger_bones

## Closes the fingers round a handle of this thickness, outright: as posed in the editor, or
## the plain fist where nothing was.
func pose_fingers(skeleton: Skeleton3D, grip_radius: float) -> void:
	var bones := finger_bones(skeleton)
	if finger_pose.size() != bones.size():
		WeaponHold.close_fist(skeleton, side, WeaponHold.fist_curls(skeleton, side, grip_radius))
		return
	for i in bones.size():
		if bones[i] >= 0:
			skeleton.set_bone_pose_rotation(bones[i], finger_pose[i])

func _fingers_now() -> Array[Quaternion]:
	var now: Array[Quaternion] = []
	for bone in finger_bones(_skeleton):
		now.append(_skeleton.get_bone_pose_rotation(bone) if bone >= 0 else Quaternion.IDENTITY)
	return now

## A finger bone turned since this script last set it was posed by hand: keep all fifteen.
func _keep_posed_fingers() -> void:
	if _fingers_put.is_empty():
		return
	var now := _fingers_now()
	for i in now.size():
		if not now[i].is_equal_approx(_fingers_put[i]):
			finger_pose = now
			_fingers_put = now
			return

## Editor: the Shoulder and Elbow markers onto the shoulder and the elbow of the arm as it was
## last solved, so that they show the arm and the next drag starts from it.
func settle_markers() -> void:
	var body := get_parent() as Node3D
	if body == null or _skeleton == null or _fingers_put.is_empty():
		return
	var to_here := (body.global_transform * transform).affine_inverse() * _skeleton.global_transform
	for pair: Array in [["Shoulder", "UpperArm"], ["Elbow", "LowerArm"]]:
		var marker := get_node_or_null(pair[0] as String) as Node3D
		var at := to_here * _skeleton.get_bone_global_pose(_skeleton.find_bone(side + (pair[1] as String))).origin
		if marker and marker.position.distance_to(at) > 0.0005:
			marker.position = at
	_elbow_seen = _place("Elbow") # moved by this script, not dragged
	_elbow_tracked = true

## Is the Elbow marker being dragged in the editor's 3D view just now: it is selected and the
## mouse is down.
func _elbow_is_dragged() -> bool:
	if not Engine.is_editor_hint() or not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		return false
	var editor := Engine.get_singleton(&"EditorInterface") # by name: the class does not exist in a game build
	var elbow := get_node_or_null("Elbow")
	return editor != null and elbow != null and (editor.call("get_selection").call("get_selected_nodes") as Array).has(elbow)

## The Elbow marker moved since last frame WHILE BEING DRAGGED: the forearm goes with it (the
## Hand marker by as much, not turned), and the shoulder comes after at the upper arm's length.
## Any other move of the marker (a reloaded scene or script, an undo, a typed number, this
## script settling it) carries nothing: the first version carried on every move, and a
## reloaded script shoved the hand half a metre with nobody touching it (Kirill, 2026-10-13).
func _carry_from_elbow(dragged: bool) -> void:
	var elbow := get_node_or_null("Elbow") as Node3D
	var hand := get_node_or_null("Hand") as Node3D
	var shoulder := get_node_or_null("Shoulder") as Node3D
	if elbow == null or hand == null or shoulder == null:
		return
	var moved := elbow.position - _elbow_seen
	if dragged and _elbow_tracked and moved.length() > 0.00001 and moved.length() < 0.25:
		hand.position += moved
		var upper := _skeleton.get_bone_global_rest(_skeleton.find_bone(side + "LowerArm")).origin.distance_to(_skeleton.get_bone_global_rest(_skeleton.find_bone(side + "UpperArm")).origin)
		var from_elbow := shoulder.position - elbow.position
		if from_elbow.length() > 0.001:
			shoulder.position = elbow.position + from_elbow.normalized() * upper
	_elbow_seen = elbow.position
	_elbow_tracked = true

## Everything the shown pose depends on.
func _inputs(data: WeaponData, radius: float) -> Array:
	return [preview, side, holds, data, radius, data.scene if data else null, data.grip if data else Transform3D.IDENTITY, data.on_forearm if data else false,
			_place("Shoulder"), _place("Hand"), _place("Elbow"), transform, hand_turn(), max_reach, finger_pose.duplicate(),
			(get_node("Hand/Grip") as Node3D).transform if has_node("Hand/Grip") else Transform3D.IDENTITY]

## The Fingers markers, in the order of finger_pose (null where one is missing).
func _joint_markers() -> Array[Node3D]:
	var markers: Array[Node3D] = []
	for finger: String in WeaponHold.FINGERS:
		for joint: String in (["Metacarpal", "Proximal", "Distal"] if finger == "Thumb" else ["Proximal", "Intermediate", "Distal"]):
			markers.append(get_node_or_null("Fingers/" + finger + joint) as Node3D)
	return markers

## A Fingers marker turned since this script last put it on its joint was turned by hand: its
## joint takes the turn. One MOVED was dragged: the joint before it on the finger turns, by the
## shortest way, until its bone points at the marker. (From the knuckle outward, so a finger
## changed at two joints at once comes out right.)
func _turn_joints_from_markers() -> void:
	var markers := _joint_markers()
	if _joints_put.size() != markers.size():
		return
	var bones := finger_bones(_skeleton)
	for i in markers.size():
		if markers[i] == null or bones[i] < 0:
			continue
		if markers[i].global_position.distance_to(_joints_put[i].origin) > 0.0005:
			# Moved. (Its turn is not looked at: the editor's move tool holds a dragged node's
			# turn as it was when the drag began, which is not a turn by hand.)
			if i % 3 == 0 and bones[i + 1] >= 0:
				# A first joint. The drag is taken a frame's worth at a time: the editor
				# keeps the marker at its start plus the whole drag, while the finger has
				# already followed all of it but the last frame's.
				var own := _skeleton.get_bone_global_pose(bones[i])
				var off := _skeleton.global_transform.affine_inverse() * markers[i].global_position - own.origin
				var step: Vector3 = off - (_first_joint_drag.get(i, Vector3.ZERO) as Vector3)
				_first_joint_drag[i] = off
				var reach := _skeleton.get_bone_global_pose(bones[i + 1]).origin - own.origin
				if step.length() > 0.00001 and reach.length() > 0.0001 and (reach + step).length() > 0.0001:
					own.basis = Basis(Quaternion(reach.normalized(), (reach + step).normalized())) * own.basis
					_skeleton.set_bone_global_pose(bones[i], own)
			elif i % 3 > 0 and bones[i - 1] >= 0:
				var to_skeleton := _skeleton.global_transform.affine_inverse()
				var before := _skeleton.get_bone_global_pose(bones[i - 1])
				var was := _skeleton.get_bone_global_pose(bones[i]).origin - before.origin
				var wanted := to_skeleton * markers[i].global_position - before.origin
				if was.length() > 0.0001 and wanted.length() > 0.0001:
					before.basis = Basis(Quaternion(was.normalized(), wanted.normalized())) * before.basis
					_skeleton.set_bone_global_pose(bones[i - 1], before)
			continue
		var now := markers[i].global_transform.basis.orthonormalized()
		if now.get_rotation_quaternion().angle_to(_joints_put[i].basis.get_rotation_quaternion()) < 0.001:
			continue
		var joint := _skeleton.get_bone_global_pose(bones[i])
		joint.basis = _skeleton.global_transform.basis.orthonormalized().inverse() * now
		_skeleton.set_bone_global_pose(bones[i], joint)

## The Fingers markers onto their joints, turned as the joints are.
func _put_joint_markers() -> void:
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_first_joint_drag.clear() # no drag is going on: the next one starts from nothing
	var markers := _joint_markers()
	var bones := finger_bones(_skeleton)
	_joints_put = []
	for i in markers.size():
		var at := Transform3D.IDENTITY
		if markers[i] != null and bones[i] >= 0:
			at = (_skeleton.global_transform * _skeleton.get_bone_global_pose(bones[i])).orthonormalized()
			if not markers[i].global_transform.is_equal_approx(at):
				markers[i].global_transform = at
		_joints_put.append(at)

func _reset_fingers() -> void:
	finger_pose = []
	_shown = []
	_fingers_put = []
	_joints_put = []

func _process(_delta: float) -> void:
	update()

## This stance's arm, shoulder to fingertips, back to the rest pose.
func _reset_own_arm() -> void:
	var todo: Array[int] = [_skeleton.find_bone(side + "UpperArm")]
	while not todo.is_empty():
		var bone: int = todo.pop_back()
		if bone < 0:
			continue
		_skeleton.reset_bone_pose(bone)
		todo.append_array(_skeleton.get_bone_children(bone))

## One editor frame (also called by headless checks).
func update() -> void:
	var body := get_parent() as Node3D
	if body == null:
		return
	if _skeleton == null or not is_instance_valid(_skeleton):
		var found := body.find_children("*", "Skeleton3D", true, false)
		if found.is_empty():
			return
		_skeleton = found[0]
	if preview:
		_turn_joints_from_markers()
		_keep_posed_fingers()
		_carry_from_elbow(_elbow_is_dragged())
	var data := body.get(holds) as WeaponData
	var radius := data.grip_radius if data else WeaponHold.REFERENCE_RADIUS
	var wanted := _inputs(data, radius)
	if wanted == _shown:
		# Nothing was moved since the arm was solved: the markers go onto it. Not while the
		# mouse is down: the editor's gizmo would fight it.
		if preview and Engine.is_editor_hint() and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			settle_markers()
			_put_joint_markers() # one that was moved goes back onto its joint
			wanted = _inputs(data, radius)
		if wanted == _shown:
			return
	_shown = wanted
	_reset_own_arm() # not the whole skeleton: the other arm's stance node has posed its own
	_fingers_put = []
	_joints_put = []
	if _preview:
		_preview.queue_free()
		_preview = null
	if not preview:
		return
	var held := socket(_skeleton, radius)
	# The markers are places from this node, which stands for the eyes, in the body's space.
	pose(_skeleton, _skeleton.global_transform.affine_inverse() * body.global_transform, position, fist_in_hand(_skeleton, radius))
	pose_fingers(_skeleton, radius)
	_fingers_put = _fingers_now()
	_put_joint_markers()
	if data and data.scene:
		_preview = data.scene.instantiate() as Node3D
		add_child(_preview) # no owner: not saved with the scene
		if data.on_forearm:
			_preview.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_skeleton.find_bone(side + "LowerArm")) * WeaponHold.in_hand(forearm_socket(_skeleton, radius), data)
		else:
			_preview.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_skeleton.find_bone(side + "Hand")) * WeaponHold.in_hand(held, data)

## The right arm as it is posed just now, in degrees and metres: "flex" (wrist toward the palm,
## negative toward the back of the hand), "to_thumb" (wrist toward the thumb, negative toward
## the little finger), "roll" (forearm from thumb-up: positive palm turning up, negative down),
## "bend" (elbow, 0 = straight), "gap" (the shoulder from the body's own, see body_shoulder).
func arm_measures() -> Dictionary:
	var body := get_parent() as Node3D
	var upper := _skeleton.get_bone_global_pose(_skeleton.find_bone(side + "UpperArm"))
	var lower := _skeleton.get_bone_global_pose(_skeleton.find_bone(side + "LowerArm"))
	var hand := _skeleton.get_bone_global_pose(_skeleton.find_bone(side + "Hand"))
	var axes := WeaponHold.hand_axes(_skeleton, side)
	var fingers: Vector3 = hand.basis * (axes["fingers_out"] as Vector3)
	var palm: Vector3 = hand.basis * (axes["palm_out"] as Vector3)
	var thumb: Vector3 = hand.basis * (axes["thumb_side"] as Vector3)
	var forearm := (hand.origin - lower.origin).normalized()
	var own := _skeleton.global_transform.affine_inverse() * body.global_transform * (position + body_shoulder)
	return {"flex": rad_to_deg(atan2(forearm.dot(-palm), forearm.dot(fingers))), "to_thumb": rad_to_deg(atan2(forearm.dot(-thumb), forearm.dot(fingers))),
			"roll": _forearm_roll(upper.origin, lower.origin, hand.origin, palm), "bend": 180.0 - rad_to_deg((upper.origin - lower.origin).angle_to(hand.origin - lower.origin)),
			"gap": upper.origin.distance_to(own)}

## Degrees the forearm is rolled from thumb-up, where the palm faces the inside of the arm's
## bend: positive toward palm up.
static func _forearm_roll(shoulder: Vector3, elbow: Vector3, wrist: Vector3, palm: Vector3) -> float:
	var forearm := (wrist - elbow).normalized()
	var inward := (shoulder - elbow).cross(wrist - elbow).normalized()
	var across := palm - forearm * palm.dot(forearm)
	return rad_to_deg(atan2(forearm.dot(inward.cross(across)), inward.dot(across)))

func _fit_pressed() -> void:
	print(fit_hand_to_sword())

## See `fit_hand`. Returns what it found, in words.
func fit_hand_to_sword() -> String:
	if side != "Right" or holds != &"weapon":
		return "[WeaponStance] fit: made for a weapon in the right fist only."
	update()
	var body := get_parent() as Node3D
	var hand_marker := get_node_or_null("Hand") as Node3D
	var grip_marker := get_node_or_null("Hand/Grip") as Node3D
	var shoulder_marker := get_node_or_null("Shoulder") as Node3D
	var elbow_marker := get_node_or_null("Elbow") as Node3D
	if body == null or _skeleton == null or hand_marker == null or grip_marker == null or shoulder_marker == null or elbow_marker == null:
		return "[WeaponStance] fit: a body with a skeleton and the Shoulder, Elbow, Hand and Hand/Grip markers are needed."
	var data := body.get(holds) as WeaponData
	var radius := data.grip_radius if data else WeaponHold.REFERENCE_RADIUS
	var to_skeleton := _skeleton.global_transform.affine_inverse() * body.global_transform
	var from_eyes := to_skeleton * Transform3D(Basis.IDENTITY, position)
	var upper_bone := _skeleton.find_bone(side + "UpperArm")
	var lower_bone := _skeleton.find_bone(side + "LowerArm")
	var hand_bone := _skeleton.find_bone(side + "Hand")
	# The arm as the markers have it now, and with it where the weapon's grip is: that stays.
	_reset_own_arm()
	pose(_skeleton, to_skeleton, position, fist_in_hand(_skeleton, radius))
	var was := arm_measures()
	var held := (_skeleton.get_bone_global_pose(hand_bone) * socket(_skeleton, radius)).orthonormalized()
	var upper_length := _skeleton.get_bone_global_pose(upper_bone).origin.distance_to(_skeleton.get_bone_global_pose(lower_bone).origin)
	var lower_length := _skeleton.get_bone_global_pose(lower_bone).origin.distance_to(_skeleton.get_bone_global_pose(hand_bone).origin)
	# The hand that holds a grip standing there in the plain way.
	var axes := WeaponHold.hand_axes(_skeleton, side)
	var plain := WeaponHold.socket(_skeleton, side, radius)
	var hand_basis := held.basis * plain.basis.orthonormalized().inverse()
	var wrist := held.origin - hand_basis * plain.origin
	var fingers: Vector3 = hand_basis * (axes["fingers_out"] as Vector3)
	var palm: Vector3 = hand_basis * (axes["palm_out"] as Vector3)
	var thumb: Vector3 = hand_basis * (axes["thumb_side"] as Vector3)
	var own := from_eyes * body_shoulder
	# Every forearm the wrist allows, and for each every upper arm: the one with the shoulder
	# nearest the body's own and the wrist least bent.
	var directions: Array[Vector3] = []
	for i in 400: # spread evenly over a ball
		var height := 1.0 - 2.0 * (i + 0.5) / 400.0
		var around := i * 2.399963
		directions.append(Vector3(cos(around) * sqrt(1.0 - height * height), height, sin(around) * sqrt(1.0 - height * height)))
	var best_cost := INF
	var best_elbow := Vector3.ZERO
	var best_shoulder := Vector3.ZERO
	var flex := -FIT_WRIST_FLEX
	while flex <= FIT_WRIST_FLEX + 0.01:
		var to_thumb := -FIT_WRIST_TO_LITTLE
		while to_thumb <= FIT_WRIST_TO_THUMB + 0.01:
			var forearm := (fingers - palm * tan(deg_to_rad(flex)) - thumb * tan(deg_to_rad(to_thumb))).normalized()
			var elbow := wrist - forearm * lower_length
			var wrist_cost := FIT_WRIST_WEIGHT * (pow(flex / FIT_WRIST_FLEX, 2.0) + pow(to_thumb / (FIT_WRIST_TO_THUMB if to_thumb > 0.0 else FIT_WRIST_TO_LITTLE), 2.0))
			for direction in directions:
				var shoulder := elbow + direction * upper_length
				var cost := shoulder.distance_to(own) + wrist_cost
				if cost >= best_cost or shoulder.distance_to(held.origin) > max_reach:
					continue
				var bend := 180.0 - rad_to_deg(direction.angle_to(forearm))
				if bend < FIT_ELBOW_BEND.x or bend > FIT_ELBOW_BEND.y or absf(_forearm_roll(shoulder, elbow, wrist, palm)) > FIT_FOREARM_ROLL:
					continue
				best_cost = cost
				best_elbow = elbow
				best_shoulder = shoulder
			to_thumb += 5.0
		flex += 5.0
	if best_cost == INF:
		_shown = []
		return "[WeaponStance] fit: no arm within the allowances (FIT_*) holds the weapon where it is. Nothing was changed."
	_before_fit.append({"Shoulder": shoulder_marker.transform, "Elbow": elbow_marker.transform, "Hand": hand_marker.transform, "Grip": grip_marker.transform, "fingers": finger_pose.duplicate()})
	var to_eyes := from_eyes.affine_inverse()
	# The Hand marker's turn that gives this hand (the reverse of what WeaponHold.solve_arm does with it).
	var turned := hand_basis * Basis(axes["fingers_out"] as Vector3, axes["palm_out"] as Vector3, axes["thumb_side"] as Vector3)
	hand_marker.transform = Transform3D((to_eyes.basis.orthonormalized() * Basis(-turned.y, turned.z, -turned.x)).orthonormalized(), to_eyes * held.origin)
	var marker := Basis(-(axes["palm_out"] as Vector3), axes["thumb_side"] as Vector3, -(axes["fingers_out"] as Vector3))
	grip_marker.transform = Transform3D((marker.inverse() * plain.basis.orthonormalized() * SOCKET_IN_GRIP.inverse()).orthonormalized(), Vector3.ZERO)
	shoulder_marker.position = to_eyes * best_shoulder
	elbow_marker.position = to_eyes * best_elbow
	_elbow_seen = elbow_marker.position # put there, not dragged
	_elbow_tracked = true
	_reset_fingers()
	update()
	if _fingers_put.is_empty(): # the preview is off: pose it for the measuring
		pose(_skeleton, to_skeleton, position, fist_in_hand(_skeleton, radius))
	var now := arm_measures()
	var held_now := (_skeleton.get_bone_global_pose(hand_bone) * socket(_skeleton, radius)).orthonormalized()
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		Engine.get_singleton(&"EditorInterface").call("mark_scene_as_unsaved")
	var line := "wrist %+.0f deg toward the palm and %+.0f toward the thumb, forearm rolled %+.0f deg from thumb-up, elbow bent %.0f deg, shoulder %.2f m off the body's own"
	return "[WeaponStance] fit the hand to the sword:\n  before: %s\n  after:  %s\n  the weapon moved %.1f mm and turned %.1f deg." % [
			line % [was["flex"], was["to_thumb"], was["roll"], was["bend"], was["gap"]], line % [now["flex"], now["to_thumb"], now["roll"], now["bend"], now["gap"]],
			held_now.origin.distance_to(held.origin) * 1000.0, rad_to_deg(held_now.basis.get_rotation_quaternion().angle_to(held.basis.get_rotation_quaternion()))]

func _put_back_before_fit() -> void:
	if _before_fit.is_empty():
		print("[WeaponStance] no fit was made since the scene was opened: nothing to put back.")
		return
	var before: Dictionary = _before_fit.pop_back()
	for marker: String in ["Shoulder", "Elbow", "Hand"]:
		(get_node(marker) as Node3D).transform = before[marker]
	(get_node("Hand/Grip") as Node3D).transform = before["Grip"]
	_elbow_seen = _place("Elbow")
	_reset_fingers()
	finger_pose = before["fingers"]
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		Engine.get_singleton(&"EditorInterface").call("mark_scene_as_unsaved")
