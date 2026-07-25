extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const AudioPolicyType := preload("res://game/audio/audio_policy.gd")
const AudioManagerType := preload("res://game/audio/audio_manager.gd")
const MANIFEST_PATH := "res://assets/final/audio/original-audio-manifest.json"


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_settings_policy(test)
	_test_rate_and_pause_policy(test)
	_test_formula_engine_pitch(test)
	_test_manifest_and_assets(test)
	_test_runtime_manager(test)
	return test.result("audio_system")


func _test_formula_engine_pitch(test: RefCounted) -> void:
	var idle := AudioManagerType.engine_pitch_target(0.0, 0.0, false, 4500.0, false)
	var power_band := AudioManagerType.engine_pitch_target(0.5, 1.0, false, 10_500.0, false)
	var redline := AudioManagerType.engine_pitch_target(0.9, 1.0, false, 12_500.0, false)
	var shifting := AudioManagerType.engine_pitch_target(0.9, 1.0, false, 9000.0, true)
	var coupled := AudioManagerType.engine_pitch_target(0.9, 1.0, false, 9000.0, false)
	test.assert_true(idle < power_band and power_band < redline, "engine pitch follows authoritative RPM through the Formula power band")
	test.assert_true(shifting < coupled, "sequential torque cut creates a bounded audible shift dip")
	test.assert_true(AudioManagerType.engine_pitch_target(1.0, 1.0, true, 12_500.0, false) < 1.0, "reverse uses a restrained single-speed engine tone")
	test.assert_true(AudioManagerType.engine_pitch_target(INF, NAN, false, INF, false) >= 0.48, "malformed engine telemetry remains inside the safe pitch range")


func _test_settings_policy(test: RefCounted) -> void:
	var policy := AudioPolicyType.new()
	policy.apply_settings({
		"music_volume": 1.8,
		"sfx_volume": -0.25,
		"engine_volume": 1.4,
		"ambience_volume": 0.33,
		"ui_volume": 0.61,
		"music_muted": true,
		"sfx_muted": "not-a-boolean",
		"audio_cues_enabled": false,
		"reduced_motion": true,
	})
	var snapshot: Dictionary = policy.snapshot()
	test.assert_near(snapshot["music_volume"], 1.0, 0.000001, "music volume must clamp high")
	test.assert_near(snapshot["sfx_volume"], 0.0, 0.000001, "SFX volume must clamp low")
	test.assert_near(snapshot["engine_volume"], 1.0, 0.000001, "engine volume must clamp high")
	test.assert_near(snapshot["ambience_volume"], 0.33, 0.000001, "ambience volume must apply")
	test.assert_near(snapshot["ui_volume"], 0.61, 0.000001, "UI volume must apply")
	test.assert_true(snapshot["music_muted"], "music mute must apply")
	test.assert_false(snapshot["sfx_muted"], "malformed booleans must keep the safe fallback")
	test.assert_false(snapshot["audio_cues_enabled"], "audio cue accessibility toggle must apply")
	test.assert_true(snapshot["reduced_motion"], "reduced-motion setting must propagate")
	policy.apply_settings({"music_volume": NAN})
	test.assert_near(policy.music_volume, 1.0, 0.000001, "non-finite volume must be ignored")
	test.assert_near(AudioPolicyType.normalized_to_db(1.0), 0.0, 0.000001, "full linear volume must be zero dB")
	test.assert_near(AudioPolicyType.normalized_to_db(0.0), -80.0, 0.000001, "zero linear volume must use silence floor")
	var nested_policy := AudioPolicyType.new()
	nested_policy.apply_settings({
		"audio": {"master": 0.8, "music": 0.6, "sfx": 0.7, "engine": 0.5, "ambience": 0.4, "ui": 0.9, "muted": true},
		"accessibility": {"reduced_motion": true},
	})
	test.assert_near(nested_policy.master_volume, 0.8, 0.000001, "nested GameSettings master volume must apply")
	test.assert_near(nested_policy.music_volume, 0.6, 0.000001, "nested GameSettings music volume must apply")
	test.assert_near(nested_policy.sfx_volume, 0.7, 0.000001, "nested GameSettings SFX volume must apply")
	test.assert_near(nested_policy.engine_volume, 0.5, 0.000001, "nested engine volume must apply")
	test.assert_near(nested_policy.ambience_volume, 0.4, 0.000001, "nested ambience volume must apply")
	test.assert_near(nested_policy.ui_volume, 0.9, 0.000001, "nested UI volume must apply")
	test.assert_true(nested_policy.muted, "nested GameSettings master mute must apply")
	test.assert_true(nested_policy.reduced_motion, "nested GameSettings accessibility must apply")


func _test_rate_and_pause_policy(test: RefCounted) -> void:
	var policy := AudioPolicyType.new()
	test.assert_equal(policy.request_cue(&"click", 1000), &"", "first click must pass")
	test.assert_equal(policy.request_cue(&"click", 1089), &"rate_limited", "click storm inside 90 ms must be limited")
	test.assert_equal(policy.request_cue(&"click", 1090), &"", "click at the boundary must pass")
	test.assert_equal(policy.request_cue(&"collision", 2000), &"", "first collision must pass")
	test.assert_equal(policy.request_cue(&"collision", 2120), &"rate_limited", "collision storms must be limited")
	policy.set_gameplay_paused(true)
	test.assert_equal(policy.request_cue(&"boost", 3000), &"gameplay_paused", "boost must not play while gameplay is paused")
	test.assert_equal(policy.request_cue(&"skid", 3000), &"gameplay_paused", "skid must not play while gameplay is paused")
	test.assert_equal(policy.request_cue(&"confirm", 3000), &"", "pause-menu UI cues must remain available")
	policy.apply_settings({"sfx_muted": true})
	test.assert_equal(policy.request_cue(&"finish", 4000), &"sfx_disabled", "muted SFX must be rejected before playback")


