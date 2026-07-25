class_name RaceInput
extends RefCounted
## Platform-neutral driving command shared by touch, tilt, controller, AI, and replay.
##
## Presentation adapters may produce any numeric values; this contract clamps and
## dead-zones them before authoritative simulation sees the command.

const SOURCE_NONE: int = 0
const SOURCE_TOUCH: int = 1
const SOURCE_TILT: int = 2
const SOURCE_CONTROLLER: int = 4
const SOURCE_KEYBOARD: int = 8
const STEER_DEADZONE: float = 0.08
const PEDAL_DEADZONE: float = 0.02

var steer: float = 0.0
var throttle: float = 0.0
var brake: float = 0.0
var nitro: bool = false
var source_mask: int = SOURCE_NONE


func _init(
		steer_value: float = 0.0,
		throttle_value: float = 0.0,
		brake_value: float = 0.0,
		nitro_value: bool = false
	) -> void:
	steer = steer_value
	throttle = throttle_value
	brake = brake_value
	nitro = nitro_value
	sanitize()


func sanitize() -> RaceInput:
	steer = _deadzone(_finite_or_zero(steer), STEER_DEADZONE)
	steer = clampf(steer, -1.0, 1.0)
	throttle = _deadzone(_finite_or_zero(throttle), PEDAL_DEADZONE)
	throttle = clampf(throttle, 0.0, 1.0)
	brake = _deadzone(_finite_or_zero(brake), PEDAL_DEADZONE)
	brake = clampf(brake, 0.0, 1.0)
	return self


func duplicate_input() -> RaceInput:
	# Values are already normalized. Copy directly so repeated simulation and
	# prediction cloning cannot re-apply analog dead zones.
	var result := RaceInput.new()
	result.steer = steer
	result.throttle = throttle
	result.brake = brake
	result.nitro = nitro
	result.source_mask = source_mask
	return result


func to_dictionary() -> Dictionary:
	return {
		"steer": steer,
		"throttle": throttle,
		"brake": brake,
		"nitro": nitro,
		"source_mask": source_mask,
	}


static func from_touch(
		steer_axis: Variant,
		throttle_axis: Variant,
		brake_axis: Variant,
		nitro_pressed: bool = false
	) -> RaceInput:
	var result := RaceInput.new(
		_numeric(steer_axis), _numeric(throttle_axis), _numeric(brake_axis), nitro_pressed
	)
	result.source_mask = SOURCE_TOUCH
	return result


static func from_tilt(
		tilt_axis: Variant,
		throttle_axis: Variant = 1.0,
		brake_axis: Variant = 0.0,
		nitro_pressed: bool = false
	) -> RaceInput:
	var result := RaceInput.new(
		_numeric(tilt_axis), _numeric(throttle_axis), _numeric(brake_axis), nitro_pressed
	)
	result.source_mask = SOURCE_TILT
	return result


static func from_controller(
		steer_axis: Variant,
		throttle_axis: Variant,
		brake_axis: Variant,
		nitro_pressed: bool = false
	) -> RaceInput:
	var result := RaceInput.new(
		_numeric(steer_axis), _numeric(throttle_axis), _numeric(brake_axis), nitro_pressed
	)
	result.source_mask = SOURCE_CONTROLLER
	return result


static func merge(primary: RaceInput, secondary: RaceInput) -> RaceInput:
	if primary == null and secondary == null:
		return RaceInput.new()
	if primary == null:
		return secondary.duplicate_input()
	if secondary == null:
		return primary.duplicate_input()
	var chosen_steer := primary.steer
	if absf(chosen_steer) <= STEER_DEADZONE and absf(secondary.steer) > STEER_DEADZONE:
		chosen_steer = secondary.steer
	var result := RaceInput.new(
		chosen_steer,
		maxf(primary.throttle, secondary.throttle),
		maxf(primary.brake, secondary.brake),
		primary.nitro or secondary.nitro
	)
	result.source_mask = primary.source_mask | secondary.source_mask
	return result


static func _numeric(value: Variant) -> float:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return 0.0
	return _finite_or_zero(float(value))


static func _finite_or_zero(value: float) -> float:
	return value if not is_nan(value) and not is_inf(value) else 0.0


static func _deadzone(value: float, deadzone: float) -> float:
	if absf(value) <= deadzone:
		return 0.0
	# Snapping, rather than range remapping, makes sanitization idempotent.
	return value
