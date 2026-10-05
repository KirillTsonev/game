# Compares two benchmark reports written by scripts/debug/perf_bench.gd (res://perf_reports/*.json).
#   powershell -File tools\perf_compare.ps1                      -> the two newest reports (older = A, newer = B)
#   powershell -File tools\perf_compare.ps1 -A <a.json> -B <b.json>
# Positive "saved" = B is cheaper than A. If either run was frame-capped (see the report header),
# only the GPU columns mean anything.
param([string]$A, [string]$B)

$dir = Join-Path $PSScriptRoot "..\perf_reports"
if (-not $A -or -not $B) {
    $newest = Get-ChildItem $dir -Filter *.json | Sort-Object Name | Select-Object -Last 2
    if ($newest.Count -lt 2) { Write-Error "Need two reports in $dir (or pass -A and -B)."; exit 1 }
    $A = $newest[0].FullName
    $B = $newest[1].FullName
}
$ra = Get-Content $A -Raw | ConvertFrom-Json
$rb = Get-Content $B -Raw | ConvertFrom-Json

function Row($name, $a, $b, $unit) {
    $saved = $a - $b
    $pct = if ($a -ne 0) { 100.0 * $saved / $a } else { 0 }
    "{0,-34} {1,10:N2} -> {2,10:N2} {3,-3}  saved {4,9:N2} ({5,6:N1} %)" -f $name, $a, $b, $unit, $saved, $pct
}

"A: {0}  [{1} {2}]" -f (Split-Path $A -Leaf), $ra.meta.git, $ra.meta.label
"B: {0}  [{1} {2}]" -f (Split-Path $B -Leaf), $rb.meta.git, $rb.meta.label
if ($ra.meta.frame_capped -or $rb.meta.frame_capped) { "!! at least one run was frame-capped: compare GPU ms only" }
if (($ra.meta.viewport -join 'x') -ne ($rb.meta.viewport -join 'x') -or $ra.meta.seed -ne $rb.meta.seed -or $ra.meta.scaling_3d_scale -ne $rb.meta.scaling_3d_scale) {
    "!! viewport, seed or 3D scale differ between the runs: NOT comparable"
}

""; "STATIONS"
foreach ($sa in $ra.stations) {
    $sb = $rb.stations | Where-Object { $_.name -eq $sa.name }
    if (-not $sb) { continue }
    Row "$($sa.name) GPU"        $sa.gpu_ms        $sb.gpu_ms        "ms"
    Row "$($sa.name) frame"      $sa.frame_ms      $sb.frame_ms      "ms"
    Row "$($sa.name) CPU render" $sa.cpu_render_ms $sb.cpu_render_ms "ms"
    Row "$($sa.name) draws"      $sa.draw_calls    $sb.draw_calls    ""
    Row "$($sa.name) tris (M)"   ($sa.primitives / 1e6) ($sb.primitives / 1e6) ""
    Row "$($sa.name) VRAM"       $sa.video_mem_mb  $sb.video_mem_mb  "MB"
}

""; "ABLATION: GPU ms each thing costs (A -> B)"
foreach ($aa in $ra.ablation) {
    $ab = $rb.ablation | Where-Object { $_.station -eq $aa.station }
    if (-not $ab) { continue }
    "  at $($aa.station)"
    foreach ($ta in $aa.toggles) {
        $tb = $ab.toggles | Where-Object { $_.name -eq $ta.name }
        if ($tb) { Row "    $($ta.name)" $ta.delta_gpu_ms $tb.delta_gpu_ms "ms" }
    }
}

""; "WALK"
Row "frame avg"  $ra.walk.frame_ms $rb.walk.frame_ms "ms"
Row "frame p99"  $ra.walk.p99_ms   $rb.walk.p99_ms   "ms"
Row "frame worst" $ra.walk.max_ms  $rb.walk.max_ms   "ms"
Row "GPU avg"    $ra.walk.gpu_ms   $rb.walk.gpu_ms   "ms"
Row "frames over 16.7 ms" $ra.walk.frames_over_16_7_ms $rb.walk.frames_over_16_7_ms ""

""; "STARTUP"
Row "_ready() total" $ra.startup.ready_total_ms $rb.startup.ready_total_ms "ms"
Row "first frame at" $ra.startup.first_frame_at_ms $rb.startup.first_frame_at_ms "ms"
foreach ($stage in $ra.startup.stage_ms.PSObject.Properties) {
    $other = $rb.startup.stage_ms.PSObject.Properties[$stage.Name]
    if ($other) { Row "  $($stage.Name)" $stage.Value $other.Value "ms" }
}

""; "LAYERS: instances x LOD 0 triangles (M)"
foreach ($la in $ra.audit.layers) {
    $lb = $rb.audit.layers | Where-Object { $_.layer -eq $la.layer }
    if ($lb) { Row $la.layer ($la.lod0_total_tris / 1e6) ($lb.lod0_total_tris / 1e6) "" }
}
Row "textures (estimated)" $ra.audit.textures.total_mb $rb.audit.textures.total_mb "MB"
