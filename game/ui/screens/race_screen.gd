extends Control

signal navigate_requested(route: String, payload: Dictionary)

const RaceWorldType := preload("res://game/presentation3d/race_world_3d.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const RaceTrackQueryType := preload("res://game/race/track_query.gd")
const RaceDirectorType := preload("res://game/race/race_director.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const InputAdapterType := preload("res://game/ui/input/race_input_adapter.gd")
const AiRosterType := preload("res://game/ai/ai_roster.gd")
const VehicleCatalogType := preload("res://game/content/vehicle_catalog.gd")
const PredefinedTrackCatalogType := preload("res://game/content/predefined_track_catalog.gd")
const MinimapType := preload("res://game/ui/components/race_minimap.gd")
const TelemetryClusterType := preload("res://game/ui/components/race_telemetry_cluster.gd")
const StandingsPanelType := preload("res://game/ui/components/race_standings_panel.gd")

const PLAYER_ID: StringName = &"player"
const DEFAULT_TOTAL_LAPS: int = 3
const DEFAULT_RACER_COUNT: int = 12
const MIN_RACER_COUNT: int = 2
const MAX_RACER_COUNT: int = 12
const PLAYER_DISPLAY_NAME := "YOU"
const DIFFICULTY_VALUES := {
	"relaxed": 0.58,
	"standard": 0.78,
	"expert": 0.94,
}

var payload: Dictionary = {}
var perspective_view: RaceWorld3D
var compiled_track: CompiledTrack
var race_query: RaceTrackQuery
var director: RaceDirector
var racers: Dictionary = {}
var settings: GameSettings
var input_adapter: RaceInputAdapter
var selected_vehicle: Dictionary = {}

var paused := false
var finished := false
var track_load_error := ""
var last_countdown_number := 4
var last_phase: StringName = RaceDirectorType.PHASE_SETUP
var go_display_remaining := 0.0
var last_completed_laps := 0
var lap_started_at := 0.0
var best_lap_seconds := INF
var player_offtrack := false
var player_wall_contacts := 0
var last_recovery_serial := 0
var recovery_cue_remaining := 0.0
var recovery_tween: Tween
var final_position := DEFAULT_RACER_COUNT
var total_laps := DEFAULT_TOTAL_LAPS
var racer_count := DEFAULT_RACER_COUNT
var ai_difficulty := float(DIFFICULTY_VALUES["standard"])
var vehicle_collisions_enabled := true
var _wheel_touch_index := -1
var _touch_left_held := false
var _touch_right_held := false
var _last_player_command: RaceInput = null

var telemetry_cluster: RaceTelemetryCluster
var standings_panel: RaceStandingsPanel
var countdown_label: Label
var pause_panel: PanelContainer
var results_panel: PanelContainer
var minimap: RaceMinimap
var camera_button: Button
var recovery_label: Label
var _results_classification_signature := ""
var _results_official_time := 0.0
var _results_persistence_summary: Dictionary = {}


func set_payload(value: Dictionary) -> void:
	payload = value.duplicate(true)


static func validated_lap_count(value: Variant) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return DEFAULT_TOTAL_LAPS
	var requested := int(value)
	return requested if requested == 3 or requested == 5 or requested == 8 else DEFAULT_TOTAL_LAPS


static func mapped_ai_difficulty(value: Variant) -> float:
	var key := str(value).strip_edges().to_lower()
	return float(DIFFICULTY_VALUES.get(key, DIFFICULTY_VALUES["standard"]))


static func validated_racer_count(value: Variant) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return DEFAULT_RACER_COUNT
	if is_nan(float(value)) or is_inf(float(value)):
		return DEFAULT_RACER_COUNT
	return clampi(roundi(float(value)), MIN_RACER_COUNT, MAX_RACER_COUNT)


static func touch_control_lift_px(value: Variant) -> float:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return 0.0
	if is_nan(float(value)) or is_inf(float(value)):
		return 0.0
	return clampf(float(value), 0.0, 1.0) * 96.0


static func best_sector_times(splits: Array) -> PackedFloat64Array:
	var best := PackedFloat64Array([INF, INF, INF])
	for value in splits:
		if not value is Dictionary:
			continue
		var sector_index := int(value.get("sector_index", 0))
		var duration := float(value.get("duration", -1.0))
		if sector_index < 1 or sector_index > 3 or duration <= 0.0 \
				or is_nan(duration) or is_inf(duration):
			continue
		best[sector_index - 1] = minf(best[sector_index - 1], duration)
	return best


static func local_persistence_warning(summary: Dictionary) -> String:
	var race_result: Variant = summary.get("race_result", {})
	var race_failed := not race_result is Dictionary or not bool(race_result.get("ok", false))
	var best_attempted := bool(summary.get("best_lap_attempted", false))
	var best_result: Variant = summary.get("best_lap_result", {})
	var best_failed := best_attempted and (
		not best_result is Dictionary or not bool(best_result.get("ok", false))
	)
	if race_failed and best_failed:
		return "RESULT AND BEST LAP WERE NOT SAVED LOCALLY"
	if race_failed:
		return "RACE RESULT WAS NOT SAVED LOCALLY"
	if best_failed:
		return "BEST LAP WAS NOT SAVED LOCALLY"
	return ""


static func share_results_text(track_name: String, official_time: float, standings: Array) -> String:
	var lines := PackedStringArray([
		"RaceGlyph — %s" % (track_name if not track_name.is_empty() else "Offline Race"),
		"Race time: %s" % _format_time(official_time),
		"Full classification:",
	])
	for row in classification_rows(standings):
		var status := str(row.get("status", "dnf")).to_upper()
		var timing := _format_time(float(row.get("finish_time_ms", -1)) / 1000.0) \
			if int(row.get("finish_time_ms", -1)) >= 0 \
			else str(row.get("dnf_reason", "no time")).replace("_", " ").to_upper()
		if timing.is_empty():
			timing = "NO TIME"
		lines.append("%d. %s — %s — %s" % [
			int(row.get("position", lines.size() - 2)),
			str(row.get("display_name", "DRIVER")),
			status,
			timing,
		])
	return "\n".join(lines)


static func studio_return_payload(race_payload: Dictionary) -> Dictionary:
	var source := str(race_payload.get("source", ""))
	var definition_json := str(race_payload.get("track_definition_json", ""))
	if source in ["saved", "studio"] and not definition_json.is_empty():
		return {"editing_track_json": definition_json}
	return {}


static func classification_rows(standings: Array) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for index in standings.size():
		var value: Variant = standings[index]
		if value is Dictionary:
			rows.append({
				"position": int(value.get("position", index + 1)),
				"display_name": str(value.get("display_name", value.get("name", "DRIVER"))),
				"status": str(value.get("status", "dnf")),
				"finish_time_ms": int(value.get("finish_time_ms", -1)),
				"dnf_reason": str(value.get("dnf_reason", "")),
			})
		else:
			var finish_seconds := float(value.finish_time)
			rows.append({
				"position": index + 1,
				"display_name": str(value.display_name),
				"status": str(value.status),
				"finish_time_ms": roundi(finish_seconds * 1000.0) if finish_seconds >= 0.0 else -1,
				"dnf_reason": str(value.dnf_reason),
			})
	return rows


func _configure_race_options() -> void:
	total_laps = validated_lap_count(payload.get("laps", DEFAULT_TOTAL_LAPS))
	racer_count = validated_racer_count(payload.get("grid_size", DEFAULT_RACER_COUNT))
	final_position = racer_count
	ai_difficulty = mapped_ai_difficulty(payload.get("difficulty", "standard"))
	var collisions_value: Variant = payload.get("collisions", true)
	vehicle_collisions_enabled = bool(collisions_value) if typeof(collisions_value) == TYPE_BOOL else true


func _ready() -> void:
	var services := _services()
	settings = services.call("settings") if services != null else GameSettings.new()
	if payload.has("camera_view"):
		settings.camera_view = GameSettings.CAMERA_COCKPIT \
			if str(payload["camera_view"]) == "cockpit" else GameSettings.CAMERA_CHASE
	input_adapter = InputAdapterType.new()
	_configure_race_options()
	set_process(true)
	set_process_unhandled_input(true)
	_build()
	call_deferred("_start_race")


func _exit_tree() -> void:
	set_process(false)
	set_process_unhandled_input(false)
	_stop_engine_audio()
	if perspective_view != null:
		perspective_view.clear_race_authority()
	if minimap != null:
		minimap.clear_race_authority()
	if director != null:
		for entry in director.entries:
			entry.controller = null
		director.entries.clear()
	director = null
	_last_player_command = null
	input_adapter = null
	race_query = null
	compiled_track = null
	racers.clear()


func _build() -> void:
	perspective_view = RaceWorldType.new()
	perspective_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(perspective_view)
	track_load_error = _configure_track_from_payload()
	if track_load_error.is_empty():
		perspective_view.configure_accessibility(
			settings.low_graphics, settings.reduced_motion, settings.high_contrast,
			SettingsRuntime.screen_shake_strength(settings)
		)
		# Select the device/settings render tier before building the long static
		# circuit. Low Graphics then tessellates once instead of building the full
		# track/scenery and immediately replacing it with the mobile tier.
		perspective_view.configure(race_query, settings.camera_view)

	var hud_safe := DesignSystem.make_margin(28, 24, 28, 26)
	hud_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(hud_safe)
	var hud := VBoxContainer.new()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_safe.add_child(hud)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_PASS
	top.add_theme_constant_override("separation", 12)
	hud.add_child(top)
	standings_panel = StandingsPanelType.new()
	standings_panel.name = "LiveStandings"
	standings_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	standings_panel.configure_accessibility(settings.reduced_motion, settings.high_contrast)
	top.add_child(standings_panel)
	var top_spacer := Control.new()
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(top_spacer)
	var map_panel := PanelContainer.new()
	map_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	map_panel.add_theme_stylebox_override("panel", _compact_panel_style(
		Color(0.025, 0.05, 0.09, 0.90), 16, Color(1.0, 1.0, 1.0, 0.12), 1
	))
	top.add_child(map_panel)
	minimap = MinimapType.new()
	minimap.configure_accessibility(SettingsRuntime.requires_non_color_cues(settings))
	map_panel.add_child(minimap)
	camera_button = DesignSystem.screen_button(_camera_button_text())
	camera_button.custom_minimum_size = Vector2(132.0, 50.0)
	camera_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	camera_button.mouse_filter = Control.MOUSE_FILTER_STOP
	camera_button.pressed.connect(_toggle_camera)
	top.add_child(camera_button)
	_refresh_camera_button()
	var pause_button := DesignSystem.screen_button("Ⅱ  PAUSE")
	pause_button.custom_minimum_size = Vector2(124.0, 50.0)
	pause_button.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	pause_button.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_button.pressed.connect(_toggle_pause)
	top.add_child(pause_button)

	var grow := Control.new()
	grow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hud.add_child(grow)
	var bottom := HBoxContainer.new()
	bottom.mouse_filter = Control.MOUSE_FILTER_PASS
	bottom.add_theme_constant_override("separation", 12)
	hud.add_child(bottom)
	_build_touch_controls(bottom)
	var reach_offset := Control.new()
	reach_offset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reach_offset.custom_minimum_size.y = touch_control_lift_px(settings.touch_control_vertical_offset)
	hud.add_child(reach_offset)
	_build_telemetry_overlay()

	countdown_label = DesignSystem.title("3", 112)
	countdown_label.set_anchors_preset(Control.PRESET_CENTER)
	countdown_label.position = Vector2(-64.0, -88.0)
	countdown_label.custom_minimum_size = Vector2(128.0, 176.0)
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(countdown_label)
	recovery_label = DesignSystem.label("↺  RECOVERED TO CIRCUIT", 18, DesignSystem.CYAN)
	recovery_label.visible = false
	recovery_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	recovery_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	recovery_label.add_theme_constant_override("outline_size", 7)
	recovery_label.add_theme_color_override("font_outline_color", DesignSystem.INK)
	recovery_label.anchor_left = 0.5
	recovery_label.anchor_right = 0.5
	recovery_label.offset_left = -190.0
	recovery_label.offset_right = 190.0
	recovery_label.offset_top = 106.0
	recovery_label.offset_bottom = 150.0
	add_child(recovery_label)
	_build_pause_panel()
	_build_results_panel()
	if not track_load_error.is_empty():
		_build_track_error_panel(track_load_error)


func _build_telemetry_overlay() -> void:
	# Keep the instrument above the tallest/lifted touch surface. A separate
	# SafeMarginContainer applies display cutouts and the home indicator without
	# coupling the high-frequency telemetry repaint to the control layout.
	var controls_height := 82.0 * settings.touch_control_size
	var bottom_clearance := 26.0 + controls_height + 20.0 \
		+ touch_control_lift_px(settings.touch_control_vertical_offset)
	var telemetry_safe := DesignSystem.make_margin(28, 24, 28, roundi(bottom_clearance))
	telemetry_safe.name = "TelemetrySafeArea"
	telemetry_safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry_safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(telemetry_safe)
	var anchor := Control.new()
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	telemetry_safe.add_child(anchor)
	telemetry_cluster = TelemetryClusterType.new()
	telemetry_cluster.name = "RaceTelemetry"
	telemetry_cluster.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	telemetry_cluster.offset_left = -TelemetryClusterType.BASE_SIZE.x
	telemetry_cluster.offset_top = -TelemetryClusterType.BASE_SIZE.y
	telemetry_cluster.configure_accessibility(settings.reduced_motion, settings.high_contrast)
	anchor.add_child(telemetry_cluster)


func _build_touch_controls(bottom: HBoxContainer) -> void:
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


func _steering_controls() -> Control:
	if settings.touch_control_scheme == GameSettings.CONTROL_TILT:
		var tilt_panel := PanelContainer.new()
		tilt_panel.custom_minimum_size = _control_size(Vector2(208.0, 70.0))
		tilt_panel.modulate.a = settings.touch_control_opacity
		tilt_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
			Color(0.035, 0.075, 0.13, 0.9), 18, DesignSystem.CYAN, 1
		))
		var tilt_label := DesignSystem.label("TILT STEERING\nCALIBRATED", 14, DesignSystem.CYAN)
		tilt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tilt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tilt_panel.add_child(tilt_label)
		return tilt_panel
	if settings.touch_control_scheme == GameSettings.CONTROL_WHEEL:
		var wheel := PanelContainer.new()
		wheel.custom_minimum_size = _control_size(Vector2(224.0, 82.0))
		wheel.modulate.a = settings.touch_control_opacity
		wheel.mouse_filter = Control.MOUSE_FILTER_STOP
		wheel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
			Color(0.035, 0.075, 0.13, 0.94), 22, DesignSystem.MINT, 2
		))
		var wheel_label := DesignSystem.label("◀  STEERING WHEEL  ▶\nDRAG TO TURN", 14, DesignSystem.WHITE)
		wheel_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wheel_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wheel_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		wheel.add_child(wheel_label)
		wheel.gui_input.connect(func(event: InputEvent) -> void: _on_wheel_input(event, wheel))
		return wheel
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	_add_hold_button(buttons, "◀", func(value: bool) -> void: _set_touch_left(value))
	_add_hold_button(buttons, "▶", func(value: bool) -> void: _set_touch_right(value))
	return buttons


