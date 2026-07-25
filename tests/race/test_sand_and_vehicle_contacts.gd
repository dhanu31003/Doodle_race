extends RefCounted
## Focused release regressions for recoverable sand and strict Formula-car hulls.

const TestCaseType := preload("res://tests/support/test_case.gd")
const FactoryType := preload("res://tests/race/race_test_factory.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const VehicleModelType := preload("res://game/race/arcade_vehicle_model.gd")
const DirectorType := preload("res://game/race/race_director.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_sand_slowdown_remains_driveable(test)
	_test_player_can_steer_out_of_sand(test)
	_test_head_on_contact_and_reacceleration(test)
	_test_side_contact_preserves_driveability(test)
	_test_stacked_field_has_no_persistent_penetration(test)
	_test_contact_solver_is_deterministic(test)
	return test.result("sand_recovery_and_vehicle_contacts")


func _test_sand_slowdown_remains_driveable(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(60.0)
	var model := VehicleModelType.new()
	var sample := track.sample_at_distance(500.0)
	var road_limit := track.track_width * 0.5 - model.config.vehicle_radius
	var state := model.create_state(&"sand-endurance", track, 500.0)
	state.position = sample["position"] + sample["normal"] * (road_limit + 6.0)
	state.lateral_offset = road_limit + 6.0
	state.velocity = sample["tangent"] * 180.0
	var initial_position := state.position
	var minimum_speed := INF
	var all_steps_valid := true
	for _tick in 600:
		all_steps_valid = all_steps_valid and model.step_fixed(
			state, RaceInputType.new(0.0, 1.0, 0.0), track
		)
		minimum_speed = minf(minimum_speed, state.speed())
	test.assert_true(all_steps_valid and state.is_finite(), "ten seconds in sand remains finite at deterministic 60 Hz")
	test.assert_true(state.is_offtrack, "neutral steering keeps the endurance fixture in the sand lane")
	test.assert_true(minimum_speed > 8.0, "full throttle in sand never falls into an unrecoverable hard stop")
	test.assert_true(state.speed() > 10.0 and state.speed() < 35.0, "sand settles to a slow but driveable crawl speed")
	test.assert_true(state.position.distance_to(initial_position) > 200.0, "sustained throttle continues moving the car through sand")

	var from_rest := model.create_state(&"sand-launch", track, 900.0)
	var rest_sample := track.sample_at_distance(900.0)
	from_rest.position = rest_sample["position"] + rest_sample["normal"] * (road_limit + 5.0)
	from_rest.lateral_offset = road_limit + 5.0
	var rest_start := from_rest.position
	for _tick in 180:
		model.step_fixed(from_rest, RaceInputType.new(0.0, 1.0, 0.0), track)
	test.assert_true(from_rest.speed() > 10.0, "first gear overcomes low-speed sand resistance from rest")
	test.assert_true(from_rest.position.distance_to(rest_start) > 25.0, "a stationary sand excursion can drive forward without recovery teleporting")


func _test_player_can_steer_out_of_sand(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(60.0)
	var director := DirectorType.new()
	director.configure(track, 1, 7301, 8, false)
	director.countdown_duration = 0.0
	var player = director.add_entry(&"sand-player", "Sand Player", true)
	var sample := track.sample_at_distance(1300.0)
	var road_limit: float = track.track_width * 0.5 \
		- float(player.vehicle_model.config.vehicle_radius)
	var starting_lateral: float = road_limit + 7.0
	player.state.position = sample["position"] + sample["normal"] * starting_lateral
	player.state.heading = Vector2.RIGHT.angle_to(sample["tangent"])
	player.state.velocity = Vector2.ZERO
	player.state.track_distance = float(sample["distance_along"])
	player.state.lateral_offset = starting_lateral
	player.state.is_offtrack = true
	player.lap_tracker.prime(
		player.state.position,
		player.state.track_distance,
		player.state.track_collision_layer
	)
	director.start()
	var escape_tick := -1
	var command := RaceInputType.new(-0.82, 1.0, 0.0)
	for tick in 300:
		director.tick_fixed({&"sand-player": command})
		if not player.state.is_offtrack:
			escape_tick = tick + 1
			break
	test.assert_true(escape_tick > 0 and escape_tick < 300, "steering and throttle manually return the player to asphalt within five seconds")
	test.assert_equal(player.automatic_recovery_count, 0, "manual sand escape does not invoke an automatic recovery snap")
	test.assert_true(absf(player.state.lateral_offset) <= road_limit, "manual escape ends inside the legal road boundary")
	test.assert_true(player.state.speed() > 5.0 and player.state.is_finite(), "the rejoined car remains moving and fully driveable")


func _test_head_on_contact_and_reacceleration(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(100.0)
	var first_model := VehicleModelType.new()
	var second_model := VehicleModelType.new()
	var sample := track.sample_at_distance(2200.0)
	var first := first_model.create_state(&"head-on-a", track, 2200.0)
	var second := second_model.create_state(&"head-on-b", track, 2200.0)
	first.position = sample["position"] - sample["tangent"] * 6.0
	second.position = sample["position"] + sample["tangent"] * 6.0
	first.heading = Vector2.RIGHT.angle_to(sample["tangent"])
	second.heading = wrapf(first.heading + PI, -PI, PI)
	first.velocity = sample["tangent"] * 100.0
	second.velocity = -sample["tangent"] * 100.0
	test.assert_true(
		first_model.resolve_vehicle_contact(first, second, second_model.config),
		"head-on capsule overlap produces a collision"
	)
	test.assert_near(first_model.vehicle_contact_penetration(first, second, second_model.config), 0.0, 0.001, "head-on collision leaves zero hull penetration")
	test.assert_true((second.velocity - first.velocity).dot(first.vehicle_contact_normal) >= -0.001, "head-on impulse leaves the bodies separating instead of tunnelling")
	test.assert_equal(first.vehicle_contact_serial, 1, "first head-on participant records one contact event")
	test.assert_equal(second.vehicle_contact_serial, 1, "second head-on participant records one contact event")
	test.assert_equal(first.vehicle_contact_other_id, second.vehicle_id, "contact telemetry identifies the other participant")
	test.assert_near(first.vehicle_contact_position.distance_to(second.vehicle_contact_position), 0.0, 0.001, "both cars publish the same authority-space impact position")
	test.assert_near(first.vehicle_contact_normal.dot(second.vehicle_contact_normal), -1.0, 0.001, "per-car contact normals face in opposite directions")
	test.assert_true(first.vehicle_contact_speed >= 190.0 and first.vehicle_contact_speed <= 210.0, "head-on telemetry reports bounded relative impact speed")
	var first_impact_speed := first.speed()
	var second_impact_speed := second.speed()
	for _tick in 180:
		first_model.step_fixed(first, RaceInputType.new(0.0, 1.0, 0.0), track)
		second_model.step_fixed(second, RaceInputType.new(0.0, 1.0, 0.0), track)
	test.assert_true(first.is_finite() and second.is_finite(), "both cars remain finite after a head-on impact")
	test.assert_true(first.speed() > first_impact_speed + 30.0, "first car reaccelerates under throttle after collision")
	test.assert_true(second.speed() > second_impact_speed + 30.0, "second car reaccelerates under throttle after collision")


func _test_side_contact_preserves_driveability(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(100.0)
	var model := VehicleModelType.new()
	var sample := track.sample_at_distance(2800.0)
	var first := model.create_state(&"side-a", track, 2800.0)
	var second := model.create_state(&"side-b", track, 2800.0)
	first.position = sample["position"] - sample["normal"] * 2.75
	second.position = sample["position"] + sample["normal"] * 2.75
	first.velocity = sample["tangent"] * 120.0 + sample["normal"] * 14.0
	second.velocity = sample["tangent"] * 120.0
	test.assert_true(model.resolve_vehicle_contact(first, second), "side-to-side overlap produces a collision")
	test.assert_near(model.vehicle_contact_penetration(first, second), 0.0, 0.001, "side collision strictly separates both hulls")
	test.assert_true(first.velocity.dot(sample["tangent"]) > 100.0, "side scrape retains bounded forward momentum")
	test.assert_true(second.velocity.dot(sample["tangent"]) > 100.0, "side impact does not immobilize the struck car")
	test.assert_true(first.is_finite() and second.is_finite(), "side collision leaves both states finite")


func _test_stacked_field_has_no_persistent_penetration(test: RefCounted) -> void:
	var fixture := _stacked_director(8107, 6)
	var director: RaceDirector = fixture["director"]
	var entries: Array = fixture["entries"]
	director.tick_fixed()
	test.assert_true(_all_hulls_separated(entries, 0.001), "six coincident cars resolve to zero persistent penetration in one fixed tick")
	var serials: Array[int] = []
	var contact_config_sanitizations := 0
	for entry in entries:
		serials.append(entry.state.vehicle_contact_serial)
		contact_config_sanitizations += \
			entry.vehicle_model.contact_config_sanitization_count
		test.assert_true(entry.state.is_finite(), "stacked contact participant remains finite")
	print("DENSE_CONTACT_WORK cars=6 passes=%d pair_checks=%d resolutions=%d config_sanitizations=%d" % [
		director.contact_solver_passes_last_tick,
		director.contact_pair_checks_last_tick,
		director.contact_resolutions_last_tick,
		contact_config_sanitizations,
	])
	test.assert_equal(
		contact_config_sanitizations, 0,
		"dense contact passes reuse sanitized configs without per-pair allocations"
	)
	director.tick_fixed()
	test.assert_true(_all_hulls_separated(entries, 0.001), "resolved stack remains non-overlapping on the following tick")
	for index in entries.size():
		test.assert_equal(entries[index].state.vehicle_contact_serial, serials[index], "separated car %d emits no phantom repeat contact" % index)


func _test_contact_solver_is_deterministic(test: RefCounted) -> void:
	var first_fixture := _stacked_director(9011, 6)
	var second_fixture := _stacked_director(9011, 6)
	var first_director: RaceDirector = first_fixture["director"]
	var second_director: RaceDirector = second_fixture["director"]
	var command := RaceInputType.new(0.0, 1.0, 0.0)
	var commands: Dictionary = {}
	for index in 6:
		commands[StringName("stack-%d" % index)] = command
	for _tick in 180:
		first_director.tick_fixed(commands)
		second_director.tick_fixed(commands)
	var first_entries: Array = first_fixture["entries"]
	var second_entries: Array = second_fixture["entries"]
	for index in first_entries.size():
		test.assert_equal(first_entries[index].state.authority_snapshot(), second_entries[index].state.authority_snapshot(), "contact authority for car %d exactly replays from the same seed" % index)
		test.assert_true(first_entries[index].state.speed() > 55.0, "contact participant %d reaccelerates after the stack separates" % index)
	test.assert_true(_all_hulls_separated(first_entries, 0.001), "accelerating deterministic field retains strict non-overlap")


func _stacked_director(seed_value: int, count: int) -> Dictionary:
	var track := FactoryType.create_large_rectangle(100.0)
	var director := DirectorType.new()
	director.configure(track, 1, seed_value, 8, true)
	director.countdown_duration = 0.0
	var entries: Array = []
	var sample := track.sample_at_distance(3400.0)
	for index in count:
		var entry = director.add_entry(
			StringName("stack-%d" % index), "Stack %d" % index, true
		)
		entry.state.position = sample["position"]
		entry.state.heading = Vector2.RIGHT.angle_to(sample["tangent"])
		entry.state.velocity = Vector2.ZERO
		entry.state.track_distance = float(sample["distance_along"])
		entry.state.lateral_offset = 0.0
		entry.lap_tracker.prime(
			entry.state.position,
			entry.state.track_distance,
			entry.state.track_collision_layer
		)
		entries.append(entry)
	director.start()
	return {"director": director, "entries": entries}


func _all_hulls_separated(entries: Array, tolerance: float) -> bool:
	for first_index in entries.size():
		for second_index in range(first_index + 1, entries.size()):
			var first = entries[first_index]
			var second = entries[second_index]
			if first.vehicle_model.vehicle_contact_penetration(
				first.state, second.state, second.vehicle_model.config
			) > tolerance:
				return false
	return true
