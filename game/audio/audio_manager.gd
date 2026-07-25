class_name AudioManager
extends Node
## Runtime music/SFX facade. Recommended autoload name: `Audio`.
##
## The manager is deliberately tolerant of absent or corrupt audio resources:
## play calls return false and emit cue_rejected instead of crashing a screen.

signal cue_played(cue_id: StringName)
signal cue_rejected(cue_id: StringName, reason: StringName)
signal music_changed(cue_id: StringName)
signal settings_changed(settings: Dictionary)

const AudioPolicyType := preload("res://game/audio/audio_policy.gd")

const MASTER_BUS: StringName = &"Master"
const MUSIC_BUS: StringName = &"Music"
const SFX_BUS: StringName = &"SFX"
const ENGINE_BUS: StringName = &"Engine"
const AMBIENCE_BUS: StringName = &"Ambience"
const UI_BUS: StringName = &"UI"
const SFX_VOICE_COUNT: int = 8
const MUSIC_CUES: Array[StringName] = [&"menu_loop", &"race_loop"]
const UI_CUES: Array[StringName] = [&"click", &"confirm", &"error"]
const VEHICLE_CUES: Array[StringName] = [&"boost", &"skid"]
const CUE_PRIORITY: Dictionary = {
	&"click": 0,
	&"confirm": 1,
	&"error": 2,
	&"countdown": 2,
	&"go": 3,
	&"boost": 1,
	&"skid": 1,
	&"collision": 2,
	&"lap": 3,
	&"finish": 4,
}
const DEFAULT_ASSET_PATHS: Dictionary = {
	&"menu_loop": "res://assets/final/audio/menu_loop.wav",
	&"race_loop": "res://assets/final/audio/race_loop.wav",
	&"engine_loop": "res://assets/final/audio/engine_loop.wav",
	&"forest_ambience": "res://assets/final/audio/forest_ambience.wav",
	&"countdown": "res://assets/final/audio/countdown.wav",
	&"go": "res://assets/final/audio/go.wav",
	&"click": "res://assets/final/audio/click.wav",
	&"confirm": "res://assets/final/audio/confirm.wav",
	&"error": "res://assets/final/audio/error.wav",
	&"boost": "res://assets/final/audio/boost.wav",
	&"skid": "res://assets/final/audio/skid.wav",
	&"collision": "res://assets/final/audio/collision.wav",
	&"lap": "res://assets/final/audio/lap.wav",
	&"finish": "res://assets/final/audio/finish.wav",
}

var _policy: AudioPolicy = AudioPolicyType.new()
var _asset_paths: Dictionary = DEFAULT_ASSET_PATHS.duplicate()
var _stream_cache: Dictionary = {}
var _music_player: AudioStreamPlayer
var _engine_player: AudioStreamPlayer
var _ambience_player: AudioStreamPlayer
var _sfx_players: Array[AudioStreamPlayer] = []
var _voice_cues: Array[StringName] = []
var _voice_started_msec: Array[int] = []
var _voice_priorities: Array[int] = []
var _current_music: StringName = &""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_audio_tree()
	_ensure_bus(MUSIC_BUS)
	_ensure_bus(SFX_BUS)
	_ensure_bus(ENGINE_BUS)
	_ensure_bus(AMBIENCE_BUS)
	_ensure_bus(UI_BUS)
	_sync_buses()


func _exit_tree() -> void:
	# Explicitly release active WAV playbacks before the autoload tree is torn
	# down; this keeps headless/mobile process exits free of resource leaks.
	if _music_player != null:
		_music_player.stop()
		_music_player.stream = null
	if _engine_player != null:
		_engine_player.stop()
		_engine_player.stream = null
	if _ambience_player != null:
		_ambience_player.stop()
		_ambience_player.stream = null
	for player in _sfx_players:
		player.stop()
		player.stream = null
	_stream_cache.clear()


func apply_settings(settings: Dictionary) -> void:
	_policy.apply_settings(settings)
	_sync_buses()
	_apply_accessibility_state()
	settings_changed.emit(_policy.snapshot())


func get_settings_snapshot() -> Dictionary:
	return _policy.snapshot()


func set_music_volume(normalized: float) -> void:
	_policy.apply_settings({"music_volume": normalized})
	_sync_buses()
	settings_changed.emit(_policy.snapshot())


func set_master_volume(normalized: float) -> void:
	_policy.apply_settings({"master_volume": normalized})
	_sync_buses()
	settings_changed.emit(_policy.snapshot())


