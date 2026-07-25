extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const GameLimitsType := preload("res://game/config/game_limits.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const WorldPlannerType := preload("res://game/track/features/track_world_feature_planner.gd")
const ExchangeType := preload("res://game/persistence/track_exchange.gd")
const QueryType := preload("res://game/race/track_query.gd")
const LapTrackerType := preload("res://game/race/lap_tracker.gd")
const DirectorType := preload("res://game/race/race_director.gd")
const TrackBuilderType := preload("res://game/presentation3d/track_mesh_builder_3d.gd")
const MapperType := preload("res://game/presentation3d/world_coordinate_mapper.gd")

const PREVIOUS_RELEASE_GEOMETRY := {
	"builtin-evergreen-oval": {"length": 1600.0, "width": 36.0},
	"builtin-crescent-run": {"length": 1680.0, "width": 34.0},
	"builtin-northstar-gp": {"length": 1720.0, "width": 34.0},
	"builtin-riverbend": {"length": 1640.0, "width": 35.0},
	"builtin-nightfall-crossing": {"length": 1840.0, "width": 34.0},
	"builtin-copper-canyon": {"length": 1760.0, "width": 32.0},
}

const RELEASE_GEOMETRY := {
	"builtin-evergreen-oval": {"length": 4000.0, "width": 48.0},
	"builtin-crescent-run": {"length": 4200.0, "width": 46.0},
	"builtin-northstar-gp": {"length": 4300.0, "width": 46.0},
	"builtin-riverbend": {"length": 4100.0, "width": 47.0},
	"builtin-nightfall-crossing": {"length": 4600.0, "width": 46.0},
	"builtin-copper-canyon": {"length": 4400.0, "width": 44.0},
}


func run() -> Dictionary:
	var test := TestCaseType.new()
	var ids: Dictionary = {}
	var hashes: Dictionary = {}
	var archetypes: Dictionary = {}
	var pit_count := 0
	var bridge_count := 0
	var minimum_difficulty := 99
	var maximum_difficulty := 0
	var items := CatalogType.all()
	test.assert_equal(items.size(), 6, "release catalog ships exactly six reviewed default circuits")
	for item in items:
		var definition: TrackDefinition = item["definition"]
		var archetype := str(item.get("archetype", ""))
		test.assert_false(archetype.is_empty(), "%s declares its authored circuit archetype" % definition.track_id)
		test.assert_false(archetypes.has(archetype), "%s archetype is unique across the six defaults" % definition.track_id)
		archetypes[archetype] = true
		var difficulty := int(item.get("difficulty", 0))
		minimum_difficulty = mini(minimum_difficulty, difficulty)
		maximum_difficulty = maxi(maximum_difficulty, difficulty)
		test.assert_false(ids.has(definition.track_id), "predefined track IDs must be unique")
		ids[definition.track_id] = true
		test.assert_false(hashes.has(definition.content_hash), "predefined track geometry hashes must be unique")
		hashes[definition.content_hash] = true
		test.assert_true(definition.validate_schema().is_valid(), "%s schema must validate" % definition.track_id)
		var compiled: TrackCompileResult = CompilerType.compile(definition)
		test.assert_true(compiled.succeeded(), "%s must compile: %s" % [definition.track_id, _errors(compiled)])
		if not compiled.succeeded():
			continue
		test.assert_true(
			_curvature_direction_changes(compiled.track.curvatures) >= 2,
			"%s must retain meaningful opposing-turn complexity instead of regressing to an oval" % definition.track_id
		)
		var world := WorldPlannerType.plan(definition, compiled.track)
		test.assert_true(world["valid"], "%s world features must plan: %s" % [definition.track_id, world["errors"]])
		test.assert_true(world["scenery"]["placements"].size() > 0, "%s must receive scenery" % definition.track_id)
		test.assert_true(world["minimap"]["closed"], "%s minimap must close" % definition.track_id)
		test.assert_true(world["track_tour"]["camera_path"].size() >= 16, "%s must receive a tour" % definition.track_id)
		if str(definition.pit_side) != "none":
			pit_count += 1
			test.assert_true(world["pit_lane"]["enabled"], "%s authored pit must build" % definition.track_id)
		if not definition.bridge_crossings.is_empty():
			bridge_count += definition.bridge_crossings.size()
			test.assert_equal(world["bridges"]["crossings"].size(), definition.bridge_crossings.size(), "%s resolves every declared release bridge" % definition.track_id)
			var query := QueryType.from_compiled(compiled.track)
			test.assert_true(query.is_valid(), "%s bridge metadata adapts to race authority" % definition.track_id)
			test.assert_equal(query.bridge_zones.size(), definition.bridge_crossings.size(), "%s race authority consumes every bridge zone" % definition.track_id)
		var repeated := CatalogType.by_id(definition.track_id)["definition"] as TrackDefinition
		test.assert_equal(repeated.canonical_json(true), definition.canonical_json(true), "catalog output must be deterministic")
		repeated.track_width = 512.0
		var isolated := CatalogType.by_id(definition.track_id)["definition"] as TrackDefinition
		test.assert_equal(isolated.canonical_json(true), definition.canonical_json(true), "catalog cache must return isolated definitions")
		var payload := CatalogType.race_payload(definition.track_id, 5, "expert")
		test.assert_false(payload.has("error"), "%s must emit a race-ready payload" % definition.track_id)
		test.assert_equal(payload.get("laps"), 5, "race payload must retain bounded lap configuration")
		var encoded := ExchangeType.encode(definition)
		test.assert_true(encoded.get("ok", false), "%s must encode for sharing" % definition.track_id)
		var decoded := ExchangeType.decode(str(encoded.get("json", "")))
		test.assert_true(decoded.get("ok", false), "%s shared envelope must verify" % definition.track_id)
		if decoded.get("ok", false):
			test.assert_equal((decoded["definition"] as TrackDefinition).content_hash, definition.content_hash, "shared definition must round-trip")
		_test_release_geometry(test, item, definition, compiled.track, world)
	test.assert_true(pit_count >= 2, "release catalog must exercise both pit-side plans")
	test.assert_true(bridge_count >= 1, "release catalog must ship at least one explicit overpass")
	test.assert_equal(minimum_difficulty, 1, "default catalog retains an accessible unusual circuit")
	test.assert_equal(maximum_difficulty, 4, "default catalog retains expert unusual circuits")
	_test_custom_track_isolation(test)
	_test_file_exchange(test, items[0]["definition"])
	return test.result("predefined_track_catalog")


func _test_release_geometry(
		test: RefCounted,
		item: Dictionary,
		definition: TrackDefinition,
		compiled: CompiledTrack,
		world: Dictionary
	) -> void:
	var track_id := definition.track_id
	var previous: Dictionary = PREVIOUS_RELEASE_GEOMETRY[track_id]
	var expected: Dictionary = RELEASE_GEOMETRY[track_id]
	test.assert_equal(definition.target_length, expected["length"], "%s uses its reviewed release lap length" % track_id)
	test.assert_equal(definition.track_width, expected["width"], "%s uses its reviewed release road width" % track_id)
	test.assert_equal(float(item["target_length"]), definition.target_length, "%s catalog metadata matches lap authority" % track_id)
	test.assert_equal(float(item["width"]), definition.track_width, "%s catalog metadata matches road authority" % track_id)
	test.assert_near(definition.target_length / float(previous["length"]), 2.5, 0.000001, "%s lap is exactly 2.5x the previous release" % track_id)
	test.assert_true(definition.track_width - float(previous["width"]) >= 12.0, "%s gains at least 12 authority units of usable width" % track_id)
	test.assert_equal(definition.canvas_size, Vector2(3000.0, 2000.0), "%s uses a proportionally enlarged authoring canvas" % track_id)
	var quantized_length_tolerance := maxf(
		0.25,
		float(compiled.centerline.size()) * GameLimitsType.COORDINATE_QUANTUM
	)
	test.assert_near(compiled.total_length, definition.target_length, quantized_length_tolerance, "%s compiled lap retains the requested distance within one coordinate quantum per sample" % track_id)
	test.assert_true(compiled.centerline.size() <= 768, "%s authority centerline stays inside the mobile sample budget" % track_id)
	var lap_length_m := MapperType.authority_scalar_to_meters(compiled.total_length)
	var road_width_m := MapperType.authority_scalar_to_meters(compiled.track_width)
	test.assert_true(lap_length_m >= 1199.9 and lap_length_m <= 1380.1, "%s physical lap is a substantial 1.2-1.38 km" % track_id)
	test.assert_true(road_width_m >= 13.2 and road_width_m <= 14.4, "%s asphalt is a Formula-suitable 13.2-14.4 m wide" % track_id)

	var all_edges_inside := true
	for edge_index in compiled.centerline.size():
		for point in [compiled.left_edge[edge_index], compiled.right_edge[edge_index]]:
			if point.x < 0.0 or point.y < 0.0 \
					or point.x > definition.canvas_size.x or point.y > definition.canvas_size.y:
				all_edges_inside = false
				break
		if not all_edges_inside:
			break
	test.assert_true(all_edges_inside, "%s widened asphalt edges remain inside authored bounds" % track_id)
	for sample_index in [
		0,
		floori(float(compiled.centerline.size()) / 3.0),
		floori(float(compiled.centerline.size()) * 2.0 / 3.0),
	]:
		test.assert_near(compiled.centerline[sample_index].distance_to(compiled.left_edge[sample_index]), compiled.track_width * 0.5, 0.002, "%s left edge aligns to the widened centerline" % track_id)
		test.assert_near(compiled.centerline[sample_index].distance_to(compiled.right_edge[sample_index]), compiled.track_width * 0.5, 0.002, "%s right edge aligns to the widened centerline" % track_id)

	var query := QueryType.from_compiled(compiled)
	test.assert_true(query.is_valid(), "%s enlarged geometry adapts to race queries" % track_id)
	if not query.is_valid():
		return
	test.assert_near(query.total_length, compiled.total_length, 0.001, "%s race, compiler and timing use one lap length" % track_id)
	test.assert_near(query.track_width, compiled.track_width, 0.001, "%s race barriers use the compiled road width" % track_id)
	var lap_tracker := LapTrackerType.new()
	test.assert_true(lap_tracker.configure(query, 3, 12), "%s builds twelve ordered race checkpoints" % track_id)
	test.assert_equal(lap_tracker._gate_distances.size(), 12, "%s checkpoint lattice is complete" % track_id)
	for checkpoint_index in lap_tracker._gate_distances.size():
		test.assert_near(float(lap_tracker._gate_distances[checkpoint_index]), query.total_length * float(checkpoint_index) / 12.0, 0.001, "%s checkpoint %d remains on lap authority" % [track_id, checkpoint_index])

	var minimap: Dictionary = world["minimap"]
	test.assert_true(bool(minimap["closed"]), "%s enlarged circuit still maps to a closed minimap" % track_id)
	var route: PackedVector2Array = minimap["polyline"]
	test.assert_true(route.size() >= 17 and route.size() <= 193, "%s minimap keeps its bounded mobile route budget" % track_id)
	var scenery: Dictionary = world["scenery"]
	test.assert_true(int(scenery["target_count"]) <= 160, "%s seeded scenery target stays inside its mobile cap" % track_id)
	test.assert_true(scenery["placements"].size() <= 160, "%s planned scenery stays inside its mobile cap" % track_id)
	for marker_variant in minimap["markers"]:
		var marker: Dictionary = marker_variant
		var marker_position: Vector2 = marker["position"]
		test.assert_true(marker_position.x >= 0.0 and marker_position.y >= 0.0 \
				and marker_position.x <= 256.0 and marker_position.y <= 160.0, "%s minimap marker stays inside its viewport" % track_id)

	var mesh_result := TrackBuilderType.build(query, {"sample_step_authority": 10.0})
	test.assert_true(bool(mesh_result.get("ok", false)), "%s builds mobile-density asphalt, kerbs and runoff" % track_id)
	if bool(mesh_result.get("ok", false)):
		var stats: Dictionary = mesh_result["stats"]
		test.assert_near(float(stats["lap_length_meters"]), lap_length_m, 0.001, "%s mesh lap length aligns with timing" % track_id)
		test.assert_near(float(stats["road_width_meters"]), road_width_m, 0.001, "%s mesh asphalt width aligns with barriers" % track_id)
		test.assert_true(float(stats["runoff_width_each_side_meters"]) >= 3.2, "%s retains safe runoff beyond widened asphalt" % track_id)
		test.assert_true(int(stats["segment_count"]) <= 460, "%s mobile mesh stays within 460 longitudinal segments" % track_id)
		test.assert_true(int(stats["triangles"]) <= 5520, "%s complete four-surface mesh stays within its triangle budget" % track_id)

	_test_start_grid(test, query, track_id)
	print("CATALOG_GEOMETRY id=%s width=%.3f width_m=%.3f previous=%.3f target=%.3f compiled=%.3f lap_m=%.3f samples=%d" % [
		track_id, definition.track_width, road_width_m, float(previous["length"]),
		definition.target_length, compiled.total_length, lap_length_m,
		compiled.centerline.size(),
	])


func _test_start_grid(test: RefCounted, query: RaceTrackQuery, track_id: String) -> void:
	var director := DirectorType.new()
	test.assert_true(director.configure(query, 3, 9137, 12, true), "%s widened circuit accepts a full race grid" % track_id)
	for grid_index in 12:
		test.assert_true(director.add_entry(StringName("grid-%02d" % grid_index), "Grid %02d" % grid_index, true) != null, "%s accepts grid slot %d" % [track_id, grid_index + 1])
	if director.entries.size() != 12:
		return
	for entry in director.entries:
		var road_limit: float = query.track_width * 0.5 - entry.vehicle_model.config.vehicle_radius
		test.assert_true(absf(entry.state.lateral_offset) <= road_limit + 0.001, "%s grid slot %d remains completely on widened asphalt" % [track_id, entry.grid_position])
		test.assert_true(entry.state.is_finite(), "%s grid slot %d has finite race authority" % [track_id, entry.grid_position])
	for first_index in director.entries.size():
		for second_index in range(first_index + 1, director.entries.size()):
			var first = director.entries[first_index]
			var second = director.entries[second_index]
			var penetration: float = first.vehicle_model.vehicle_contact_penetration(
				first.state, second.state, second.vehicle_model.config
			)
			test.assert_near(penetration, 0.0, 0.001, "%s grid capsules %d/%d do not overlap before launch" % [track_id, first.grid_position, second.grid_position])


func _test_custom_track_isolation(test: RefCounted) -> void:
	var fixture_path := "res://tests/fixtures/tracks/stadium_v1.json"
	var custom := TrackDefinition.from_json(FileAccess.get_file_as_string(fixture_path))
	var canonical_before := custom.canonical_json(true)
	var compiled_before := CompilerType.compile(custom)
	test.assert_true(compiled_before.succeeded(), "saved custom fixture compiles before catalog access")
	CatalogType.all()
	var compiled_after := CompilerType.compile(custom)
	test.assert_true(compiled_after.succeeded(), "saved custom fixture compiles after enlarged catalog access")
	test.assert_equal(custom.canonical_json(true), canonical_before, "built-in scaling never mutates a custom definition")
	test.assert_equal(custom.target_length, 1600.0, "custom target length is not globally scaled")
	test.assert_equal(custom.track_width, 36.0, "custom road width is not globally widened")
	if compiled_before.succeeded() and compiled_after.succeeded():
		test.assert_equal(compiled_after.track.compile_hash, compiled_before.track.compile_hash, "custom compile output is unchanged by the built-in catalog")


func _test_file_exchange(test: RefCounted, definition: TrackDefinition) -> void:
	var directory := "user://raceglyph_test_exchange"
	var first := ExchangeType.export_to_file(definition, directory)
	test.assert_true(first.get("ok", false), "portable circuit export must write atomically")
	test.assert_true(FileAccess.file_exists(str(first.get("path", ""))), "portable circuit file must exist after read-back")
	var second := ExchangeType.export_to_file(definition, directory)
	test.assert_true(second.get("ok", false) and second.get("replaced", false), "repeat export must replace through a backup")
	var tampered: Variant = JSON.parse_string(str(first.get("json", "")))
	if tampered is Dictionary:
		tampered["compiled_hash"] = "0".repeat(64)
		test.assert_equal(ExchangeType.decode(JSON.stringify(tampered)).get("error_code"), "export_fingerprint_mismatch", "tampered shared fingerprint must fail closed")
	var absolute := ProjectSettings.globalize_path(directory)
	if FileAccess.file_exists(str(first.get("path", ""))):
		DirAccess.remove_absolute(str(first["path"]))
	DirAccess.remove_absolute(absolute)


func _errors(result: TrackCompileResult) -> String:
	var messages: PackedStringArray = []
	for issue in result.report.issues:
		if issue.severity_name() == "error":
			messages.append("%s: %s %s" % [issue.code, issue.message, issue.details])
	return "; ".join(messages)


func _curvature_direction_changes(curvatures: PackedFloat64Array) -> int:
	var signs := PackedInt32Array()
	for curvature in curvatures:
		# Ignore almost-straight quantization noise. Only material left/right
		# direction changes establish the non-oval contract.
		if absf(curvature) <= 1.0 / 1200.0:
			continue
		signs.append(1 if curvature > 0.0 else -1)
	if signs.size() < 2:
		return 0
	var changes := 0
	for index in signs.size():
		if signs[index] != signs[(index + 1) % signs.size()]:
			changes += 1
	return changes