func _pedal_controls() -> Control:
	var pedals := HBoxContainer.new()
	pedals.add_theme_constant_override("separation", 10)
	_add_hold_button(
		pedals, "GAS",
		func(value: bool) -> void: input_adapter.touch_throttle = 1.0 if value else 0.0,
		true, Vector2(132.0, 76.0)
	)
	_add_hold_button(
		pedals, "BRAKE\nREVERSE",
		func(value: bool) -> void: input_adapter.touch_brake = 1.0 if value else 0.0,
		false, Vector2(132.0, 76.0)
	)
	return pedals


func _add_hold_button(
		container: Container,
		text: String,
		setter: Callable,
		primary: bool = false,
		base_size: Vector2 = Vector2(108.0, 70.0)
	) -> void:
	var button := DesignSystem.button(text, primary, true)
	button.custom_minimum_size = _control_size(base_size)
	button.modulate.a = settings.touch_control_opacity
	button.focus_mode = Control.FOCUS_NONE
	button.button_down.connect(func() -> void: setter.call(true))
	button.button_up.connect(func() -> void: setter.call(false))
	container.add_child(button)


func _control_size(base: Vector2) -> Vector2:
	return base * settings.touch_control_size


func _compact_panel_style(
		color: Color,
		radius: int,
		border_color: Color,
		border_width: int
	) -> StyleBoxFlat:
	var style := DesignSystem.panel_style(color, radius, border_color, border_width)
	style.content_margin_left = 14.0
	style.content_margin_top = 9.0
	style.content_margin_right = 14.0
	style.content_margin_bottom = 9.0
	style.shadow_size = 5
	style.shadow_offset = Vector2(0.0, 3.0)
	return style


