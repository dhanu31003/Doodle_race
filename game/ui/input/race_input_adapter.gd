class_name RaceInputAdapter
extends RefCounted
## Godot input boundary that converts touch, wheel, tilt, keyboard, and gamepad
## state into the platform-neutral RaceInput contract.

const RaceInputType := preload("res://game/race/race_input.gd")
const GameSettingsType := preload("res://game/settings/game_settings.gd")

var touch_steer: float = 0.0
var touch_throttle: float = 0.0
var touch_brake: float = 0.0


func reset_touch() -> void:
	touch_steer = 0.0
	touch_throttle = 0.0
	touch_brake = 0.0


func sample(settings: GameSettings, assist_context: Dictionary = {}) -> RaceInput:
	var safe_settings := settings if settings != null else GameSettingsType.new()
	var touch := RaceInputType.from_touch(touch_steer, touch_throttle, touch_brake)
	if safe_settings.touch_control_scheme == GameSettingsType.CONTROL_TILT:
		touch = RaceInputType.from_tilt(
			_tilt_axis(Input.get_accelerometer(), safe_settings),
			touch_throttle,
			touch_brake
		)
	var merged := RaceInputType.merge(_controller_input(), touch)
	merged = RaceInputType.merge(_keyboard_input(), merged)
	return apply_settings(merged, safe_settings, assist_context)


static func apply_settings(
		raw_command: RaceInput,
		settings: GameSettings,
		assist_context: Dictionary = {}
	) -> RaceInput:
	var safe_settings := settings if settings != null else GameSettingsType.new()
	var output := raw_command.duplicate_input() if raw_command != null else RaceInputType.new()
	if safe_settings.auto_accelerate:
		output.throttle = maxf(output.throttle, 1.0 - output.brake)
	var half_width := maxf(_number(assist_context.get("track_half_width", 1.0), 1.0), 1.0)
	var lateral := _number(assist_context.get("lateral_offset", 0.0), 0.0)
	var heading_error := _number(assist_context.get("heading_error", 0.0), 0.0)
	var correction := clampf(heading_error / 0.75 - lateral / half_width * 0.62, -1.0, 1.0)
	var assist_weight := safe_settings.steering_assist * (1.0 - absf(output.steer) * 0.45)
	output.steer = clampf(output.steer + correction * assist_weight, -1.0, 1.0)

	var radius := _number(assist_context.get("upcoming_radius", INF), INF)
	var speed := maxf(_number(assist_context.get("speed", 0.0), 0.0), 0.0)
	var maximum_speed := maxf(_number(assist_context.get("maximum_speed", 310.0), 310.0), 20.0)
	if not is_inf(radius):
		var assisted_target_speed := clampf(sqrt(maxf(radius, 1.0)) * 22.0, 55.0, maximum_speed)
		var overspeed := clampf((speed - assisted_target_speed) / 70.0, 0.0, 1.0)
		output.brake = maxf(output.brake, overspeed * safe_settings.braking_assist)
		output.throttle *= 1.0 - output.brake * safe_settings.braking_assist
	output.sanitize()
	return output


static func tilt_axis_from_acceleration(acceleration: Vector3, settings: GameSettings) -> float:
	var safe_settings := settings if settings != null else GameSettingsType.new()
	return _tilt_axis(acceleration, safe_settings)


func _keyboard_input() -> RaceInput:
	var steer_axis := 0.0
	if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
		steer_axis -= 1.0
	if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
		steer_axis += 1.0
	var command := RaceInputType.new(
		steer_axis,
		1.0 if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W) else 0.0,
		1.0 if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S) else 0.0
	)
	command.source_mask = RaceInputType.SOURCE_KEYBOARD
	return command


func _controller_input() -> RaceInput:
	var joypads := Input.get_connected_joypads()
	if joypads.is_empty():
		return RaceInputType.new()
	var device := int(joypads[0])
	var command := RaceInputType.from_controller(
		Input.get_joy_axis(device, JOY_AXIS_LEFT_X),
		_trigger(Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT)),
		_trigger(Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT))
	)
	return command


static func _tilt_axis(acceleration: Vector3, settings: GameSettings) -> float:
	if not _finite(acceleration.y):
		return 0.0
	# Landscape roll maps to the device Y accelerometer on both mobile exports.
	var calibrated := (acceleration.y - settings.tilt_calibration.y) / 4.9
	var scaled := calibrated * settings.tilt_sensitivity
	var dead_zone := settings.tilt_dead_zone
	if absf(scaled) <= dead_zone:
		return 0.0
	var sign_value := -1.0 if scaled < 0.0 else 1.0
	return sign_value * clampf((absf(scaled) - dead_zone) / maxf(1.0 - dead_zone, 0.01), 0.0, 1.0)


static func _trigger(value: float) -> float:
	if not _finite(value):
		return 0.0
	if value < -0.05:
		return clampf((value + 1.0) * 0.5, 0.0, 1.0)
	return clampf(value, 0.0, 1.0)


static func _number(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var converted := float(value)
	return converted if _finite(converted) else fallback


static func _finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)
