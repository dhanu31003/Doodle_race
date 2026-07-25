extends Control
## Dedicated private-room race presentation. Simulation remains deterministic
## 2D authority, while driving is shown only through cockpit or chase cameras.

signal navigate_requested(route: String, payload: Dictionary)

const RuntimeType := preload("res://game/network/client/network_race_runtime.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const DefinitionType := preload("res://game/track/definition/track_definition.gd")
const InputAdapterType := preload("res://game/ui/input/race_input_adapter.gd")
const RaceWorldType := preload("res://game/presentation3d/race_world_3d.gd")
const MinimapType := preload("res://game/ui/components/race_minimap.gd")
const TelemetryClusterType := preload("res://game/ui/components/race_telemetry_cluster.gd")
const StandingsPanelType := preload("res://game/ui/components/race_standings_panel.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const VehicleCatalogType := preload("res://game/content/vehicle_catalog.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")

var payload: Dictionary = {}
var session: PrivateMultiplayerSession
var runtime: NetworkRaceRuntime
var settings: GameSettings
var input_adapter: RaceInputAdapter
var perspective: RaceWorld3D
var minimap: RaceMinimap
var _fixture_mode := false
var _scheduled_start_tick := 0
var _started := false
var _terminal_shown := false
var _touch_left := false
var _touch_right := false
var _wheel_touch_index := -1
var _track_id := ""
var _result_recorded := false
var _selected_vehicle: Dictionary = {}
var _last_wall_contacts := 0
var _last_completed_laps := 0
var _last_recovery_serial := 0
var _recovery_cue_remaining := 0.0
var _recovery_tween: Tween

var _room_label: Label
var _role_label: Label
var _telemetry_cluster: RaceTelemetryCluster
var _standings_panel: RaceStandingsPanel
var _sync_label: Label
var _countdown_label: Label
var _camera_button: Button
var _connection_panel: PanelContainer
var _connection_label: Label
var _terminal_panel: PanelContainer
var _terminal_title: Label
var _terminal_detail: Label
var _terminal_results: VBoxContainer
var _terminal_history_status: Label
var _rematch_button: Button
var _leave_panel: PanelContainer
var _recovery_label: Label


static func touch_control_lift_px(value: Variant) -> float:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return 0.0
	if is_nan(float(value)) or is_inf(float(value)):
		return 0.0
	return clampf(float(value), 0.0, 1.0) * 96.0


static func sector_hud_text(sector: int, elapsed_seconds: float, authoritative: bool) -> String:
	var safe_sector := clampi(sector, 1, 3)
	var safe_elapsed := 0.0 if is_nan(elapsed_seconds) or is_inf(elapsed_seconds) else maxf(0.0, elapsed_seconds)
	var total_ms := maxi(0, roundi(safe_elapsed * 1000.0))
	var minutes := total_ms / 60000
	var seconds := (total_ms / 1000) % 60
	var millis := total_ms % 1000
	return "S%d  %02d:%02d.%03d%s" % [
		safe_sector, minutes, seconds, millis, "" if authoritative else "  LOCAL",
	]


func set_payload(value: Dictionary) -> void:
	payload = value.duplicate(true)


func _ready() -> void:
	session = get_node_or_null("/root/NetworkSession")
	var services := _services()
	settings = services.call("settings") if services != null else GameSettings.new()
	input_adapter = InputAdapterType.new()
	_fixture_mode = bool(payload.get("visual_fixture", false)) or payload.is_empty()
	if _fixture_mode and not payload.has("track_definition_json"):
		var fixture_options := payload.duplicate(true)
		payload = _fixture_payload()
		payload.merge(fixture_options, true)
	if payload.has("camera_view"):
		settings.camera_view = GameSettings.CAMERA_COCKPIT \
			if str(payload["camera_view"]) == "cockpit" else GameSettings.CAMERA_CHASE
	_build()
	_configure_runtime()
	_connect_session()
	set_process(true)
	set_process_unhandled_input(true)


func _exit_tree() -> void:
	set_process(false)
	set_process_unhandled_input(false)
	_disconnect_session()
	if perspective != null:
		perspective.clear_race_authority()
	if minimap != null:
		minimap.clear_race_authority()
	if runtime != null and runtime.director != null:
		for entry in runtime.director.entries:
			entry.controller = null
		runtime.director.entries.clear()
	runtime = null
	input_adapter = null


func _process(delta: float) -> void:
	if runtime == null or runtime.local_entry == null:
		return
	_update_connection_surface()
	if not _fixture_mode and session != null \
			and str(session.public_snapshot().get("connection", "offline")) != "online":
		if runtime != null:
			runtime.set_suspended(true)
		return
	if not _started:
		var estimated_tick := _scheduled_start_tick if _fixture_mode or session == null else session.estimated_server_tick()
		var remaining_ticks := maxi(0, _scheduled_start_tick - estimated_tick)
		_countdown_label.text = "GO" if remaining_ticks == 0 else str(maxi(1, ceili(float(remaining_ticks) / 60.0)))
		if _fixture_mode or remaining_ticks <= 0:
			_begin_runtime(_scheduled_start_tick)
		else:
			return
	var command := input_adapter.sample(settings, _assist_context())
	command.nitro = false
	runtime.advance_frame(delta, command)
	_update_feedback(delta)
	perspective.update_race(runtime.local_entry, runtime.entries, command, runtime.presentation_alpha())
	minimap.update_entries(runtime.entries)
	_update_hud()
	var audio := get_node_or_null("/root/Audio")
	if audio != null:
		audio.call(
			"update_engine",
			clampf(runtime.local_entry.state.speed() / 100.0, 0.0, 1.0),
			command.throttle,
			runtime.local_entry.state.forward_speed() < -0.2,
			runtime.local_entry.state.engine_rpm,
			runtime.local_entry.state.shift_ticks_remaining > 0
		)
	if runtime.finished and not _terminal_shown:
		_show_terminal(runtime.terminal_reason)


func _build() -> void:
	perspective = RaceWorldType.new()
	perspective.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(perspective)
	var safe := DesignSystem.make_margin(26, 22, 26, 24)
	safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)
	var hud := VBoxContainer.new()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	safe.add_child(hud)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_PASS
	top.add_theme_constant_override("separation", 10)
	hud.add_child(top)
	var network_card := PanelContainer.new()
	network_card.add_theme_stylebox_override("panel", _hud_style(Color(0.025, 0.05, 0.09, 0.91), DesignSystem.MINT))
	top.add_child(network_card)
	var network_row := HBoxContainer.new()
	network_row.add_theme_constant_override("separation", 12)
	network_card.add_child(network_row)
	_room_label = DesignSystem.label("ROOM ------", 14, DesignSystem.WHITE)
	network_row.add_child(_room_label)
	_role_label = DesignSystem.label("HOST AUTHORITY", 12, DesignSystem.MINT)
	network_row.add_child(_role_label)
	_sync_label = DesignSystem.label("SYNC", 12, DesignSystem.CYAN)
	network_row.add_child(_sync_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)
	_camera_button = DesignSystem.screen_button(_camera_text())
	_camera_button.custom_minimum_size.x = 132.0
	_camera_button.pressed.connect(_toggle_camera)
	top.add_child(_camera_button)
	var leave := DesignSystem.screen_button("LEAVE")
	leave.custom_minimum_size.x = 104.0
	leave.add_theme_color_override("font_color", DesignSystem.CORAL)
	leave.pressed.connect(_arm_leave)
	top.add_child(leave)
	var race_line := HBoxContainer.new()
	race_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(race_line)
	_standings_panel = StandingsPanelType.new()
	_standings_panel.name = "LiveStandings"
	_standings_panel.configure_accessibility(settings.reduced_motion, settings.high_contrast)
	race_line.add_child(_standings_panel)
	var race_spacer := Control.new()
	race_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	race_line.add_child(race_spacer)
	var map_panel := PanelContainer.new()
	map_panel.name = "MinimapOverlay"
	map_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_panel.add_theme_stylebox_override("panel", _hud_style(Color(0.025, 0.05, 0.09, 0.91), Color(1.0, 1.0, 1.0, 0.12)))
	map_panel.anchor_left = 1.0
	map_panel.anchor_right = 1.0
	map_panel.offset_left = -202.0
	map_panel.offset_top = 126.0
	map_panel.offset_right = -26.0
	map_panel.offset_bottom = 222.0
	add_child(map_panel)
	minimap = MinimapType.new()
	map_panel.add_child(minimap)
	var grow := Control.new()
	grow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hud.add_child(grow)
	var bottom := HBoxContainer.new()
	bottom.mouse_filter = Control.MOUSE_FILTER_PASS
	bottom.add_theme_constant_override("separation", 12)
	hud.add_child(bottom)
	var steering := _steering_controls()
	var pedals := _pedal_controls()
	if settings.left_handed_controls:
		bottom.add_child(pedals)
	else:
		bottom.add_child(steering)
	var control_spacer := Control.new()
	control_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(control_spacer)
	if settings.left_handed_controls:
		bottom.add_child(steering)
	else:
		bottom.add_child(pedals)
	var reach_offset := Control.new()
	reach_offset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reach_offset.custom_minimum_size.y = touch_control_lift_px(settings.touch_control_vertical_offset)
	hud.add_child(reach_offset)
	_build_telemetry_overlay()
	_countdown_label = DesignSystem.title("3", 106)
	_countdown_label.set_anchors_preset(Control.PRESET_CENTER)
	_countdown_label.position = Vector2(-78.0, -92.0)
	_countdown_label.custom_minimum_size = Vector2(156.0, 184.0)
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_countdown_label)
	_recovery_label = DesignSystem.label("↺  RECOVERED TO CIRCUIT", 18, DesignSystem.CYAN)
	_recovery_label.visible = false
	_recovery_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_recovery_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recovery_label.add_theme_constant_override("outline_size", 7)
	_recovery_label.add_theme_color_override("font_outline_color", DesignSystem.INK)
	_recovery_label.anchor_left = 0.5
	_recovery_label.anchor_right = 0.5
	_recovery_label.offset_left = -190.0
	_recovery_label.offset_right = 190.0
	_recovery_label.offset_top = 106.0
	_recovery_label.offset_bottom = 150.0
	add_child(_recovery_label)
	_build_connection_panel()
	_build_leave_panel()
	_build_terminal_panel()


