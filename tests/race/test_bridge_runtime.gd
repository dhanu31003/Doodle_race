extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const CompiledTrackType := preload("res://game/track/generation/compiled_track.gd")
const AnalyzerType := preload("res://game/track/generation/track_geometry_analyzer.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const WorldPlannerType := preload("res://game/track/features/track_world_feature_planner.gd")
const TrackQueryType := preload("res://game/race/track_query.gd")
const VehicleModelType := preload("res://game/race/arcade_vehicle_model.gd")
const LapTrackerType := preload("res://game/race/lap_tracker.gd")
const AiDriverType := preload("res://game/ai/ai_driver.gd")
const RaceDirectorType := preload("res://game/race/race_director.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const FactoryType := preload("res://tests/race/race_test_factory.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_context_window_equivalence_and_fallback(test)
	_test_ai_cached_projection_equivalence(test)
	var fixture := _make_bridge_fixture()
	_test_declared_bridge_contract(test, fixture)
	if bool(fixture.get("valid", false)):
		_test_contextual_projection_and_layers(test, fixture)
		_test_natural_crest_airtime(test, fixture)
		_test_collision_and_recovery(test, fixture)
		_test_layered_checkpoint_authority(test, fixture)
		_test_multi_lap_ai_traversal(test, fixture)
	_test_director_disables_boost(test)
	return test.result("bridge_runtime_authority")


func _test_ai_cached_projection_equivalence(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(80.0)
	var model := VehicleModelType.new()
	var state := model.create_state(&"cache-probe", track, 100.0, 3.0)
	state.velocity = state.forward() * 130.0
	var malformed_cache := state.duplicate_state()
	malformed_cache.track_distance += track.total_length
	malformed_cache.lateral_offset = track.track_width * 3.0
	var cached_driver := AiDriverType.new(&"cache-probe", 7719, 0.8)
	var fallback_driver := AiDriverType.new(&"cache-probe", 7719, 0.8)
	var cached := cached_driver.command(state, track, [], 0)
	var fallback := fallback_driver.command(malformed_cache, track, [], 0)
	test.assert_near(cached.steer, fallback.steer, 0.0001, "authoritative AI cache matches defensive projection steering")
	test.assert_near(cached.throttle, fallback.throttle, 0.0001, "authoritative AI cache matches defensive projection throttle")
	test.assert_near(cached.brake, fallback.brake, 0.0001, "authoritative AI cache matches defensive projection braking")


func _test_context_window_equivalence_and_fallback(test: RefCounted) -> void:
	var track := FactoryType.create_oval(128, 44.0, 300.0, 190.0)
	for index in 12:
		var distance := track.total_length * float(index) / 12.0 + 7.0
		var sample := track.sample_at_distance(distance)
		var position: Vector2 = sample["position"] + sample["normal"] * 4.0
		var global := track.nearest(position)
		var contextual := track.nearest_continuous(position, distance, TrackQueryType.COLLISION_LAYER_GROUND, 52.0)
		test.assert_near(float(contextual["distance_along"]), float(global["distance_along"]), 0.001, "hint window matches global projection on ordinary sample %d" % index)
	var far_distance := track.total_length * 0.35
	var far_sample := track.sample_at_distance(far_distance)
	var full_fallback := track.nearest_continuous(
		far_sample["position"], 0.0, TrackQueryType.COLLISION_LAYER_GROUND, track.total_length * 0.5
	)
	test.assert_true(track.circular_distance(float(full_fallback["distance_along"]), far_distance) < 0.1, "half-lap context explicitly falls back to the global projection")
	var bounded := track.nearest_continuous(
		far_sample["position"], 0.0, TrackQueryType.COLLISION_LAYER_GROUND, 20.0
	)
	test.assert_true(track.circular_distance(float(bounded["distance_along"]), 0.0) <= track.track_width, "bounded context refuses a stale teleport to a remote route branch")


func _test_declared_bridge_contract(test: RefCounted, fixture: Dictionary) -> void:
	test.assert_true(bool(fixture.get("valid", false)), "synthetic bridge fixture builds through the world planner: %s" % str(fixture.get("errors", [])))
	if not bool(fixture.get("valid", false)):
		return
	var compiled: CompiledTrack = fixture["compiled"]
	var definition: TrackDefinition = fixture["definition"]
	var world: Dictionary = fixture["world"]
	var query: RaceTrackQuery = fixture["query"]
	test.assert_equal(definition.bridge_crossings.size(), 1, "authored fixture contains one explicit bridge declaration")
	test.assert_equal(compiled.bridge_crossings, [definition.bridge_crossings[0].to_dictionary()], "compiled authority retains the declared bridge identity")
	test.assert_true(bool(world["bridges"]["valid"]), "aggregate world plan exposes a valid bridge physics contract")
	test.assert_equal(world["bridges"]["crossings"].size(), 1, "world plan resolves exactly one geometric crossing")
	test.assert_equal(query.bridge_zones.size(), 1, "race query consumes exactly one resolved bridge zone")
	test.assert_true(query.is_valid(), "declared self-crossing adapts to a valid race query")


func _test_contextual_projection_and_layers(test: RefCounted, fixture: Dictionary) -> void:
	var query: RaceTrackQuery = fixture["query"]
	var crossing: Dictionary = fixture["crossing"]
	var position: Vector2 = crossing["position"]
	var branch_a: Dictionary = crossing["branch_a"]
	var branch_b: Dictionary = crossing["branch_b"]
	var distance_a := float(branch_a["lap_distance"])
	var distance_b := float(branch_b["lap_distance"])
	var layer_a := int(crossing["collision"]["branch_a_layer"])
	var layer_b := int(crossing["collision"]["branch_b_layer"])
	var projection_a := query.nearest_continuous(position, distance_a, layer_a, 32.0)
	var projection_b := query.nearest_continuous(position, distance_b, layer_b, 32.0)
	test.assert_true(query.circular_distance(float(projection_a["distance_along"]), distance_a) < 1.0, "branch A projection cannot jump to the coincident branch")
	test.assert_true(query.circular_distance(float(projection_b["distance_along"]), distance_b) < 1.0, "branch B projection cannot jump to the coincident branch")
	test.assert_equal(int(projection_a["collision_layer"]), layer_a, "branch A projection carries its planned collision layer")
	test.assert_equal(int(projection_b["collision_layer"]), layer_b, "branch B projection carries its planned collision layer")
	test.assert_true(layer_a != layer_b, "overpass and underpass resolve to distinct collision layers")
	var overpass_distance := float(crossing["branch_a"]["lap_distance"]) \
		if str(crossing["overpass_branch"]) == "a" else float(crossing["branch_b"]["lap_distance"])
	var underpass_distance := distance_b if str(crossing["overpass_branch"]) == "a" else distance_a
	var overpass := query.sample_at_distance(overpass_distance)
	var underpass := query.sample_at_distance(underpass_distance)
	test.assert_equal(int(overpass["collision_layer"]), TrackQueryType.COLLISION_LAYER_ELEVATED, "deck sample is elevated")
	test.assert_equal(str(overpass["bridge_branch"]), "overpass", "deck sample identifies the overpass branch")
	test.assert_equal(int(underpass["collision_layer"]), TrackQueryType.COLLISION_LAYER_GROUND, "underpass sample remains on ground")
	test.assert_equal(str(underpass["bridge_branch"]), "underpass", "ground sample identifies the underpass branch")
	var zone: Dictionary = query.bridge_zones[0]
	var deck_half := float(zone["deck_half_length"])
	var ramp_half := float(zone["ramp_half_length"])
	var upper_ramp := query.sample_at_distance(overpass_distance + lerpf(deck_half, ramp_half, 0.25))
	var lower_ramp := query.sample_at_distance(overpass_distance + lerpf(deck_half, ramp_half, 0.75))
	test.assert_equal(int(upper_ramp["collision_mask"]), TrackQueryType.COLLISION_MASK_TRANSITION, "upper ramp accepts the deterministic layer handoff")
	test.assert_equal(int(lower_ramp["collision_mask"]), TrackQueryType.COLLISION_MASK_TRANSITION, "lower ramp accepts the deterministic layer handoff")
	test.assert_true(query.collision_layers_compatible(
		int(upper_ramp["collision_layer"]), int(upper_ramp["collision_mask"]),
		int(lower_ramp["collision_layer"]), int(lower_ramp["collision_mask"])
	), "cars remain collidable across the ramp layer transition")


func _test_natural_crest_airtime(test: RefCounted, fixture: Dictionary) -> void:
	var query: RaceTrackQuery = fixture["query"]
	var zone: Dictionary = query.bridge_zones[0]
	var overpass_distance := float(zone["overpass_distance"])
	var deck_half := float(zone["deck_half_length"])
	var ramp_half := float(zone["ramp_half_length"])
	# Positive route travel rises on the approach side of the overpass.
	var crest_distance := query.wrap_distance(overpass_distance - deck_half)
	var model := VehicleModelType.new()

	var flat := model.create_state(&"flat-no-launch", query, overpass_distance)
	flat.velocity = flat.forward() * 180.0
	test.assert_true(model.step_fixed(flat, RaceInputType.new(), query), "high-speed flat-deck step remains finite")
	test.assert_true(flat.is_grounded, "high speed alone never creates airtime on flat road")
	test.assert_near(flat.vertical_offset_meters, 0.0, 0.0001, "flat road retains exact zero vertical offset")

	var low_speed := model.create_state(
		&"slow-crest", query, query.wrap_distance(crest_distance - 0.75)
	)
	low_speed.velocity = low_speed.forward() * 90.0
	test.assert_true(model.step_fixed(low_speed, RaceInputType.new(), query), "low-speed crest traversal remains finite")
	test.assert_true(low_speed.is_grounded, "a low-speed car follows the rising crest without artificial airtime")

	var downhill_bottom := model.create_state(
		&"downhill-bottom", query,
		query.wrap_distance(overpass_distance + ramp_half - 0.75)
	)
	downhill_bottom.velocity = downhill_bottom.forward() * 180.0
	test.assert_true(model.step_fixed(downhill_bottom, RaceInputType.new(), query), "downhill-ramp bottom traversal remains finite")
	test.assert_true(downhill_bottom.is_grounded, "flattening at a downhill-ramp bottom is not misclassified as a launch crest")

	var launch_distance := query.wrap_distance(crest_distance - 1.25)
	var airborne := model.create_state(&"crest-airborne", query, launch_distance)
	airborne.velocity = airborne.forward() * 150.0
	var replay_model := VehicleModelType.new()
	var replay := airborne.duplicate_state()
	test.assert_true(model.step_fixed(airborne, RaceInputType.new(), query), "fast rising-crest traversal remains finite")
	test.assert_true(replay_model.step_fixed(replay, RaceInputType.new(), query), "same fast crest replays through the fixed-step model")
	test.assert_equal(airborne.authority_snapshot(), replay.authority_snapshot(), "crest launch is deterministic on its first authority tick")
	test.assert_false(airborne.is_grounded, "a sufficiently fast car releases from the rising ramp onto the flat deck")
	test.assert_true(
		airborne.vertical_velocity_mps >= VehicleModelType.MIN_CREST_LAUNCH_VERTICAL_SPEED_MPS \
			and airborne.vertical_velocity_mps <= VehicleModelType.MAX_CREST_LAUNCH_VERTICAL_SPEED_MPS,
		"crest launch vertical speed stays inside the short physical arc envelope"
	)
	test.assert_near(airborne.vertical_offset_meters, 0.0, 0.0001, "launch begins continuously at the road surface")
	var launch_velocity := airborne.vertical_velocity_mps
	model.step_fixed(airborne, RaceInputType.new(), query)
	replay_model.step_fixed(replay, RaceInputType.new(), query)
	test.assert_equal(airborne.authority_snapshot(), replay.authority_snapshot(), "gravity integration replays exactly after launch")
	test.assert_true(airborne.vertical_offset_meters > 0.0, "the car gains measurable clearance after leaving the crest")
	test.assert_near(
		airborne.vertical_velocity_mps,
		launch_velocity - VehicleModelType.STANDARD_GRAVITY * VehicleModelType.FIXED_DT,
		0.0002,
		"airborne vertical velocity descends by standard gravity each fixed tick"
	)
	var airborne_ticks := 1
	var maximum_height := airborne.vertical_offset_meters
	var last_positive_height := airborne.vertical_offset_meters
	var saw_descent := airborne.vertical_velocity_mps < 0.0
	while not airborne.is_grounded and airborne_ticks < 90:
		last_positive_height = airborne.vertical_offset_meters
		test.assert_true(model.step_fixed(airborne, RaceInputType.new(), query), "airborne authority remains finite through tick %d" % airborne_ticks)
		test.assert_true(replay_model.step_fixed(replay, RaceInputType.new(), query), "airborne replay remains finite through tick %d" % airborne_ticks)
		maximum_height = maxf(maximum_height, airborne.vertical_offset_meters)
		saw_descent = saw_descent or airborne.vertical_velocity_mps < 0.0
		airborne_ticks += 1
	test.assert_equal(airborne.authority_snapshot(), replay.authority_snapshot(), "complete gravity arc is deterministic through landing")
	test.assert_true(saw_descent, "ballistic arc includes a gravity-driven descent")
	test.assert_true(airborne.is_grounded, "the car lands back on the bridge surface")
	test.assert_true(airborne_ticks >= 4 and airborne_ticks < 60, "crest airtime is visible but bounded below one second")
	test.assert_true(maximum_height > 0.02 and maximum_height < 1.0, "crest float is measurable without becoming an exaggerated jump")
	test.assert_true(last_positive_height < 0.12, "landing closes only a small final clearance for a smooth touchdown")
	test.assert_near(airborne.vertical_offset_meters, 0.0, 0.0001, "landing restores exact zero height")
	test.assert_near(airborne.vertical_velocity_mps, 0.0, 0.0001, "landing clears vertical velocity")
	test.assert_true(airborne.is_finite(), "landed authority remains finite")
	for _tick in 5:
		model.step_fixed(airborne, RaceInputType.new(), query)
	test.assert_true(airborne.is_grounded, "landing on the deck cannot repeatedly relaunch the car")


func _test_collision_and_recovery(test: RefCounted, fixture: Dictionary) -> void:
	var query: RaceTrackQuery = fixture["query"]
	var crossing: Dictionary = fixture["crossing"]
	var model := VehicleModelType.new()
	var distance_a := float(crossing["branch_a"]["lap_distance"])
	var distance_b := float(crossing["branch_b"]["lap_distance"])
	var first := model.create_state(&"bridge-a", query, distance_a)
	var second := model.create_state(&"bridge-b", query, distance_b)
	first.position = crossing["position"]
	second.position = crossing["position"]
	var shared_position: Vector2 = crossing["position"]
	test.assert_false(model.resolve_vehicle_contact(first, second), "coincident overpass and underpass cars cannot collide")
	test.assert_equal(first.position, shared_position, "layer-separated contact leaves the first car untouched")
	test.assert_equal(second.position, shared_position, "layer-separated contact leaves the second car untouched")

	var same_layer := model.create_state(&"bridge-a-peer", query, distance_a)
	same_layer.position = first.position
	test.assert_true(model.resolve_vehicle_contact(first, same_layer), "cars on the same bridge surface still collide")

	var overpass_distance := distance_a if first.track_collision_layer == TrackQueryType.COLLISION_LAYER_ELEVATED else distance_b
	var recovering := model.create_state(&"recovering", query, overpass_distance)
	recovering.position = crossing["position"] + Vector2(2.0, -2.0)
	recovering.velocity = Vector2(120.0, -40.0)
	recovering.vertical_offset_meters = 0.45
	recovering.vertical_velocity_mps = -1.2
	recovering.is_grounded = false
	var original_layer := recovering.track_collision_layer
	test.assert_true(model.recover_to_track(recovering, query), "bridge recovery returns a finite car to its contextual route")
	test.assert_equal(recovering.track_collision_layer, original_layer, "recovery preserves the elevated bridge layer")
	test.assert_true(query.circular_distance(recovering.track_distance, overpass_distance) < 4.0, "recovery preserves the intended route branch")
	test.assert_near(recovering.speed(), 0.0, 0.001, "safe recovery clears stale velocity by default")
	test.assert_true(recovering.is_grounded, "recovery returns airborne authority to the road surface")
	test.assert_near(recovering.vertical_offset_meters, 0.0, 0.0001, "recovery clears stale airborne height")
	test.assert_near(recovering.vertical_velocity_mps, 0.0, 0.0001, "recovery clears stale vertical velocity")


func _test_layered_checkpoint_authority(test: RefCounted, fixture: Dictionary) -> void:
	var query: RaceTrackQuery = fixture["query"]
	var tracker := LapTrackerType.new()
	test.assert_true(tracker.configure(query, 2, 12), "bridge circuit configures ordered checkpoint authority")
	var distance := 3.0
	var sample := query.sample_at_distance(distance)
	tracker.prime(sample["position"], distance, int(sample["collision_layer"]))
	var tick := 0
	var saw_overpass := false
	var saw_underpass := false
	while not tracker.finished and tick < 4000:
		distance += 3.5
		tick += 1
		sample = query.sample_at_distance(distance)
		saw_overpass = saw_overpass or str(sample["bridge_branch"]) == "overpass"
		saw_underpass = saw_underpass or str(sample["bridge_branch"]) == "underpass"
		tracker.update(
			sample["position"],
			sample["tangent"] * 210.0,
			1.0 / 60.0,
			tick,
			float(tick) / 60.0,
			int(sample["collision_layer"]),
			int(sample["collision_mask"])
		)
	test.assert_true(saw_overpass and saw_underpass, "authoritative traversal visits both coincident bridge branches")
	test.assert_equal(tracker.invalid_motion_count, 0, "contextual projection never reports a false shortcut at the crossing")
	test.assert_equal(tracker.laps_completed, 2, "ordered checkpoints remain correct across two bridge laps")
	test.assert_true(tracker.finished, "layer-aware checkpoint traversal reaches the deterministic finish")
	test.assert_near(tracker.validated_progress(), query.total_length * 2.0, 0.001, "bridge finish progress is exact")


func _test_multi_lap_ai_traversal(test: RefCounted, fixture: Dictionary) -> void:
	var query: RaceTrackQuery = fixture["query"]
	var model := VehicleModelType.new()
	var driver := AiDriverType.new(&"bridge-ai", 48271, 0.86, model.config.maximum_forward_speed)
	var state := model.create_state(&"bridge-ai", query, 12.0)
	var tracker := LapTrackerType.new()
	tracker.configure(query, 2, 12)
	tracker.prime(state.position, state.track_distance, state.track_collision_layer)
	var saw_overpass := false
	var saw_underpass := false
	for tick in 9000:
		var command := driver.command(state, query, [], tick)
		if not model.step_fixed(state, command, query):
			break
		tracker.update(
			state.position,
			state.velocity,
			VehicleModelType.FIXED_DT,
			tick + 1,
			float(tick + 1) * VehicleModelType.FIXED_DT,
			state.track_collision_layer,
			state.track_collision_mask
		)
		var surface := query.surface_context_at_distance(state.track_distance)
		saw_overpass = saw_overpass or str(surface["bridge_branch"]) == "overpass"
		saw_underpass = saw_underpass or str(surface["bridge_branch"]) == "underpass"
		if tracker.finished:
			break
	test.assert_true(state.is_finite(), "AI remains finite throughout the bridge race")
	test.assert_true(saw_overpass, "AI traverses the elevated branch")
	test.assert_true(saw_underpass, "AI traverses the ground branch")
	test.assert_equal(tracker.invalid_motion_count, 0, "AI never branch-jumps or trips shortcut authority")
	test.assert_equal(tracker.laps_completed, 2, "AI completes multiple laps across both bridge branches")
	test.assert_true(tracker.finished, "AI reaches the layer-aware race finish")


func _test_director_disables_boost(test: RefCounted) -> void:
	var director := RaceDirectorType.new()
	var track := FactoryType.create_oval(64)
	director.configure(track, 1, 2026, 8, false)
	director.countdown_duration = 0.0
	var entry := director.add_entry(&"human", "Human", true)
	director.start()
	var energy_before := entry.state.nitro_energy
	director.tick_fixed({&"human": RaceInputType.new(0.0, 1.0, 0.0, true)})
	test.assert_false(entry.state.nitro_active, "authoritative race director strips the dormant boost bit")
	test.assert_near(entry.state.nitro_energy, energy_before, 0.0001, "stripped boost cannot consume authoritative energy")


func _make_bridge_fixture() -> Dictionary:
	const SAMPLE_COUNT := 160
	var points := PackedVector2Array()
	points.resize(SAMPLE_COUNT)
	for index in SAMPLE_COUNT:
		var angle := PI * 0.5 + TAU * (float(index) + 0.5) / float(SAMPLE_COUNT)
		points[index] = Vector2(
			640.0 + sin(angle) * 410.0,
			360.0 + sin(angle) * cos(angle) * 250.0
		)
	var analysis := AnalyzerType.analyze(points)
	var compiled := CompiledTrackType.new()
	compiled.source_hash = "bridge-runtime-source"
	compiled.track_id = "bridge-runtime-fixture"
	compiled.canvas_size = Vector2(1280.0, 720.0)
	compiled.direction = &"clockwise"
	compiled.theme = &"forest"
	compiled.pit_side = TrackDefinitionType.PIT_NONE
	compiled.decoration_density = 0.5
	compiled.deterministic_seed = 48271
	compiled.track_width = 48.0
	compiled.centerline = points
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
		compiled.left_edge[index] = QuantizationType.vector2(points[index] + compiled.normals[index] * compiled.track_width * 0.5)
		compiled.right_edge[index] = QuantizationType.vector2(points[index] - compiled.normals[index] * compiled.track_width * 0.5)
	var actual := ValidatorType.find_crossings(compiled)
	if actual.size() != 1:
		return {"valid": false, "errors": ["expected one crossing, found %d" % actual.size()]}
	var definition := TrackDefinitionType.new()
	definition.track_id = compiled.track_id
	definition.target_length = compiled.total_length
	definition.track_width = compiled.track_width
	definition.canvas_size = compiled.canvas_size
	definition.theme = compiled.theme
	definition.pit_side = compiled.pit_side
	definition.decoration_density = compiled.decoration_density
	definition.deterministic_seed = compiled.deterministic_seed
	var declaration := BridgeDefinitionType.new(
		"bridge-runtime-main",
		QuantizationType.scalar(float(actual[0]["distance_a"])),
		QuantizationType.scalar(float(actual[0]["distance_b"])),
		BridgeDefinitionType.OVERPASS_B
	)
	definition.bridge_crossings.append(declaration)
	compiled.bridge_crossings.append(declaration.to_dictionary())
	compiled.refresh_compile_hash()
	var world := WorldPlannerType.plan(definition, compiled)
	if not bool(world.get("valid", false)):
		return {"valid": false, "errors": world.get("errors", [])}
	var query := TrackQueryType.from_compiled(compiled)
	if not query.is_valid():
		return {"valid": false, "errors": ["query: %s" % str(query.error)]}
	return {
		"valid": true,
		"definition": definition,
		"compiled": compiled,
		"world": world,
		"crossing": world["bridges"]["crossings"][0],
		"query": query,
	}
