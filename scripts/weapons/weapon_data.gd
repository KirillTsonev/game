@tool
class_name WeaponData
extends Resource
## One weapon that a hand can hold: its model and where on it the hand closes. Any creature on
## the humanoid skeleton holds any weapon through WeaponHold; nothing is set up per pair.
## How to add one: docs/weapons.md.

## The weapon's model.
@export var scene: PackedScene
## Where the middle of the fist goes, in the model's own axes: the origin on the handle's middle
## line, +Y along the handle toward the blade or head, +X the way the leading edge faces (it
## ends up on the knuckles' side).
@export var grip: Transform3D = Transform3D.IDENTITY
## The handle's thickness there, from its middle line (m). Moves the handle off the palm and
## opens or closes the fingers to suit.
@export var grip_radius: float = 0.022
## A SHIELD: carried on the forearm, not in the fist, and turned by the forearm alone (the
## wrist's bend does not move it). `grip` then means: the origin on the forearm's middle line
## where the fist is, +Y along the forearm from the elbow toward the hand, +X the way the
## shield's face looks (away from the arm, the back of the hand's side). Made for one arm:
## on the other it comes out upside down.
@export var on_forearm: bool = false