func _set_touch_left(value: bool) -> void:
	_touch_left_held = value
	input_adapter.touch_steer = float(int(_touch_right_held) - int(_touch_left_held))


func _set_touch_right(value: bool) -> void:
	_touch_right_held = value
	input_adapter.touch_steer = float(int(_touch_right_held) - int(_touch_left_held))


func _on_wheel_input(event: InputEvent, wheel: Control) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and (_wheel_touch_index < 0 or _wheel_touch_index == event.index):
			_wheel_touch_index = event.index
			_set_wheel_axis(event.position.x, wheel.size.x)
		elif not event.pressed and event.index == _wheel_touch_index:
			_wheel_touch_index = -1
			input_adapter.touch_steer = 0.0
		wheel.accept_event()
	elif event is InputEventScreenDrag and event.index == _wheel_touch_index:
		_set_wheel_axis(event.position.x, wheel.size.x)
		wheel.accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_set_wheel_axis(event.position.x, wheel.size.x)
		else:
			input_adapter.touch_steer = 0.0
		wheel.accept_event()
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		_set_wheel_axis(event.position.x, wheel.size.x)
		wheel.accept_event()


func _set_wheel_axis(local_x: float, wheel_width: float) -> void:
	input_adapter.touch_steer = clampf(local_x / maxf(wheel_width, 1.0) * 2.0 - 1.0, -1.0, 1.0)


