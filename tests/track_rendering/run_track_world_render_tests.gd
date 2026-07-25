extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const RendererType := preload("res://game/track/rendering/track_renderer.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const CompiledTrackType := preload("res://game/track/generation/compiled_track.gd")
const AnalyzerType := preload("res://game/track/generation/track_geometry_analyzer.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const PerspectiveType := preload("res://game/ui/components/race_perspective_view.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	_test_daylight_ground_contract(test)
	await _test_release_world(test)
	await _test_bridge_draw_contract(test)
	var result := test.result("track_world_rendering")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _test_daylight_ground_contract(test: RefCounted) -> void:
	var palette := PerspectiveType.daylight_palette()
	test.assert_true(
		palette["sky_top"].get_luminance() > 0.45,
		"active race sky is explicitly daylight-bright"
	)
	test.assert_true(
		palette["sky_horizon"].get_luminance() > palette["sky_top"].get_luminance(),
		"daylight sky brightens toward the atmospheric horizon"
	)
	test.assert_true(
		palette["grass_near"].get_luminance() > 0.20,
		"active race ground remains visibly sunlit"
	)
	var cockpit_horizon := PerspectiveType.environment_horizon_ratio(PerspectiveType.CAMERA_COCKPIT)
	var chase_horizon := PerspectiveType.environment_horizon_ratio(PerspectiveType.CAMERA_CHASE)
	test.assert_true(
		cockpit_horizon >= 0.28 and cockpit_horizon <= 0.38,
		"cockpit daylight terrain uses a bounded perspective horizon"
	)
	test.assert_true(
		chase_horizon >= 0.28 and chase_horizon <= 0.38,
		"chase daylight terrain uses a bounded perspective horizon"
	)
	var layers := PerspectiveType.grounded_road_layer_factors()
	test.assert_equal(layers.size(), 5, "grounded road exposes cut, foundation, gravel, kerb, and asphalt layers")
	if layers.size() == 5:
		test.assert_true(
			layers[0] > layers[1] and layers[1] > layers[2] \
				and layers[2] > layers[3] and layers[3] > layers[4],
			"road construction layers descend continuously into the asphalt footprint"
		)
	test.assert_true(
		RendererType.WORLD_GRASS.get_luminance() > DesignSystem.GRASS.get_luminance(),
		"track previews use the same brighter daytime-world intent"
	)


func _test_release_world(test: RefCounted) -> void:
	# Crescent owns the catalog's reviewed right-side pit plan. Evergreen was
	# intentionally redesigned as the accessible no-pit Trident, so using it as
	# the pit renderer fixture would test stale content rather than rendering.
	var definition: TrackDefinition = CatalogType.by_id("builtin-crescent-run")["definition"]
	test.assert_equal(
		definition.pit_side,
		TrackDefinitionType.PIT_RIGHT,
		"release renderer fixture uses the intended Crescent right-side pit plan"
	)
	var compiled_result: TrackCompileResult = CompilerType.compile(definition)
	test.assert_true(compiled_result.succeeded(), "release pit-lane fixture must compile")
	if not compiled_result.succeeded():
		return
	var definition_before := definition.canonical_json(true)
	var centerline_before := compiled_result.track.centerline.duplicate()
	var renderer := RendererType.new()
	renderer.size = Vector2(1280.0, 720.0)
	root.add_child(renderer)
	var accepted := renderer.set_track_world(definition, compiled_result.track)
	await process_frame
	renderer.queue_redraw()
	await process_frame
	test.assert_true(accepted, "renderer must accept valid deterministic world data")
	test.assert_true(renderer.get_world_plan()["valid"], "renderer exposes the aggregate world plan")
	test.assert_true(renderer.get_world_plan()["scenery"]["placements"].size() > 0, "renderer receives planned scenery")
	test.assert_true(renderer.get_world_plan()["pit_lane"]["enabled"], "renderer receives planned pit geometry")
	test.assert_true(renderer.get_minimap_plan()["closed"], "renderer exposes a closed minimap")
	test.assert_true(renderer.get_tour_plan()["camera_path"].size() >= 16, "renderer exposes planned tour waypoints")
	var baseline := renderer.get_track_point(0.25)
	test.assert_true(renderer.set_tour_progress(0.25), "valid tour plan drives the presentation camera")
	var focused := renderer.get_track_point(0.25)
	test.assert_true(renderer._view_zoom > 1.0, "tour camera applies planned zoom")
	test.assert_true(focused != baseline, "tour camera transforms presentation coordinates")
	renderer.clear_tour_camera()
	test.assert_near(renderer.get_track_point(0.25).distance_to(baseline), 0.0, 0.001, "clearing tour camera restores overview mapping")
	test.assert_equal(definition.canonical_json(true), definition_before, "renderer treats TrackDefinition as read-only")
	test.assert_equal(compiled_result.track.centerline, centerline_before, "renderer treats CompiledTrack as read-only")
	renderer.set_compiled_track(compiled_result.track)
	test.assert_true(renderer.get_world_plan().is_empty(), "legacy set_compiled_track remains available and clears feature state")
	test.assert_equal(renderer.curve.size(), compiled_result.track.centerline.size() + 1, "legacy compiled renderer path still rebuilds its curve")
	root.remove_child(renderer)
	renderer.free()


func _test_bridge_draw_contract(test: RefCounted) -> void:
	var compiled := _make_bow_tie()
	var crossings := ValidatorType.find_crossings(compiled)
	test.assert_equal(crossings.size(), 1, "visual bridge fixture contains one crossing")
	if crossings.is_empty():
		return
	var definition := TrackDefinitionType.new()
	definition.track_id = compiled.track_id
	definition.canvas_size = compiled.canvas_size
	definition.target_length = compiled.total_length
	definition.track_width = compiled.track_width
	definition.theme = compiled.theme
	definition.decoration_density = 0.5
	definition.deterministic_seed = compiled.deterministic_seed
	definition.bridge_crossings.append(BridgeDefinitionType.new(
		"visual-overpass",
		QuantizationType.scalar(float(crossings[0]["distance_a"])),
		QuantizationType.scalar(float(crossings[0]["distance_b"])),
		BridgeDefinitionType.OVERPASS_B
	))
	var renderer := RendererType.new()
	renderer.size = Vector2(960.0, 640.0)
	root.add_child(renderer)
	var accepted := renderer.set_track_world(definition, compiled)
	await process_frame
	renderer.queue_redraw()
	await process_frame
	var world := renderer.get_world_plan()
	test.assert_true(accepted, "renderer accepts a declared bridge world")
	test.assert_equal(world["bridges"]["crossings"].size(), 1, "bridge render phase receives one crossing")
	if not world["bridges"]["crossings"].is_empty():
		var crossing: Dictionary = world["bridges"]["crossings"][0]
		test.assert_equal(crossing["draw_sequence"][0]["kind"], "road_branch", "bridge draw contract begins with underpass")
		test.assert_equal(crossing["draw_sequence"][1]["kind"], "bridge_shadow", "bridge shadow follows underpass")
		test.assert_equal(crossing["draw_sequence"][2]["kind"], "bridge_deck", "elevated deck follows its shadow")
		test.assert_equal(crossing["ramps"].size(), 2, "bridge render contract includes both ramps")
		var deck_line := renderer._display_world_polyline(crossing["deck"]["polyline"])
		test.assert_true(deck_line.size() >= 2, "bridge deck converts from authored world to presentation coordinates")
	root.remove_child(renderer)
	renderer.free()


func _make_bow_tie() -> CompiledTrack:
	var points := PackedVector2Array([
		Vector2(180.0, 180.0), Vector2(820.0, 820.0),
		Vector2(820.0, 180.0), Vector2(180.0, 820.0),
	])
	var analysis := AnalyzerType.analyze(points)
	var compiled := CompiledTrackType.new()
	compiled.source_hash = "bridge-render-source"
	compiled.compile_hash = "bridge-render-compile"
	compiled.track_id = "bridge-render-fixture"
	compiled.canvas_size = Vector2(1000.0, 1000.0)
	compiled.theme = &"night"
	compiled.pit_side = TrackDefinitionType.PIT_NONE
	compiled.decoration_density = 0.5
	compiled.deterministic_seed = 91827
	compiled.track_width = 28.0
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