func _test_manifest_and_assets(test: RefCounted) -> void:
	test.assert_true(FileAccess.file_exists(MANIFEST_PATH), "audio provenance manifest must exist")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	test.assert_true(parsed is Dictionary, "audio provenance manifest must parse")
	if parsed is not Dictionary:
		return
	var manifest := parsed as Dictionary
	test.assert_equal(manifest.get("generator"), "tools/audio/generate_original_audio.py", "manifest must identify the checked-in generator")
	test.assert_true(str(manifest.get("provenance", "")).contains("no external audio"), "manifest must state original procedural provenance")
	var assets: Array = manifest.get("assets", [])
	test.assert_equal(assets.size(), 14, "all required music, engine, ambience, and SFX cues must be inventoried")
	for entry_variant: Variant in assets:
		test.assert_true(entry_variant is Dictionary, "each manifest entry must be a dictionary")
		if entry_variant is not Dictionary:
			continue
		var entry := entry_variant as Dictionary
		var path := "res://" + str(entry.get("path", ""))
		test.assert_true(FileAccess.file_exists(path), "inventoried WAV must exist: %s" % path)
		test.assert_equal(_sha256(path), str(entry.get("sha256", "")), "inventoried WAV hash must match: %s" % path)


func _test_runtime_manager(test: RefCounted) -> void:
	var manager := AudioManagerType.new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(manager)
	test.assert_true(AudioServer.get_bus_index(&"Music") >= 0, "Music bus must be available")
	test.assert_true(AudioServer.get_bus_index(&"SFX") >= 0, "SFX bus must be available")
	test.assert_true(AudioServer.get_bus_index(&"Engine") >= 0, "Engine bus must be available")
	test.assert_true(AudioServer.get_bus_index(&"Ambience") >= 0, "Ambience bus must be available")
	test.assert_true(AudioServer.get_bus_index(&"UI") >= 0, "UI bus must be available")
	test.assert_equal(manager.get_asset_ids().size(), 14, "manager must expose every required cue")
	for cue_id: StringName in manager.get_asset_ids():
		test.assert_true(manager.has_audio_asset(cue_id), "manager asset must load: %s" % cue_id)
		test.assert_true(manager.load_stream(cue_id) is AudioStreamWAV, "cue must import as AudioStreamWAV: %s" % cue_id)
	manager.set_asset_path(&"missing_test", "res://assets/final/audio/does-not-exist.wav")
	test.assert_false(manager.has_audio_asset(&"missing_test"), "missing asset probe must be safe")
	test.assert_true(manager.load_stream(&"missing_test") == null, "missing stream load must return null")
	test.assert_false(manager.play_sfx(&"missing_test"), "missing SFX playback must fail safely")
	manager.reset_asset_paths()
	var looped_stream := manager.call("_looping_copy", manager.load_stream(&"menu_loop")) as AudioStreamWAV
	test.assert_true(looped_stream is AudioStreamWAV, "music must prepare as a WAV stream")
	if looped_stream is AudioStreamWAV:
		test.assert_equal(looped_stream.loop_mode, AudioStreamWAV.LOOP_FORWARD, "music must loop at runtime")
	manager.apply_settings({"music_volume": 0.5, "sfx_volume": 0.25, "music_muted": true})
	test.assert_near(
		AudioServer.get_bus_volume_db(AudioServer.get_bus_index(&"Music")),
		AudioPolicyType.normalized_to_db(0.5),
		0.0001,
		"manager must apply music bus volume"
	)
	test.assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index(&"Music")), "manager must apply music mute")
	manager.set_gameplay_paused(true)
	test.assert_false(manager.play_sfx(&"boost"), "runtime boost cue must respect gameplay pause")
	manager.set_reduced_motion(true)
	var music_player := manager.get_node("MusicPlayer") as AudioStreamPlayer
	test.assert_near(music_player.pitch_scale, 1.0, 0.000001, "reduced motion must keep stable audio pitch")
	var engine_stream := manager.call("_looping_copy", manager.load_stream(&"engine_loop")) as AudioStreamWAV
	test.assert_equal(engine_stream.loop_mode, AudioStreamWAV.LOOP_FORWARD, "engine bed must prepare as a seamless runtime loop")
	var ambience_stream := manager.call("_looping_copy", manager.load_stream(&"forest_ambience")) as AudioStreamWAV
	test.assert_equal(ambience_stream.loop_mode, AudioStreamWAV.LOOP_FORWARD, "ambience bed must prepare as a seamless runtime loop")
	manager.apply_settings({"music_volume": 0.72, "sfx_volume": 0.86, "music_muted": false, "sfx_muted": false})
	manager.shutdown()
	manager.free()


func _sha256(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	while file.get_position() < file.get_length():
		context.update(file.get_buffer(65_536))
	return context.finish().hex_encode()