func _configure_track_from_payload() -> String:
	var result: TrackCompileResult
	if payload.has("track_definition_json"):
		var definition: TrackDefinition = TrackDefinitionType.from_json(str(payload["track_definition_json"]))
		result = TrackCompilerType.compile(definition)
		if not result.succeeded():
			return _first_compile_error(result)
		var expected_source := str(payload.get("source_hash", ""))
		var expected_compile := str(payload.get("compiled_hash", ""))
		if not expected_source.is_empty() and expected_source != result.track.source_hash:
			return "Track source verification failed. Return to Track Studio and rebuild."
		if not expected_compile.is_empty() and expected_compile != result.track.compile_hash:
			return "Generated track verification failed. This circuit cannot be raced safely."
	elif payload.has("control_points") and payload["control_points"] is PackedVector2Array:
		var legacy := _definition_for_points(payload["control_points"], "Legacy Preview", "legacy-preview")
		result = TrackCompilerType.compile(legacy)
	else:
		result = TrackCompilerType.compile(_builtin_definition())
	if result == null or not result.succeeded() or result.track == null:
		return _first_compile_error(result) if result != null else "The race circuit could not be built."
	compiled_track = result.track
	race_query = RaceTrackQueryType.from_compiled(compiled_track)
	if not race_query.is_valid():
		return "The compiled circuit is not safe for race simulation."
	return ""


func _builtin_definition() -> TrackDefinition:
	# Direct /race launches use the same isolated, validated definition as Track
	# Select. This prevents the debug/deep-link route from silently falling back
	# to the obsolete short and narrow prototype loop.
	var item := PredefinedTrackCatalogType.by_id("builtin-evergreen-oval")
	return item.get("definition") as TrackDefinition


func _definition_for_points(points: PackedVector2Array, display_name: String, track_id: String) -> TrackDefinition:
	var definition := TrackDefinitionType.create(points, Vector2(1200.0, 800.0), 36.0, display_name, track_id, 424242)
	definition.target_length = 1600.0
	definition.refresh_content_hash()
	return definition


func _first_compile_error(result: TrackCompileResult) -> String:
	if result == null:
		return "The track definition could not be compiled."
	for issue in result.report.issues:
		if issue.severity_name() == "error":
			return issue.message
	return "The track definition could not be compiled."


func _build_track_error_panel(message: String) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-270.0, -150.0)
	panel.custom_minimum_size = Vector2(540.0, 300.0)
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.035, 0.075, 0.13, 0.99), 28, DesignSystem.CORAL, 2
	))
	add_child(panel)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 18)
	panel.add_child(content)
	content.add_child(DesignSystem.title("TRACK BLOCKED", 36))
	var detail := DesignSystem.label(message, 18, DesignSystem.MUTED)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(detail)
	var back := DesignSystem.button("RETURN TO TRACK STUDIO", true, true)
	back.pressed.connect(func() -> void: navigate_requested.emit("studio", studio_return_payload(payload)))
	content.add_child(back)


func _build_pause_panel() -> void:
	pause_panel = PanelContainer.new()
	pause_panel.visible = false
	pause_panel.set_anchors_preset(Control.PRESET_CENTER)
	pause_panel.position = Vector2(-190.0, -160.0)
	pause_panel.custom_minimum_size = Vector2(380.0, 320.0)
	pause_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.035, 0.075, 0.13, 0.98), 28, DesignSystem.MINT, 2
	))
	add_child(pause_panel)
	var menu := VBoxContainer.new()
	menu.alignment = BoxContainer.ALIGNMENT_CENTER
	menu.add_theme_constant_override("separation", 15)
	pause_panel.add_child(menu)
	menu.add_child(DesignSystem.title("RACE PAUSED", 36))
	menu.add_child(DesignSystem.label("Race time and fixed-step authority are frozen.", 14, DesignSystem.MUTED))
	var resume := DesignSystem.button("RESUME", true, true)
	resume.pressed.connect(_toggle_pause)
	menu.add_child(resume)
	var restart := DesignSystem.button("RESTART", false, true)
	restart.pressed.connect(_restart)
	menu.add_child(restart)
	var leave := DesignSystem.button("RETURN TO PADDOCK", false, true)
	leave.pressed.connect(func() -> void: navigate_requested.emit("home", {}))
	menu.add_child(leave)


func _build_results_panel() -> void:
	results_panel = PanelContainer.new()
	results_panel.visible = false
	results_panel.set_anchors_preset(Control.PRESET_CENTER)
	results_panel.position = Vector2(-350.0, -305.0)
	results_panel.custom_minimum_size = Vector2(700.0, 610.0)
	results_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.035, 0.075, 0.13, 0.98), 30, DesignSystem.GOLD, 2
	))
	add_child(results_panel)