func set_sfx_volume(normalized: float) -> void:
	_policy.apply_settings({"sfx_volume": normalized})
	_sync_buses()
	settings_changed.emit(_policy.snapshot())


func set_music_muted(muted: bool) -> void:
	_policy.apply_settings({"music_muted": muted})
	_sync_buses()
	settings_changed.emit(_policy.snapshot())


func set_sfx_muted(muted: bool) -> void:
	_policy.apply_settings({"sfx_muted": muted})
	_sync_buses()
	settings_changed.emit(_policy.snapshot())


func set_muted(muted: bool) -> void:
	_policy.apply_settings({"muted": muted})
	_sync_buses()
	settings_changed.emit(_policy.snapshot())


func set_audio_cues_enabled(enabled: bool) -> void:
	_policy.apply_settings({"audio_cues_enabled": enabled})
	settings_changed.emit(_policy.snapshot())


func set_reduced_motion(enabled: bool) -> void:
	_policy.set_reduced_motion(enabled)
	_apply_accessibility_state()
	settings_changed.emit(_policy.snapshot())


func set_gameplay_paused(paused: bool) -> void:
	_policy.set_gameplay_paused(paused)
	_ensure_audio_tree()
	if _current_music == &"race_loop":
		_music_player.stream_paused = paused
	_engine_player.stream_paused = paused
	_ambience_player.stream_paused = paused
	if paused:
		_stop_vehicle_cues()


func play_music(cue_id: StringName, restart: bool = false) -> bool:
	if cue_id not in MUSIC_CUES:
		return _reject(cue_id, &"not_music")
	_ensure_audio_tree()
	var stream := load_stream(cue_id)
	if stream == null:
		return _reject(cue_id, &"missing_asset")
	if not is_inside_tree():
		return _reject(cue_id, &"not_in_tree")
	if _current_music == cue_id and _music_player.playing and not restart:
		return true
	_music_player.stop()
	_music_player.stream = _looping_copy(stream)
	_music_player.pitch_scale = 1.0
	_music_player.stream_paused = _policy.gameplay_paused and cue_id == &"race_loop"
	_music_player.play()
	_current_music = cue_id
	music_changed.emit(cue_id)
	return true


func stop_music() -> void:
	_ensure_audio_tree()
	_music_player.stop()
	_music_player.stream = null
	_current_music = &""
	music_changed.emit(&"")


func start_engine() -> bool:
	_ensure_audio_tree()
	var stream := load_stream(&"engine_loop")
	if stream == null or not is_inside_tree():
		return _reject(&"engine_loop", &"missing_asset")
	if _engine_player.playing:
		return true
	_engine_player.stream = _looping_copy(stream)
	_engine_player.pitch_scale = 0.68
	_engine_player.volume_db = -7.0
	_engine_player.stream_paused = _policy.gameplay_paused
	_engine_player.play()
	return true


static func engine_pitch_target(
		normalized_speed: float,
		throttle: float,
		reversing: bool = false,
		engine_rpm: float = -1.0,
		shifting: bool = false
	) -> float:
	var speed := clampf(
		normalized_speed if not is_nan(normalized_speed) and not is_inf(normalized_speed) else 0.0,
		0.0, 1.25
	)
	var pedal := clampf(
		throttle if not is_nan(throttle) and not is_inf(throttle) else 0.0, 0.0, 1.0
	)
	if reversing:
		return 0.54 + minf(speed, 1.0) * 0.42
	var has_formula_rpm := not is_nan(engine_rpm) and not is_inf(engine_rpm) and engine_rpm >= 0.0
	var target_pitch := 0.0
	if has_formula_rpm:
		var rpm_ratio := clampf((engine_rpm - 4500.0) / 8000.0, 0.0, 1.0)
		target_pitch = 0.64 + pow(rpm_ratio, 0.72) * 1.31 + pedal * 0.06
		if shifting:
			target_pitch -= 0.10
	else:
		# Compatibility path for non-race callers and old playback fixtures.
		target_pitch = 0.58 + sqrt(speed / 1.25) * 1.34 + pedal * 0.10
	return clampf(target_pitch, 0.48, 2.05)


