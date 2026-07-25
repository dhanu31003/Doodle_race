extends SceneTree
## Headless production-screen smoke: verified payload -> authority -> UI adapter.

const TestCaseType := preload("res://tests/support/test_case.gd")
const ConfigScreenType := preload("res://game/ui/screens/offline_race_config_screen.gd")
const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const RaceInputType := preload("res://game/race/race_input.gd")

const FIXTURE := "res://tests/fixtures/tracks/stadium_v1.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test := TestCaseType.new()
	var definition := TrackDefinitionType.from_json(FileAccess.get_file_as_string(FIXTURE))
	var compiled := TrackCompilerType.compile(definition)
	test.assert_true(compiled.succeeded(), "screen fixture must compile before UI handoff")
	if not compiled.succeeded():
		_finish(test)
		return
	var custom_payload := {
		"track_definition_json": definition.canonical_json(true),
		"source_hash": compiled.track.source_hash,
		"compiled_hash": compiled.track.compile_hash,
		"source": "saved",
		"display_name": "Integration Circuit",
		"location": "CUSTOM CREATION",
		"laps": 3,
		"difficulty": "standard",
		"grid_size": 12,
		"collisions": true,
	}
	var config_screen := ConfigScreenType.new()
	config_screen.set_payload(custom_payload)
	var config_navigation: Array[Dictionary] = []
	config_screen.navigate_requested.connect(func(route: String, route_payload: Dictionary) -> void:
		config_navigation.append({"route": route, "payload": route_payload.duplicate(true)})
	)
	root.add_child(config_screen)
	config_screen.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	test.assert_true(config_screen._start_button != null and not config_screen._start_button.disabled, "verified custom track enables the dedicated offline setup launch")
	test.assert_true(config_screen._status_label.text.ends_with("READY"), "offline setup visibly confirms track verification")
	config_screen._start_race()
	config_screen._return_to_source()
	test.assert_equal(config_navigation.size(), 2, "offline setup exposes both race launch and exact back navigation")
	if config_navigation.size() == 2:
		test.assert_equal(config_navigation[0]["route"], "race", "offline setup is the only screen that launches the configured race")
		test.assert_equal(config_navigation[0]["payload"]["track_definition_json"], custom_payload["track_definition_json"], "setup launch preserves exact custom-track bytes")
		test.assert_equal(config_navigation[1]["route"], "tour", "custom setup returns to the originating track tour")
		test.assert_equal(config_navigation[1]["payload"]["track_definition_json"], custom_payload["track_definition_json"], "setup back navigation preserves exact custom-track bytes")
	config_screen.queue_free()
	await process_frame
	config_screen = null
	var direct_screen := RaceScreenType.new()
	direct_screen.set_payload({"visual_fixture": true})
	root.add_child(direct_screen)
	direct_screen.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	await process_frame
	test.assert_equal(direct_screen.track_load_error, "", "direct race route compiles its catalog fallback")
	test.assert_true(direct_screen.compiled_track != null, "direct race route resolves a canonical compiled circuit")
	if direct_screen.compiled_track != null:
		test.assert_equal(direct_screen.compiled_track.track_id, "builtin-evergreen-oval", "direct race route uses the enlarged Evergreen catalog circuit")
		test.assert_true(direct_screen.compiled_track.track_width >= 48.0, "direct race route no longer uses the narrow prototype road")
		test.assert_true(direct_screen.compiled_track.total_length >= 3900.0, "direct race route no longer finishes laps on the short prototype loop")
	direct_screen.queue_free()
	await process_frame
	direct_screen = null
	var screen := RaceScreenType.new()
	screen.set_payload({
		"track_definition_json": definition.canonical_json(true),
		"source_hash": compiled.track.source_hash,
		"compiled_hash": compiled.track.compile_hash,
		"source": "integration",
		"laps": 5,
		"difficulty": "expert",
		"grid_size": 6,
		"collisions": false,
	})
	root.add_child(screen)
	screen.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	await process_frame
	test.assert_equal(screen.track_load_error, "", "verified payload opens without a race block")
	test.assert_true(screen.compiled_track != null, "screen retains canonical CompiledTrack authority")
	if screen.compiled_track != null:
		test.assert_equal(screen.compiled_track.compile_hash, compiled.track.compile_hash, "screen races the verified compile hash")
	test.assert_true(screen.race_query != null and screen.race_query.is_valid(), "screen constructs the shared race projection")
	test.assert_true(screen.director != null, "screen creates a fixed-step RaceDirector")
	test.assert_equal(screen.total_laps, 5, "five-lap selector payload reaches the race screen")
	test.assert_equal(screen.racer_count, 6, "six-driver setup payload reaches offline race authority")
	test.assert_near(screen.ai_difficulty, RaceScreenType.mapped_ai_difficulty("expert"), 0.0001, "expert selector payload maps to race AI difficulty")
	test.assert_false(screen.vehicle_collisions_enabled, "disabled collision selector reaches race options")
	test.assert_near(RaceScreenType.mapped_ai_difficulty("relaxed"), 0.58, 0.0001, "relaxed difficulty has a stable race mapping")
	test.assert_near(RaceScreenType.mapped_ai_difficulty("standard"), 0.78, 0.0001, "standard difficulty has a stable race mapping")
	test.assert_near(RaceScreenType.mapped_ai_difficulty("expert"), 0.94, 0.0001, "expert difficulty has a stable race mapping")
	test.assert_false(_control_tree_contains(screen, "BOOST"), "race UI exposes no boost control or telemetry")
	var telemetry_snapshot: Dictionary = screen.telemetry_cluster.debug_snapshot() if screen.telemetry_cluster != null else {}
	var standings_snapshot: Dictionary = screen.standings_panel.debug_snapshot() if screen.standings_panel != null else {}
	test.assert_equal(int(telemetry_snapshot.get("sector", 0)), 1, "offline instrument exposes the current authoritative sector")
	test.assert_equal(str(telemetry_snapshot.get("gear", "")), "1", "offline instrument exposes authoritative gear")
	test.assert_true(int(telemetry_snapshot.get("rpm", 0)) >= 4500, "offline instrument exposes authoritative engine RPM")
	test.assert_equal(int(standings_snapshot.get("row_count", 0)), 6, "live standings contain every configured authoritative entrant")
	test.assert_equal(int(standings_snapshot.get("player_position", 0)), 1, "live standings clearly identify the player's initial grid rank")
	var gas_button := _find_button(screen, "GAS")
	var brake_button := _find_button(screen, "BRAKE\nREVERSE")
	var left_button := _find_button(screen, "◀")
	var right_button := _find_button(screen, "▶")
	test.assert_true(gas_button != null and brake_button != null, "mobile accelerator and conventional brake/reverse pedals are present")
	test.assert_true(left_button != null and right_button != null, "mobile left/right steering controls are present")
	if gas_button != null:
		gas_button.button_down.emit()
		test.assert_equal(screen.input_adapter.touch_throttle, 1.0, "holding GAS reaches the sampled touch throttle")
		gas_button.button_up.emit()
		test.assert_equal(screen.input_adapter.touch_throttle, 0.0, "releasing GAS clears touch throttle")
	if brake_button != null:
		brake_button.button_down.emit()
		test.assert_equal(screen.input_adapter.touch_brake, 1.0, "holding BRAKE/REVERSE reaches the sampled touch brake")
		brake_button.button_up.emit()
		test.assert_equal(screen.input_adapter.touch_brake, 0.0, "releasing BRAKE/REVERSE clears touch brake")
	if left_button != null and right_button != null:
		left_button.button_down.emit()
		test.assert_equal(screen.input_adapter.touch_steer, -1.0, "holding left produces full normalized left steering")
		left_button.button_up.emit()
		right_button.button_down.emit()
		test.assert_equal(screen.input_adapter.touch_steer, 1.0, "holding right produces full normalized right steering")
		right_button.button_up.emit()
		test.assert_equal(screen.input_adapter.touch_steer, 0.0, "releasing steering returns the touch axis to center")
	if screen.director != null:
		test.assert_equal(screen.director.entries.size(), 6, "configured grid launches one player and five AI")
		test.assert_equal(screen.director.total_laps, 5, "RaceDirector and lap trackers use the selected five laps")
		test.assert_false(screen.director.vehicle_collisions_enabled, "RaceDirector honors disabled car-to-car collisions")
		test.assert_equal(screen.racers.size(), 6, "every configured authoritative entry reaches perspective presentation metadata")
		test.assert_true(screen.minimap != null, "authoritative minimap is present")
		test.assert_true(screen.perspective_view != null, "race uses the dedicated true 3D world renderer")
		var player = screen.director.entry(&"player")
		test.assert_true(player != null and player.previous_state != null, "player exposes interpolation state")
		screen.director.countdown_remaining = 0.0
		screen.director.tick_fixed()
		test.assert_equal(screen.director.phase, screen.director.PHASE_RACING, "countdown transitions to authoritative racing")
		var time_before_pause := screen.director.race_time
		screen.on_application_paused()
		screen.director.tick_fixed({&"player": RaceInputType.new(0.0, 1.0, 0.0)})
		test.assert_equal(screen.director.race_time, time_before_pause, "application pause freezes race time")
		test.assert_true(screen.paused and screen.pause_panel.visible, "application pause opens explicit resume UI")
		screen.on_application_resumed()
		test.assert_true(screen.paused, "application resume never resumes driving implicitly")
		screen._toggle_pause()
		screen.director.tick_fixed({&"player": RaceInputType.new(0.0, 1.0, 0.0)})
		test.assert_true(screen.director.race_time > time_before_pause, "explicit resume restores fixed ticks")
		screen._render_authority(0.5)
		test.assert_true(screen.perspective_view.has_race_authority(), "3D world consumes interpolated RaceDirector state")
		var world_snapshot: Dictionary = screen.perspective_view.debug_snapshot()
		test.assert_true(bool(world_snapshot.get("fixed_world_invariant", false)), "track and scenery remain fixed while vehicles move through world space")
		test.assert_equal(int(world_snapshot.get("vehicle_count", 0)), 6, "true 3D renderer instantiates the configured Formula grid")
		var original_camera: StringName = screen.perspective_view.camera_mode
		screen._toggle_camera(false)
		test.assert_true(screen.perspective_view.camera_mode != original_camera, "camera toggle switches between cockpit and chase")
		screen._toggle_camera(false)
		test.assert_equal(screen.perspective_view.camera_mode, original_camera, "camera toggle returns to the original persisted view")
		if not screen.selected_vehicle.is_empty():
			test.assert_true(str(screen.selected_vehicle.get("car_id", "")).begins_with("car-"), "garage-selected vehicle identity reaches the grid")
	screen.queue_free()
	await process_frame
	screen = null

	var endurance := RaceScreenType.new()
	endurance.set_payload({
		"track_definition_json": definition.canonical_json(true),
		"source_hash": compiled.track.source_hash,
		"compiled_hash": compiled.track.compile_hash,
		"source": "integration",
		"laps": 8,
		"difficulty": "relaxed",
		"grid_size": 2,
		"collisions": true,
	})
	root.add_child(endurance)
	endurance.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	await process_frame
	test.assert_equal(endurance.track_load_error, "", "eight-lap selector payload opens without a race block")
	test.assert_equal(endurance.total_laps, 8, "eight-lap selector payload reaches the race screen")
	test.assert_equal(endurance.racer_count, 2, "minimum two-driver grid reaches the race screen")
	test.assert_near(endurance.ai_difficulty, RaceScreenType.mapped_ai_difficulty("relaxed"), 0.0001, "relaxed selector payload maps to race AI difficulty")
	if endurance.director != null:
		test.assert_equal(endurance.director.entries.size(), 2, "minimum grid launches one player and one AI")
		test.assert_equal(endurance.director.total_laps, 8, "RaceDirector and lap trackers use the selected eight laps")
		test.assert_true(endurance.director.vehicle_collisions_enabled, "RaceDirector honors enabled car-to-car collisions")
	endurance.queue_free()
	await process_frame
	endurance = null

	var blocked := RaceScreenType.new()
	blocked.set_payload({
		"track_definition_json": definition.canonical_json(true),
		"source_hash": "tampered-source",
		"compiled_hash": compiled.track.compile_hash,
	})
	root.add_child(blocked)
	blocked.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	test.assert_true(not blocked.track_load_error.is_empty(), "source-hash mismatch blocks the race")
	test.assert_true(blocked.director == null, "blocked payload never creates race authority")
	blocked.queue_free()
	await process_frame
	blocked = null
	definition = null
	compiled = null
	await process_frame
	var audio := root.get_node_or_null("Audio")
	if audio != null:
		audio.call("shutdown")
	await create_timer(0.12).timeout
	_finish(test)


func _finish(test: RefCounted) -> void:
	var result: Dictionary = test.result("race_screen_runtime_integration")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
	else:
		print("FAIL %s" % result.suite)
		for failure in result.failures:
			print("  - %s" % failure)
	call_deferred("_quit_after_cleanup", 0 if result.passed else 1)


func _quit_after_cleanup(exit_code: int) -> void:
	quit(exit_code)


func _control_tree_contains(node: Node, needle: String) -> bool:
	if node is Label and needle in node.text.to_upper():
		return true
	if node is Button and needle in node.text.to_upper():
		return true
	for child in node.get_children():
		if _control_tree_contains(child, needle):
			return true
	return false


func _find_button(node: Node, exact_text: String) -> Button:
	if node is Button and node.text == exact_text:
		return node
	for child in node.get_children():
		var match := _find_button(child, exact_text)
		if match != null:
			return match
	return null