func _build_telemetry_overlay() -> void:
	var controls_height := 82.0 * settings.touch_control_size
	var bottom_clearance := 24.0 + controls_height + 20.0 \
		+ touch_control_lift_px(settings.touch_control_vertical_offset)
	var telemetry_safe := DesignSystem.make_margin(26, 22, 26, roundi(bottom_clearance))
	telemetry_safe.name = "TelemetrySafeArea"
	telemetry_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry_safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(telemetry_safe)
	var anchor := Control.new()
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry_safe.add_child(anchor)
	_telemetry_cluster = TelemetryClusterType.new()
	_telemetry_cluster.name = "RaceTelemetry"
	_telemetry_cluster.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_telemetry_cluster.offset_left = -TelemetryClusterType.BASE_SIZE.x
	_telemetry_cluster.offset_top = -TelemetryClusterType.BASE_SIZE.y
	_telemetry_cluster.configure_accessibility(settings.reduced_motion, settings.high_contrast)
	anchor.add_child(_telemetry_cluster)


func _configure_runtime() -> void:
	var definition := DefinitionType.from_json(str(payload.get("track_definition_json", "")))
	var compiled: TrackCompileResult = CompilerType.compile(definition)
	if not compiled.succeeded() or compiled.track == null \
			or (not str(payload.get("source_hash", "")).is_empty() and str(payload["source_hash"]) != compiled.track.source_hash) \
			or (not str(payload.get("compiled_hash", "")).is_empty() and str(payload["compiled_hash"]) != compiled.track.compile_hash):
		_show_terminal("track_verification_failed")
		return
	_track_id = compiled.track.track_id
	runtime = RuntimeType.new()
	var countdown: Dictionary = payload.get("countdown", {})
	_scheduled_start_tick = int(countdown.get("start_tick", 0))
	var result := runtime.configure(
		compiled.track,
		payload.get("roster", []),
		str(payload.get("local_player_id", "")),
		str(payload.get("host_id", "")),
		str(payload.get("room_code", "")),
		int(payload.get("room_epoch", 0)),
		_scheduled_start_tick,
		null if _fixture_mode else session,
		int(payload.get("laps", 3)),
		bool(payload.get("collisions", true))
	)
	if not result.get("ok", false):
		_show_terminal(str(result.get("error", {}).get("code", "network_race_configuration_invalid")))
		return
	runtime.terminal.connect(_show_terminal)
	_selected_vehicle = _selected_cosmetic_vehicle(payload.get("roster", []), str(payload.get("local_player_id", "")))
	perspective.configure(runtime.track, settings.camera_view, _selected_vehicle.get("accent", DesignSystem.MINT))
	perspective.configure_entry_colors(_entry_cosmetic_colors(payload.get("roster", [])))
	_refresh_camera_button()
	perspective.configure_accessibility(
		settings.low_graphics, settings.reduced_motion, settings.high_contrast,
		SettingsRuntime.screen_shake_strength(settings)
	)
	minimap.configure(runtime.track, StringName(str(payload.get("local_player_id", ""))))
	minimap.configure_accessibility(SettingsRuntime.requires_non_color_cues(settings))
	minimap.update_entries(runtime.entries)
	_room_label.text = "ROOM %s" % str(payload.get("room_code", "------"))
	_role_label.text = "HOST AUTHORITY" if runtime.is_host else "GUEST PREDICTION"
	_role_label.add_theme_color_override("font_color", DesignSystem.MINT if runtime.is_host else DesignSystem.CYAN)


