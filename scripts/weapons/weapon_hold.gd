@tool
class_name WeaponHold
extends RefCounted
## Puts a weapon (WeaponData) into the hand of anything on the humanoid skeleton. Static only.
##
## Two places meet: the weapon's grip (WeaponData.grip, set once per weapon) and the hand's
## socket (the middle of the closed fist, worked out here from the hand's bones, so set per
## creature not at all). The weapon is laid with the one on the other. The socket must never
## steer the arm: where the weapon points is the arm's pose, which comes from a clip or from a
## stance set by hand (weapon_stance.gd, solve_arm below). The first sword
## hold steered the arm by the blade's direction instead, and every wrong grip was "met" by
## rolling the forearm up to half a turn (2026-10-13).
##
## The socket's numbers were measured on the rogue's glove (points sampled on its faces, the
## fingers closed until their surface met a handle 2.2 cm thick from its middle) and are scaled
## by the hand's length for another body. A WeaponStance node (scripts/weapons/weapon_stance.gd)
## can shift the socket, slant it and set the fingers by eye.

const FINGERS: Array[String] = ["Thumb", "Index", "Middle", "Ring", "Little"]
## The rogue's hand: the hand bone to the middle finger's knuckle (m), and the handle's
## thickness the numbers below were measured with.
const REFERENCE_HAND := 0.1
const REFERENCE_RADIUS := 0.022
## The fist's middle from the hand bone on that hand (m): toward the fingers, out of the palm,
## and toward the thumb's side.
const SOCKET_TO_FINGERS := 0.074
const SOCKET_TO_PALM := 0.057
const SOCKET_TO_THUMB := -0.01
## Radians the handle lies slanted in the fist: the blade leant toward the way the fingers
## point, about the fist's middle, as a real hand holds a sword (the pommel toward the heel of
## the hand). Held square (0) the blade's lean had to come from the wrist alone, and at the
## 47 degrees the stance needed the arm "looks broken" (Kirill, 2026-10-13). The fingers are
## still closed as for a square handle.
const GRIP_SLANT := 0.52
## Radians each joint of thumb, forefinger, middle, ring and little finger closes round it.
## (The thumb stays as it is: closed, its surface went into the handle at every angle tried.)
const FIST_CURL: Array[float] = [0.0, 0.92, 0.93, 0.81, 0.71]
## Radians a finger joint closes further per metre the handle is thinner. An estimate from the
## fingers' lengths, not measured on the glove.
const CURL_PER_METRE := 29.0

## The hand's own directions, in the hand bone's axes: "fingers_out", "palm_out", "thumb_side"
## (unit, square to one another) and "length" (hand bone to the middle knuckle, m). The rest
## pose of the humanoid skeleton is the T-pose, palms down.
static func hand_axes(skeleton: Skeleton3D, side: String) -> Dictionary:
	var rest := skeleton.get_bone_global_rest(skeleton.find_bone(side + "Hand"))
	var to_hand := rest.basis.inverse()
	var knuckle := skeleton.get_bone_global_rest(skeleton.find_bone(side + "MiddleProximal")).origin - rest.origin
	var fingers_out := (to_hand * knuckle).normalized()
	var palm_out := to_hand * Vector3.DOWN
	palm_out = (palm_out - fingers_out * palm_out.dot(fingers_out)).normalized()
	var thumb_side := fingers_out.cross(palm_out)
	var forefinger := skeleton.get_bone_global_rest(skeleton.find_bone(side + "IndexProximal")).origin
	var little := skeleton.get_bone_global_rest(skeleton.find_bone(side + "LittleProximal")).origin
	if thumb_side.dot(to_hand * (forefinger - little)) < 0.0:
		thumb_side = -thumb_side
	return {"fingers_out": fingers_out, "palm_out": palm_out, "thumb_side": thumb_side, "length": knuckle.length()}

## The middle of the closed fist in the hand bone's axes: +Y the way a blade runs (out of the
## thumb's side, slanted by GRIP_SLANT toward the fingers), +X square to it on the knuckles' side.
static func socket(skeleton: Skeleton3D, side: String, grip_radius: float = REFERENCE_RADIUS, slant: float = GRIP_SLANT) -> Transform3D:
	var axes := hand_axes(skeleton, side)
	var size: float = axes["length"] / REFERENCE_HAND
	var fingers: Vector3 = axes["fingers_out"]
	var thumb: Vector3 = axes["thumb_side"]
	var origin := fingers * (SOCKET_TO_FINGERS * size) + thumb * (SOCKET_TO_THUMB * size) \
			+ (axes["palm_out"] as Vector3) * (SOCKET_TO_PALM * size + grip_radius - REFERENCE_RADIUS * size)
	return Transform3D(Basis(fingers.cross(thumb), -slant) * Basis(fingers, thumb, fingers.cross(thumb)), origin)

