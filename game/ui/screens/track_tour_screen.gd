extends Control

signal navigate_requested(route: String, payload: Dictionary)

const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackRendererType := preload("res://game/track/rendering/track_renderer.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")

class TourBeacon extends Node2D:
	var accent := Color("5fffd0")
	func _draw() -> void:
		draw_circle(Vector2.ZERO, 18.0, Color(0.0, 0.0, 0.0, 0.36))
		draw_circle(Vector2.ZERO, 11.0, Color(accent, 0.24))
		draw_arc(Vector2.ZERO, 11.0, 0.0, TAU, 32, accent, 3.0, true)
		draw_polygon(PackedVector2Array([Vector2(13.0, 0.0), Vector2(-5.0, -6.0), Vector2(-5.0, 6.0)]), PackedColorArray([accent]))

class TourMinimap extends Control:
	var plan_data: Dictionary = {}

	func set_plan(value: Dictionary) -> void:
		plan_data = value.duplicate(true)
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.055, 0.09, 0.94), true)
		if not bool(plan_data.get("valid", false)):
			return
		var route: Variant = plan_data.get("polyline", PackedVector2Array())
		var target_size: Vector2 = plan_data.get("target_size", Vector2(256.0, 160.0))
		if not route is PackedVector2Array or route.size() < 2:
			return
		var scale := minf((size.x - 20.0) / target_size.x, (size.y - 16.0) / target_size.y)
		var offset := (size - target_size * scale) * 0.5
		var display_route := PackedVector2Array()
		for point in route:
			display_route.append(offset + point * scale)
		draw_polyline(display_route, Color(0.0, 0.0, 0.0, 0.42), 7.0, true)
		draw_polyline(display_route, Color("dce7ec"), 4.0, true)
		draw_polyline(display_route, DesignSystem.MINT, 2.0, true)
		var markers: Variant = plan_data.get("markers", [])
		if not markers is Array:
			return
		for marker_variant in markers:
			if not marker_variant is Dictionary or not marker_variant.get("position") is Vector2:
				continue
			var kind := str(marker_variant.get("kind", ""))
			var color := DesignSystem.CYAN
			var radius := 3.0
			if kind == "start_finish":
				color = DesignSystem.GOLD
				radius = 5.0
			elif kind == "bridge":
				color = DesignSystem.CORAL
				radius = 4.5
			elif kind.begins_with("pit_"):
				color = DesignSystem.MINT
				radius = 4.0
			var position: Vector2 = offset + marker_variant["position"] * scale
			draw_circle(position, radius + 2.0, Color(0.0, 0.0, 0.0, 0.35))
			draw_circle(position, radius, color)

var payload: Dictionary = {}
var _definition: TrackDefinition
var _compiled: CompiledTrack
var _world: Dictionary = {}
var _renderer: TrackRenderer
var _beacon: TourBeacon
var _progress := 0.0
var _playing := true
var _progress_label: Label
var _highlight_label: Label
var _play_button: Button
var _minimap: TourMinimap
var _tour_highlights: Array[Dictionary] = []
var _active_highlight := -1
var _tour_duration := 16.0


func set_payload(value: Dictionary) -> void:
	payload = value.duplicate(true)


func _ready() -> void:
	set_process(true)
	if not payload.has("track_definition_json") and payload.get("visual_fixture", false):
		_apply_visual_fixture()
	_build()
	_load_track()


func _apply_visual_fixture() -> void:
	payload = CatalogType.race_payload("builtin-evergreen-oval", 3, "standard")
	payload["display_name"] = "EVERGREEN OVAL"
	payload["location"] = "MISTWOOD PARK"
	payload["accent"] = "5fffd0"


func _build() -> void:
	var safe := DesignSystem.make_margin(42, 28, 42, 30)
	add_child(safe)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	safe.add_child(root)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	root.add_child(top)
	var back := DesignSystem.screen_button("‹ CIRCUITS")
	back.pressed.connect(func() -> void: navigate_requested.emit("tracks", {}))
	top.add_child(back)
	var title := DesignSystem.title("TRACK TOUR", 38)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_progress_label = DesignSystem.label("GENERATING TOUR…", 14, DesignSystem.MINT)
	_progress_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_progress_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	root.add_child(body)
	var viewport_panel := PanelContainer.new()
	viewport_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(DesignSystem.GRASS, 28, Color(0.37, 1.0, 0.82, 0.16), 1))
	body.add_child(viewport_panel)
	_renderer = TrackRendererType.new()
	# Leave room for the overview card's scrollbar and scaled status copy at
	# the 1280x720 / 1.30x accessibility ceiling. The renderer still expands
	# into all remaining width; this only removes a six-pixel minimum-width
	# conflict between the two panels.
	_renderer.custom_minimum_size = Vector2(760.0, 480.0)
	_renderer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_renderer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_renderer.clip_contents = true
	viewport_panel.add_child(_renderer)
	_beacon = TourBeacon.new()
	_beacon.z_index = 100
	_renderer.add_child(_beacon)

	var side := PanelContainer.new()
	side.custom_minimum_size.x = 330.0
	side.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.97), 26, Color(1.0, 1.0, 1.0, 0.08), 1))
	body.add_child(side)
	var side_scroll := ScrollContainer.new()
	side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(side_scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 9)
	side_scroll.add_child(content)
	content.add_child(DesignSystem.label("CIRCUIT OVERVIEW", 15, DesignSystem.MINT))
	var name := DesignSystem.title(str(payload.get("display_name", "YOUR CIRCUIT")), 28)
	name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(name)
	var location := DesignSystem.label(str(payload.get("location", "CUSTOM CREATION")), 14, DesignSystem.MUTED)
	content.add_child(location)
	_minimap = TourMinimap.new()
	_minimap.custom_minimum_size = Vector2(300.0, 108.0)
	_minimap.clip_contents = true
	content.add_child(_minimap)
	_highlight_label = DesignSystem.label("Inspecting start and grid…", 16, DesignSystem.WHITE)
	_highlight_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_highlight_label.custom_minimum_size.y = 72.0
	content.add_child(_highlight_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer)
	_play_button = DesignSystem.button("PAUSE TOUR", false, true)
	_play_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_play_button.custom_minimum_size.y = 48.0
	_play_button.pressed.connect(_toggle_tour)
	content.add_child(_play_button)
	var race := DesignSystem.button("CONFIGURE RACE  ›", true, true)
	race.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	race.custom_minimum_size.y = 48.0
	race.pressed.connect(func() -> void: navigate_requested.emit("race_config", payload.duplicate(true)))
	content.add_child(race)
	safe.call_deferred("set_anchors_and_offsets_preset", Control.PRESET_FULL_RECT)


