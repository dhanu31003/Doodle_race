class_name GameSettings
extends RefCounted
## Versioned, sanitized local preferences. This object contains no account,
## telemetry, or cloud state and is safe to serialize inside LocalSaveData.

const SCHEMA_VERSION: int = 1

const CONTROL_BUTTONS: StringName = &"buttons"
const CONTROL_WHEEL: StringName = &"wheel"
const CONTROL_TILT: StringName = &"tilt"
const CAMERA_COCKPIT: StringName = &"cockpit"
const CAMERA_CHASE: StringName = &"chase"

const MIN_CONTROL_SIZE: float = 0.75
const MAX_CONTROL_SIZE: float = 1.50
const MIN_CONTROL_OPACITY: float = 0.35
const MAX_CONTROL_OPACITY: float = 1.0
const MIN_UI_SCALE: float = 0.85
const MAX_UI_SCALE: float = 1.30

var schema_version: int = SCHEMA_VERSION

var master_volume: float = 0.85
var music_volume: float = 0.70
var sfx_volume: float = 0.85
var engine_volume: float = 0.82
var ambience_volume: float = 0.58
var ui_volume: float = 0.88
var muted: bool = false

var touch_control_scheme: StringName = CONTROL_BUTTONS
var touch_control_size: float = 1.0
var touch_control_opacity: float = 0.82
var touch_control_vertical_offset: float = 0.0
var left_handed_controls: bool = false
var tilt_calibration: Vector2 = Vector2.ZERO
var tilt_sensitivity: float = 1.0
var tilt_dead_zone: float = 0.08
var vibration_enabled: bool = true
var auto_accelerate: bool = false
var steering_assist: float = 0.35
var braking_assist: float = 0.20

var low_graphics: bool = false
var battery_saver: bool = false
var camera_view: StringName = CAMERA_CHASE
var reduced_motion: bool = false
var high_contrast: bool = false
var color_safe_differentiation: bool = true
var ui_scale: float = 1.0
var screen_shake: float = 0.35


static func from_dictionary(input: Variant) -> GameSettings:
	var settings := GameSettings.new()
	if not input is Dictionary:
		return settings
	var data: Dictionary = input
	var version := _read_int(data.get("schema_version"), 0)
	if version > SCHEMA_VERSION:
		# A newer writer may have changed semantics. Safe defaults are preferable
		# to guessing at controls or accessibility behavior.
		return settings

	var audio: Dictionary = _read_dictionary(data.get("audio", {}))
	var controls: Dictionary = _read_dictionary(data.get("controls", {}))
	var graphics: Dictionary = _read_dictionary(data.get("graphics", {}))
	var accessibility: Dictionary = _read_dictionary(data.get("accessibility", {}))

	# Version zero prototypes stored some values at the root. Nested v1 values
	# take precedence, while the aliases keep migration deterministic.
	settings.master_volume = _unit_float(audio.get("master", data.get("master_volume", settings.master_volume)), settings.master_volume)
	settings.music_volume = _unit_float(audio.get("music", data.get("music_volume", settings.music_volume)), settings.music_volume)
	settings.sfx_volume = _unit_float(audio.get("sfx", data.get("sfx_volume", settings.sfx_volume)), settings.sfx_volume)
	settings.engine_volume = _unit_float(audio.get("engine", data.get("engine_volume", settings.engine_volume)), settings.engine_volume)
	settings.ambience_volume = _unit_float(audio.get("ambience", data.get("ambience_volume", settings.ambience_volume)), settings.ambience_volume)
	settings.ui_volume = _unit_float(audio.get("ui", data.get("ui_volume", settings.ui_volume)), settings.ui_volume)
	settings.muted = _read_bool(audio.get("muted", data.get("muted", settings.muted)), settings.muted)

	settings.touch_control_scheme = _control_scheme(controls.get("scheme", data.get("control_scheme", settings.touch_control_scheme)))
	settings.touch_control_size = clampf(_read_float(controls.get("size", settings.touch_control_size), settings.touch_control_size), MIN_CONTROL_SIZE, MAX_CONTROL_SIZE)
	settings.touch_control_opacity = clampf(_read_float(controls.get("opacity", settings.touch_control_opacity), settings.touch_control_opacity), MIN_CONTROL_OPACITY, MAX_CONTROL_OPACITY)
	settings.touch_control_vertical_offset = _unit_float(controls.get("vertical_offset", settings.touch_control_vertical_offset), settings.touch_control_vertical_offset)
	settings.left_handed_controls = _read_bool(controls.get("left_handed", settings.left_handed_controls), settings.left_handed_controls)
	settings.tilt_calibration = _read_vector2(controls.get("tilt_calibration", [0.0, 0.0])).clamp(Vector2(-1.0, -1.0), Vector2.ONE)
	settings.tilt_sensitivity = clampf(_read_float(controls.get("tilt_sensitivity", settings.tilt_sensitivity), settings.tilt_sensitivity), 0.25, 2.5)
	settings.tilt_dead_zone = clampf(_read_float(controls.get("tilt_dead_zone", settings.tilt_dead_zone), settings.tilt_dead_zone), 0.0, 0.40)
	settings.vibration_enabled = _read_bool(controls.get("vibration", settings.vibration_enabled), settings.vibration_enabled)
	settings.auto_accelerate = _read_bool(controls.get("auto_accelerate", settings.auto_accelerate), settings.auto_accelerate)
	settings.steering_assist = _unit_float(controls.get("steering_assist", settings.steering_assist), settings.steering_assist)
	settings.braking_assist = _unit_float(controls.get("braking_assist", settings.braking_assist), settings.braking_assist)

	settings.low_graphics = _read_bool(graphics.get("low_graphics", settings.low_graphics), settings.low_graphics)
	settings.battery_saver = _read_bool(graphics.get("battery_saver", settings.battery_saver), settings.battery_saver)
	settings.camera_view = _camera_view(graphics.get("camera_view", data.get("camera_view", settings.camera_view)))
	settings.reduced_motion = _read_bool(accessibility.get("reduced_motion", settings.reduced_motion), settings.reduced_motion)
	settings.high_contrast = _read_bool(accessibility.get("high_contrast", settings.high_contrast), settings.high_contrast)
	settings.color_safe_differentiation = _read_bool(accessibility.get("color_safe_differentiation", settings.color_safe_differentiation), settings.color_safe_differentiation)
	settings.ui_scale = clampf(_read_float(accessibility.get("ui_scale", settings.ui_scale), settings.ui_scale), MIN_UI_SCALE, MAX_UI_SCALE)
	settings.screen_shake = _unit_float(accessibility.get("screen_shake", settings.screen_shake), settings.screen_shake)
	settings.schema_version = SCHEMA_VERSION
	return settings