func _begin_runtime(tick: int) -> void:
	if _started or runtime == null:
		return
	_started = runtime.begin(tick)
	if not _started:
		return
	_last_wall_contacts = runtime.local_entry.state.wall_contacts
	_last_completed_laps = runtime.local_entry.lap_tracker.laps_completed if runtime.local_entry.lap_tracker != null else 0
	_last_recovery_serial = runtime.local_entry.state.recovery_hard_snap_serial
	_emit_haptic(&"start")
	_countdown_label.text = "GO"
	if settings.reduced_motion:
		_countdown_label.modulate.a = 0.0
		_countdown_label.visible = false
	else:
		var tween := create_tween()
		tween.tween_property(_countdown_label, "modulate:a", 0.0, 0.65)
		tween.tween_callback(func() -> void: _countdown_label.visible = false)


static func haptic_pattern(cue: StringName) -> Dictionary:
	match cue:
		&"start":
			return {"duration_ms": 70, "amplitude": 0.38}
		&"contact":
			return {"duration_ms": 70, "amplitude": 0.45}
		&"lap":
			return {"duration_ms": 90, "amplitude": 0.48}
		&"recovery":
			return {"duration_ms": 110, "amplitude": 0.52}
		&"finish":
			return {"duration_ms": 140, "amplitude": 0.65}
	return {}