func _start_race() -> void:
	if not track_load_error.is_empty() or compiled_track == null or race_query == null:
		return
	_clear_racer_visuals()
	input_adapter.reset_touch()
	selected_vehicle = _selected_vehicle()
	perspective_view.configure_accessibility(
		settings.low_graphics, settings.reduced_motion, settings.high_contrast,
		SettingsRuntime.screen_shake_strength(settings)
	)
	perspective_view.configure(
		race_query, settings.camera_view, selected_vehicle["accent"]
	)
	director = RaceDirectorType.new()
	if not director.configure(
		race_query,
		total_laps,
		compiled_track.deterministic_seed,
		8,
		vehicle_collisions_enabled
	):
		track_load_error = "Race authority could not initialize this circuit."
		_build_track_error_panel(track_load_error)
		return
	director.countdown_duration = 3.0
	director.race_time_limit = 12.0 * 60.0
	director.add_entry(PLAYER_ID, PLAYER_DISPLAY_NAME, true)
	var ai_drivers := AiRosterType.create_drivers(
		compiled_track.deterministic_seed, maxi(10, racer_count - 1), ai_difficulty
	)
	for index in racer_count - 1:
		var ai = ai_drivers[index]
		director.add_entry(ai.driver_id, AiRosterType.display_name(index), false, ai)
	_build_racer_visuals()
	minimap.configure(race_query, PLAYER_ID)
	minimap.configure_accessibility(SettingsRuntime.requires_non_color_cues(settings))
	minimap.update_entries(director.entries)
	paused = false
	finished = false
	_results_classification_signature = ""
	_results_official_time = 0.0
	_results_persistence_summary.clear()
	last_completed_laps = 0
	lap_started_at = 0.0
	best_lap_seconds = INF
	final_position = racer_count
	player_offtrack = false
	player_wall_contacts = 0
	last_recovery_serial = director.entry(PLAYER_ID).state.recovery_hard_snap_serial
	recovery_cue_remaining = 0.0
	recovery_label.visible = false
	_last_player_command = RaceInputType.new()
	last_countdown_number = 4
	go_display_remaining = 0.0
	director.start()
	_start_engine_audio()
	last_phase = director.phase
	countdown_label.visible = true
	countdown_label.text = "3"
	countdown_label.add_theme_color_override("font_color", DesignSystem.WHITE)
	_render_authority(1.0)
	_update_hud()


func _selected_vehicle() -> Dictionary:
	var services := _services()
	var saved: Dictionary = services.call("selected_cosmetics") if services != null else {}
	return VehicleCatalogType.by_car_id(str(saved.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID)))


func _build_racer_visuals() -> void:
	for entry in director.entries:
		racers[entry.participant_id] = {
			"grid_position": entry.grid_position,
			"display_name": entry.display_name,
		}


func _clear_racer_visuals() -> void:
	racers.clear()


func _process(delta: float) -> void:
	if director == null:
		return
	var command := RaceInputType.new()
	if not finished and director.phase == RaceDirectorType.PHASE_RACING and not paused:
		command = input_adapter.sample(settings, _assist_context())
		# RaceInput keeps this legacy bit for replay compatibility, but shipped
		# gameplay intentionally exposes only the conventional pedal contract.
		command.nitro = false
	_last_player_command = command
	var phase_before := director.phase
	director.advance_frame(delta, {PLAYER_ID: command})
	if recovery_cue_remaining > 0.0:
		recovery_cue_remaining = maxf(0.0, recovery_cue_remaining - delta)
		if recovery_cue_remaining <= 0.0 and settings.reduced_motion:
			recovery_label.visible = false
	_update_countdown(phase_before, delta)
	if not finished:
		_update_feedback()
		_update_engine_audio(command)
	var interpolation := 1.0 if paused or director.phase != RaceDirectorType.PHASE_RACING else director.interpolation_alpha()
	_render_authority(interpolation)
	_update_hud()
	minimap.update_entries(director.entries)
	var player := director.entry(PLAYER_ID)
	if not finished and player != null and (
		player.status == RaceEntry.STATUS_FINISHED
		or player.status == RaceEntry.STATUS_DNF
	):
		_finish_race()
	elif finished:
		_refresh_results_panel_if_changed()
	last_phase = director.phase


func _assist_context() -> Dictionary:
	var player := director.entry(PLAYER_ID)
	if player == null or player.state == null:
		return {}
	var state := player.state
	var lookahead := clampf(28.0 + state.speed() * 0.30, 30.0, 120.0)
	var target := race_query.sample_at_distance(state.track_distance + lookahead)
	return {
		"track_half_width": race_query.track_width * 0.5,
		"lateral_offset": state.lateral_offset,
		"heading_error": state.forward().angle_to(target.get("tangent", state.forward())),
		"upcoming_radius": race_query.upcoming_minimum_radius(state.track_distance, lookahead * 1.5, 10),
		"speed": state.speed(),
		"maximum_speed": player.vehicle_model.config.maximum_forward_speed,
	}


func _update_countdown(phase_before: StringName, delta: float) -> void:
	if director.phase == RaceDirectorType.PHASE_COUNTDOWN:
		var number := clampi(ceili(director.countdown_remaining), 1, 3)
		countdown_label.visible = true
		countdown_label.text = str(number)
		if number != last_countdown_number:
			last_countdown_number = number
			_play_sfx(&"countdown")
	elif phase_before == RaceDirectorType.PHASE_COUNTDOWN and director.phase == RaceDirectorType.PHASE_RACING:
		countdown_label.visible = true
		countdown_label.text = "GO"
		countdown_label.add_theme_color_override("font_color", DesignSystem.MINT)
		go_display_remaining = 0.65
		_play_sfx(&"go")
	elif go_display_remaining > 0.0 and not paused:
		go_display_remaining = maxf(0.0, go_display_remaining - delta)
		countdown_label.visible = go_display_remaining > 0.0
	else:
		countdown_label.visible = false


