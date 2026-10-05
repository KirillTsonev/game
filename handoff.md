These are the open items from the list I gave after the painterly rewrite, largest first, with what has changed since:

1. **The visible trees: 2.3–2.6 ms of GPU.** This is the largest remaining item. The trees draw their full mesh (5,800–11,300 triangles) out to 175 m, then switch to an 8-triangle impostor. The fix is a mid-distance LOD in between. It has the biggest visual risk, because the crowns are leaf cards and those simplify badly, so each tree needs your eye. About a third of this cost is per pixel (leaf cards overdrawing each other), so the mid LOD should use fewer, larger cards.

2. **Tree shadows from a cheaper mesh: ceiling about 1 ms, measured.** Every tree casts its shadow from the full mesh in each cascade. I tested the extreme case (casting from the impostor) and it saved 0.6–1.3 ms, so that is the most this can give. Two ways to get there:
   - Build reduced shadow meshes for the 14 trees in Blender; my guess is 0.5–0.9 ms recovered.
   - Look at whether the impostor's own shadows are acceptable as they are. That would be the full 1 ms for no work, but I expect them to look wrong near the player.

3. **MSAA: 0.6–1.0 ms.** This is a look decision, like SSAO was: it smooths geometry edges, and the grass shader notes say thin blades depend on it. I can add a toggle to the Options pane so you can judge it against the live scene.

4. **The other five post effects: done as far as is worthwhile.** The Gaussian blur's wasted copy is removed (0.04 ms). What remains is 0.1–0.2 ms and would tie the effects together, which I advised against in my last two answers.

Two smaller ones I mentioned earlier and you asked about:

5. **Saplings casting shadows from their impostors.** The whole sapling layer is 0.16–0.29 ms of GPU and 0.33–0.92 ms of CPU, so the gain is a fraction of that. Their shadows would stop at 80 m instead of 150 m.

6. **Radial blur's sample count, 16 to 8:** about 0.05 ms, a slight look change toward the screen corners.

And one that is parked, not open:

7. **GPU-driven drawing for the ferns and bushes.** This is a CPU-side fix, and the frame is GPU-limited since the understory shadow change, so it would not raise the frame rate now.

My recommendation is unchanged: item 2 first, because its ceiling is measured and the visible trees stay exactly as they are, then item 1. Item 3 is the cheapest to try if you want a quick look-versus-speed decision in between.