func _update_feedback(delta: float) -> void:
	if _recovery_cue_remaining > 0.0:
		_recovery_cue_remaining = maxf(0.0, _recovery_cue_remaining - delta)
		if _recovery_cue_remaining <= 0.0 and settings.reduced_motion and _recovery_label != null:
			_recovery_label.visible = false
	if runtime == null or runtime.local_entry == null:
		return
	var entry := runtime.local_entry
	var state := entry.state
	var laps := entry.lap_tracker.laps_completed if entry.lap_tracker != null else 0
	var recovered := state.recovery_hard_snap_serial != _last_recovery_serial
	if recovered:
		_show_recovery_cue()
		_emit_haptic(&"recovery")
	elif laps > _last_completed_laps:
		_emit_haptic(&"lap")
	elif state.wall_contacts > _last_wall_contacts:
		_emit_haptic(&"contact")
	_last_recovery_serial = state.recovery_hard_snap_serial
	_last_completed_laps = laps
	_last_wall_contacts = state.wall_contacts


func _show_recovery_cue() -> void:
	if _recovery_label == null:
		return
	if _recovery_tween != null and _recovery_tween.is_valid():
		_recovery_tween.kill()
	_recovery_label.visible = true
	_recovery_label.modulate.a = 1.0
	_recovery_cue_remaining = 1.25
	if settings.reduced_motion:
		return
	_recovery_tween = create_tween()
	_recovery_tween.tween_interval(0.8)
	_recovery_tween.tween_property(_recovery_label, "modulate:a", 0.0, 0.35)
	_recovery_tween.tween_callback(func() -> void: _recovery_label.visible = false)


func _emit_haptic(cue: StringName) -> void:
	if _fixture_mode or not SettingsRuntime.allows_vibration(settings):
		return
	var pattern := haptic_pattern(cue)
	if pattern.is_empty():
		return
	Input.vibrate_handheld(int(pattern["duration_ms"]), float(pattern["amplitude"]))


func _update_hud() -> void:
	var entry := runtime.local_entry
	var laps := entry.lap_tracker.laps_completed if entry.lap_tracker != null else 0
	var current_lap := mini(laps + 1, runtime.director.total_laps)
	var sector_index := 1
	var sector_elapsed := 0.0
	if entry.lap_tracker != null:
		sector_index = entry.lap_tracker.current_sector_index()
		sector_elapsed = entry.lap_tracker.current_sector_elapsed(runtime.director.race_time)
	var standings := runtime.director.standings()
	if _telemetry_cluster != null:
		_telemetry_cluster.update_telemetry(
			SettingsRuntime.speed_to_kmh(entry.state.speed()),
			entry.state.gear,
			entry.state.engine_rpm,
			entry.vehicle_model.config.redline_rpm,
			entry.state.shift_ticks_remaining > 0,
			current_lap,
			runtime.director.total_laps,
			sector_index,
			runtime.director.race_time,
			sector_elapsed,
			entry.state.is_offtrack
		)
	if _standings_panel != null:
		_standings_panel.update_standings(
			standings, entry.participant_id, runtime.track.total_length,
			current_lap, runtime.director.total_laps, runtime.director.race_time,
			runtime.director.fixed_tick
		)
	if runtime.is_host:
		_sync_label.text = "60 HZ AUTH • 12 HZ SNAP"
		_sync_label.add_theme_color_override("font_color", DesignSystem.MINT)
	else:
		var correction := runtime.last_reconcile_error_q
		_sync_label.text = "RECONCILED • Δ %.2f m" % (Vector2(correction).length() / 10_000.0)
		_sync_label.add_theme_color_override("font_color", DesignSystem.GOLD if runtime.last_hard_reconcile else DesignSystem.CYAN)


func _assist_context() -> Dictionary:
	if runtime == null or runtime.local_entry == null:
		return {}
	var state := runtime.local_entry.state
	var sample := runtime.track.sample_at_distance(state.track_distance)
	var heading_error := wrapf(float(sample.get("tangent", state.forward()).angle()) - state.heading, -PI, PI)
	return {
		"track_half_width": runtime.track.track_width * 0.5,
		"lateral_offset": state.lateral_offset,
		"heading_error": heading_error,
		"upcoming_radius": runtime.track.upcoming_minimum_radius(state.track_distance, 120.0),
		"speed": state.speed(),
		"maximum_speed": runtime.local_entry.vehicle_model.config.maximum_forward_speed,
	}


func _steering_controls() -> Control:
	var surface := steering_surface_for_scheme(settings.touch_control_scheme)
	if surface == &"tilt":
		var tilt_panel := PanelContainer.new()
		tilt_panel.custom_minimum_size = Vector2(208.0, 70.0) * settings.touch_control_size
		tilt_panel.modulate.a = settings.touch_control_opacity
		tilt_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.035, 0.075, 0.13, 0.90), 18, DesignSystem.CYAN, 1))
		var tilt_label := DesignSystem.label("TILT STEERING\nCALIBRATED", 14, DesignSystem.CYAN)
		tilt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tilt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tilt_panel.add_child(tilt_label)
		return tilt_panel
	if surface == &"wheel":
		var wheel := PanelContainer.new()
		wheel.custom_minimum_size = Vector2(224.0, 82.0) * settings.touch_control_size
		wheel.modulate.a = settings.touch_control_opacity
		wheel.mouse_filter = Control.MOUSE_FILTER_STOP
		wheel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.035, 0.075, 0.13, 0.94), 22, DesignSystem.MINT, 2))
		var label := DesignSystem.label("◀  STEERING WHEEL  ▶\nDRAG TO TURN", 14, DesignSystem.WHITE)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		wheel.add_child(label)
		wheel.gui_input.connect(func(event: InputEvent) -> void: _on_wheel_input(event, wheel))
		return wheel
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_add_hold_button(row, "◀", func(value: bool) -> void:
		_touch_left = value
		_update_touch_steer()
	)
	_add_hold_button(row, "▶", func(value: bool) -> void:
		_touch_right = value
		_update_touch_steer()
	)
	return row