func _update_feedback() -> void:
	var player := director.entry(PLAYER_ID)
	if player == null:
		return
	var state := player.state
	var recovered := state.recovery_hard_snap_serial != last_recovery_serial
	if recovered:
		_show_recovery_cue()
		_vibrate(110, 0.52)
	if state.wall_contacts > player_wall_contacts:
		_play_sfx(&"collision")
		if not recovered:
			_vibrate(80, 0.55)
	player_wall_contacts = state.wall_contacts
	last_recovery_serial = state.recovery_hard_snap_serial
	if state.is_offtrack and not player_offtrack and state.speed() > 90.0:
		_play_sfx(&"skid")
	player_offtrack = state.is_offtrack
	if player.lap_tracker.laps_completed > last_completed_laps:
		_update_lap_timing(player.lap_tracker.laps_completed)


func _show_recovery_cue() -> void:
	if recovery_label == null:
		return
	if recovery_tween != null and recovery_tween.is_valid():
		recovery_tween.kill()
	recovery_label.visible = true
	recovery_label.modulate.a = 1.0
	recovery_cue_remaining = 1.25
	if settings.reduced_motion:
		return
	recovery_tween = create_tween()
	recovery_tween.tween_interval(0.8)
	recovery_tween.tween_property(recovery_label, "modulate:a", 0.0, 0.35)
	recovery_tween.tween_callback(func() -> void: recovery_label.visible = false)


func _render_authority(alpha: float) -> void:
	if director == null or perspective_view == null:
		return
	perspective_view.update_race(
		director.entry(PLAYER_ID), director.entries,
		_last_player_command if _last_player_command != null else RaceInputType.new(), alpha
	)


func _update_hud() -> void:
	if director == null:
		return
	var player := director.entry(PLAYER_ID)
	if player == null:
		return
	var standings := director.standings()
	final_position = player.race_position
	var current_lap := mini(player.lap_tracker.laps_completed + 1, total_laps)
	var sector_index := player.lap_tracker.current_sector_index()
	var sector_elapsed := player.lap_tracker.current_sector_elapsed(director.race_time)
	if telemetry_cluster != null:
		telemetry_cluster.update_telemetry(
			SettingsRuntime.speed_to_kmh(player.state.speed()),
			player.state.gear,
			player.state.engine_rpm,
			player.vehicle_model.config.redline_rpm,
			player.state.shift_ticks_remaining > 0,
			current_lap,
			total_laps,
			sector_index,
			director.race_time,
			sector_elapsed,
			player.state.is_offtrack
		)
	if standings_panel != null:
		standings_panel.update_standings(
			standings, PLAYER_ID, race_query.total_length,
			current_lap, total_laps, director.race_time, director.fixed_tick
		)


func _update_lap_timing(completed_laps: int) -> void:
	if completed_laps <= last_completed_laps:
		return
	for completed in range(last_completed_laps + 1, mini(completed_laps, total_laps) + 1):
		var lap_time := director.race_time - lap_started_at
		lap_started_at = director.race_time
		best_lap_seconds = minf(best_lap_seconds, lap_time)
		if completed < total_laps:
			_play_sfx(&"lap")
			_vibrate(55, 0.35)
	last_completed_laps = mini(completed_laps, total_laps)


func _toggle_pause() -> void:
	if finished or director == null:
		return
	_set_paused(not paused)


func _set_paused(value: bool) -> void:
	paused = value
	director.set_paused(paused)
	pause_panel.visible = paused and not finished
	if paused:
		_release_controls()
	_set_audio_paused(paused)


func on_application_paused() -> void:
	if director != null and (
		director.phase == RaceDirectorType.PHASE_COUNTDOWN
		or director.phase == RaceDirectorType.PHASE_RACING
	):
		_set_paused(true)


func on_application_resumed() -> void:
	# Never resume driving without an explicit player action after interruption.
	# Once the player has already finished there is no driving input to expose;
	# resume the remaining AI classification automatically so results cannot stall.
	if finished and paused and director != null:
		paused = false
		director.set_paused(false)
		_set_audio_paused(false)
		return
	_set_audio_paused(paused)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_pause()
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START:
		_toggle_pause()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_C:
		_toggle_camera()
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_Y:
		_toggle_camera()
		get_viewport().set_input_as_handled()


func _release_controls() -> void:
	input_adapter.reset_touch()
	_wheel_touch_index = -1
	_touch_left_held = false
	_touch_right_held = false


func _toggle_camera(persist: bool = true) -> void:
	settings.camera_view = GameSettings.CAMERA_COCKPIT \
		if settings.camera_view == GameSettings.CAMERA_CHASE \
		else GameSettings.CAMERA_CHASE
	perspective_view.set_camera_mode(settings.camera_view)
	_refresh_camera_button()
	_play_sfx(&"click")
	var services := _services()
	if persist and services != null:
		services.call("update_settings", settings)


func _camera_button_text() -> String:
	return "CHASE VIEW" if settings.camera_view == GameSettings.CAMERA_COCKPIT else "COCKPIT VIEW"


func _refresh_camera_button() -> void:
	if camera_button == null:
		return
	var current := "COCKPIT" if settings.camera_view == GameSettings.CAMERA_COCKPIT else "CHASE"
	var target := "CHASE" if current == "COCKPIT" else "COCKPIT"
	camera_button.text = _camera_button_text()
	camera_button.tooltip_text = "Current view: %s. Activate to switch to %s view." % [current.capitalize(), target.capitalize()]
	camera_button.accessibility_name = "Current %s view; switch to %s view" % [current.to_lower(), target.to_lower()]