func update_engine(
		normalized_speed: float,
		throttle: float,
		reversing: bool = false,
		engine_rpm: float = -1.0,
		shifting: bool = false
	) -> void:
	_ensure_audio_tree()
	if not _engine_player.playing:
		start_engine()
	var speed := clampf(normalized_speed if not is_nan(normalized_speed) and not is_inf(normalized_speed) else 0.0, 0.0, 1.25)
	var pedal := clampf(throttle if not is_nan(throttle) and not is_inf(throttle) else 0.0, 0.0, 1.0)
	var target_pitch := engine_pitch_target(
		speed, pedal, reversing, engine_rpm, shifting
	)
	_engine_player.pitch_scale = move_toward(
		_engine_player.pitch_scale, target_pitch, 0.11 if shifting else 0.055
	)
	_engine_player.volume_db = lerpf(-8.5, -0.8, clampf(speed + pedal * 0.32, 0.0, 1.0))


func stop_engine() -> void:
	_ensure_audio_tree()
	_engine_player.stop()
	_engine_player.stream = null
	_engine_player.pitch_scale = 1.0


func play_ambience() -> bool:
	_ensure_audio_tree()
	var stream := load_stream(&"forest_ambience")
	if stream == null or not is_inside_tree():
		return _reject(&"forest_ambience", &"missing_asset")
	if _ambience_player.playing:
		return true
	_ambience_player.stream = _looping_copy(stream)
	_ambience_player.pitch_scale = 1.0
	_ambience_player.stream_paused = _policy.gameplay_paused
	_ambience_player.play()
	return true


func stop_ambience() -> void:
	_ensure_audio_tree()
	_ambience_player.stop()
	_ambience_player.stream = null


func stop_all_sfx() -> void:
	_ensure_audio_tree()
	for index in _sfx_players.size():
		_sfx_players[index].stop()
		_sfx_players[index].stream = null
		_voice_cues[index] = &""
		_voice_started_msec[index] = 0
		_voice_priorities[index] = -1
	_policy.reset_cue_gate()


func shutdown() -> void:
	stop_music()
	stop_engine()
	stop_ambience()
	stop_all_sfx()
	_stream_cache.clear()


func play_sfx(cue_id: StringName) -> bool:
	if cue_id in MUSIC_CUES:
		return _reject(cue_id, &"not_sfx")
	if not _asset_paths.has(cue_id):
		return _reject(cue_id, &"unknown_cue")
	var rejection := _policy.request_cue(cue_id)
	if not rejection.is_empty():
		return _reject(cue_id, rejection)
	_ensure_audio_tree()
	var stream := load_stream(cue_id)
	if stream == null:
		return _reject(cue_id, &"missing_asset")
	if not is_inside_tree():
		return _reject(cue_id, &"not_in_tree")
	var priority := int(CUE_PRIORITY.get(cue_id, 1))
	var voice_index := _choose_voice(priority)
	if voice_index < 0:
		return _reject(cue_id, &"voice_pool_busy")
	var player := _sfx_players[voice_index]
	player.stop()
	player.bus = UI_BUS if cue_id in UI_CUES else SFX_BUS
	player.stream = stream
	player.pitch_scale = 1.0
	_voice_cues[voice_index] = cue_id
	_voice_started_msec[voice_index] = Time.get_ticks_msec()
	_voice_priorities[voice_index] = priority
	player.play()
	cue_played.emit(cue_id)
	return true


func load_stream(cue_id: StringName) -> AudioStream:
	if _stream_cache.has(cue_id):
		return _stream_cache[cue_id] as AudioStream
	var path := get_asset_path(cue_id)
	if path.is_empty() or not ResourceLoader.exists(path, "AudioStream"):
		return null
	var resource := ResourceLoader.load(path, "AudioStream", ResourceLoader.CACHE_MODE_REUSE)
	if resource is not AudioStream:
		return null
	_stream_cache[cue_id] = resource
	return resource as AudioStream


func has_audio_asset(cue_id: StringName) -> bool:
	var path := get_asset_path(cue_id)
	return not path.is_empty() and ResourceLoader.exists(path, "AudioStream")


func get_asset_path(cue_id: StringName) -> String:
	return str(_asset_paths.get(cue_id, ""))


func get_asset_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for cue_id: Variant in _asset_paths.keys():
		ids.append(StringName(str(cue_id)))
	ids.sort()
	return ids


func set_asset_path(cue_id: StringName, path: String) -> void:
	_asset_paths[cue_id] = path
	_stream_cache.erase(cue_id)


func reset_asset_paths() -> void:
	_asset_paths = DEFAULT_ASSET_PATHS.duplicate()
	_stream_cache.clear()