static func steering_surface_for_scheme(scheme: StringName) -> StringName:
	if scheme == GameSettings.CONTROL_TILT:
		return &"tilt"
	if scheme == GameSettings.CONTROL_WHEEL:
		return &"wheel"
	return &"buttons"


func _pedal_controls() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_add_hold_button(row, "GAS", func(value: bool) -> void: input_adapter.touch_throttle = 1.0 if value else 0.0, true, Vector2(132.0, 76.0))
	_add_hold_button(row, "BRAKE\nREVERSE", func(value: bool) -> void: input_adapter.touch_brake = 1.0 if value else 0.0, false, Vector2(132.0, 76.0))
	return row


func _add_hold_button(container: Container, text: String, setter: Callable, primary := false, size := Vector2(108.0, 70.0)) -> void:
	var button := DesignSystem.button(text, primary, true)
	button.custom_minimum_size = size * settings.touch_control_size
	button.modulate.a = settings.touch_control_opacity
	button.focus_mode = Control.FOCUS_NONE
	button.button_down.connect(func() -> void: setter.call(true))
	button.button_up.connect(func() -> void: setter.call(false))
	container.add_child(button)


func _update_touch_steer() -> void:
	input_adapter.touch_steer = float(int(_touch_right) - int(_touch_left))


func _on_wheel_input(event: InputEvent, wheel: Control) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and (_wheel_touch_index < 0 or _wheel_touch_index == event.index):
			_wheel_touch_index = event.index
			input_adapter.touch_steer = clampf(event.position.x / maxf(wheel.size.x, 1.0) * 2.0 - 1.0, -1.0, 1.0)
		elif not event.pressed and event.index == _wheel_touch_index:
			_wheel_touch_index = -1
			input_adapter.touch_steer = 0.0
	elif event is InputEventScreenDrag and event.index == _wheel_touch_index:
		input_adapter.touch_steer = clampf(event.position.x / maxf(wheel.size.x, 1.0) * 2.0 - 1.0, -1.0, 1.0)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		input_adapter.touch_steer = clampf(event.position.x / maxf(wheel.size.x, 1.0) * 2.0 - 1.0, -1.0, 1.0) if event.pressed else 0.0


func _toggle_camera() -> void:
	var mode := RaceWorldType.CAMERA_COCKPIT if perspective.camera_mode == RaceWorldType.CAMERA_CHASE else RaceWorldType.CAMERA_CHASE
	perspective.set_camera_mode(mode)
	settings.camera_view = mode
	var services := _services()
	if services != null:
		services.call("update_settings", settings)
	_refresh_camera_button()


func _camera_text() -> String:
	if perspective != null and perspective.camera_mode == RaceWorldType.CAMERA_COCKPIT:
		return "CHASE VIEW"
	return "COCKPIT VIEW"


func _refresh_camera_button() -> void:
	if _camera_button == null:
		return
	var current := "COCKPIT" if perspective != null and perspective.camera_mode == RaceWorldType.CAMERA_COCKPIT else "CHASE"
	var target := "CHASE" if current == "COCKPIT" else "COCKPIT"
	_camera_button.text = _camera_text()
	_camera_button.tooltip_text = "Current view: %s. Activate to switch to %s view." % [current.capitalize(), target.capitalize()]
	_camera_button.accessibility_name = "Current %s view; switch to %s view" % [current.to_lower(), target.to_lower()]


func _build_connection_panel() -> void:
	_connection_panel = PanelContainer.new()
	_connection_panel.visible = false
	_connection_panel.set_anchors_preset(Control.PRESET_CENTER)
	_connection_panel.position = Vector2(-250.0, -90.0)
	_connection_panel.custom_minimum_size = Vector2(500.0, 180.0)
	_connection_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.035, 0.075, 0.13, 0.99), 26, DesignSystem.GOLD, 2))
	add_child(_connection_panel)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 14)
	_connection_panel.add_child(content)
	content.add_child(DesignSystem.title("RECONNECTING", 32))
	_connection_label = DesignSystem.label("Private-room authority is paused on this device.", 16, DesignSystem.MUTED)
	_connection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_connection_label)
	var retry := DesignSystem.button("RETRY NOW", true, true)
	retry.pressed.connect(func() -> void:
		if session != null:
			session.reconnect_async()
	)
	content.add_child(retry)


func _update_connection_surface() -> void:
	if _fixture_mode or session == null:
		_connection_panel.visible = false
		return
	var snapshot := session.public_snapshot()
	var connection := str(snapshot.get("connection", "online"))
	_connection_panel.visible = connection == "reconnecting" or connection == "failed"
	if connection == "reconnecting":
		_connection_label.text = "%d seconds remain in the private-room resume window." % ceili(float(snapshot.get("reconnect_remaining_ms", 0)) / 1000.0)
	elif connection == "failed":
		_connection_label.text = "Resume failed. The race remains stopped on this device; retry or leave cleanly."


