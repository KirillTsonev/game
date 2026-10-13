# Weapons in hands

(2026-10-13) How a weapon gets into a hand, how to add a weapon, and how to give one to a
body. One-handed, right hand only so far. Not judged in game yet.

## How it works

Two places are laid on each other:

- **The weapon's grip** -- `WeaponData.grip` (`scripts/weapons/weapon_data.gd`), set once per
  weapon: where the middle of the fist goes on the handle, +Y toward the blade or head, +X
  the way the leading edge faces.
- **The hand's socket** -- `WeaponHold.socket()` (`scripts/weapons/weapon_hold.gd`), worked out
  from the hand's bones: the middle of the closed fist, +Y out of the thumb's side, +X toward
  the knuckles. Its numbers were measured on the rogue's glove and are scaled by the hand's
  length, so a body on the humanoid skeleton needs no setup.

Ten weapons and five bodies are fifteen setups (in practice ten: the bodies need none), never
fifty.

**The socket never poses the arm.** Where a weapon points is the arm's pose, and that comes
from a clip, or for the player, until the combat clips are in, from the stance in
`PlayerBody._hold_weapon` (the fist at a place set from the eyes, elbow down, palm inward,
wrist tipped by `weapon_wrist_tilt`; the `weapon_*` settings of the Body node). The first
sword hold did the opposite -- it rolled the forearm until the blade pointed a set way -- and
so any grip, right or wrong, gave the same sword with a forearm twisted up to half a turn.

## Adding a weapon

1. The model, as a `.glb` or scene. Any origin and any axes will do, but the handle straight.
2. A `WeaponData` resource beside it (`assets/models/weapons/sword/sword.tres` is the pattern):
   - `scene`: the model.
   - `grip`: origin on the handle's middle line where the fist's middle goes (for the sword
     0.0735 m above the handle's middle, which leaves the hand's upper edge 1.5 cm under the
     guard); +Y along the handle toward the blade; +X toward the leading edge.
   - `grip_radius`: the handle's thickness from its middle line there.
3. Look at it: set it as `weapon` on the Body of `scenes/player_body.tscn`. The editor shows the
   arm in a hold with the fist closed and the weapon in it. Change `grip` in the resource until
   it sits right; the view follows.

## Giving a weapon to a body

- The player: `PlayerBody.equip(data)` at any time (`null` empties the hand); `weapon` on the
  Body node is what it starts with.
- Anything else on the humanoid skeleton: `WeaponHold.attach(skeleton, "Right", data)` puts the
  model on a BoneAttachment3D. Its clips pose the arm. Its fingers must be closed after its
  clips have run each frame (`WeaponHold.close_fist` with `WeaponHold.fist_curls`), or they
  stay as the clip has them.
- A body the worked-out socket does not suit: give it a Marker3D with
  `scripts/weapons/hand_socket.gd` as its direct child (`WeaponSocket` in
  `scenes/player_body.tscn`), switch its `automatic` off and move it by eye in the editor: the
  node sits in the fist and keeps what it is moved to in its `socket`. With `automatic` on it
  is put back every frame. `PlayerBody` reads `socket` every frame, so it can be changed in
  the Remote tree while the game runs.

## The sword arm from clips (a try, 2026-10-13)

`raw-assets/animations/Pro Sword and Shield Pack` is Mixamo's: 51 clips on the skeleton the jogs
and dodges use (4 idles; attacks and slashes, four in place and five that lunge 1 to 3.6 m,
three of those with a jump or a drop; walk, run and strafes at about 1.1-1.5 and 3.4-4.4 m/s,
no diagonals; blocks; 3 impacts, 2 deaths; draw / sheath; kick, jumps, turns, casting). Every
clip holds a shield on the left arm and stands in a combat crouch (head about 12 cm lower).

Three are in the project (`sword_idle` = "idle (4)", `sword_slash` = "slash", `sword_attack` =
"attack (4)"), and ONLY THEIR RIGHT ARM is used: `PlayerBody.ARM_CLIPS`, played by a second
AnimationPlayer after the body's (`_advance_arm`), so legs, body, left arm and camera are as
before. Left click = `PlayerBody.attack()`, the two swings in turn. `weapon_arm_from_clips` on
the Body switches between this and the stance worked out in code.

Measured on the sword's mesh, not judged in game:

- **The idle holds the sword beside and behind the head.** The pack is made to be seen from
  outside: the hand is 0.4 m right of, 0.5 m below and 0.2-0.4 m BEHIND the eyes (in the
  source clip itself 0.44 m behind). Only the blade's upper part can be in the picture (tip
  about 47 deg right standing, 50-110 deg right jogging), and the sword passes 0.15-0.2 m
  from the eyes.