## How far each finger closes (the order of FINGERS) round a handle of this thickness.
static func fist_curls(skeleton: Skeleton3D, side: String, grip_radius: float = REFERENCE_RADIUS) -> Array[float]:
	var size: float = hand_axes(skeleton, side)["length"] / REFERENCE_HAND
	var curls: Array[float] = [FIST_CURL[0]]
	for i in range(1, FIST_CURL.size()):
		curls.append(maxf(FIST_CURL[i] + (REFERENCE_RADIUS * size - grip_radius) / size * CURL_PER_METRE, 0.0))
	return curls

## Per finger (FINGERS' names) its three joints as [bone, the axis it closes about in its own
## axes], and under "thumb_in" the axis the thumb's first joint swings in about. A finger
## closes by turning from the way it points toward the ground, the palm's side in the rest pose.
static func finger_joints(skeleton: Skeleton3D, side: String) -> Dictionary:
	var hand_rest := skeleton.get_bone_global_rest(skeleton.find_bone(side + "Hand"))
	var knuckle := skeleton.get_bone_global_rest(skeleton.find_bone(side + "MiddleProximal")).origin
	var fingers := {}
	for finger: String in FINGERS:
		var joints: Array[String] = ["Proximal", "Intermediate", "Distal"]
		if finger == "Thumb":
			joints = ["Metacarpal", "Proximal", "Distal"]
		fingers[finger] = []
		for i in joints.size():
			var bone := skeleton.find_bone(side + finger + joints[i])
			var rest := skeleton.get_bone_global_rest(bone)
			# The way the joint points: to the next one, or as the one before for the last.
			var along := rest.origin - skeleton.get_bone_global_rest(skeleton.find_bone(side + finger + joints[i - 1])).origin
			if i < joints.size() - 1:
				along = skeleton.get_bone_global_rest(skeleton.find_bone(side + finger + joints[i + 1])).origin - rest.origin
			(fingers[finger] as Array).append([bone, (rest.basis.inverse() * along.cross(Vector3.DOWN)).normalized()])
	# The thumb's other movement, at its first joint: swinging in toward the way the fingers
	# point, which is what brings its tip to the forefinger's for a pinch (closing alone leaves
	# the two tips 3 cm apart at best).
	var thumb_rest := skeleton.get_bone_global_rest(fingers["Thumb"][0][0])
	var thumb_along := skeleton.get_bone_global_rest(fingers["Thumb"][1][0]).origin - thumb_rest.origin
	fingers["thumb_in"] = (thumb_rest.basis.inverse() * thumb_along.cross(knuckle - hand_rest.origin)).normalized()
	return fingers

## Closes the hand outright (no blend with a clip): `curls` in the order of FINGERS (radians a
## joint), the thumb swung in by `thumb_in`, and the share of a finger's curl each of its three
## joints takes, from the knuckle outward.
static func close_fist(skeleton: Skeleton3D, side: String, curls: Array[float], thumb_in: float = 0.0, joint_share: Vector3 = Vector3.ONE) -> void:
	var fingers := finger_joints(skeleton, side)
	for i in FINGERS.size():
		var joints: Array = fingers[FINGERS[i]]
		for j in joints.size():
			var bone: int = joints[j][0]
			var turn := skeleton.get_bone_rest(bone).basis.get_rotation_quaternion() * Quaternion(joints[j][1] as Vector3, curls[i] * (joint_share[j] if i > 0 else 1.0))
			if i == 0 and j == 0:
				turn = turn * Quaternion(fingers["thumb_in"] as Vector3, thumb_in)
			skeleton.set_bone_pose_rotation(bone, turn)

## Where the weapon's model goes in the hand bone's axes, for a socket found by socket().
static func in_hand(hand_socket: Transform3D, data: WeaponData) -> Transform3D:
	return hand_socket * data.grip.affine_inverse()

## The simple way, for a body whose clips pose the arm (an enemy): the weapon's model on a
## BoneAttachment3D under the skeleton, which is returned. The fingers are not closed here: a
## clip sets them every frame, so the caller closes them after its clips have run.
static func attach(skeleton: Skeleton3D, side: String, data: WeaponData) -> BoneAttachment3D:
	var attachment := BoneAttachment3D.new()
	attachment.name = side + "HandWeapon"
	skeleton.add_child(attachment)
	attachment.bone_name = side + "Hand"
	var model := data.scene.instantiate() as Node3D
	attachment.add_child(model)
	model.transform = in_hand(socket(skeleton, side, data.grip_radius), data)
	return attachment