func _ensure_audio_tree() -> void:
	if _music_player == null:
		_music_player = AudioStreamPlayer.new()
		_music_player.name = "MusicPlayer"
		_music_player.bus = MUSIC_BUS
		_music_player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_music_player)
	if _engine_player == null:
		_engine_player = AudioStreamPlayer.new()
		_engine_player.name = "EnginePlayer"
		_engine_player.bus = ENGINE_BUS
		_engine_player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_engine_player)
	if _ambience_player == null:
		_ambience_player = AudioStreamPlayer.new()
		_ambience_player.name = "AmbiencePlayer"
		_ambience_player.bus = AMBIENCE_BUS
		_ambience_player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_ambience_player)
	if _sfx_players.is_empty():
		for index in SFX_VOICE_COUNT:
			var player := AudioStreamPlayer.new()
			player.name = "SFXVoice%d" % (index + 1)
			player.bus = SFX_BUS
			player.process_mode = Node.PROCESS_MODE_ALWAYS
			add_child(player)
			_sfx_players.append(player)
			_voice_cues.append(&"")
			_voice_started_msec.append(0)
			_voice_priorities.append(-1)


func _ensure_bus(bus_name: StringName) -> int:
	var index := AudioServer.get_bus_index(bus_name)
	if index >= 0:
		return index
	AudioServer.add_bus()
	index = AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, &"Master")
	return index


func _sync_buses() -> void:
	var master_bus := _ensure_bus(MASTER_BUS)
	var music_bus := _ensure_bus(MUSIC_BUS)
	var sfx_bus := _ensure_bus(SFX_BUS)
	var engine_bus := _ensure_bus(ENGINE_BUS)
	var ambience_bus := _ensure_bus(AMBIENCE_BUS)
	var ui_bus := _ensure_bus(UI_BUS)
	AudioServer.set_bus_volume_db(master_bus, AudioPolicy.normalized_to_db(_policy.master_volume))
	AudioServer.set_bus_volume_db(music_bus, AudioPolicy.normalized_to_db(_policy.music_volume))
	AudioServer.set_bus_volume_db(sfx_bus, AudioPolicy.normalized_to_db(_policy.sfx_volume))
	AudioServer.set_bus_volume_db(engine_bus, AudioPolicy.normalized_to_db(_policy.engine_volume))
	AudioServer.set_bus_volume_db(ambience_bus, AudioPolicy.normalized_to_db(_policy.ambience_volume))
	AudioServer.set_bus_volume_db(ui_bus, AudioPolicy.normalized_to_db(_policy.ui_volume))
	AudioServer.set_bus_mute(master_bus, _policy.muted)
	AudioServer.set_bus_mute(music_bus, _policy.music_muted)
	AudioServer.set_bus_mute(sfx_bus, _policy.sfx_muted)
	AudioServer.set_bus_mute(engine_bus, false)
	AudioServer.set_bus_mute(ambience_bus, false)
	AudioServer.set_bus_mute(ui_bus, false)


func _apply_accessibility_state() -> void:
	# Reduced-motion users get stable playback: no pitch modulation or tweened
	# transitions are required to understand a cue.
	_ensure_audio_tree()
	_music_player.pitch_scale = 1.0
	if _ambience_player != null:
		_ambience_player.pitch_scale = 1.0
	for player in _sfx_players:
		player.pitch_scale = 1.0


func _looping_copy(stream: AudioStream) -> AudioStream:
	var copy := stream.duplicate() as AudioStream
	if copy is AudioStreamWAV:
		var wav := copy as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = maxi(1, int(round(wav.get_length() * float(wav.mix_rate))))
	return copy


func _choose_voice(priority: int) -> int:
	for index in _sfx_players.size():
		if not _sfx_players[index].playing:
			return index
	var candidate := -1
	var candidate_priority := priority
	var oldest_msec := Time.get_ticks_msec()
	for index in _sfx_players.size():
		if _voice_priorities[index] <= candidate_priority and _voice_started_msec[index] <= oldest_msec:
			candidate = index
			candidate_priority = _voice_priorities[index]
			oldest_msec = _voice_started_msec[index]
	return candidate


func _stop_vehicle_cues() -> void:
	for index in _sfx_players.size():
		if _voice_cues[index] in VEHICLE_CUES:
			_sfx_players[index].stop()
			_voice_cues[index] = &""
			_voice_priorities[index] = -1


func _reject(cue_id: StringName, reason: StringName) -> bool:
	cue_rejected.emit(cue_id, reason)
	return false
