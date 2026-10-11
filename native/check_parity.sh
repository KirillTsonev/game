#!/bin/bash
# Checks that the native kernels give the same world as the GDScript loops they copy.
#   native/check_parity.sh              the two test seeds
#   native/check_parity.sh 123 456      other seeds
# Starts the game four times per run (each seed with the library and with --no-native-kernels,
# world cache off, 20 frames each: about a minute in all) and compares every checksum line and
# every other log line that carries no timing. Prints PASS or FAIL per seed; exit code 1 on a FAIL.
# Run it after changing a loop that has a kernel, or the kernel (docs/native_kernels.md).
# Not while a game is running: each start opens a game window for a few seconds.
# The game's own exit code is ignored (it crashes on quit, a known fault, after the log is written).
cd "$(dirname "$0")/.."
PROJECT="$(pwd)"
GODOT="$PROJECT/../Godot_v4.7.2-stable_win64_console.exe"
OUT="${TMPDIR:-/tmp}/terrain_kernels_parity"
mkdir -p "$OUT"
SEEDS="${*:-3082472107 2415213935}"

# The lines that must match: everything the generation prints, without its timings.
comparable() {
	grep -E "TERRAIN_GEN|GRASS|GROUND_PAINT" "$1" \
		| grep -vE "native kernels|world cache|TERRAIN_GEN_STARTUP|KNOT_PROFILE|TOTAL|heightmap build took|started at t=" \
		| sed -E 's/\(?[0-9.]+ ?m?s\)?( --.*untimed.*)?$//; s/timing.*$//; s/[0-9]+ ms//g; s/\([0-9.]+s[^)]*\)//g; s/[0-9]+\.[0-9]+s\b//g'
}

failed=0
for seed in $SEEDS; do
	for mode in native script; do
		extra=""
		[ "$mode" = script ] && extra="--no-native-kernels"
		"$GODOT" --path "$PROJECT" --quit-after 20 -- --seed=$seed --no-world-cache $extra > "$OUT/${mode}_$seed.log" 2>&1
	done
	if ! grep -q "native kernels -- in use" "$OUT/native_$seed.log"; then
		echo "FAIL seed $seed: the library was not in use ($(grep -o 'native kernels -- .*' "$OUT/native_$seed.log" | head -1))"
		failed=1
		continue
	fi
	off="$(grep -o 'left to their GDScript loops.*' "$OUT/native_$seed.log" | head -1)"
	checks="$(grep -c checksum "$OUT/native_$seed.log")"
	if [ "$checks" -lt 5 ]; then
		echo "FAIL seed $seed: only $checks checksum line(s) in the log -- did the game start? See $OUT/native_$seed.log"
		failed=1
		continue
	fi
	if grep -qE "SCRIPT ERROR|Parse Error|TerrainKernels:" "$OUT/native_$seed.log" "$OUT/script_$seed.log"; then
		echo "FAIL seed $seed: script or kernel errors in the log:"
		grep -hE "SCRIPT ERROR|Parse Error|TerrainKernels:" "$OUT/native_$seed.log" "$OUT/script_$seed.log" | sort -u | head -5
		failed=1
		continue
	fi
	comparable "$OUT/native_$seed.log" > "$OUT/native_$seed.cmp"
	comparable "$OUT/script_$seed.log" > "$OUT/script_$seed.cmp"
	if diff -q "$OUT/native_$seed.cmp" "$OUT/script_$seed.cmp" > /dev/null; then
		echo "PASS seed $seed: $checks checksum lines and $(wc -l < "$OUT/native_$seed.cmp") log lines identical${off:+ ($off)}"
	else
		echo "FAIL seed $seed: the library and the scripts differ (< library, > scripts):"
		diff "$OUT/native_$seed.cmp" "$OUT/script_$seed.cmp" | head -12 | cut -c1-220
		failed=1
	fi
done
echo "logs: $OUT"
exit $failed
