class_name SettingsRuntime
extends RefCounted
## Side-effect boundary for applying persisted preferences. UI/race systems can
## also use the pure helpers without depending on the persistence repository.

const GameSettingsType := preload("res://game/settings/game_settings.gd")
const WORLD_SPEED_TO_KMH: float = 1.08
const PERFORMANCE_TARGET_FPS := 60
const BATTERY_TARGET_FPS := 30


static func apply_audio(settings: GameSettings) -> void:
	if settings == null:
		return
	_set_bus(&"Master", settings.master_volume, settings.muted)
	_set_bus(&"Music", settings.music_volume, false)
	_set_bus(&"SFX", settings.sfx_volume, false)


static func apply_performance(settings: GameSettings) -> void:
	if settings == null:
		return
	Engine.max_fps = target_fps(settings)


static func target_fps(settings: GameSettings) -> int:
	return BATTERY_TARGET_FPS if settings != null and settings.battery_saver else PERFORMANCE_TARGET_FPS


static func motion_multiplier(settings: GameSettings) -> float:
	return 0.0 if settings != null and settings.reduced_motion else 1.0


static func screen_shake_strength(settings: GameSettings) -> float:
	if settings == null or settings.reduced_motion:
		return 0.0
	return settings.screen_shake


static func allows_vibration(settings: GameSettings) -> bool:
	return settings != null and settings.vibration_enabled


static func requires_non_color_cues(settings: GameSettings) -> bool:
	return settings == null or settings.color_safe_differentiation


static func speed_to_kmh(world_speed: float) -> int:
	if is_nan(world_speed) or is_inf(world_speed):
		return 0
	return clampi(roundi(maxf(world_speed, 0.0) * WORLD_SPEED_TO_KMH), 0, 999)


static func drivetrain_hud_text(gear: int, engine_rpm: float, shifting: bool = false) -> String:
	var gear_text := "N"
	if gear < 0:
		gear_text = "R"
	elif gear > 0:
		gear_text = "G%d" % clampi(gear, 1, 8)
	var safe_rpm := 0.0 if is_nan(engine_rpm) or is_inf(engine_rpm) else engine_rpm
	return "%s  %05d RPM%s" % [
		gear_text,
		clampi(roundi(safe_rpm), 0, 20_000),
		"  SHIFT" if shifting else "",
	]


static func _set_bus(bus_name: StringName, linear_volume: float, muted: bool) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(linear_volume, 0.0001)))
	AudioServer.set_bus_mute(index, muted)
