extends SceneTree
## Visual-only declared-overpass fixture for deterministic screenshot review.

const RendererType := preload("res://game/track/rendering/track_renderer.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const CompiledTrackType := preload("res://game/track/generation/compiled_track.gd")
const AnalyzerType := preload("res://game/track/generation/track_geometry_analyzer.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")
const QuantizationType := preload("res://game/core/quantization.gd")


func _initialize() -> void:
	_build.call_deferred()


func _build() -> void:
	root.size = Vector2i(1280, 720)
	var backdrop := ColorRect.new()
	backdrop.color = DesignSystem.INK
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(backdrop)
	var renderer := RendererType.new()
	renderer.position = Vector2(42.0, 106.0)
	renderer.size = Vector2(1196.0, 568.0)
	renderer.clip_contents = true
	root.add_child(renderer)
	var title := DesignSystem.title("DECLARED OVERPASS", 36)
	title.position = Vector2(46.0, 28.0)
	title.size = Vector2(600.0, 52.0)
	root.add_child(title)
	var detail := DesignSystem.label("UNDERPASS  →  SHADOW  →  RAMPS  →  ELEVATED DECK", 15, DesignSystem.MINT)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	detail.position = Vector2(620.0, 40.0)
	detail.size = Vector2(614.0, 30.0)
	root.add_child(detail)
	var compiled := _make_bow_tie()
	var crossings := ValidatorType.find_crossings(compiled)
	if crossings.is_empty():
		return
	var definition := TrackDefinitionType.new()
	definition.track_id = compiled.track_id
	definition.canvas_size = compiled.canvas_size
	definition.target_length = compiled.total_length
	definition.track_width = compiled.track_width
	definition.theme = compiled.theme
	definition.decoration_density = 0.45
	definition.deterministic_seed = compiled.deterministic_seed
	definition.bridge_crossings.append(BridgeDefinitionType.new(
		"crosswind-overpass",
		QuantizationType.scalar(float(crossings[0]["distance_a"])),
		QuantizationType.scalar(float(crossings[0]["distance_b"])),
		BridgeDefinitionType.OVERPASS_B
	))
	renderer.set_track_world(definition, compiled)


func _make_bow_tie() -> CompiledTrack:
	var points := PackedVector2Array([
		Vector2(170.0, 210.0), Vector2(830.0, 790.0),
		Vector2(830.0, 210.0), Vector2(170.0, 790.0),
	])
	var analysis := AnalyzerType.analyze(points)
	var compiled := CompiledTrackType.new()
	compiled.source_hash = "bridge-visual-source"
	compiled.compile_hash = "bridge-visual-compile"
	compiled.track_id = "bridge-visual-fixture"
	compiled.canvas_size = Vector2(1000.0, 1000.0)
	compiled.theme = &"night"
	compiled.pit_side = TrackDefinitionType.PIT_NONE
	compiled.decoration_density = 0.45
	compiled.deterministic_seed = 62913
	compiled.track_width = 42.0
	compiled.sample_spacing = 8.0
	compiled.centerline = points
	compiled.tangents = analysis.tangents
	compiled.normals = analysis.normals
	compiled.curvatures = analysis.curvatures
	compiled.radii = analysis.radii
	compiled.arc_distances = analysis.arc_distances
	compiled.total_length = analysis.total_length
	compiled.straight_sections = analysis.straight_sections
	compiled.corner_sections = analysis.corner_sections
	compiled.left_edge.resize(points.size())
	compiled.right_edge.resize(points.size())
	for index in points.size():
		compiled.left_edge[index] = points[index] + compiled.normals[index] * compiled.track_width * 0.5
		compiled.right_edge[index] = points[index] - compiled.normals[index] * compiled.track_width * 0.5
	return compiled