func _build_leave_panel() -> void:
	_leave_panel = PanelContainer.new()
	_leave_panel.visible = false
	_leave_panel.set_anchors_preset(Control.PRESET_CENTER)
	_leave_panel.position = Vector2(-245.0, -130.0)
	_leave_panel.custom_minimum_size = Vector2(490.0, 260.0)
	_leave_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.12, 0.045, 0.07, 0.99), 26, DesignSystem.CORAL, 2))
	add_child(_leave_panel)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 14)
	_leave_panel.add_child(content)
	content.add_child(DesignSystem.title("LEAVE PRIVATE RACE?", 31))
	var warning := DesignSystem.label("", 16, DesignSystem.MUTED)
	warning.name = "Warning"
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(warning)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	content.add_child(actions)
	var cancel := DesignSystem.button("STAY IN RACE", false, true)
	cancel.pressed.connect(func() -> void: _leave_panel.visible = false)
	actions.add_child(cancel)
	var confirm := DesignSystem.button("LEAVE", true, true)
	confirm.pressed.connect(_confirm_leave)
	actions.add_child(confirm)


func _arm_leave() -> void:
	if _fixture_mode:
		navigate_requested.emit("home", {})
		return
	var warning: Label = _leave_panel.find_child("Warning")
	warning.text = "You are the simulation host. Leaving ends this v1 race for every driver." if runtime != null and runtime.is_host else "You will leave the race. Other drivers may continue with the host authority."
	_leave_panel.visible = true


func _confirm_leave() -> void:
	_leave_panel.visible = false
	if session != null:
		await session.leave_async()
	navigate_requested.emit("home", {})


func _build_terminal_panel() -> void:
	_terminal_panel = PanelContainer.new()
	_terminal_panel.visible = false
	_terminal_panel.set_anchors_preset(Control.PRESET_CENTER)
	_terminal_panel.position = Vector2(-300.0, -260.0)
	_terminal_panel.custom_minimum_size = Vector2(600.0, 520.0)
	_terminal_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.035, 0.075, 0.13, 0.99), 30, DesignSystem.GOLD, 2))
	add_child(_terminal_panel)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 15)
	_terminal_panel.add_child(content)
	_terminal_title = DesignSystem.title("RACE COMPLETE", 38)
	content.add_child(_terminal_title)
	_terminal_detail = DesignSystem.label("", 17, DesignSystem.MUTED)
	_terminal_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_terminal_detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_terminal_detail)
	_terminal_history_status = DesignSystem.label("", 13, DesignSystem.CORAL)
	_terminal_history_status.visible = false
	_terminal_history_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_terminal_history_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_terminal_history_status)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520.0, 220.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_terminal_results = VBoxContainer.new()
	_terminal_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_terminal_results.add_theme_constant_override("separation", 6)
	scroll.add_child(_terminal_results)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	content.add_child(actions)
	_rematch_button = DesignSystem.button("REMATCH", false, true)
	_rematch_button.custom_minimum_size.x = 170.0
	_rematch_button.pressed.connect(_request_rematch)
	actions.add_child(_rematch_button)
	var share := DesignSystem.button("COPY RESULTS", false, true)
	share.custom_minimum_size.x = 170.0
	share.pressed.connect(_share_classification)
	actions.add_child(share)
	var exit := DesignSystem.button("LEAVE RESULTS", true, true)
	exit.custom_minimum_size.x = 170.0
	exit.pressed.connect(_confirm_leave)
	actions.add_child(exit)


func _show_terminal(reason: String) -> void:
	if _terminal_shown:
		return
	_terminal_shown = true
	if reason == "race_complete":
		_emit_haptic(&"finish")
	_terminal_panel.visible = true
	match reason:
		"race_complete":
			_terminal_title.text = "HOST RESULTS LOCKED"
			_terminal_detail.text = "The host authority completed the race. Private-room v1 ends cleanly when the host leaves these results."
		"simulation_host_departed":
			_terminal_title.text = "HOST LEFT • RACE ENDED"
			_terminal_detail.text = "RaceGlyph does not pretend to migrate a running simulation. This race ended for every driver."
		"track_verification_failed":
			_terminal_title.text = "CIRCUIT VERIFICATION FAILED"
			_terminal_detail.text = "The local circuit did not match the room fingerprint, so driving was blocked before simulation."
		_:
			_terminal_title.text = "PRIVATE RACE ENDED"
			_terminal_detail.text = "The authoritative room ended safely (%s)." % reason
	if reason == "race_complete":
		_record_authoritative_result_once()
	_render_terminal_results()
	if _rematch_button != null:
		_rematch_button.visible = reason == "race_complete"
		_rematch_button.text = "HOST: REMATCH" if runtime != null and runtime.is_host else "REQUEST REMATCH"