func _load_track() -> void:
	_definition = TrackDefinitionType.from_json(str(payload.get("track_definition_json", "")))
	var result: TrackCompileResult = CompilerType.compile(_definition)
	var actual_source := result.track.source_hash if result.track != null else ""
	var actual_compile := result.track.compile_hash if result.track != null else ""
	var source_matches := str(payload.get("source_hash", actual_source)) == actual_source
	var compile_matches := str(payload.get("compiled_hash", actual_compile)) == actual_compile
	if not result.succeeded() or not source_matches or not compile_matches:
		_playing = false
		_progress_label.text = "TRACK VERIFICATION FAILED"
		_progress_label.add_theme_color_override("font_color", DesignSystem.CORAL)
		_highlight_label.text = "This circuit cannot be toured or raced safely. Return to the circuit list."
		return
	_compiled = result.track
	if not _renderer.set_track_world(_definition, _compiled):
		_playing = false
		_progress_label.text = "WORLD GENERATION FAILED"
		_progress_label.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	_world = _renderer.get_world_plan()
	var tour: Dictionary = _renderer.get_tour_plan()
	var summary: Variant = tour.get("summary", {})
	if summary is Dictionary:
		_tour_duration = maxf(float(summary.get("tour_duration", 16.0)), 1.0)
		_progress_label.text = str(summary.get(
			"headline",
			"%d m • %d CORNER SECTIONS" % [_compiled.total_length, _compiled.corner_sections.size()]
		)).to_upper()
	else:
		_progress_label.text = "%d m • %d CORNER SECTIONS" % [_compiled.total_length, _compiled.corner_sections.size()]
	_prepare_highlights(tour)
	_minimap.set_plan(_renderer.get_minimap_plan())
	_renderer.set_tour_progress(0.0)
	_update_planned_highlight(0.0)
	_beacon.accent = Color(str(payload.get("accent", "5fffd0")))
	_beacon.queue_redraw()
	var services := get_node_or_null("/root/GameServices")
	var settings_value: Variant = services.call("settings") if services != null else null
	if settings_value is GameSettings and settings_value.reduced_motion:
		_playing = false
		_renderer.clear_tour_camera()
		_play_button.text = "PLAY TOUR"


func _process(delta: float) -> void:
	if not _playing or _compiled == null:
		return
	_progress = fposmod(_progress + delta / _tour_duration, 1.0)
	_renderer.set_tour_progress(_progress)
	_beacon.position = _renderer.get_track_point(_progress)
	_beacon.rotation = _renderer.get_track_tangent(_progress).angle()
	_update_planned_highlight(_progress * _compiled.total_length)


func _toggle_tour() -> void:
	_playing = not _playing
	_play_button.text = "PAUSE TOUR" if _playing else "RESUME TOUR"
	_play_sfx(&"click")


func _play_sfx(cue_id: StringName) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play_sfx"):
		audio.call("play_sfx", cue_id)


func _prepare_highlights(tour: Dictionary) -> void:
	_tour_highlights.clear()
	var highlights: Variant = tour.get("highlights", [])
	if highlights is Array:
		for value in highlights:
			if value is Dictionary:
				_tour_highlights.append(value.duplicate(true))
	_tour_highlights.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return float(first.get("lap_distance", 0.0)) < float(second.get("lap_distance", 0.0))
	)


func _update_planned_highlight(lap_distance: float) -> void:
	if _tour_highlights.is_empty():
		_highlight_label.text = "Follow the generated racing line from the start grid through every sector."
		return
	var selected := _tour_highlights.size() - 1
	for index in _tour_highlights.size():
		if float(_tour_highlights[index].get("lap_distance", 0.0)) <= lap_distance:
			selected = index
		else:
			break
	if selected == _active_highlight:
		return
	_active_highlight = selected
	var highlight := _tour_highlights[selected]
	_highlight_label.text = _highlight_copy(
		str(highlight.get("kind", "sector")),
		str(highlight.get("highlight_id", ""))
	)


func _highlight_copy(kind: String, highlight_id: String) -> String:
	match kind:
		"start_finish":
			return "Start gantry and launch grid. Build speed cleanly before committing to the opening sector."
		"corner":
			return "%s: brake in a straight line, rotate once, then protect exit speed." % highlight_id.replace("-", " ").capitalize()
		"pit_entry":
			return "Pit entry: leave the racing line early and settle the car before the merge lane narrows."
		"pit_exit":
			return "Pit exit: hold the marked lane until the merge is clear, then rejoin smoothly."
		"bridge":
			return "%s overpass: the elevated deck and ground branch use separate collision layers." % highlight_id.replace("-", " ").capitalize()
		_:
			return "Generated sector highlight. Read the road ahead and carry momentum into the next feature."
