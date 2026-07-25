extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const CompiledTrackType := preload("res://game/track/generation/compiled_track.gd")
const AnalyzerType := preload("res://game/track/generation/track_geometry_analyzer.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")
const BridgePlanner := preload("res://game/track/features/bridge_plan_builder.gd")
const PitPlanner := preload("res://game/track/features/pit_lane_plan_builder.gd")
const SceneryPlanner := preload("res://game/track/features/scenery_plan_builder.gd")
const MinimapPlanner := preload("res://game/track/features/minimap_plan_builder.gd")
const TourPlanner := preload("res://game/track/features/track_tour_plan_builder.gd")
const WorldPlanner := preload("res://game/track/features/track_world_feature_planner.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_bridge_plans(test)
	_test_pit_sides(test)
	_test_scenery_determinism_and_clearance(test)
	_test_minimap_and_tour(test)
	_test_compiler_integration(test)
	_test_malformed_arrays_fail_closed(test)
	return test.result("track_world_features")


func _test_bridge_plans(test: RefCounted) -> void:
	var plain := _make_long_rectangle()
	var plain_definition := _definition_for(plain)
	var plain_before := plain.centerline.duplicate()
	var no_crossing := BridgePlanner.plan(plain_definition, plain)
	test.assert_true(no_crossing["valid"], "non-crossing track must produce a valid empty bridge plan")
	test.assert_equal(no_crossing["crossings"].size(), 0, "non-crossing track has no bridge plans")
	test.assert_equal(plain.centerline, plain_before, "bridge planning must not mutate compiled geometry")

	var crossing := _make_bow_tie()
	var crossing_definition := _definition_for(crossing)
	var actual := ValidatorType.find_crossings(crossing)
	test.assert_equal(actual.size(), 1, "bow-tie fixture must expose exactly one crossing")
	if actual.is_empty():
		return
	var crossing_declaration := BridgeDefinitionType.new(
		"bridge-main",
		QuantizationType.scalar(float(actual[0]["distance_a"]) + 5.0),
		QuantizationType.scalar(float(actual[0]["distance_b"]) - 5.0),
		BridgeDefinitionType.OVERPASS_B
	)
	crossing_definition.bridge_crossings.append(crossing_declaration)
	var bridge_plan := BridgePlanner.plan(crossing_definition, crossing)
	test.assert_true(bridge_plan["valid"], "declared geometric crossing must build a bridge plan: %s" % str(bridge_plan["errors"]))
	test.assert_equal(bridge_plan["crossings"].size(), 1, "one declaration yields one bridge")
	if bridge_plan["crossings"].is_empty():
		return
	var planned: Dictionary = bridge_plan["crossings"][0]
	test.assert_equal(planned["overpass_branch"], "b", "authored overpass branch must be retained")
	test.assert_equal(planned["branch_a"]["elevation_level"], 0, "underpass branch uses ground elevation")
	test.assert_equal(planned["branch_b"]["elevation_level"], 1, "overpass branch is elevated")
	test.assert_near(
		float(planned["branch_a"]["lap_distance"]), float(actual[0]["distance_a"]), 0.001,
		"bridge deck geometry uses detected crossing distance instead of an approximate declaration"
	)
	test.assert_equal(
		planned["branch_a"]["authored_lap_distance"], crossing_declaration.distance_a,
		"bridge plan retains authored distance for diagnostics"
	)
	test.assert_equal(planned["draw_sequence"][0]["branch"], "a", "underpass renders before bridge shadow/deck")
	test.assert_equal(planned["draw_sequence"][2]["branch"], "b", "elevated deck renders after its shadow")
	test.assert_equal(planned["collision"]["branch_a_layer"], 1, "underpass collision metadata uses ground layer")
	test.assert_equal(planned["collision"]["branch_b_layer"], 2, "overpass collision metadata uses elevated layer")
	test.assert_equal(planned["ramps"].size(), 2, "bridge has an entry and exit ramp")
	test.assert_true(planned["ramps"][0]["profile"].size() >= 2, "entry ramp contains a height profile")
	test.assert_true(planned["deck"]["polyline"].size() <= 64, "bridge deck polyline obeys its cap")
	test.assert_equal(bridge_plan["exclusion_zones"].size(), 1, "bridge exposes scenery exclusion metadata")

	var undeclared_definition := _definition_for(crossing)
	var undeclared := BridgePlanner.plan(undeclared_definition, crossing)
	test.assert_false(undeclared["valid"], "undeclared self-crossing must fail closed")
	test.assert_true(_has_error(undeclared, "bridge.undeclared_crossing"), "undeclared crossing has a stable error code")


func _test_pit_sides(test: RefCounted) -> void:
	var compiled := _make_long_rectangle()
	var definition := _definition_for(compiled)
	definition.pit_side = TrackDefinitionType.PIT_NONE
	compiled.pit_side = TrackDefinitionType.PIT_NONE
	var no_pit := PitPlanner.plan(definition, compiled)
	test.assert_true(no_pit["valid"], "pit_side none is a valid disabled plan")
	test.assert_false(no_pit["enabled"], "pit_side none must not derive lane geometry")
	test.assert_equal(no_pit["lane_polyline"].size(), 0, "disabled pit has no lane samples")

	definition.pit_side = TrackDefinitionType.PIT_LEFT
	compiled.pit_side = TrackDefinitionType.PIT_LEFT
	var left := PitPlanner.plan(definition, compiled)
	test.assert_true(left["valid"], "left pit must plan on the long straight: %s" % str(left["errors"]))
	test.assert_true(left["enabled"], "left pit is enabled")
	test.assert_true(left["lane_polyline"].size() <= 128, "pit polyline obeys its sample cap")
	test.assert_true(left["boxes"].size() >= 1 and left["boxes"].size() <= 12, "pit box count is safely bounded")
	test.assert_true(not left["entry"].is_empty() and not left["exit"].is_empty(), "pit plan declares entry and exit")
	var middle_index: int = int(left["lane_samples"].size()) / 2
	var left_middle: Dictionary = left["lane_samples"][middle_index]
	var left_road := FeatureGeometry.sample_at_distance(compiled, float(left_middle["distance"]))
	test.assert_true(
		(left_middle["position"] - left_road["position"]).dot(left_road["normal"]) > 0.0,
		"left pit offsets along the route-left normal"
	)

	definition.pit_side = TrackDefinitionType.PIT_RIGHT
	compiled.pit_side = TrackDefinitionType.PIT_RIGHT
	var right := PitPlanner.plan(definition, compiled)
	test.assert_true(right["valid"], "right pit must plan on the same straight: %s" % str(right["errors"]))
	var right_middle: Dictionary = right["lane_samples"][int(right["lane_samples"].size()) / 2]
	var right_road := FeatureGeometry.sample_at_distance(compiled, float(right_middle["distance"]))
	test.assert_true(
		(right_middle["position"] - right_road["position"]).dot(right_road["normal"]) < 0.0,
		"right pit offsets opposite the route-left normal"
	)
	test.assert_true(left["fingerprint"] != right["fingerprint"], "pit side changes deterministic plan fingerprint")


func _test_scenery_determinism_and_clearance(test: RefCounted) -> void:
	var compiled := _make_long_rectangle()
	compiled.pit_side = TrackDefinitionType.PIT_LEFT
	var definition := _definition_for(compiled)
	definition.pit_side = TrackDefinitionType.PIT_LEFT
	definition.decoration_density = 1.0
	definition.deterministic_seed = 73191
	definition.theme = &"forest"
	compiled.theme = definition.theme
	var pit := PitPlanner.plan(definition, compiled)
	test.assert_true(pit["valid"], "scenery fixture pit plan must be valid")
	var bridge_zone := {
		"valid": true,
		"crossings": [],
		"exclusion_zones": [{
			"kind": "bridge",
			"id": "synthetic-clearance-probe",
			"center": Vector2(500.0, 600.0),
			"radius": 105.0,
		}],
	}
	var first := SceneryPlanner.plan(definition, compiled, pit, bridge_zone)
	var repeated := SceneryPlanner.plan(definition, compiled, pit, bridge_zone)
	test.assert_true(first["valid"], "valid scenery inputs produce a plan")
	test.assert_true(first["placements"].size() > 0, "dense track receives at least one decoration")
	test.assert_true(first["placements"].size() <= 160, "scenery placements obey the safety cap")
	test.assert_equal(first["fingerprint"], repeated["fingerprint"], "identical seed and inputs repeat byte-stably")
	test.assert_equal(first["placements"], repeated["placements"], "identical seed repeats placement data")

	var changed_definition := _definition_for(compiled)
	changed_definition.pit_side = definition.pit_side
	changed_definition.decoration_density = definition.decoration_density
	changed_definition.deterministic_seed = definition.deterministic_seed + 1
	changed_definition.theme = definition.theme
	var changed := SceneryPlanner.plan(changed_definition, compiled, pit, bridge_zone)
	test.assert_true(changed["fingerprint"] != first["fingerprint"], "changing only seed changes scenery fingerprint")

	var road_clearance := float(first["clearances"]["road"])
	var start_clearance := float(first["clearances"]["start_finish"])
	var pit_clearance := float(first["clearances"]["pit"])
	var pit_polyline: PackedVector2Array = pit["lane_polyline"]
	for placement in first["placements"]:
		var position: Vector2 = placement["position"]
		test.assert_true(
			FeatureGeometry.point_to_track_distance(position, compiled) + 0.001 >= road_clearance,
			"scenery remains outside road clearance"
		)
		test.assert_true(
			position.distance_to(compiled.centerline[0]) + 0.001 >= start_clearance,
			"scenery remains outside start/finish exclusion"
		)
		test.assert_true(
			FeatureGeometry.point_to_polyline_distance(position, pit_polyline) + 0.001 >= pit_clearance,
			"scenery remains outside pit-lane exclusion"
		)
		test.assert_true(
			position.distance_to(bridge_zone["exclusion_zones"][0]["center"]) + 0.001 \
					>= float(bridge_zone["exclusion_zones"][0]["radius"]),
			"scenery remains outside bridge/ramp exclusion"
		)
	var placement_spacing := float(first["clearances"]["between_placements"])
	for first_index in first["placements"].size():
		for second_index in range(first_index + 1, first["placements"].size()):
			test.assert_true(
				first["placements"][first_index]["position"].distance_to(
					first["placements"][second_index]["position"]
				) + 0.001 >= placement_spacing,
				"scenery placements maintain mutual clearance"
			)


func _test_minimap_and_tour(test: RefCounted) -> void:
	var compiled := _make_long_rectangle()
	compiled.pit_side = TrackDefinitionType.PIT_RIGHT
	var definition := _definition_for(compiled)
	definition.pit_side = TrackDefinitionType.PIT_RIGHT
	var pit := PitPlanner.plan(definition, compiled)
	var bridge := BridgePlanner.plan(definition, compiled)
	var minimap := MinimapPlanner.plan(compiled, pit, bridge, Vector2(320.0, 180.0), 14.0)
	test.assert_true(minimap["valid"], "minimap builds from valid geometry")
	test.assert_true(minimap["closed"], "minimap polyline is explicitly closed")
	test.assert_true(minimap["polyline"].size() >= 17 and minimap["polyline"].size() <= 193, "minimap route points obey caps")
	test.assert_equal(minimap["world_polyline"][0], minimap["world_polyline"][-1], "world minimap route closes exactly")
	test.assert_true(_has_marker(minimap["markers"], "start_finish"), "minimap contains start/finish marker")
	test.assert_true(_has_marker(minimap["markers"], "pit_entry"), "minimap contains pit entry marker")
	test.assert_true(_has_marker(minimap["markers"], "pit_exit"), "minimap contains pit exit marker")
	for point in minimap["polyline"]:
		test.assert_true(point.x >= 0.0 and point.x <= 320.0 and point.y >= 0.0 and point.y <= 180.0, "minimap point fits requested viewport")

	var tour := TourPlanner.plan(compiled, pit, bridge)
	test.assert_true(tour["valid"], "track tour builds from valid geometry")
	test.assert_true(tour["camera_path"].size() >= 16 and tour["camera_path"].size() <= 64, "tour path obeys waypoint caps")
	test.assert_true(tour["loop"], "tour explicitly declares its camera path as a loop")
	test.assert_equal(tour["summary"]["waypoint_count"], tour["camera_path"].size(), "tour summary reports actual waypoint count")
	test.assert_equal(tour["summary"]["pit_side"], "right", "tour summary includes pit side")
	test.assert_true(str(tour["summary"]["headline"]).contains("m lap"), "tour summary provides a display-ready headline")

	var world := WorldPlanner.plan(definition, compiled)
	test.assert_true(world["valid"], "aggregate planner succeeds when each subsystem succeeds: %s" % str(world["errors"]))
	test.assert_true(not str(world["fingerprint"]).is_empty(), "aggregate output is content fingerprinted")
	test.assert_equal(world["compile_hash"], compiled.compile_hash, "aggregate plan carries compiled identity without mutation")


func _test_malformed_arrays_fail_closed(test: RefCounted) -> void:
	var malformed := _make_long_rectangle()
	malformed.normals = PackedVector2Array()
	var definition := _definition_for(malformed)
	var plans := [
		BridgePlanner.plan(definition, malformed),
		PitPlanner.plan(definition, malformed),
		SceneryPlanner.plan(definition, malformed),
		MinimapPlanner.plan(malformed),
		TourPlanner.plan(malformed),
		WorldPlanner.plan(definition, malformed),
	]
	for feature_plan in plans:
		test.assert_false(feature_plan["valid"], "malformed compiled arrays must fail closed without indexing")
		test.assert_true(feature_plan["errors"].size() >= 1, "malformed compiled arrays return structured errors")
	var direct_errors := FeatureGeometry.validate_compiled(malformed)
	test.assert_true(direct_errors.size() >= 1, "shared defensive validator reports malformed arrays")
	test.assert_equal(direct_errors[0]["code"], "features.parallel_array_mismatch", "malformed-array error code is stable")


func _test_compiler_integration(test: RefCounted) -> void:
	var fixture_text := FileAccess.get_file_as_string("res://tests/fixtures/tracks/stadium_v1.json")
	var definition := TrackDefinitionType.from_json(fixture_text)
	var compile_result := CompilerType.compile(definition)
	test.assert_true(compile_result.track != null, "feature integration fixture must compile")
	if compile_result.track == null:
		return
	var definition_before := definition.to_dictionary(true)
	var centerline_before := compile_result.track.centerline.duplicate()
	var world := WorldPlanner.plan(definition, compile_result.track)
	test.assert_true(world["valid"], "real compiler output feeds the aggregate planner: %s" % str(world["errors"]))
	test.assert_true(world["scenery"]["placements"].size() > 0, "compiled fixture receives deterministic scenery")
	test.assert_true(world["minimap"]["closed"], "compiled fixture receives a closed minimap")
	test.assert_true(world["track_tour"]["camera_path"].size() >= 16, "compiled fixture receives a tour path")
	test.assert_equal(definition.to_dictionary(true), definition_before, "aggregate planner treats TrackDefinition as read-only")
	test.assert_equal(compile_result.track.centerline, centerline_before, "aggregate planner treats CompiledTrack as read-only")


func _definition_for(compiled: CompiledTrack) -> TrackDefinition:
	var definition := TrackDefinitionType.new()
	definition.track_id = compiled.track_id
	definition.target_length = compiled.total_length
	definition.track_width = compiled.track_width
	definition.canvas_size = compiled.canvas_size
	definition.pit_side = compiled.pit_side
	definition.theme = compiled.theme
	definition.decoration_density = compiled.decoration_density
	definition.deterministic_seed = compiled.deterministic_seed
	return definition


func _make_long_rectangle() -> CompiledTrack:
	var points := PackedVector2Array([
		Vector2(100.0, 300.0), Vector2(200.0, 300.0), Vector2(300.0, 300.0),
		Vector2(400.0, 300.0), Vector2(500.0, 300.0), Vector2(500.0, 450.0),
		Vector2(500.0, 600.0), Vector2(400.0, 600.0), Vector2(300.0, 600.0),
		Vector2(200.0, 600.0), Vector2(100.0, 600.0), Vector2(100.0, 450.0),
	])
	var compiled := _make_compiled(points, 40.0, 73191)
	compiled.straight_sections = [{
		"start_index": 0,
		"end_index": 4,
		"start_distance": 0.0,
		"length": 400.0,
	}]
	compiled.corner_sections = [
		{"start_index": 4, "end_index": 6, "start_distance": 400.0, "length": 300.0},
		{"start_index": 10, "end_index": 0, "start_distance": 1000.0, "length": 300.0},
	]
	return compiled


func _make_bow_tie() -> CompiledTrack:
	return _make_compiled(PackedVector2Array([
		Vector2(180.0, 180.0), Vector2(820.0, 820.0),
		Vector2(820.0, 180.0), Vector2(180.0, 820.0),
	]), 20.0, 4102)


func _make_compiled(points: PackedVector2Array, width: float, seed: int) -> CompiledTrack:
	var analysis := AnalyzerType.analyze(points)
	var compiled := CompiledTrackType.new()
	compiled.source_hash = "source-fixture"
	compiled.compile_hash = "compile-fixture"
	compiled.track_id = "feature-fixture"
	compiled.canvas_size = Vector2(1000.0, 1000.0)
	compiled.theme = &"forest"
	compiled.pit_side = TrackDefinitionType.PIT_NONE
	compiled.decoration_density = 1.0
	compiled.deterministic_seed = seed
	compiled.track_width = width
	compiled.centerline = points.duplicate()
	compiled.tangents = analysis.tangents
	compiled.normals = analysis.normals
	compiled.curvatures = analysis.curvatures
	compiled.radii = analysis.radii
	compiled.arc_distances = analysis.arc_distances
	compiled.total_length = analysis.total_length
	compiled.sample_spacing = analysis.total_length / float(points.size())
	compiled.straight_sections = analysis.straight_sections
	compiled.corner_sections = analysis.corner_sections
	compiled.left_edge.resize(points.size())
	compiled.right_edge.resize(points.size())
	for index in points.size():
		compiled.left_edge[index] = QuantizationType.vector2(points[index] + compiled.normals[index] * width * 0.5)
		compiled.right_edge[index] = QuantizationType.vector2(points[index] - compiled.normals[index] * width * 0.5)
	return compiled


func _has_error(plan_data: Dictionary, code: String) -> bool:
	for error_value in plan_data.get("errors", []):
		if error_value is Dictionary and str(error_value.get("code", "")) == code:
			return true
	return false


func _has_marker(markers: Array, kind: String) -> bool:
	for marker in markers:
		if marker is Dictionary and str(marker.get("kind", "")) == kind:
			return true
	return false