func _selected_cosmetic_vehicle(roster: Array = [], local_id: String = "") -> Dictionary:
	for member_value in roster:
		if not member_value is Dictionary:
			continue
		var member: Dictionary = member_value
		if str(member.get("player_id", "")) != local_id:
			continue
		var car_id := str(member.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID))
		var team_id := str(member.get("team_id", VehicleCatalogType.DEFAULT_TEAM_ID))
		if VehicleCatalogType.is_valid_pair(car_id, team_id):
			return VehicleCatalogType.by_car_id(car_id)
	var services := _services()
	var saved: Dictionary = services.call("selected_cosmetics") if services != null else {}
	return VehicleCatalogType.by_car_id(str(saved.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID)))


static func _entry_cosmetic_colors(roster: Array) -> Dictionary:
	var output := {}
	for member_value in roster:
		if not member_value is Dictionary:
			continue
		var member: Dictionary = member_value
		var player_id := str(member.get("player_id", ""))
		var car_id := str(member.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID))
		var team_id := str(member.get("team_id", VehicleCatalogType.DEFAULT_TEAM_ID))
		if not player_id.is_empty() and VehicleCatalogType.is_valid_pair(car_id, team_id):
			output[player_id] = VehicleCatalogType.by_car_id(car_id)["accent"]
	return output


static func local_history_record(
		results: Array,
		local_player_id: String,
		track_id: String,
		vehicle_id: String
	) -> Dictionary:
	for result_value in results:
		if not result_value is Dictionary:
			continue
		var result: Dictionary = result_value
		if str(result.get("player_id", result.get("participant_id", ""))) != local_player_id:
			continue
		return {
			"track_id": track_id,
			"position": int(result.get("position", 0)),
			"racer_count": results.size(),
			"total_time_ms": maxi(0, int(result.get(
				"finish_time_ms", roundi(float(result.get("finish_time", 0.0)) * 1000.0)
			))),
			"finished": str(result.get("status", "dnf")) == "finished",
			"vehicle_id": vehicle_id,
		}
	return {}


func _record_authoritative_result_once() -> void:
	var services := _services()
	if _result_recorded or _fixture_mode or runtime == null or services == null:
		return
	var record := local_history_record(
		runtime.results(), str(payload.get("local_player_id", "")), _track_id,
		str(_selected_vehicle.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID))
	)
	if record.is_empty():
		return
	var persisted: Dictionary = services.call("record_race_result", record)
	if persisted.get("ok", false):
		_result_recorded = true
		return
	if _terminal_history_status != null:
		_terminal_history_status.visible = true
		_terminal_history_status.text = history_persistence_failure_text(persisted)


static func classification_share_text(results: Array, roster: Array) -> String:
	var names := {}
	for member_value in roster:
		if member_value is Dictionary:
			var member: Dictionary = member_value
			names[str(member.get("player_id", ""))] = str(member.get("display_name", "DRIVER"))
	var ordered := results.duplicate(true)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("position", 99)) < int(b.get("position", 99))
	)
	var lines := PackedStringArray(["RACEGLYPH PRIVATE CLASSIFICATION"])
	for result_value in ordered:
		if not result_value is Dictionary:
			continue
		var result: Dictionary = result_value
		var player_id := str(result.get("player_id", result.get("participant_id", "")))
		var name := str(names.get(player_id, "DRIVER"))
		var status := str(result.get("status", "dnf")).to_upper()
		var time_ms := maxi(0, int(result.get("finish_time_ms", 0)))
		var formatted := "%02d:%02d.%03d" % [time_ms / 60000, (time_ms / 1000) % 60, time_ms % 1000]
		lines.append("P%d  %s  •  %s  •  %s" % [
			int(result.get("position", 0)), name, status, formatted,
		])
	return "\n".join(lines)


static func history_persistence_failure_text(result: Dictionary) -> String:
	if result.get("ok", false):
		return ""
	return "LOCAL HISTORY NOT SAVED • %s" % str(
		result.get("message", "Storage rejected the result. Copy Results is still available.")
	)


func _share_classification() -> void:
	if runtime == null:
		return
	var text := classification_share_text(runtime.results(), payload.get("roster", []))
	if text.get_slice_count("\n") <= 1:
		return
	DisplayServer.clipboard_set(text)
	if _terminal_history_status != null and not _terminal_history_status.visible:
		_terminal_history_status.visible = true
		_terminal_history_status.text = "CLASSIFICATION COPIED • names, positions and times only"
		_terminal_history_status.add_theme_color_override("font_color", DesignSystem.MINT)


func _request_rematch() -> void:
	if _fixture_mode:
		_rematch_button.disabled = true
		_terminal_detail.text = "REMATCH CONTROL VERIFIED IN VISUAL FIXTURE"
		return
	if session == null or _rematch_button == null:
		return
	_rematch_button.disabled = true
	var host_restart := runtime != null and runtime.is_host
	var result: Dictionary = await session.request_rematch_async()
	if not result.get("ok", false):
		_rematch_button.disabled = false
		_terminal_detail.text = str(result.get("error", {}).get("message", "Rematch request failed."))
		return
	if host_restart:
		navigate_requested.emit("multiplayer", {"return_room_code": str(payload.get("room_code", ""))})
	else:
		_rematch_button.text = "REMATCH REQUESTED"
		_terminal_detail.text = "Rematch request sent to the host. This result remains authoritative until the host restarts the room."


