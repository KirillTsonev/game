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

## Editor only. Off: the body in its rest pose and no weapon shown.
@export var preview: bool = true
## The furthest the fist is held from the shoulder (m). The arm is 0.56 m long.
@export_range(0.2, 0.56, 0.005) var max_reach: float = 0.54
## The right hand's fifteen finger joints as posed in the editor (each bone's own rotation):
## thumb, forefinger, middle, ring, little finger, three joints each from the hand outward.
## Empty: the plain fist.
@export var finger_pose: Array[Quaternion] = []
## Back to the plain fist.
@export_tool_button("Reset the fingers to the plain fist") var reset_fingers: Callable = _reset_fingers

const HAND := "Right"
## A socket's axes (+X the leading edge, +Y the blade) in the Grip marker's (-Z, +Y).
const SOCKET_IN_GRIP := Basis(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0), Vector3(1.0, 0.0, 0.0))
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
	# The shown pose is not the scene's: keep what was posed by hand, then let the skeleton be
	# saved at rest. The next frame shows the hold again.
	_keep_posed_fingers()
	_skeleton.reset_bone_poses()
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
	return WeaponHold.socket(skeleton, HAND, grip_radius, 0.0).origin

## Where the weapon's grip goes in the hand bone's axes: the fist's middle, moved and turned as
## the Hand/Grip marker is in the Hand marker.
func socket(skeleton: Skeleton3D, grip_radius: float) -> Transform3D:
	var grip := get_node_or_null("Hand/Grip") as Node3D
	if grip == null:
		return WeaponHold.socket(skeleton, HAND, grip_radius)
	var axes := WeaponHold.hand_axes(skeleton, HAND)
	# The Hand marker's axes in the hand bone's: -X the palm, +Y the thumb's side, -Z the fingers.
	var marker := Basis(-(axes["palm_out"] as Vector3), axes["thumb_side"] as Vector3, -(axes["fingers_out"] as Vector3))
	return Transform3D(marker * grip.basis.orthonormalized() * SOCKET_IN_GRIP, fist_in_hand(skeleton, grip_radius) + marker * grip.position)

## Poses the arm (not the fingers) outright. `eye` and the stance are in the space that
## `to_skeleton` brings into the skeleton's.
func pose(skeleton: Skeleton3D, to_skeleton: Transform3D, eye: Vector3, grip_in_hand: Vector3) -> void:
	WeaponHold.solve_arm(skeleton, HAND, to_skeleton, eye + shoulder_from_eyes(), eye + hand_from_eyes(), elbow_toward(), hand_turn(), grip_in_hand, max_reach)

## The right hand's finger joints, in the order of finger_pose.
func finger_bones(skeleton: Skeleton3D) -> PackedInt32Array:
	if _finger_bones_of != skeleton or _finger_bones.is_empty():
		_finger_bones = PackedInt32Array()
		for finger: String in WeaponHold.FINGERS:
			for joint: String in (["Metacarpal", "Proximal", "Distal"] if finger == "Thumb" else ["Proximal", "Intermediate", "Distal"]):
				_finger_bones.append(skeleton.find_bone(HAND + finger + joint))
		_finger_bones_of = skeleton
	return _finger_bones

## Closes the fingers round a handle of this thickness, outright: as posed in the editor, or
## the plain fist where nothing was.
func pose_fingers(skeleton: Skeleton3D, grip_radius: float) -> void:
	var bones := finger_bones(skeleton)
	if finger_pose.size() != bones.size():
		WeaponHold.close_fist(skeleton, HAND, WeaponHold.fist_curls(skeleton, HAND, grip_radius))
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
		var at := to_here * _skeleton.get_bone_global_pose(_skeleton.find_bone(HAND + (pair[1] as String))).origin
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
		var upper := _skeleton.get_bone_global_rest(_skeleton.find_bone(HAND + "LowerArm")).origin.distance_to(_skeleton.get_bone_global_rest(_skeleton.find_bone(HAND + "UpperArm")).origin)
		var from_elbow := shoulder.position - elbow.position
		if from_elbow.length() > 0.001:
			shoulder.position = elbow.position + from_elbow.normalized() * upper
	_elbow_seen = elbow.position
	_elbow_tracked = true

## Everything the shown pose depends on.
func _inputs(data: WeaponData, radius: float) -> Array:
	return [preview, data, radius, data.scene if data else null, data.grip if data else Transform3D.IDENTITY,
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
	var data := body.get("weapon") as WeaponData
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
	_skeleton.reset_bone_poses()
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
		_preview.global_transform = _skeleton.global_transform * _skeleton.get_bone_global_pose(_skeleton.find_bone(HAND + "Hand")) * WeaponHold.in_hand(held, data)
