extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const FactoryType := preload("res://tests/race/race_test_factory.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const VehicleConfigType := preload("res://game/race/vehicle_config.gd")
const VehicleModelType := preload("res://game/race/arcade_vehicle_model.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_input_contract(test)
	_test_acceleration_braking_and_coast(test)
	_test_formula_sequential_drivetrain(test)
	_test_speed_sensitive_steering_and_tyre_load(test)
	_test_conventional_reverse(test)
	_test_offtrack_wall_and_contact(test)
	_test_nitro_energy_and_cooldown(test)
	_test_malformed_bounds(test)
	return test.result("arcade_vehicle_model")


func _test_input_contract(test: RefCounted) -> void:
	var touch := RaceInputType.from_touch(2.0, -4.0, 1.5, true)
	test.assert_equal(touch.steer, 1.0, "touch steer clamps to normalized maximum")
	test.assert_equal(touch.throttle, 0.0, "negative throttle clamps to zero")
	test.assert_equal(touch.brake, 1.0, "touch brake clamps to normalized maximum")
	test.assert_true(touch.nitro, "digital nitro survives normalization")
	var malformed := RaceInputType.from_controller(NAN, INF, "brake", false)
	test.assert_equal(malformed.steer, 0.0, "non-finite steer becomes neutral")
	test.assert_equal(malformed.throttle, 0.0, "non-finite throttle becomes neutral")
	test.assert_equal(malformed.brake, 0.0, "non-numeric brake becomes neutral")
	var tilt := RaceInputType.from_tilt(0.6, 0.7)
	var merged := RaceInputType.merge(RaceInputType.new(), tilt)
	test.assert_true(merged.steer > 0.5 and merged.throttle > 0.6, "tilt merges through the shared command contract")
	test.assert_true((merged.source_mask & RaceInputType.SOURCE_TILT) != 0, "input source provenance is retained")


func _test_acceleration_braking_and_coast(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle()
	var model := VehicleModelType.new()
	var state := model.create_state(&"acceleration", track, 100.0)
	for _tick in 120:
		model.step_fixed(state, RaceInputType.new(0.0, 1.0, 0.0), track)
	var accelerated_speed := state.speed()
	test.assert_true(
		accelerated_speed > 75.0 and accelerated_speed < 105.0,
		"two-second launch is strong but traction-limited instead of instant arcade acceleration"
	)
	test.assert_true(state.gear >= 2, "automatic sequential gearbox upshifts during the launch")
	for _tick in 30:
		model.step_fixed(state, RaceInputType.new(0.0, 0.0, 1.0), track)
	var braked_speed := state.speed()
	test.assert_true(braked_speed < accelerated_speed * 0.55, "brake decisively reduces forward speed")
	state = model.create_state(&"coast", track, 100.0)
	state.velocity = state.forward() * 140.0
	model.step_fixed(state, RaceInputType.new(), track)
	test.assert_true(state.speed() < 140.0, "coasting applies rolling and aerodynamic drag")
	state = model.create_state(&"steer", track, 100.0)
	state.velocity = state.forward() * 220.0
	var before_heading := state.heading
	model.step_fixed(state, RaceInputType.new(1.0, 0.0, 0.0), track)
	test.assert_true(state.heading > before_heading, "steering rotates the vehicle at speed")


func _test_formula_sequential_drivetrain(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(100.0)
	var model := VehicleModelType.new()
	var launch := model.create_state(&"launch-benchmark", track, 100.0)
	var launch_ticks := 0
	var target_100_kmh := 100.0 / 1.08
	while launch.speed() < target_100_kmh and launch_ticks < 240:
		model.step_fixed(launch, RaceInputType.new(0.0, 1.0, 0.0), track)
		launch_ticks += 1
	var launch_seconds := float(launch_ticks) * VehicleModelType.FIXED_DT
	test.assert_true(
		launch_seconds >= 2.0 and launch_seconds <= 2.7,
		"zero-to-100 km/h launch stays inside the authored accessible Formula window"
	)
	var braking_benchmark := model.create_state(&"braking-benchmark", track, 100.0)
	braking_benchmark.velocity = braking_benchmark.forward() * (200.0 / 1.08)
	braking_benchmark.gear = 5
	var braking_ticks := 0
	while braking_benchmark.forward_speed() > 1.0 and braking_ticks < 240:
		model.step_fixed(braking_benchmark, RaceInputType.new(0.0, 0.0, 1.0), track)
		braking_ticks += 1
	var braking_seconds := float(braking_ticks) * VehicleModelType.FIXED_DT
	test.assert_true(
		braking_seconds >= 1.6 and braking_seconds <= 2.6,
		"200-to-zero braking stays bounded by carbon-brake and aero-load calibration"
	)
	test.assert_true(braking_benchmark.forward_speed() >= 0.0, "braking benchmark reaches neutral without overshooting into reverse")

	var state := model.create_state(&"gearbox", track, 100.0)
	var gears := [state.gear]
	var shift_rpm_drops := 0
	var previous_rpm := state.engine_rpm
	for _tick in 900:
		var previous_gear := state.gear
		model.step_fixed(state, RaceInputType.new(0.0, 1.0, 0.0), track)
		if state.gear != previous_gear:
			gears.append(state.gear)
			test.assert_equal(state.gear, previous_gear + 1, "forward gearbox shifts exactly one ratio at a time")
			test.assert_true(state.shift_ticks_remaining > 0, "upshift exposes a deterministic torque-cut window")
			if state.engine_rpm < previous_rpm:
				shift_rpm_drops += 1
		previous_rpm = state.engine_rpm
		if state.gear == 8 and state.speed() > 285.0:
			break
	test.assert_equal(gears, [1, 2, 3, 4, 5, 6, 7, 8], "eight-speed automatic box traverses every forward ratio in order")
	test.assert_equal(shift_rpm_drops, 7, "every upshift produces the expected audible RPM drop")
	test.assert_true(state.engine_rpm >= model.config.idle_rpm and state.engine_rpm <= model.config.redline_rpm, "engine RPM remains inside the authored Formula band")
	test.assert_true(state.wheel_slip >= 0.0 and state.wheel_slip < 0.25, "launch traction control exposes bounded wheel slip")

	var downshift_gears: Array[int] = []
	var previous_gear := state.gear
	for _tick in 220:
		model.step_fixed(state, RaceInputType.new(0.0, 0.0, 1.0), track)
		if state.gear != previous_gear and state.gear > 0:
			downshift_gears.append(state.gear)
			test.assert_equal(state.gear, previous_gear - 1, "braking downshift remains sequential")
		previous_gear = state.gear
		if state.speed() < 70.0:
			break
	test.assert_true(downshift_gears.size() >= 4, "heavy braking traverses multiple lower gears")

	var no_engine_brake_config := VehicleConfigType.new()
	no_engine_brake_config.engine_brake_deceleration = 0.0
	var no_engine_brake_model := VehicleModelType.new(no_engine_brake_config)
	var with_engine_brake := model.create_state(&"engine-brake", track, 100.0)
	var without_engine_brake := no_engine_brake_model.create_state(&"coast-only", track, 100.0)
	with_engine_brake.velocity = with_engine_brake.forward() * 150.0
	without_engine_brake.velocity = without_engine_brake.forward() * 150.0
	with_engine_brake.gear = 4
	without_engine_brake.gear = 4
	model.step_fixed(with_engine_brake, RaceInputType.new(), track)
	no_engine_brake_model.step_fixed(without_engine_brake, RaceInputType.new(), track)
	test.assert_true(with_engine_brake.speed() < without_engine_brake.speed(), "closed throttle applies ratio-aware engine braking")


func _test_speed_sensitive_steering_and_tyre_load(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle(120.0)
	var model := VehicleModelType.new()
	# Lock representative rack and full-lock radius values so future visual or
	# mobile tuning cannot silently remove steering authority at racing speeds.
	# The low-speed endpoint remains unchanged; only the upper-speed envelope is
	# modestly tighter and still constrained by the shared Formula tyre limit.
	var rack_calibration := [
		[40.0, 0.445574],
		[100.0, 0.346648],
		[160.0, 0.229256],
		[220.0, 0.156710],
		[280.0, 0.153000],
		[310.0, 0.153000],
	]
	var radius_calibration_m := [
		[40.0, 11.348],
		[100.0, 36.617],
		[160.0, 71.073],
		[220.0, 99.260],
		[280.0, 119.648],
		[310.0, 127.425],
	]
	test.assert_near(
		model.config.maximum_steering_angle_for_speed(0.0), 0.47, 0.000001,
		"stationary and low-speed steering endpoint remains unchanged"
	)
	for row in rack_calibration:
		var calibration_speed := float(row[0])
		test.assert_near(
			model.config.maximum_steering_angle_for_speed(calibration_speed),
			float(row[1]), 0.00001,
			"speed-sensitive rack angle remains calibrated at %.0f world units/s" % calibration_speed
		)
	for row in radius_calibration_m:
		var calibration_speed := float(row[0])
		test.assert_near(
			_full_lock_radius_m(model, track, calibration_speed),
			float(row[1]), 0.35,
			"full-lock tyre-limited radius remains calibrated at %.0f world units/s" % calibration_speed
		)
	var low := model.create_state(&"low-speed-steer", track, 200.0)
	var high := model.create_state(&"high-speed-steer", track, 200.0)
	low.velocity = low.forward() * 40.0
	high.velocity = high.forward() * 220.0
	low.steering_input = 1.0
	high.steering_input = 1.0
	var low_heading := low.heading
	var high_heading := high.heading
	model.step_fixed(low, RaceInputType.new(1.0, 0.0, 0.0), track)
	model.step_fixed(high, RaceInputType.new(1.0, 0.0, 0.0), track)
	var low_yaw := absf(wrapf(low.heading - low_heading, -PI, PI))
	var high_yaw := absf(wrapf(high.heading - high_heading, -PI, PI))
	var low_radius := 40.0 * VehicleModelType.FIXED_DT / maxf(low_yaw, 0.0001)
	var high_radius := 220.0 * VehicleModelType.FIXED_DT / maxf(high_yaw, 0.0001)
	test.assert_true(high_radius > low_radius * 1.7, "speed-sensitive rack produces a wider, stable high-speed turning radius")
	var top_speed_capacity := model.lateral_acceleration_capacity(model.config.maximum_forward_speed)
	var top_speed_g := VehicleModelType.world_lateral_acceleration_to_g(top_speed_capacity)
	var tyre_limited_radius_m := (
		model.config.maximum_forward_speed * model.config.maximum_forward_speed
		/ top_speed_capacity * VehicleModelType.WORLD_UNIT_TO_METERS
	)
	test.assert_true(top_speed_g >= 5.5 and top_speed_g <= 7.0, "maximum downforce load remains in a plausible modern Formula lateral-g envelope")
	test.assert_true(tyre_limited_radius_m >= 120.0, "top-speed full lock is tyre-limited to a plausible high-speed turn radius")
	var radius_100_speed := model.config.corner_speed_limit_for_radius(100.0)
	var radius_200_speed := model.config.corner_speed_limit_for_radius(200.0)
	var radius_300_speed := model.config.corner_speed_limit_for_radius(300.0)
	test.assert_near(radius_100_speed, 88.39, 0.05, "100-unit corner speed solves the mechanical-plus-downforce tyre envelope")
	test.assert_near(radius_200_speed, 139.92, 0.05, "200-unit corner speed solves the mechanical-plus-downforce tyre envelope")
	test.assert_near(radius_300_speed, 198.28, 0.05, "300-unit corner speed solves the mechanical-plus-downforce tyre envelope")
	for radius in [100.0, 200.0, 300.0]:
		var corner_speed := model.config.corner_speed_limit_for_radius(radius, 0.96)
		var required_acceleration: float = corner_speed * corner_speed / radius
		test.assert_true(
			required_acceleration <= model.lateral_acceleration_capacity(corner_speed) + 0.001,
			"AI-safe corner speed remains within physical tyre authority at radius %.0f" % radius
		)
	test.assert_equal(model.config.corner_speed_limit_for_radius(NAN), 0.0, "malformed corner radius fails to a stopped target")
	test.assert_equal(model.config.corner_speed_limit_for_radius(INF), model.config.maximum_forward_speed, "unbounded radius permits configured straight-line speed")
	var corner_target := model.config.corner_speed_limit_for_radius(120.0, 0.96)
	var immediate_limit := model.config.braking_approach_speed_limit(corner_target, 0.0, 0.90)
	var distant_limit := model.config.braking_approach_speed_limit(corner_target, 240.0, 0.90)
	test.assert_near(immediate_limit, corner_target, 0.001, "zero-distance braking envelope equals the physical corner target")
	test.assert_true(distant_limit > immediate_limit, "distance-aware braking envelope permits acceleration before a future corner")
	var braking_base := model.config.brake_deceleration
	var braking_aero := model.config.brake_downforce_coefficient
	var required_braking_distance := log(
		(braking_base + braking_aero * distant_limit * distant_limit) \
			/ (braking_base + braking_aero * corner_target * corner_target)
	) / (2.0 * braking_aero * 0.90)
	test.assert_true(
		required_braking_distance <= 240.01,
		"approach target integrates only the shared bounded Formula brake curve"
	)

	var rate_limited := model.create_state(&"rack-rate", track, 200.0)
	rate_limited.velocity = rate_limited.forward() * 100.0
	model.step_fixed(rate_limited, RaceInputType.new(1.0, 0.0, 0.0), track)
	test.assert_true(rate_limited.steering_input > 0.0 and rate_limited.steering_input < 0.2, "steering rack builds lock progressively instead of snapping")

	var low_load := model.create_state(&"low-load", track, 200.0)
	var high_load := model.create_state(&"high-load", track, 200.0)
	low_load.velocity = low_load.forward() * 40.0 + Vector2(-sin(low_load.heading), cos(low_load.heading)) * 50.0
	high_load.velocity = high_load.forward() * 220.0 + Vector2(-sin(high_load.heading), cos(high_load.heading)) * 50.0
	model.step_fixed(low_load, RaceInputType.new(), track)
	model.step_fixed(high_load, RaceInputType.new(), track)
	test.assert_true(absf(high_load.lateral_acceleration) > absf(low_load.lateral_acceleration), "aerodynamic load raises available high-speed lateral tyre force")
	test.assert_true(absf(high_load.slip_angle) > 0.0 and high_load.slip_angle <= PI * 0.5, "tyre slip angle is finite and exposed as authority telemetry")
	var high_lateral_after := absf(high_load.velocity.dot(Vector2(-sin(high_load.heading), cos(high_load.heading))))
	test.assert_true(high_lateral_after < 50.0 and high_lateral_after > 0.0, "tyres recover lateral slip progressively without instant velocity rotation")


func _full_lock_radius_m(model: ArcadeVehicleModel, track: RaceTrackQuery, speed: float) -> float:
	var state := model.create_state(StringName("full-lock-%.0f" % speed), track, 200.0)
	state.velocity = state.forward() * speed
	state.steering_input = 1.0
	var before_heading := state.heading
	model.step_fixed(state, RaceInputType.new(1.0, 0.0, 0.0), track)
	var yaw_delta := absf(wrapf(state.heading - before_heading, -PI, PI))
	return speed * VehicleModelType.FIXED_DT / maxf(yaw_delta, 0.0001) \
		* VehicleModelType.WORLD_UNIT_TO_METERS


func _test_conventional_reverse(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle()
	var model := VehicleModelType.new()
	var braking := model.create_state(&"braking", track, 500.0)
	braking.velocity = braking.forward() * 75.0
	model.step_fixed(braking, RaceInputType.new(0.0, 0.0, 1.0), track)
	test.assert_true(
		braking.forward_speed() > 0.0 and braking.forward_speed() < 75.0,
		"brake decelerates a moving car without instantly engaging reverse"
	)
	braking.velocity = braking.forward() * 4.2
	model.step_fixed(braking, RaceInputType.new(0.0, 0.0, 1.0), track)
	test.assert_true(braking.forward_speed() >= 0.0, "braking settles forward motion at neutral first")
	var reverse_engaged := false
	for _tick in 8:
		var speed_before := braking.forward_speed()
		model.step_fixed(braking, RaceInputType.new(0.0, 0.0, 1.0), track)
		if braking.forward_speed() < 0.0:
			reverse_engaged = true
			test.assert_true(speed_before <= 1.0, "reverse engages only after forward motion reaches the neutral threshold")
			break
	test.assert_true(reverse_engaged, "holding brake engages reverse within a bounded neutral transition")
	var state := model.create_state(&"reverse", track, 500.0)
	for _tick in 90:
		model.step_fixed(state, RaceInputType.new(0.0, 0.0, 1.0), track)
	test.assert_true(state.forward_speed() < -35.0, "holding brake from rest engages conventional reverse")
	test.assert_true(state.forward_speed() >= -model.config.maximum_reverse_speed - 0.01, "reverse speed respects its deterministic limit")
	var reverse_speed := state.forward_speed()
	var crossed_neutral := false
	for _tick in 180:
		model.step_fixed(state, RaceInputType.new(0.0, 1.0, 0.0), track)
		if state.forward_speed() > 1.0:
			crossed_neutral = true
			break
	test.assert_true(state.forward_speed() > reverse_speed, "accelerator actively decelerates a reversing car toward neutral")
	test.assert_true(crossed_neutral and state.gear == 1, "continued accelerator crosses neutral into first-gear forward motion")


func _test_offtrack_wall_and_contact(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle()
	var model := VehicleModelType.new()
	var sample := track.sample_at_distance(500.0)
	var ontrack := model.create_state(&"road", track, 500.0)
	var offtrack := model.create_state(&"grass", track, 500.0)
	ontrack.velocity = sample["tangent"] * 180.0
	offtrack.position = sample["position"] + sample["normal"] * (track.track_width * 0.5 + 3.0)
	offtrack.velocity = sample["tangent"] * 180.0
	model.step_fixed(ontrack, RaceInputType.new(0.0, 1.0, 0.0), track)
	model.step_fixed(offtrack, RaceInputType.new(0.0, 1.0, 0.0), track)
	test.assert_true(offtrack.is_offtrack, "road-edge excursion is classified off-track")
	test.assert_true(offtrack.speed() < ontrack.speed(), "grass applies engine loss and extra slowdown")
	var wall := model.create_state(&"wall", track, 500.0)
	var shoulder := maxf(6.0, track.track_width * 0.35)
	wall.position = sample["position"] + sample["normal"] * (
		track.track_width * 0.5 + shoulder + 12.0
	)
	wall.velocity = sample["normal"] * 100.0 + sample["tangent"] * 60.0
	model.step_fixed(wall, RaceInputType.new(), track)
	test.assert_true(wall.wall_contacts > 0, "outer barrier records a wall contact")
	var wall_projection := track.clamp_to_wall(wall.position, model.config.vehicle_radius)
	test.assert_near(float(wall_projection["wall_penetration"]), 0.0, 0.001, "wall response removes barrier penetration")
	test.assert_true(wall.velocity.dot(sample["normal"]) <= 0.0, "wall response reflects outward velocity")
	var first := model.create_state(&"contact_a", track, 700.0)
	var second := first.duplicate_state()
	second.vehicle_id = &"contact_b"
	second.position += Vector2.RIGHT * 2.0
	first.velocity = Vector2.RIGHT * 10.0
	second.velocity = Vector2.LEFT * 10.0
	test.assert_true(model.resolve_vehicle_contact(first, second), "overlapping vehicles resolve a contact")
	test.assert_near(
		model.vehicle_contact_penetration(first, second),
		0.0,
		0.001,
		"contact separates the complete Formula capsule hulls"
	)


func _test_nitro_energy_and_cooldown(test: RefCounted) -> void:
	var track := FactoryType.create_large_rectangle()
	var model := VehicleModelType.new()
	var normal := model.create_state(&"normal", track, 100.0)
	var boosted := model.create_state(&"boosted", track, 100.0)
	for _tick in 90:
		model.step_fixed(normal, RaceInputType.new(0.0, 1.0, 0.0, false), track)
		model.step_fixed(boosted, RaceInputType.new(0.0, 1.0, 0.0, true), track)
	test.assert_true(boosted.speed() > normal.speed() + 25.0, "nitro creates a measurable acceleration advantage")
	test.assert_true(boosted.nitro_energy < model.config.nitro_capacity - 1.0, "active nitro drains bounded energy")
	model.step_fixed(boosted, RaceInputType.new(0.0, 1.0, 0.0, false), track)
	test.assert_false(boosted.nitro_active, "releasing nitro stops boost")
	test.assert_true(boosted.nitro_cooldown_remaining > 0.9, "released nitro enters cooldown")
	var energy_after_release := boosted.nitro_energy
	for _tick in 10:
		model.step_fixed(boosted, RaceInputType.new(0.0, 1.0, 0.0, false), track)
	test.assert_near(boosted.nitro_energy, energy_after_release, 0.001, "nitro does not recharge during cooldown")


func _test_malformed_bounds(test: RefCounted) -> void:
	var malformed_config := VehicleConfigType.new()
	malformed_config.engine_acceleration = INF
	malformed_config.brake_deceleration = NAN
	malformed_config.maximum_forward_speed = INF
	malformed_config.lateral_grip = -100.0
	malformed_config.vehicle_radius = NAN
	var model := VehicleModelType.new(malformed_config)
	test.assert_equal(model.config.engine_acceleration, 58.0, "non-finite engine force uses the Formula fallback")
	test.assert_equal(model.config.brake_deceleration, 76.0, "non-finite brake force uses the Formula fallback")
	test.assert_equal(model.config.maximum_forward_speed, 310.0, "non-finite speed falls back safely")
	test.assert_equal(model.config.lateral_grip, 0.0, "negative grip is bounded")
	test.assert_equal(model.config.vehicle_radius, 4.5, "non-finite radius falls back safely")
	var track := FactoryType.create_large_rectangle()
	var state := model.create_state(&"invalid-step", track, 100.0)
	test.assert_false(model.step(state, RaceInputType.new(), track, NAN), "non-finite delta is rejected")
	test.assert_false(model.step(state, RaceInputType.new(), track, 1.0), "oversized simulation delta is rejected")