func _services() -> Node:
	return get_node_or_null("/root/GameServices")


func _render_terminal_results() -> void:
	if _terminal_results == null:
		return
	for child in _terminal_results.get_children():
		child.queue_free()
	if runtime == null or runtime.results().is_empty():
		_terminal_results.add_child(DesignSystem.label("No authoritative classification was published.", 14, DesignSystem.MUTED))
		return
	var results := runtime.results()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("position", 99)) < int(b.get("position", 99)))
	for result in results:
		var player_id := str(result.get("player_id", result.get("participant_id", "")))
		var panel := PanelContainer.new()
		var local := player_id == str(payload.get("local_player_id", ""))
		panel.add_theme_stylebox_override("panel", _hud_style(
			Color(0.04, 0.09, 0.15, 0.96),
			DesignSystem.MINT if local else Color(1.0, 1.0, 1.0, 0.08)
		))
		_terminal_results.add_child(panel)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		panel.add_child(row)
		row.add_child(DesignSystem.label("P%d" % int(result.get("position", 0)), 16, DesignSystem.GOLD))
		var name := _display_name_for(player_id)
		var name_label := DesignSystem.label(name + ("  •  YOU" if local else ""), 15, DesignSystem.WHITE)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var status := str(result.get("status", "dnf")).to_upper()
		row.add_child(DesignSystem.label(status, 12, DesignSystem.MINT if status == "FINISHED" else DesignSystem.CORAL))
		var time_ms := int(result.get("finish_time_ms", roundi(float(result.get("finish_time", 0.0)) * 1000.0)))
		row.add_child(DesignSystem.label(_format_time_ms(time_ms), 13, DesignSystem.MUTED))


func _display_name_for(player_id: String) -> String:
	for member in payload.get("roster", []):
		if str(member.get("player_id", "")) == player_id:
			return str(member.get("display_name", "DRIVER"))
	return "DRIVER"


func _format_time_ms(value: int) -> String:
	var safe := maxi(0, value)
	return "%02d:%02d.%03d" % [safe / 60000, (safe / 1000) % 60, safe % 1000]


func _connect_session() -> void:
	if _fixture_mode or session == null:
		return
	if not session.event_received.is_connected(_on_network_event):
		session.event_received.connect(_on_network_event)
	if not session.race_started.is_connected(_on_race_started):
		session.race_started.connect(_on_race_started)
	if not session.room_ended.is_connected(_show_terminal):
		session.room_ended.connect(_show_terminal)


func _disconnect_session() -> void:
	if session == null:
		return
	if session.event_received.is_connected(_on_network_event):
		session.event_received.disconnect(_on_network_event)
	if session.race_started.is_connected(_on_race_started):
		session.race_started.disconnect(_on_race_started)
	if session.room_ended.is_connected(_show_terminal):
		session.room_ended.disconnect(_show_terminal)


func _on_network_event(event: Dictionary) -> void:
	var event_payload: Dictionary = event.get("payload", {})
	if int(event.get("opcode", -1)) == ProtocolType.OP_RACE_EVENT and str(event_payload.get("type", "")) == "rematch_requested" \
			and runtime != null and runtime.is_host and _terminal_shown:
		_terminal_detail.text = "%s requested a rematch. Use Host: Rematch to restart the verified room." % _display_name_for(
			str(event_payload.get("player_id", ""))
		)
	if runtime != null:
		runtime.handle_event(event)


func _on_race_started(tick: int) -> void:
	_begin_runtime(tick)


func on_application_paused() -> void:
	if not _fixture_mode and session != null:
		session.on_application_paused()


func on_application_resumed() -> void:
	if not _fixture_mode and session != null:
		session.on_application_resumed()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_arm_leave()
		get_viewport().set_input_as_handled()


func _hud_style(color: Color, border: Color) -> StyleBoxFlat:
	var style := DesignSystem.panel_style(color, 16, border, 1)
	style.content_margin_left = 13.0
	style.content_margin_right = 13.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	style.shadow_size = 4
	return style


func _fixture_payload() -> Dictionary:
	var item := CatalogType.all()[0]
	var definition: TrackDefinition = item["definition"]
	var compiled: TrackCompileResult = CompilerType.compile(definition)
	var roster := [
		{"player_id": "fixture-host", "display_name": "SABARI", "car_id": "car-prime", "team_id": "team-vector", "slot": 0},
		{"player_id": "fixture-2", "display_name": "NOVA", "car_id": "car-aurora", "team_id": "team-aurora", "slot": 1},
		{"player_id": "fixture-3", "display_name": "APEX", "car_id": "car-cinder", "team_id": "team-cinder", "slot": 2},
		{"player_id": "fixture-4", "display_name": "MINT", "car_id": "car-jade", "team_id": "team-jade", "slot": 3},
	]
	return {
		"visual_fixture": true,
		"track_definition_json": definition.canonical_json(true),
		"source_hash": compiled.track.source_hash,
		"compiled_hash": compiled.track.compile_hash,
		"room_code": "R7G2PH",
		"room_epoch": 1,
		"roster": roster,
		"host_id": "fixture-host",
		"local_player_id": "fixture-host",
		"countdown": {"start_tick": 0},
		"laps": 3,
	}
