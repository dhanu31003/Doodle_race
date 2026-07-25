class_name AudioPolicy
extends RefCounted
## Pure audio settings and cue-rate policy shared by runtime and headless tests.

const MIN_DB: float = -80.0
const DEFAULT_CUE_INTERVAL_MS: int = 28
const CUE_INTERVAL_MS: Dictionary = {
	&"click": 90,
	&"confirm": 60,
	&"error": 100,
	&"countdown": 140,
	&"go": 250,
	&"boost": 110,
	&"skid": 160,
	&"collision": 140,
	&"lap": 400,
	&"finish": 900,
}
const PAUSE_BLOCKED_CUES: Array[StringName] = [&"boost", &"skid"]

var master_volume: float = 1.0
var music_volume: float = 0.72
var sfx_volume: float = 0.86
var engine_volume: float = 0.82
var ambience_volume: float = 0.58
var ui_volume: float = 0.88
var muted: bool = false
var music_muted: bool = false
var sfx_muted: bool = false
var audio_cues_enabled: bool = true
var reduced_motion: bool = false
var gameplay_paused: bool = false

var _last_cue_msec: Dictionary = {}


func apply_settings(settings: Dictionary) -> void:
	master_volume = _normalized_setting(settings, &"master_volume", master_volume)
	music_volume = _normalized_setting(settings, &"music_volume", music_volume)
	sfx_volume = _normalized_setting(settings, &"sfx_volume", sfx_volume)
	engine_volume = _normalized_setting(settings, &"engine_volume", engine_volume)
	ambience_volume = _normalized_setting(settings, &"ambience_volume", ambience_volume)
	ui_volume = _normalized_setting(settings, &"ui_volume", ui_volume)
	muted = _bool_setting(settings, &"muted", muted)
	music_muted = _bool_setting(settings, &"music_muted", music_muted)
	sfx_muted = _bool_setting(settings, &"sfx_muted", sfx_muted)
	audio_cues_enabled = _bool_setting(settings, &"audio_cues_enabled", audio_cues_enabled)
	reduced_motion = _bool_setting(settings, &"reduced_motion", reduced_motion)
	# GameSettings.to_dictionary() uses stable nested groups. Supporting that
	# shape here keeps persistence and audio decoupled without adapter glue.
	var audio_variant: Variant = settings.get("audio", {})
	if audio_variant is Dictionary:
		var audio := audio_variant as Dictionary
		master_volume = _normalized_setting(audio, &"master", master_volume)
		music_volume = _normalized_setting(audio, &"music", music_volume)
		sfx_volume = _normalized_setting(audio, &"sfx", sfx_volume)
		engine_volume = _normalized_setting(audio, &"engine", engine_volume)
		ambience_volume = _normalized_setting(audio, &"ambience", ambience_volume)
		ui_volume = _normalized_setting(audio, &"ui", ui_volume)
		muted = _bool_setting(audio, &"muted", muted)
	var accessibility_variant: Variant = settings.get("accessibility", {})
	if accessibility_variant is Dictionary:
		reduced_motion = _bool_setting(accessibility_variant as Dictionary, &"reduced_motion", reduced_motion)


func snapshot() -> Dictionary:
	return {
		"master_volume": master_volume,
		"music_volume": music_volume,
		"sfx_volume": sfx_volume,
		"engine_volume": engine_volume,
		"ambience_volume": ambience_volume,
		"ui_volume": ui_volume,
		"muted": muted,
		"music_muted": music_muted,
		"sfx_muted": sfx_muted,
		"audio_cues_enabled": audio_cues_enabled,
		"reduced_motion": reduced_motion,
	}


func request_cue(cue_id: StringName, now_msec: int = -1) -> StringName:
	if not audio_cues_enabled or muted or sfx_muted or master_volume <= 0.0 or sfx_volume <= 0.0:
		return &"sfx_disabled"
	if gameplay_paused and cue_id in PAUSE_BLOCKED_CUES:
		return &"gameplay_paused"
	var timestamp := Time.get_ticks_msec() if now_msec < 0 else now_msec
	var minimum_interval := int(CUE_INTERVAL_MS.get(cue_id, DEFAULT_CUE_INTERVAL_MS))
	if _last_cue_msec.has(cue_id):
		var elapsed := timestamp - int(_last_cue_msec[cue_id])
		if elapsed >= 0 and elapsed < minimum_interval:
			return &"rate_limited"
	_last_cue_msec[cue_id] = timestamp
	return &""


func reset_cue_gate(cue_id: StringName = &"") -> void:
	if cue_id.is_empty():
		_last_cue_msec.clear()
	else:
		_last_cue_msec.erase(cue_id)


func set_gameplay_paused(value: bool) -> void:
	gameplay_paused = value


func set_reduced_motion(value: bool) -> void:
	reduced_motion = value


static func normalized_to_db(value: float) -> float:
	var normalized := clampf(value, 0.0, 1.0)
	return MIN_DB if normalized <= 0.0001 else linear_to_db(normalized)


func _normalized_setting(settings: Dictionary, key: StringName, fallback: float) -> float:
	if not settings.has(key):
		return fallback
	var value: Variant = settings[key]
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var numeric := float(value)
	if is_nan(numeric) or is_inf(numeric):
		return fallback
	return clampf(numeric, 0.0, 1.0)


func _bool_setting(settings: Dictionary, key: StringName, fallback: bool) -> bool:
	if not settings.has(key) or typeof(settings[key]) != TYPE_BOOL:
		return fallback
	return bool(settings[key])