## Poses one arm to hold a weapon, outright (the caller blends it with a clip if it wants):
## the shoulder PUT at `shoulder_at` (the upper arm's bone moved there bodily; Vector3.INF
## leaves it on the body), the fist's middle (`grip_in_hand`, a place in the hand bone's axes)
## at `grip_at` -- THE HAND LEADS: where that is further than `max_reach` from the shoulder, a
## placed shoulder is drawn after it along their line (one left on the body is not, and the
## fist then stops at `max_reach`) -- the elbow to the side
## `elbow_toward` points, and the hand turned as `hand_turn` says: a basis whose -Z is the way
## the fingers point, +Y the thumb's side and -X the way the palm faces (so no turn at all is
## fingers ahead, thumb up, palm to the left). Of that turn the FOREARM takes what is a roll
## about its own line, as a real one turns the hand over, and the wrist bends by the rest. Places and directions are in the space `to_skeleton`
## brings into the skeleton's. NOTHING HERE LOOKS AT THE WEAPON (see the header).
## The game (PlayerBody._hold_weapon) and the editor's view (weapon_stance.gd) both call this,
## so what the editor shows is what the game does.
static func solve_arm(skeleton: Skeleton3D, side: String, to_skeleton: Transform3D, shoulder_at: Vector3, grip_at: Vector3, elbow_toward: Vector3, hand_turn: Basis, grip_in_hand: Vector3, max_reach: float) -> void:
	var upper_bone := skeleton.find_bone(side + "UpperArm")
	var lower_bone := skeleton.find_bone(side + "LowerArm")
	var hand_bone := skeleton.find_bone(side + "Hand")
	var axes := hand_axes(skeleton, side)
	var upper := skeleton.get_bone_global_pose(upper_bone)
	if shoulder_at.is_finite():
		upper.origin = to_skeleton * shoulder_at
		skeleton.set_bone_global_pose(upper_bone, upper)
	var to_grip := to_skeleton * grip_at - upper.origin
	if shoulder_at.is_finite() and to_grip.length() > max_reach:
		upper.origin += to_grip - to_grip.limit_length(max_reach)
		skeleton.set_bone_global_pose(upper_bone, upper)
	var goal := upper.origin + (to_skeleton * grip_at - upper.origin).limit_length(max_reach)
	var pole := (to_skeleton.basis * elbow_toward).normalized()
	# The hand bone's turn in the skeleton's space that puts fingers, palm and thumb as asked.
	var asked := (to_skeleton.basis * hand_turn).orthonormalized()
	var wanted := Basis(-asked.z, -asked.x, asked.y) * Basis(axes["fingers_out"] as Vector3, axes["palm_out"] as Vector3, axes["thumb_side"] as Vector3).inverse()
	var on_forearm := skeleton.get_bone_rest(hand_bone).basis # the hand's rest on the forearm: wrist straight
	for pass_index in 5: # the hand turns as the arm bends, which moves the fist: settle it
		var lower := skeleton.get_bone_global_pose(lower_bone)
		var hand := skeleton.get_bone_global_pose(hand_bone)
		var forearm := (hand.origin - lower.origin).normalized()
		# From the hand as the forearm carries it (wrist straight) to the hand as asked: the
		# part of that turn that is about the forearm's own line goes into the forearm.
		var turn := (wanted * (lower.basis * on_forearm).orthonormalized().inverse()).get_rotation_quaternion()
		var roll := 2.0 * atan2(Vector3(turn.x, turn.y, turn.z).dot(forearm), turn.w)
		lower.basis = Basis(forearm, wrapf(roll, -PI, PI)) * lower.basis
		skeleton.set_bone_global_pose(lower_bone, lower)
		hand = skeleton.get_bone_global_pose(hand_bone)
		hand.basis = wanted
		skeleton.set_bone_global_pose(hand_bone, hand)
		if pass_index == 4:
			break # the last pass only sets the hand's turn for the arm as solved
		upper = skeleton.get_bone_global_pose(upper_bone)
		var hand_goal := hand.origin + goal - hand * grip_in_hand
		var upper_length := (lower.origin - upper.origin).length()
		var lower_length := (hand.origin - lower.origin).length()
		var to_goal := hand_goal - upper.origin
		var distance := clampf(to_goal.length(), absf(upper_length - lower_length) + 0.001, upper_length + lower_length - 0.001)
		var toward := to_goal.normalized()
		var sideways := pole - toward * pole.dot(toward)
		if sideways.length_squared() < 0.0001:
			sideways = toward.cross(Vector3.UP)
		# The triangle shoulder - elbow - hand with its three sides known.
		var cosine := clampf((upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * upper_length * distance), -1.0, 1.0)
		var elbow_at := upper.origin + toward * (upper_length * cosine) + sideways.normalized() * (upper_length * sqrt(1.0 - cosine * cosine))
		upper.basis = Basis(Quaternion((lower.origin - upper.origin).normalized(), (elbow_at - upper.origin).normalized())) * upper.basis
		skeleton.set_bone_global_pose(upper_bone, upper)
		lower = skeleton.get_bone_global_pose(lower_bone)
		hand = skeleton.get_bone_global_pose(hand_bone)
		lower.basis = Basis(Quaternion((hand.origin - lower.origin).normalized(), (upper.origin + toward * distance - lower.origin).normalized())) * lower.basis
		skeleton.set_bone_global_pose(lower_bone, lower)