func _restart() -> void:
	paused = false
	finished = false
	_release_controls()
	pause_panel.visible = false
	results_panel.visible = false
	_set_audio_paused(false)
	_start_race()


func _finish_race() -> void:
	if finished:
		return
	finished = true
	_release_controls()
	_play_sfx(&"finish")
	_stop_engine_audio()
	_vibrate(140, 0.65)
	director.standings()
	var player := director.entry(PLAYER_ID)
	final_position = player.race_position
	var official_time := player.finish_time if player.finish_time >= 0.0 else director.race_time
	var persistence_summary := _record_local_result(player, official_time)
	_results_official_time = official_time
	_results_persistence_summary = persistence_summary.duplicate(true)
	_results_classification_signature = ""
	_render_results_panel()


func _refresh_results_panel_if_changed(force: bool = false) -> void:
	if director == null or not finished:
		return
	var signature := _classification_signature()
	if force or signature != _results_classification_signature:
		_render_results_panel()


func _classification_signature() -> String:
	var parts := PackedStringArray([str(director.phase)])
	for row in classification_rows(director.standings()):
		parts.append("%d:%s:%d:%s" % [
			int(row.get("position", 0)),
			str(row.get("status", "")),
			int(row.get("finish_time_ms", -1)),
			str(row.get("dnf_reason", "")),
		])
	return "|".join(parts)


func _field_is_classified() -> bool:
	if director == null or director.entries.is_empty():
		return false
	for entry in director.entries:
		if entry.status != RaceEntry.STATUS_FINISHED \
				and entry.status != RaceEntry.STATUS_DNF:
			return false
	return true


func _classified_count() -> int:
	var count := 0
	if director == null:
		return count
	for entry in director.entries:
		if entry.status == RaceEntry.STATUS_FINISHED \
				or entry.status == RaceEntry.STATUS_DNF:
			count += 1
	return count


func _render_results_panel() -> void:
	if director == null or results_panel == null:
		return
	var player := director.entry(PLAYER_ID)
	if player == null:
		return
	var official_time := _results_official_time
	var persistence_summary := _results_persistence_summary
	var official_standings := director.standings()
	var field_classified := _field_is_classified()
	_results_classification_signature = _classification_signature()
	results_panel.visible = true
	for child in results_panel.get_children():
		child.queue_free()
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 9)
	results_panel.add_child(content)
	var finished_normally := player.status == RaceEntry.STATUS_FINISHED
	content.add_child(DesignSystem.label("CHEQUERED FLAG" if finished_normally else "RACE CONTROL", 16, DesignSystem.GOLD))
	content.add_child(DesignSystem.title("P%d FINISH" % final_position if finished_normally else "DID NOT FINISH", 46))
	content.add_child(DesignSystem.label("Race time  " + _format_time(official_time), 19, DesignSystem.MUTED))
	if not is_inf(best_lap_seconds):
		content.add_child(DesignSystem.label("Best lap  " + _format_time(best_lap_seconds), 17, DesignSystem.MINT))
	var best_sectors := best_sector_times(player.lap_tracker.sector_splits_snapshot())
	var sector_parts := PackedStringArray()
	var has_sector_time := false
	for index in best_sectors.size():
		if is_inf(best_sectors[index]):
			sector_parts.append("S%d  --:--.---" % (index + 1))
		else:
			has_sector_time = true
			sector_parts.append("S%d  %s" % [index + 1, _format_time(best_sectors[index])])
	if has_sector_time:
		content.add_child(DesignSystem.label("BEST SECTORS  •  " + "  •  ".join(sector_parts), 14, DesignSystem.CYAN))
	var persistence_warning := local_persistence_warning(persistence_summary)
	if not persistence_warning.is_empty():
		content.add_child(DesignSystem.label("⚠  " + persistence_warning, 13, DesignSystem.CORAL))
	var classification_heading := "FULL CLASSIFICATION • %d DRIVERS" \
			% director.entries.size() if field_classified \
			else "LIVE CLASSIFICATION • %d/%d COMPLETE" % [
				_classified_count(), director.entries.size()
			]
	content.add_child(DesignSystem.label(classification_heading, 13, DesignSystem.CYAN))
	var classification_scroll := ScrollContainer.new()
	classification_scroll.custom_minimum_size = Vector2(620.0, 210.0)
	classification_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	classification_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	content.add_child(classification_scroll)
	var classification := VBoxContainer.new()
	classification.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	classification.add_theme_constant_override("separation", 4)
	classification_scroll.add_child(classification)
	for row_data in classification_rows(official_standings):
		var row_panel := PanelContainer.new()
		row_panel.add_theme_stylebox_override("panel", _compact_panel_style(
			Color(0.025, 0.055, 0.10, 0.94), 10,
			DesignSystem.MINT if str(row_data["display_name"]) == PLAYER_DISPLAY_NAME else Color(1.0, 1.0, 1.0, 0.08), 1
		))
		classification.add_child(row_panel)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row_panel.add_child(row)
		var place := DesignSystem.label("P%02d" % int(row_data["position"]), 14, DesignSystem.GOLD)
		place.custom_minimum_size.x = 48.0
		row.add_child(place)
		var driver_name := DesignSystem.label(str(row_data["display_name"]), 14, DesignSystem.WHITE)
		driver_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(driver_name)
		var status := str(row_data["status"]).to_upper()
		var status_text := "FINISHING" if status == "RACING" else status
		var status_color := DesignSystem.MINT if status == "FINISHED" \
				else (DesignSystem.GOLD if status == "RACING" else DesignSystem.CORAL)
		row.add_child(DesignSystem.label(status_text, 12, status_color))
		var timing := _format_time(float(row_data["finish_time_ms"]) / 1000.0) if int(row_data["finish_time_ms"]) >= 0 else str(row_data["dnf_reason"]).replace("_", " ").to_upper()
		if timing.is_empty():
			timing = "ON TRACK" if status == "RACING" else "NO TIME"
		var timing_label := DesignSystem.label(timing, 12, DesignSystem.MUTED)
		timing_label.custom_minimum_size.x = 112.0
		timing_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(timing_label)
	var share_status := DesignSystem.label("", 12, DesignSystem.MINT)
	share_status.custom_minimum_size.y = 18.0
	share_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(share_status)
	if not field_classified:
		share_status.text = "AI DRIVERS ARE STILL FINISHING — TIMES UPDATE LIVE"
	var actions := GridContainer.new()
	actions.columns = 2
	actions.add_theme_constant_override("separation", 8)
	content.add_child(actions)
	var again := DesignSystem.button("RACE AGAIN", true, true)
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again.custom_minimum_size.x = 300.0
	again.pressed.connect(_restart)
	actions.add_child(again)
	var share_text := share_results_text(
		str(payload.get("display_name", compiled_track.track_id if compiled_track != null else "Offline Race")),
		official_time,
		official_standings
	)
	var share := DesignSystem.button("SHARE RESULTS", false, true)
	share.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	share.custom_minimum_size.x = 300.0
	share.disabled = not field_classified
	if not field_classified:
		share.text = "WAIT FOR FIELD"
	share.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(share_text)
		share.text = "COPIED  ✓"
		share_status.text = "FULL CLASSIFICATION COPIED — READY TO SHARE"
	)
	actions.add_child(share)
	var edit_payload := studio_return_payload(payload)
	var studio := DesignSystem.button("EDIT CUSTOM CIRCUIT" if not edit_payload.is_empty() else "OPEN NEW TRACK STUDIO", false, true)
	studio.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	studio.custom_minimum_size.x = 300.0
	studio.pressed.connect(func() -> void: navigate_requested.emit("studio", edit_payload))
	actions.add_child(studio)
	var home := DesignSystem.button("PADDOCK", false, true)
	home.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	home.custom_minimum_size.x = 300.0
	home.pressed.connect(func() -> void: navigate_requested.emit("home", {}))
	actions.add_child(home)


