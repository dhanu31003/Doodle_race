extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const FactoryType := preload("res://tests/race/race_test_factory.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const DirectorType := preload("res://game/race/race_director.gd")
const VehicleModelType := preload("res://game/race/arcade_vehicle_model.gd")
const AiDriverType := preload("res://game/ai/ai_driver.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const SoakCatalogType := preload("res://tests/race/ai_soak_track_catalog.gd")
const BridgeRuntimeSuiteType := preload("res://tests/race/test_bridge_runtime.gd")


class StationaryController extends RefCounted:
	func command(_state: VehicleState, _track: RaceTrackQuery, _nearby: Array, _tick: int) -> RaceInput:
		return RaceInput.new()


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_automatic_recovery_contract(test)
	_test_single_contact_recovery_contract(test)
	_test_stationary_ontrack_is_not_recovered(test)
	_test_recovery_cap_and_determinism(test)
	_test_projection_reuse_equivalence(test)
	_test_frozen_soak_catalog_is_valid(test)
	return test.result("race_recovery_and_release_quality")


func _test_automatic_recovery_contract(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(60.0)
	var director := DirectorType.new()
	director.configure(track, 2, 7701, 8, false)
	director.countdown_duration = 0.0
	var human = director.add_entry(&"human", "Human", true)
	var ai = director.add_entry(&"ai-stationary", "AI", false, StationaryController.new())
	_force_offtrack(human, track, 400.0)
	_force_offtrack(ai, track, 1400.0)
	var human_checkpoint: int = human.lap_tracker.next_checkpoint
	var ai_checkpoint: int = ai.lap_tracker.next_checkpoint
	director.start()
	for _tick in DirectorType.AUTOMATIC_RECOVERY_DELAY_TICKS - 1:
		director.tick_fixed()
	test.assert_equal(human.automatic_recovery_count, 0, "human recovery waits for the full deterministic delay")
	test.assert_equal(ai.automatic_recovery_count, 0, "AI recovery waits for the same deterministic delay")
	director.tick_fixed()
	test.assert_equal(human.automatic_recovery_count, 1, "off-track blocked human is recovered automatically without another control")
	test.assert_equal(ai.automatic_recovery_count, 1, "off-track blocked AI uses the same authoritative recovery")
	test.assert_false(human.state.is_offtrack, "automatic recovery returns the human inside the road limit")
	test.assert_false(ai.state.is_offtrack, "automatic recovery returns the AI inside the road limit")
	test.assert_equal(human.lap_tracker.laps_completed, 0, "human recovery cannot grant a lap")
	test.assert_equal(ai.lap_tracker.laps_completed, 0, "AI recovery cannot grant a lap")
	test.assert_equal(human.lap_tracker.next_checkpoint, human_checkpoint, "human recovery cannot grant a checkpoint")
	test.assert_equal(ai.lap_tracker.next_checkpoint, ai_checkpoint, "AI recovery cannot grant a checkpoint")
	test.assert_equal(human.lap_tracker.invalid_motion_count, 0, "human recovery re-primes motion authority without a teleport violation")
	test.assert_equal(ai.lap_tracker.invalid_motion_count, 0, "AI recovery re-primes motion authority without a teleport violation")
	test.assert_equal(human.result_dictionary()["automatic_recoveries"], 1, "classification result exposes the human recovery count")
	test.assert_equal(human.state.recovery_hard_snap_serial, 1, "authority snapshot exposes an explicit recovery hard-snap serial")
	test.assert_equal(human.state.last_recovery_tick, director.fixed_tick, "authority snapshot timestamps the recovery fixed tick")
	test.assert_equal(human.state.last_recovery_reason, &"blocked_offtrack", "authority snapshot carries a stable recovery reason")
	test.assert_equal(human.state.gear, 1, "stationary recovery resets the drivetrain to first gear")
	test.assert_near(human.state.engine_rpm, human.vehicle_model.config.idle_rpm, 0.1, "stationary recovery emits idle RPM instead of a stale high-RPM audio pop")
	test.assert_equal(human.state.authority_snapshot(), human.state.duplicate_state().authority_snapshot(), "recovery telemetry survives authoritative state duplication")
	test.assert_equal(human.recovery_events.size(), human.automatic_recovery_count, "bounded recovery event stream has one record per recovery")
	test.assert_equal(human.recovery_events[0]["tick"], director.fixed_tick, "recovery event records the authoritative fixed tick")
	test.assert_equal(human.recovery_events[0]["reason"], "blocked_offtrack", "recovery event uses the stable reason code")
	_force_offtrack(human, track, 600.0)
	for _tick in DirectorType.AUTOMATIC_RECOVERY_COOLDOWN_TICKS - 1:
		director.tick_fixed()
	test.assert_equal(human.automatic_recovery_count, 1, "recovery cooldown prevents an immediate repeated hard snap")


func _test_single_contact_recovery_contract(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(60.0)
	var director := DirectorType.new()
	director.configure(track, 1, 7703, 8, false)
	director.countdown_duration = 0.0
	var human = director.add_entry(&"contact-blocked", "Contact Blocked", true)
	director.start()
	# One authoritative wall-contact increment must remain valid evidence for the
	# complete recovery delay; otherwise the former two-second grace made the
	# five-second threshold mathematically unreachable.
	human.state.wall_contacts += 1
	for _tick in DirectorType.AUTOMATIC_RECOVERY_DELAY_TICKS - 1:
		director.tick_fixed()
	test.assert_equal(human.automatic_recovery_count, 0, "single-contact recovery still waits for the full delay")
	director.tick_fixed()
	test.assert_equal(human.automatic_recovery_count, 1, "one on-road blocking contact can satisfy the recovery delay")
	test.assert_equal(human.state.last_recovery_reason, &"blocked_contact", "single-contact recovery reports the stable contact reason")
	test.assert_false(human.state.is_offtrack, "contact recovery remains on the legal road surface")


func _test_stationary_ontrack_is_not_recovered(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(60.0)
	var director := DirectorType.new()
	director.configure(track, 1, 7702, 8, false)
	director.countdown_duration = 0.0
	var human = director.add_entry(&"parked-human", "Parked Human", true)
	director.start()
	for _tick in DirectorType.AUTOMATIC_RECOVERY_DELAY_TICKS + 180:
		director.tick_fixed()
	test.assert_equal(human.automatic_recovery_count, 0, "choosing to stop safely on the road never triggers recovery")
	test.assert_equal(human.state.wall_contacts, 0, "stationary on-road control has no false contact evidence")


func _test_recovery_cap_and_determinism(test: RefCounted) -> void:
	var first := _blocked_director(8803)
	var second := _blocked_director(8803)
	for _tick in DirectorType.AUTOMATIC_RECOVERY_DELAY_TICKS:
		first.tick_fixed()
		second.tick_fixed()
	var first_entry = first.entry(&"blocked")
	var second_entry = second.entry(&"blocked")
	test.assert_equal(first_entry.automatic_recovery_count, 1, "blocked deterministic fixture recovers exactly once")
	test.assert_equal(first_entry.state.authority_snapshot(), second_entry.state.authority_snapshot(), "same-seed automatic recovery produces identical authority")
	test.assert_equal(first_entry.recovery_last_tick, second_entry.recovery_last_tick, "same-seed recovery fires on the same fixed tick")

	var capped := _blocked_director(8804)
	var capped_entry = capped.entry(&"blocked")
	capped_entry.automatic_recovery_count = DirectorType.MAX_AUTOMATIC_RECOVERIES
	for _tick in DirectorType.AUTOMATIC_RECOVERY_DELAY_TICKS + 30:
		capped.tick_fixed()
	test.assert_equal(capped_entry.automatic_recovery_count, DirectorType.MAX_AUTOMATIC_RECOVERIES, "automatic recovery obeys its hard per-entrant cap")


func _test_projection_reuse_equivalence(test: RefCounted) -> void:
	var ordinary := FactoryType.create_large_rectangle(60.0)
	var model := VehicleModelType.new()
	model.projection_equivalence_probe_enabled = true
	var wall_state := model.create_state(&"wall-equivalence", ordinary, 500.0)
	var wall_sample := ordinary.sample_at_distance(500.0)
	var shoulder := maxf(6.0, ordinary.track_width * 0.35)
	wall_state.position = wall_sample["position"] + wall_sample["normal"] * (
		ordinary.track_width * 0.5 + shoulder + 8.0
	)
	wall_state.velocity = wall_sample["normal"] * 90.0 + wall_sample["tangent"] * 70.0
	model.step_fixed(wall_state, RaceInputType.new(), ordinary)
	var wall_match := model.last_projection_equivalence_match
	test.assert_true(wall_match, "reused wall projection matches the legacy post-wall projection exactly")
	test.assert_true(wall_state.wall_contacts > 0, "projection equivalence probe exercises a real wall contact")

	var bridge_fixture := BridgeRuntimeSuiteType.new()._make_bridge_fixture()
	test.assert_true(bool(bridge_fixture.get("valid", false)), "projection equivalence obtains the validated bridge fixture")
	if not bool(bridge_fixture.get("valid", false)):
		return
	var bridge: RaceTrackQuery = bridge_fixture["query"]
	var crossing: Dictionary = bridge_fixture["crossing"]
	var overpass_distance := float(crossing["branch_a"]["lap_distance"]) \
		if str(crossing["overpass_branch"]) == "a" \
		else float(crossing["branch_b"]["lap_distance"])
	var zone: Dictionary = bridge.bridge_zones[0]
	var bridge_state := model.create_state(
		&"bridge-equivalence", bridge, overpass_distance - float(zone["ramp_half_length"]) - 45.0
	)
	bridge_state.velocity = bridge_state.forward() * 125.0
	var driver := AiDriverType.new(&"bridge-equivalence", 19937, 0.86)
	var mismatch_count := 0
	var saw_transition := false
	var saw_elevated := false
	for tick in 300:
		var command := driver.command(bridge_state, bridge, [], tick)
		if not model.step_fixed(bridge_state, command, bridge) \
				or not model.last_projection_equivalence_match:
			mismatch_count += 1
		saw_transition = saw_transition or bridge_state.track_collision_mask \
			== RaceTrackQuery.COLLISION_MASK_TRANSITION
		saw_elevated = saw_elevated or bridge_state.track_collision_layer \
			== RaceTrackQuery.COLLISION_LAYER_ELEVATED
	test.assert_equal(mismatch_count, 0, "reused projection produces the same authority signature as the legacy double projection across every bridge probe tick")
	test.assert_true(saw_transition, "equivalence probe traverses a bridge ramp transition mask")
	test.assert_true(saw_elevated, "equivalence probe traverses the elevated bridge layer")


func _test_frozen_soak_catalog_is_valid(test: RefCounted) -> void:
	var representatives := SoakCatalogType.representative_specs()
	test.assert_equal(representatives.size(), 4, "release soak freezes exactly four golden archetypes")
	var archetypes: Dictionary = {}
	for spec in representatives:
		var result := CompilerType.compile(spec["definition"])
		test.assert_true(result.succeeded(), "golden %s compiles before endurance simulation: %s" % [spec["id"], str(result.report.to_dictionary())])
		archetypes[str(spec["archetype"])] = true
		if str(spec["archetype"]) == "s_bends" and result.track != null:
			var positive := false
			var negative := false
			for curvature in result.track.curvatures:
				positive = positive or curvature > 0.00005
				negative = negative or curvature < -0.00005
			test.assert_true(positive and negative, "S-bend golden contains real alternating curvature instead of a relabeled oval")
		if str(spec["archetype"]) == "bridge_capable" and result.track != null:
			test.assert_true(result.track.bridge_crossings.size() > 0, "bridge golden retains an explicit crossing declaration")
	test.assert_equal(archetypes.size(), 4, "golden panel covers four distinct release archetypes")
	var fixture := SoakCatalogType.corpus_fixture()
	var records: Array = fixture.get("tracks", [])
	test.assert_equal(records.size(), 20, "frozen generated corpus contains exactly twenty tracks")
	var compile_hashes: Dictionary = {}
	for record in records:
		var result := CompilerType.compile(SoakCatalogType.corpus_definition(record))
		test.assert_true(result.succeeded(), "frozen corpus %s is a valid generated track: %s" % [record.get("id", "unknown"), str(result.report.to_dictionary())])
		if result.track != null:
			compile_hashes[result.track.compile_hash] = true
	test.assert_equal(compile_hashes.size(), 20, "frozen corpus compiles to twenty distinct authority hashes")


func _blocked_director(seed_value: int) -> RaceDirector:
	var track := FactoryType.create_large_rectangle(60.0)
	var director := DirectorType.new()
	director.configure(track, 1, seed_value, 8, false)
	director.countdown_duration = 0.0
	var entry = director.add_entry(&"blocked", "Blocked", false, StationaryController.new())
	_force_offtrack(entry, track, 900.0)
	director.start()
	return director


func _force_offtrack(entry: RaceEntry, track: RaceTrackQuery, distance: float) -> void:
	var sample := track.sample_at_distance(distance)
	var road_limit := track.track_width * 0.5 - entry.vehicle_model.config.vehicle_radius
	var shoulder := maxf(6.0, track.track_width * 0.35)
	entry.state.position = sample["position"] + sample["normal"] * (road_limit + shoulder + 6.0)
	entry.state.velocity = Vector2.ZERO
	entry.state.track_distance = float(sample["distance_along"])
	entry.state.lateral_offset = road_limit + shoulder + 6.0
	entry.lap_tracker.prime(
		entry.state.position,
		entry.state.track_distance,
		entry.state.track_collision_layer
	)
