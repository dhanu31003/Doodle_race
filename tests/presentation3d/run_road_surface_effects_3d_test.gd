extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const EffectsType := preload("res://game/presentation3d/road_surface_effects_3d.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const QueryType := preload("res://game/race/track_query.gd")
const SurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")
const RaceEntryType := preload("res://game/race/race_entry.gd")
const VehicleStateType := preload("res://game/race/vehicle_state.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	var effects := EffectsType.new()
	root.add_child(effects)
	await process_frame
	var visual := Node3D.new()
	visual.name = "SurfaceEffectsPlayer"
	root.add_child(visual)
	var entry := RaceEntryType.new()
	entry.participant_id = &"surface-player"
	entry.state = VehicleStateType.new()
	entry.state.vehicle_id = entry.participant_id
	entry.state.is_grounded = true
	entry.state.velocity = Vector2(140.0, 0.0)
	var entries: Array[RaceEntry] = [entry]
	var vehicles := {"surface-player": visual}

	var cases := [
		["builtin-evergreen-oval", SurfaceCatalogType.SMOOTH_ASPHALT, false, false],
		["builtin-crescent-run", SurfaceCatalogType.WEATHERED_ASPHALT, true, false],
		["builtin-northstar-gp", SurfaceCatalogType.BUMPY_ASPHALT, false, true],
		["builtin-copper-canyon", SurfaceCatalogType.COMPACT_GRAVEL, false, true],
		["builtin-riverbend", SurfaceCatalogType.MUD, false, true],
	]
	for case in cases:
		var query := _query(str(case[0]))
		test.assert_true(query != null and query.is_valid(), "%s surface query compiles" % str(case[1]))
		if query == null or not query.is_valid():
			continue
		effects.configure(query, true, false)
		effects.update_vehicles(entries, vehicles, "surface-player")
		var snapshot := effects.presentation_snapshot()
		test.assert_equal(
			str(snapshot.get("surface_style", "")), str(case[1]),
			"effect controller consumes the selected %s surface" % str(case[1])
		)
		test.assert_equal(
			bool(snapshot.get("rain_enabled", false)), bool(case[2]),
			"%s owns the expected bounded rain state" % str(case[1])
		)
		var expects_loose_detail := bool(case[3])
		test.assert_equal(
			int(snapshot.get("static_detail_count", 0)) > 0,
			expects_loose_detail,
			"%s owns the expected one-draw loose road detail" % str(case[1])
		)
		var expects_spray: bool = case[1] != SurfaceCatalogType.SMOOTH_ASPHALT
		test.assert_equal(
			int(snapshot.get("active_spray_count", 0)) > 0,
			expects_spray,
			"%s owns the expected wheel spray/debris effect" % str(case[1])
		)
		test.assert_true(
			int(snapshot.get("active_spray_count", 0))
					<= (1 if case[1] == SurfaceCatalogType.MUD else 2)
					and int(snapshot.get("spray_pool_size", 0)) == 4
					and int(snapshot.get("spray_particle_capacity", 9999)) <= 96,
			"%s stays within the fixed mobile particle pool" % str(case[1])
		)
		var expects_two_pass_spray: bool = case[1] == SurfaceCatalogType.COMPACT_GRAVEL
		test.assert_equal(
			int(snapshot.get("spray_draw_passes", 0)),
			2 if expects_two_pass_spray else 1,
			"%s uses the intended debris-plus-plume draw treatment" % str(case[1])
		)
		test.assert_true(
			float(snapshot.get("minimum_spray_speed", 99.0)) <= 12.0,
			"%s moving effects begin at a readable low road speed" % str(case[1])
		)
		test.assert_equal(
			int(snapshot.get("mobile_update_stride", 0)), 2,
			"%s updates presentation bindings at a bounded half-rate" % str(case[1])
		)
		if case[1] == SurfaceCatalogType.MUD:
			test.assert_true(
				int(snapshot.get("spray_particle_capacity", 999)) <= 48
						and int(snapshot.get("static_detail_count", 999)) <= 20
						and bool(snapshot.get("rear_axle_only", false)),
				"mobile mud uses one compact rear wake, 48 pooled particles and 20 details"
			)

	effects.reset_effects()
	var reset := effects.presentation_snapshot()
	test.assert_equal(int(reset.get("active_spray_count", -1)), 0, "reset stops every moving surface effect")
	test.assert_equal(int(reset.get("static_detail_count", -1)), 0, "reset clears the shared loose-detail draw")
	root.remove_child(effects)
	effects.free()
	root.remove_child(visual)
	visual.free()
	await process_frame
	var result := test.result("road_surface_effects_3d")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _query(track_id: String) -> RaceTrackQuery:
	var definition: TrackDefinition = CatalogType.by_id(track_id).get("definition")
	var result := CompilerType.compile(definition)
	if result.track == null:
		return null
	return QueryType.from_compiled(result.track)