func _record_local_result(player: RaceEntry, official_time: float) -> Dictionary:
	var track_id := compiled_track.track_id if compiled_track != null and not compiled_track.track_id.is_empty() else "builtin-demo"
	var vehicle_id := str(selected_vehicle.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID))
	var services := _services()
	var best_attempted := not is_inf(best_lap_seconds)
	var summary := {
		"race_result": {"ok": false, "error_code": "services_unavailable"},
		"best_lap_attempted": best_attempted,
		"best_lap_result": {"ok": not best_attempted},
	}
	if services == null:
		return summary
	var race_result: Variant = services.call("record_race_result", {
		"track_id": track_id,
		"position": final_position,
		"racer_count": racer_count,
		"total_time_ms": maxi(1, roundi(official_time * 1000.0)),
		"finished": player.status == RaceEntry.STATUS_FINISHED,
		"vehicle_id": vehicle_id,
	})
	summary["race_result"] = race_result if race_result is Dictionary else {
		"ok": false,
		"error_code": "invalid_service_response",
	}
	if best_attempted:
		var best_result: Variant = services.call("record_best_lap",
			track_id, maxi(1, roundi(best_lap_seconds * 1000.0)), vehicle_id
		)
		summary["best_lap_result"] = best_result if best_result is Dictionary else {
			"ok": false,
			"error_code": "invalid_service_response",
		}
	return summary


func _services() -> Node:
	return get_node_or_null("/root/GameServices")


func _audio() -> Node:
	return get_node_or_null("/root/Audio")


func _play_sfx(cue_id: StringName) -> void:
	if _fixture_audio_disabled():
		return
	var audio := _audio()
	if audio != null:
		audio.call("play_sfx", cue_id)


func _set_audio_paused(value: bool) -> void:
	var audio := _audio()
	if audio != null:
		audio.call("set_gameplay_paused", value)


func _start_engine_audio() -> void:
	if _fixture_audio_disabled():
		return
	var audio := _audio()
	if audio != null and audio.has_method("start_engine"):
		audio.call("start_engine")


func _update_engine_audio(command: RaceInput) -> void:
	if _fixture_audio_disabled():
		return
	var audio := _audio()
	if audio == null or not audio.has_method("update_engine") or director == null:
		return
	var player := director.entry(PLAYER_ID)
	if player == null or player.state == null:
		return
	var forward_speed := player.state.forward_speed()
	var maximum_speed := player.vehicle_model.config.maximum_forward_speed
	var reversing := forward_speed < -0.5
	var pedal := command.brake if reversing else command.throttle
	audio.call(
		"update_engine",
		clampf(absf(forward_speed) / maximum_speed, 0.0, 1.0),
		pedal,
		reversing,
		player.state.engine_rpm,
		player.state.shift_ticks_remaining > 0
	)


func _stop_engine_audio() -> void:
	if _fixture_audio_disabled():
		return
	var audio := _audio()
	if audio != null and audio.has_method("stop_engine"):
		audio.call("stop_engine")


func _fixture_audio_disabled() -> bool:
	# Visual fixtures exercise presentation/layout; audio playback has a separate
	# real-stream smoke and is suppressed so movie/UI capture exits are clean.
	return bool(payload.get("visual_fixture", false))


func _vibrate(duration_ms: int, amplitude: float) -> void:
	if SettingsRuntime.allows_vibration(settings):
		Input.vibrate_handheld(duration_ms, clampf(amplitude, 0.0, 1.0))


static func _format_time(seconds: float) -> String:
	var safe_seconds := maxf(seconds, 0.0)
	var minutes := int(safe_seconds) / 60
	var whole_seconds := int(safe_seconds) % 60
	var millis := int(fmod(safe_seconds, 1.0) * 1000.0)
	return "%02d:%02d.%03d" % [minutes, whole_seconds, millis]
