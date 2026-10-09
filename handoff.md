Yes, and your instinct (change something by position, undo it on the way down) is the right mechanism. I'd point it at something other than light energy, though.

Why it reads as a blob. I checked the scene settings: there is no fog at all, the moon is the only light at energy 2, and the ambient light is one flat blue. Seen from above, every crown lands in the same narrow dark band, with nothing separating near trees from far ones. Raising the moon's energy lifts that whole band together, so you'd mostly get a brighter blob; the view lacks separation more than exposure.

Ideas, best value first:

Moonlit mist in the valley. Distance fog plus height fog that pools below the crowns turns the mass into layers: dark near crowns against paler ones behind, and trunks fading into haze. This is the standard trick for exactly this view, and the non-volumetric kind costs almost nothing. Its density can be driven by the player's position: thick from the ledge, thinning as you descend, so the forest interior looks as it does now.

Pick the moon's direction for this view. The hub is fixed and the ledge always faces north, so the moon can be placed for it. Light from the side or from behind the forest rims each crown and gives it a shadowed side; light from behind the viewer flattens it. This changes shadows everywhere in the map, so it is a look decision for the whole game.

Lighten the tops of the crowns. A small change in the leaf shader that brightens and slightly desaturates leaves near the top of each tree, perhaps with a per-tree variation. From the ledge each crown becomes a separate shape; from the ground you never see the tops, so nothing changes down there.

Give the eye something bright. Zelda and Elden Ring overlooks work because of landmarks more than forest detail: a lit window, a campfire glow in a clearing, a pale ruin, the road as a light ribbon, water catching the moon. A few of these make the dark forest read as intentional contrast. It also answers the open "which way to go" question in the handoff.

Your idea, as exposure instead of light energy. Blend the tonemap exposure or the ambient energy up near the ledge and back down along the trail, like eyes adjusting. It is cheap and works, with one catch: the plateau and village brighten too, so the blend has to be slow enough to go unnoticed. I'd use it as a small top-up after the others.

Break up the mass. Clearings, the road cut and rock outcrops that catch light give the silhouette detail. This is generation work and the most expensive of the six.

My recommendation: try 1 first, then 3, and treat 4 as content for later.

Fog is something you can judge yourself in a minute, live in the Inspector on the WorldEnvironment, with no code. Starting values to try, not tuned:

Fog: enabled, density about 0.002, light colour a dim blue-grey a little brighter than the canopy, sun scatter about 0.3.
Height fog: height around 15–20 m (the valley floor is at 4 m, the plateau at 34 m), with a small height density so it thickens toward the ground.
If the fog looks right from the ledge but too thick inside the forest, that is where the position-driven blend comes in.
