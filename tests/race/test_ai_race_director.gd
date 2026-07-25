extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const FactoryType := preload("res://tests/race/race_test_factory.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const TrackQueryType := preload("res://game/race/track_query.gd")
const AiPersonalityType := preload("res://game/ai/ai_personality.gd")
const AiDriverType := preload("res://game/ai/ai_driver.gd")
const AiRosterType := preload("res://game/ai/ai_roster.gd")
const DirectorType := preload("res://game/race/race_director.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")

const TRACK_FIXTURE := "res://tests/fixtures/tracks/stadium_v1.json"


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_ai_personality_and_decisions(test)
	_test_twelve_car_reproducibility(test)
	_test_render_rate_stability(test)
	_test_countdown_pause_dnf_and_bounds(test)
	_test_vehicle_collision_option(test)
	_test_malformed_track_query(test)
	_test_compiled_track_adapter(test)
	return test.result("ai_and_race_director")


func _test_ai_personality_and_decisions(test: RefCounted) -> void:
	var first := AiPersonalityType.generate(9917, &"nova", 0.8)
	var repeat := AiPersonalityType.generate(9917, &"nova", 0.8)
	var other := AiPersonalityType.generate(9917, &"apex", 0.8)
	test.assert_equal(first.to_dictionary(), repeat.to_dictionary(), "same seed and driver produce the same bounded personality")
	test.assert_true(first.to_dictionary() != other.to_dictionary(), "distinct driver streams produce distinct personalities")
	test.assert_true(first.skill >= 0.62 and first.skill <= 0.98, "AI skill remains inside authored bounds")
	test.assert_true(first.aggression >= 0.22 and first.aggression <= 0.92, "AI aggression remains inside authored bounds")
	test.assert_true(absf(first.line_bias) <= 0.58, "AI racing-line bias remains bounded")
	test.assert_true(first.reaction_ticks >= 2 and first.reaction_ticks <= 4, "AI reaction cadence remains bounded")
	test.assert_equal(AiRosterType.create_drivers(10, 1).size(), 10, "AI roster enforces a minimum ten-car field")
	test.assert_equal(AiRosterType.create_drivers(10, 99).size(), 12, "AI roster enforces the twelve-car maximum")
	var track := FactoryType.create_oval()
	test.assert_near(
		track.radius_at_distance(25.0),
		float(track.sample_at_distance(25.0)["radius"]),
		0.001,
		"allocation-free radius lookup matches the canonical track sample"
	)
	test.assert_equal(
		track.is_corner_at_distance(25.0),
		bool(track.sample_at_distance(25.0)["in_corner"]),
		"allocation-free corner lookup matches the canonical track sample"
	)
	var driver := AiDriverType.new(&"nova", 9917, 0.8)
	driver.personality.top_speed_factor = 1.0
	driver.personality.skill = 1.0
	driver.personality.risk = 0.0
	var conservative_corner_speed := driver.target_speed_for_radius(200.0)
	var physical_config := preload("res://game/race/vehicle_config.gd").new().sanitized()
	test.assert_near(
		conservative_corner_speed,
		physical_config.corner_speed_limit_for_radius(200.0, 0.90),
		0.001,
		"AI corner target consumes the shared tyre-envelope solver"
	)
	driver.personality.risk = 1.0
	test.assert_true(
		driver.target_speed_for_radius(200.0) > conservative_corner_speed,
		"risk changes only the bounded safety margin below the same physical corner limit"
	)
	test.assert_near(driver.target_speed_for_radius(INF), 310.0, 0.001, "straight target retains configured maximum speed")
	test.assert_true(driver.target_speed_for_radius(200.0, false, true) <= 105.0, "off-track target remains recovery-limited")
	var immediate_corner_target := driver.approach_speed_for_corner(120.0, 0.0)
	var distant_corner_target := driver.approach_speed_for_corner(120.0, 240.0)
	test.assert_near(
		immediate_corner_target,
		driver.target_speed_for_radius(120.0, true),
		0.001,
		"AI applies the physical corner target at the sampled corner"
	)
	test.assert_true(
		distant_corner_target > immediate_corner_target,
		"AI does not apply a future corner's exit speed across the preceding straight"
	)
	test.assert_true(distant_corner_target <= 310.0, "distance-aware target remains inside configured vehicle speed")
	var model := preload("res://game/race/arcade_vehicle_model.gd").new()
	var state := model.create_state(&"nova", track, 0.0)
	state.velocity = state.forward() * 130.0
	var opponent := model.create_state(&"opponent", track, 14.0)
	opponent.velocity = opponent.forward() * 100.0
	var command := driver.command(state, track, [opponent], 0)
	test.assert_true(command.throttle >= 0.0 and command.throttle <= 1.0, "AI throttle uses normalized input contract")
	test.assert_true(command.brake >= 0.0 and command.brake <= 1.0, "AI brake uses normalized input contract")
	test.assert_true(command.brake > 0.25, "AI applies bounded headway braking behind slower same-lane traffic")
	test.assert_true(absf(command.steer) <= 1.0, "AI steer uses normalized input contract")
	test.assert_false(command.nitro, "offline AI uses only conventional steering and pedals")
	test.assert_equal(command.to_dictionary(), driver.command(state, track, [opponent], 0).to_dictionary(), "AI reaction cache is deterministic")


func _test_twelve_car_reproducibility(test: RefCounted) -> void:
	var first := _build_ai_director(7351)
	var second := _build_ai_director(7351)
	# Fifteen simulated seconds catches delayed cornering, recovery, and contact
	# failures without turning the core test into a full endurance benchmark.
	for _frame in 900:
		first.advance_frame(1.0 / 60.0)
		second.advance_frame(1.0 / 60.0)
	test.assert_equal(first.entries.size(), 12, "race director simulates the full twelve-car field")
	var moving_count := 0
	var progressed_count := 0
	var distinct_snapshots: Dictionary = {}
	for index in first.entries.size():
		var first_state = first.entries[index].state
		var second_state = second.entries[index].state
		test.assert_true(first_state.is_finite(), "AI car %d remains finite" % index)
		test.assert_equal(first_state.authority_snapshot(), second_state.authority_snapshot(), "AI car %d replays exactly from seed" % index)
		test.assert_equal(first.entries[index].lap_tracker.invalid_motion_count, 0, "AI car %d never trips shortcut authority" % index)
		if first_state.speed() > 45.0:
			moving_count += 1
		if first.entries[index].classification_progress() > 100.0:
			progressed_count += 1
		distinct_snapshots[str(first_state.position)] = true
	test.assert_true(moving_count >= 10, "at least ten AI cars are actively racing after launch")
	test.assert_true(progressed_count >= 10, "at least ten AI cars make validated forward race progress")
	test.assert_true(distinct_snapshots.size() >= 10, "AI field does not collapse into one identical path state")
	test.assert_equal(first.fixed_tick, second.fixed_tick, "replicated AI races execute the same fixed tick count")
	var standings := first.standings()
	for index in standings.size():
		test.assert_equal(standings[index].race_position, index + 1, "classification assigns stable position %d" % (index + 1))


func _test_render_rate_stability(test: RefCounted) -> void:
	var at_30 := _simulate_human_at_rate(30, 6.0)
	var at_60 := _simulate_human_at_rate(60, 6.0)
	var at_120 := _simulate_human_at_rate(120, 6.0)
	test.assert_equal(at_30["tick"], 360, "30 Hz presentation executes 360 fixed ticks in six seconds")
	test.assert_equal(at_60["tick"], 360, "60 Hz presentation executes 360 fixed ticks in six seconds")
	test.assert_equal(at_120["tick"], 360, "120 Hz presentation executes 360 fixed ticks in six seconds")
	test.assert_equal(at_30["snapshot"], at_60["snapshot"], "30 and 60 Hz presentation produce identical authority")
	test.assert_equal(at_60["snapshot"], at_120["snapshot"], "60 and 120 Hz presentation produce identical authority")


func _test_countdown_pause_dnf_and_bounds(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle()
	var director := DirectorType.new()
	director.configure(track, 1, 55)
	director.countdown_duration = 1.0
	director.add_entry(&"human", "Human", true)
	director.start()
	director.advance_frame(0.5)
	var before_pause := director.countdown_remaining
	director.set_paused(true)
	test.assert_equal(director.advance_frame(1.0), 0, "paused race executes no fixed ticks")
	test.assert_equal(director.countdown_remaining, before_pause, "pause freezes countdown authority")
	director.set_paused(false)
	for _frame in 50:
		director.advance_frame(1.0 / 60.0)
	test.assert_equal(director.phase, DirectorType.PHASE_RACING, "countdown resumes into racing phase")
	var limited := DirectorType.new()
	limited.configure(track, 1, 1)
	limited.countdown_duration = 0.0
	limited.race_time_limit = 0.05
	limited.add_entry(&"a", "A", true)
	limited.add_entry(&"b", "B", true)
	limited.start()
	for _tick in 5:
		limited.tick_fixed()
	test.assert_equal(limited.phase, DirectorType.PHASE_RESULTS, "time limit retires remaining cars into results")
	test.assert_equal(limited.results().size(), 2, "results classify every starter")
	test.assert_equal(limited.results()[0]["status"], "dnf", "time-limit result carries DNF status")
	var bounded := DirectorType.new()
	bounded.configure(track, 1, 1)
	for index in 12:
		test.assert_true(bounded.add_entry(StringName("car_%d" % index), "Car", true) != null, "grid accepts slot %d" % (index + 1))
	test.assert_true(bounded.add_entry(&"car_12", "Overflow", true) == null, "thirteenth grid slot is rejected")
	test.assert_true(bounded.add_entry(&"car_0", "Duplicate", true) == null, "duplicate participant id is rejected")
	var maximum_initial_penetration := 0.0
	var minimum_same_lane_spacing := INF
	for first_index in bounded.entries.size():
		for second_index in range(first_index + 1, bounded.entries.size()):
			var first: RaceEntry = bounded.entries[first_index]
			var second: RaceEntry = bounded.entries[second_index]
			maximum_initial_penetration = maxf(
				maximum_initial_penetration,
				first.vehicle_model.vehicle_contact_penetration(
					first.state, second.state, second.vehicle_model.config
				)
			)
			if second_index == first_index + 2:
				minimum_same_lane_spacing = minf(
					minimum_same_lane_spacing,
					first.state.position.distance_to(second.state.position)
				)
	var grid_center_span := bounded.entries[0].state.position.distance_to(
		bounded.entries[-1].state.position
	)
	print("START_GRID_CLEARANCE slots=12 slot_spacing=%.1f same_lane=%.3f span=%.3f max_penetration=%.6f" % [
		DirectorType.GRID_SLOT_SPACING, minimum_same_lane_spacing,
		grid_center_span, maximum_initial_penetration,
	])
	test.assert_true(
		minimum_same_lane_spacing >= 17.99 and grid_center_span <= 100.01,
		"staggered grid clears same-lane capsules without exceeding its compact 100-unit span"
	)
	var grid_slots_in_start_straight := 0
	for entry in bounded.entries:
		if not track.is_corner_at_distance(entry.state.track_distance):
			grid_slots_in_start_straight += 1
	test.assert_equal(
		grid_slots_in_start_straight, 12,
		"all twelve compact grid slots remain on the start straight"
	)
	test.assert_near(
		maximum_initial_penetration, 0.0, 0.0001,
		"twelve-car staggered grid starts with zero capsule penetration"
	)
	bounded.countdown_duration = 0.0
	test.assert_true(bounded.start(), "clear twelve-car grid can begin immediately")
	bounded.tick_fixed()
	var initial_contact_events := 0
	var steady_state_config_sanitizations := 0
	for entry in bounded.entries:
		initial_contact_events += entry.state.vehicle_contact_serial
		steady_state_config_sanitizations += \
			entry.vehicle_model.contact_config_sanitization_count
	test.assert_equal(
		initial_contact_events, 0,
		"first fixed tick performs no collision work for the separated starting grid"
	)
	print("START_GRID_CONTACT_WORK passes=%d pair_checks=%d resolutions=%d" % [
		bounded.contact_solver_passes_last_tick,
		bounded.contact_pair_checks_last_tick,
		bounded.contact_resolutions_last_tick,
	])
	test.assert_equal(
		bounded.contact_solver_passes_last_tick, 1,
		"separated twelve-car start exits the contact solver after one broad pass"
	)
	test.assert_equal(
		bounded.contact_pair_checks_last_tick, 66,
		"one separated twelve-car pass performs exactly n choose two pair checks"
	)
	test.assert_equal(
		bounded.contact_resolutions_last_tick, 0,
		"separated starting field needs no iterative contact resolution"
	)
	test.assert_equal(
		steady_state_config_sanitizations, 0,
		"contact broad passes reuse sanitized model configs without per-pair allocations"
	)


func _test_vehicle_collision_option(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle()
	var enabled := DirectorType.new()
	enabled.configure(track, 1, 91, 8, true)
	enabled.countdown_duration = 0.0
	var enabled_a = enabled.add_entry(&"enabled_a", "A", true)
	var enabled_b = enabled.add_entry(&"enabled_b", "B", true)
	enabled_b.state.position = enabled_a.state.position
	enabled_b.state.heading = enabled_a.state.heading
	enabled.start()
	enabled.tick_fixed()
	test.assert_true(
		enabled_a.state.position.distance_to(enabled_b.state.position) > 0.1,
		"enabled car-to-car collisions separate overlapping vehicles"
	)

	var disabled := DirectorType.new()
	disabled.configure(track, 1, 91, 8, false)
	disabled.countdown_duration = 0.0
	var disabled_a = disabled.add_entry(&"disabled_a", "A", true)
	var disabled_b = disabled.add_entry(&"disabled_b", "B", true)
	disabled_b.state.position = disabled_a.state.position
	disabled_b.state.heading = disabled_a.state.heading
	disabled.start()
	disabled.tick_fixed()
	test.assert_near(
		disabled_a.state.position.distance_to(disabled_b.state.position), 0.0, 0.001,
		"disabled car-to-car collisions leave overlapping authority untouched"
	)


func _test_malformed_track_query(test: RefCounted) -> void:
	var query := TrackQueryType.new()
	test.assert_false(query.configure(PackedVector2Array([Vector2.ZERO, Vector2.ONE]), 30.0), "too few centerline samples are rejected")
	test.assert_equal(query.error, &"centerline_sample_count_out_of_bounds", "sample bound has stable error code")
	var triangle := PackedVector2Array([Vector2.ZERO, Vector2(10, 0), Vector2(0, 10)])
	test.assert_false(query.configure(triangle, 0.0), "zero-width runtime track is rejected")
	test.assert_equal(query.error, &"track_width_out_of_bounds", "width bound has stable error code")
	var non_finite := PackedVector2Array([Vector2.ZERO, Vector2(INF, 0), Vector2(0, 10)])
	test.assert_false(query.configure(non_finite, 30.0), "non-finite centerline is rejected")
	var duplicate := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2(0, 10)])
	test.assert_false(query.configure(duplicate, 30.0), "degenerate centerline segment is rejected")
	test.assert_true(query.nearest(Vector2.ZERO).is_empty(), "invalid track query returns an empty projection")
	var bare_object := RefCounted.new()
	var from_bare := TrackQueryType.from_compiled(bare_object)
	test.assert_false(from_bare.is_valid(), "missing compiled-track properties fail without runtime errors")
	test.assert_equal(from_bare.error, &"invalid_centerline_type", "missing compiled centerline has stable error code")


func _test_compiled_track_adapter(test: RefCounted) -> void:
	var definition := TrackDefinitionType.from_json(FileAccess.get_file_as_string(TRACK_FIXTURE))
	var compile_result := TrackCompilerType.compile(definition)
	test.assert_true(compile_result.track != null, "race adapter fixture compiles through the canonical track pipeline")
	if compile_result.track == null:
		return
	var query := TrackQueryType.from_compiled(compile_result.track)
	test.assert_true(query.is_valid(), "race query accepts canonical CompiledTrack output")
	test.assert_equal(query.centerline.size(), compile_result.track.centerline.size(), "race query preserves canonical centerline sample count")
	test.assert_near(query.total_length, compile_result.track.total_length, 0.01, "race query length matches compiler authority")
	test.assert_equal(query.corner_sections.size(), compile_result.track.corner_sections.size(), "race query consumes compiler corner sections")


func _build_ai_director(seed_value: int) -> RaceDirector:
	var director := DirectorType.new()
	var track := FactoryType.create_oval(72, 50.0, 300.0, 210.0)
	director.configure(track, 2, seed_value, 8)
	director.countdown_duration = 0.0
	var drivers := AiRosterType.create_drivers(seed_value, 12, 0.78)
	for index in drivers.size():
		var driver = drivers[index]
		director.add_entry(driver.driver_id, AiRosterType.display_name(index), false, driver)
	director.start()
	return director


func _simulate_human_at_rate(render_hz: int, seconds: float) -> Dictionary:
	var director := DirectorType.new()
	var track := FactoryType.create_large_rectangle(80.0)
	director.configure(track, 3, 100)
	director.countdown_duration = 0.0
	var entry = director.add_entry(&"human", "Human", true)
	entry.state = entry.vehicle_model.create_state(&"human", track, 100.0, 0.0)
	entry.lap_tracker.prime(entry.state.position)
	director.start()
	var command := RaceInputType.new(0.0, 0.82, 0.0, false)
	var commands := {&"human": command}
	for _frame in int(round(seconds * float(render_hz))):
		director.advance_frame(1.0 / float(render_hz), commands)
	return {"tick": director.fixed_tick, "snapshot": entry.state.authority_snapshot()}