func to_dictionary() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"audio": {
			"master": master_volume,
			"music": music_volume,
			"sfx": sfx_volume,
			"engine": engine_volume,
			"ambience": ambience_volume,
			"ui": ui_volume,
			"muted": muted,
		},
		"controls": {
			"scheme": str(touch_control_scheme),
			"size": touch_control_size,
			"opacity": touch_control_opacity,
			"vertical_offset": touch_control_vertical_offset,
			"left_handed": left_handed_controls,
			"tilt_calibration": [tilt_calibration.x, tilt_calibration.y],
			"tilt_sensitivity": tilt_sensitivity,
			"tilt_dead_zone": tilt_dead_zone,
			"vibration": vibration_enabled,
			"auto_accelerate": auto_accelerate,
			"steering_assist": steering_assist,
			"braking_assist": braking_assist,
		},
		"graphics": {
			"low_graphics": low_graphics,
			"battery_saver": battery_saver,
			"camera_view": str(camera_view),
		},
		"accessibility": {
			"reduced_motion": reduced_motion,
			"high_contrast": high_contrast,
			"color_safe_differentiation": color_safe_differentiation,
			"ui_scale": ui_scale,
			"screen_shake": screen_shake,
		},
	}


func sanitized_copy() -> GameSettings:
	return GameSettings.from_dictionary(to_dictionary())


func effective_volume(category: StringName) -> float:
	if muted:
		return 0.0
	match category:
		&"master":
			return master_volume
		&"music":
			return master_volume * music_volume
		&"sfx":
			return master_volume * sfx_volume
		&"engine":
			return master_volume * engine_volume
		&"ambience":
			return master_volume * ambience_volume
		&"ui":
			return master_volume * ui_volume
		_:
			return master_volume


static func _control_scheme(value: Variant) -> StringName:
	var scheme := StringName(str(value))
	if scheme == CONTROL_WHEEL or scheme == CONTROL_TILT:
		return scheme
	return CONTROL_BUTTONS


static func _camera_view(value: Variant) -> StringName:
	return CAMERA_COCKPIT if StringName(str(value)) == CAMERA_COCKPIT else CAMERA_CHASE


static func _unit_float(value: Variant, fallback: float) -> float:
	return clampf(_read_float(value, fallback), 0.0, 1.0)


static func _read_float(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var parsed := float(value)
	if is_nan(parsed) or is_inf(parsed):
		return fallback
	return parsed


static func _read_int(value: Variant, fallback: int) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT:
		var parsed := float(value)
		if not is_nan(parsed) and not is_inf(parsed) and parsed == round(parsed):
			return int(parsed)
	return fallback


static func _read_bool(value: Variant, fallback: bool) -> bool:
	return value if typeof(value) == TYPE_BOOL else fallback


static func _read_dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _read_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value if is_finite(value.x) and is_finite(value.y) else Vector2.ZERO
	if value is Array and value.size() == 2:
		return Vector2(_read_float(value[0], 0.0), _read_float(value[1], 0.0))
	return Vector2.ZERO
