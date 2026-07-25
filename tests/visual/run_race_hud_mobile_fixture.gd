extends SceneTree
## Deterministic integrated capture: production cockpit, nearby Formula cars,
## twelve-car authority order and shipped mobile controls/HUD at 1280x720.

const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const InputType := preload("res://game/race/race_input.gd")
const SafeMarginType := preload("res://game/ui/components/safe_margin_container.gd")


func _initialize() -> void:
	call_deferred("_build_fixture")


func _build_fixture() -> void:
	var prove_safe_area := "--safe-area-proof" in OS.get_cmdline_user_args()
	var screen := RaceScreenType.new()
	screen.set_payload({"visual_fixture": true, "camera_view": "cockpit"})
	root.add_child(screen)
	screen.size = Vector2(root.size)
	for unused in 5:
		await process_frame
	if screen.director == null or screen.race_query == null:
		push_error("HUD_MOBILE_FIXTURE could not initialize race authority")
		quit(1)
		return
	screen.set_process(false)
	if screen.perspective_view.camera_mode != GameSettings.CAMERA_COCKPIT:
		screen._toggle_camera(false)
	if prove_safe_area:
		for child in screen.get_children():
			if child is SafeMarginType:
				child.call("_apply_margins", Vector4(48.0, 18.0, 48.0, 28.0))
		await process_frame
	screen.director.countdown_remaining = 0.0
	screen.director.tick_fixed()
	var base_distance := screen.race_query.total_length * 0.19
	var player_progress := screen.race_query.total_length + base_distance
	var progress_offsets := [0.0, 52.0, 35.0, 17.0, -26.0, -48.0, -72.0, -96.0, -125.0, -154.0, -188.0, -224.0]
	var physical_offsets := [0.0, 18.0, 28.0, 52.0, -35.0, -56.0, -78.0, -102.0, -126.0, -150.0, -176.0, -204.0]
	var lateral_offsets := [0.0, -6.4, 6.4, -2.0, 5.0, -5.0, 4.0, -4.0, 5.5, -5.5, 3.0, -3.0]
	for index in screen.director.entries.size():
		var entry: RaceEntry = screen.director.entries[index]
		var distance := base_distance + float(physical_offsets[index])
		var sample := screen.race_query.sample_at_distance(distance)
		var tangent := Vector2(sample.get("tangent", Vector2.RIGHT)).normalized()
		var normal := Vector2(sample.get("normal", Vector2.DOWN)).normalized()
		entry.status = RaceEntry.STATUS_RACING
		entry.state.position = Vector2(sample.get("position", Vector2.ZERO)) + normal * float(lateral_offsets[index])
		entry.state.velocity = tangent * (232.0 if index == 0 else 224.0)
		entry.state.heading = tangent.angle()
		entry.state.track_distance = fposmod(distance, screen.race_query.total_length)
		entry.state.lateral_offset = float(lateral_offsets[index])
		entry.state.track_collision_layer = int(sample.get("collision_layer", 1))
		entry.state.track_collision_mask = int(sample.get("collision_mask", entry.state.track_collision_layer))
		entry.state.track_elevation = float(sample.get("elevation_level", 0.0))
		entry.state.gear = 6 if index == 0 else 5
		entry.state.engine_rpm = 11_340.0 if index == 0 else 10_600.0
		entry.state.steering_input = 0.08
		entry.state.simulation_tick = 360
		entry.state.recovery_hard_snap_serial += 1
		entry.previous_state = entry.state.duplicate_state()
		entry.lap_tracker.laps_completed = 1
		entry.lap_tracker.last_validated_progress = player_progress + float(progress_offsets[index])
		entry.race_position = 0
	screen.director.race_time = 84.283
	screen.countdown_label.visible = false
	screen._last_player_command = InputType.new(0.08, 0.88, 0.0)
	screen._render_authority(1.0)
	screen._update_hud()
	screen.minimap.update_entries(screen.director.entries)
	await process_frame
	await process_frame
	var telemetry: Dictionary = screen.telemetry_cluster.debug_snapshot()
	var standings: Dictionary = screen.standings_panel.debug_snapshot()
	print("HUD_MOBILE_FIXTURE speed=%d gear=%s rank=%d rows=%d telemetry_nodes=%d standings_nodes=%d" % [
		int(telemetry.get("speed_kmh", 0)), str(telemetry.get("gear", "")),
		int(standings.get("player_position", 0)), int(standings.get("row_count", 0)),
		int(telemetry.get("node_count", 0)), int(standings.get("node_count", 0)),
	])
