extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const AdapterType := preload("res://game/ui/input/race_input_adapter.gd")
const SettingsType := preload("res://game/settings/game_settings.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_auto_acceleration_and_manual_pedals(test)
	_test_steering_and_braking_assistance(test)
	_test_tilt_calibration(test)
	return test.result("race_input_adapter")


func _test_auto_acceleration_and_manual_pedals(test: RefCounted) -> void:
	var settings := SettingsType.new()
	settings.auto_accelerate = true
	var automatic := AdapterType.apply_settings(RaceInputType.new(), settings)
	test.assert_equal(automatic.throttle, 1.0, "auto accelerate supplies full throttle when pedals are idle")
	var braking := AdapterType.apply_settings(RaceInputType.new(0.0, 0.0, 0.7), settings)
	test.assert_near(braking.throttle, 0.3, 0.001, "auto accelerate yields proportionally to manual brake")
	settings.auto_accelerate = false
	var manual := AdapterType.apply_settings(RaceInputType.new(0.0, 0.62, 0.0), settings)
	test.assert_true(manual.throttle > 0.60 and manual.throttle < 0.63, "manual throttle survives normalized settings adapter")


func _test_steering_and_braking_assistance(test: RefCounted) -> void:
	var settings := SettingsType.new()
	settings.auto_accelerate = false
	settings.steering_assist = 1.0
	settings.braking_assist = 1.0
	var assisted := AdapterType.apply_settings(RaceInputType.new(0.0, 1.0, 0.0), settings, {
		"track_half_width": 20.0,
		"lateral_offset": 10.0,
		"heading_error": 0.5,
		"upcoming_radius": 20.0,
		"speed": 300.0,
		"maximum_speed": 310.0,
	})
	test.assert_true(absf(assisted.steer) > 0.05, "steering assist produces bounded recovery authority")
	test.assert_true(assisted.brake > 0.5, "braking assist responds to an overspeed tight corner")
	test.assert_true(assisted.throttle < 0.5, "braking assist reduces conflicting throttle")
	test.assert_true(absf(assisted.steer) <= 1.0 and assisted.brake <= 1.0, "all assistance remains normalized")
	settings.steering_assist = 0.0
	settings.braking_assist = 0.0
	var disabled := AdapterType.apply_settings(RaceInputType.new(0.25, 0.8, 0.0), settings, {
		"heading_error": 1.0, "lateral_offset": 20.0, "track_half_width": 20.0,
		"upcoming_radius": 10.0, "speed": 300.0,
	})
	test.assert_near(disabled.steer, RaceInputType.new(0.25).steer, 0.001, "zero steering assist preserves player steering")
	test.assert_equal(disabled.brake, 0.0, "zero braking assist does not inject brake")


func _test_tilt_calibration(test: RefCounted) -> void:
	var settings := SettingsType.new()
	settings.touch_control_scheme = SettingsType.CONTROL_TILT
	settings.tilt_calibration = Vector2(0.0, 0.5)
	settings.tilt_dead_zone = 0.10
	settings.tilt_sensitivity = 1.0
	test.assert_equal(AdapterType.tilt_axis_from_acceleration(Vector3(0.0, 0.5, 0.0), settings), 0.0, "calibrated neutral tilt stays centered")
	var right := AdapterType.tilt_axis_from_acceleration(Vector3(0.0, 3.0, 0.0), settings)
	var left := AdapterType.tilt_axis_from_acceleration(Vector3(0.0, -2.0, 0.0), settings)
	test.assert_true(right > 0.3 and left < -0.3, "tilt adapter produces signed landscape steering")
	settings.tilt_sensitivity = 2.0
	test.assert_true(AdapterType.tilt_axis_from_acceleration(Vector3(0.0, 3.0, 0.0), settings) > right, "tilt sensitivity scales steering response")