- The slash goes back over the shoulder for 0.5 s (out of the picture), crosses the view low
  from right to left in about 0.1 s, and takes 0.8 s to come back. The attack is mostly beside
  and behind the head too.
- With the arm alone, the body does not turn into a swing.

## A first-person reference: Skyrim (measured 2026-10-13)

Kirill's reference for what a sword should look like from the eyes: Skyrim's own first-person
clips and the mod in `raw-assets/animations/All in one 161095 ...` (728 clips for the "Stances
- Dynamic Weapon Movesets SE" mod: four stances, each with idle, walk, run, attacks, power
attacks, blocks, staggers, draw / sheathe, dodges). To be measured and aimed at, not copied
into the game (the mod is its author's).

`tools/skyrim_reference/` reads them: `bsa.py` (a file out of the game's archives, read-only;
the game is at `E:\Games\The Elder Scrolls 5 Skyrim Anniversary Edition`), `hkx.py` (the
Havok 2010 64-bit files: the skeleton, and a spline-compressed clip sampled per frame, with
its named events), `measure.py` (hand, grip and blade from the camera through a clip). The
skeleton is `meshes\actors\character\_1stperson\characterassets\skeletonfirst.hkx` in
`Skyrim - Animations.bsa`; the mod's files hold tracks by bone number only. The reader was
checked on Skyrim's own idle: every bone's length comes out as in the skeleton's rest pose.
The blade is taken as the Weapon bone's +Y, the axis nearest the fist's thumb side (0.94) --
worked out from the hand, not read from a sword's mesh.

What it shows (metres from the camera: right, ahead, up):

- **The arms are placed for the camera, not on a body.** The right shoulder is 0.15-0.2 right
  of the camera, 0.17-0.32 below and only 0.05-0.09 BEHIND it. Ours is 0.36 behind. So their
  fist rests 0.39-0.52 m AHEAD of the camera; ours cannot get past about 0.1-0.25.
- At rest the grip is about (+0.22, +0.4, -0.2 to -0.3). The blade: Skyrim's own idle 57 deg
  above level, tip 25 deg right / 30 up; the mod's mid stance 21 deg above level and pointing
  ahead, tip near the picture's middle; low 44 deg; neutral 70 deg; high: back over the shoulder.
- Skyrim's own right attack (1.47 s) is the plain template: 0-0.27 s the hand out to the right
  (+0.6, +0.2-0.4, +0.12), blade pointing right and back; 0.27-0.5 s the cut, the grip going
  from +0.65 to -0.41 right at camera height, 0.4-0.7 ahead, blade level, tip up to 34 m/s;
  to 0.9 s it follows through down to the left (-0.15, +0.06, -0.67); to 1.47 s back to rest.
  The camera turns 10 deg with it.
- The mod's attacks are two cuts in one clip (hits at 0.67 and 0.97 s), a held pose from 1.4
  to 2.1 s in which the next attack may start, and the way back to rest by 2.5 s. Their arm
  bones are also moved bodily (the grip up to 1.4 m to the side with the elbow straight): what
  happens outside the picture is not anatomy.

## Pitfalls

- **Find a model's axes on its mesh, never from a note or its scene's root.** The sword's
  import tool said "blade along +Y"; the mesh node inside `sword.glb` is turned 90 degrees and
  the blade runs along the scene's +Z. Every grip of the first day was fitted to an axis the
  blade was not on, and every check read the weapon node's own +Y, so the numbers passed while
  the sword lay level across the wrist (Kirill's screenshot, 2026-10-13). A check of a hold
  takes the two ends of the weapon from its mesh's vertices, in the world.
- **In the editor a body stands in the T-pose, palms down.** A weapon held rightly lies LEVEL
  there, pointing ahead; turned upright by eye it goes through the palm. That is why
  `hand_socket.gd` poses the arm in the editor. Judge a grip in that pose only.
- Measure on the glove's surface, sampled on its faces, not on finger bones or vertices: a
  grip 3 cm clear of every bone went through the palm.
- A check must measure what a wrong result would change. "Blade within 5 degrees of the
  direction asked" passed for every grip, because the solver made it so. What showed the
  fault: the forearm's roll, which way the palm faces, and the wrist's bend.
- Known and left: the thumb is not closed (closed, its surface goes into the handle); the
  finger curls for another handle thickness are an estimate (`CURL_PER_METRE`); turning the
  lantern on / off (L) uses the same hand and opens it round the weapon.
