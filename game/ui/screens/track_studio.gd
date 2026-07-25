extends Control

signal navigate_requested(route: String, payload: Dictionary)

const TrackCanvasScript := preload("res://game/track/authoring/track_canvas.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const TrackValidatorType := preload("res://game/track/validation/track_validator.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const WorldPlannerType := preload("res://game/track/features/track_world_feature_planner.gd")
const RaceTrackQueryType := preload("res://game/race/track_query.gd")
const AUTHORING_HELP_TEXT := "Draw one closed loop in any corner style. Sharp turns are rounded automatically; every small-gap fix is shown before you accept it."
# Persistence and compiler authority must never depend on the physical size of
# the phone or desktop canvas that happened to capture the normalized stroke.
const AUTHORING_AUTHORITY_CANVAS_SIZE := Vector2(1280.0, 720.0)

var canvas: TrackCanvas
var status_label: Label
var count_label: Label
var undo_button: Button
var redo_button: Button
var auto_close_button: Button
var confirm_button: Button
var payload: Dictionary = {}
var editing_definition: TrackDefinition
var name_field: LineEdit
var length_option: OptionButton
var width_option: OptionButton
var direction_option: OptionButton
var pit_option: OptionButton
var density_slider: HSlider
var density_label: Label
var bridge_toggle: CheckButton
var _auto_close_accepted := false
var _mode_tabs: TabBar
var _tabs: TabContainer
var _clear_button: Button
var _demo_button: Button
var _start_fix_panel: PanelContainer
var _start_fix_label: Label
var _pending_start_fix_definition: TrackDefinition
var _pending_start_fix_distance := 0.0
# Integration seam for an isolated in-memory profile service. Production uses
# the GameServices autoload; tests can prove the complete BUILD CIRCUIT flow
# without touching the player's real save data.
var persistence_service_override: Object

func set_payload(value: Dictionary) -> void:
	payload = value.duplicate(true)

func _ready() -> void:
	_build()
	if payload.has("editing_track_json"):
		_load_editing_track()
	elif payload.get("visual_fixture", false):
		_load_visual_fixture()

func _load_visual_fixture() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	canvas.load_demo_loop()

func _load_editing_track() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	editing_definition = TrackDefinitionType.from_json(str(payload.get("editing_track_json", "")))
	if not editing_definition.validate_schema().is_valid():
		editing_definition = null
		_on_status("This saved circuit is damaged and cannot be edited safely.", true)
		return
	canvas.load_normalized_loop(editing_definition.control_points)
	_sync_editing_controls()
	_on_status("Editing “%s”. Building will replace its saved geometry." % editing_definition.track_name, false)

func _build() -> void:
	# The project renders from a 1280x720 landscape baseline, but notches and
	# rounded display corners can remove meaningful horizontal room on phones.
	# Keep the base gutter compact and let SafeMarginContainer add the platform
	# insets so the drawing canvas and every action remain inside the safe area.
	var safe := DesignSystem.make_margin(24, 18, 24, 20)
	safe.name = "SafeArea"
	add_child(safe)
	# Apply the preset after parenting. Applying it while the MarginContainer is
	# orphaned can preserve its content minimum as stale full-rect offsets.
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.name = "StudioLayout"
	root.add_theme_constant_override("separation", 12)
	safe.add_child(root)

	var top := HBoxContainer.new()
	top.name = "Header"
	top.add_theme_constant_override("separation", 14)
	root.add_child(top)
	var room_return := bool(payload.get("multiplayer_return", false))
	var back := DesignSystem.screen_button("‹ PRIVATE ROOM" if room_return else "‹ PADDOCK")
	back.pressed.connect(_return_without_building)
	top.add_child(back)
	var heading := DesignSystem.title("TRACK STUDIO", 38)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(heading)
	count_label = DesignSystem.label("0 POINTS", 15, DesignSystem.MUTED)
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(count_label)

	var body := HBoxContainer.new()
	body.name = "Workspace"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	root.add_child(body)

	canvas = TrackCanvasScript.new()
	canvas.name = "TrackCanvas"
	# A smaller hard minimum lets the canvas share a notched 16:9 phone safely;
	# it still expands to consume all space not used by the compact inspector.
	canvas.custom_minimum_size = Vector2(450.0, 360.0)
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.track_changed.connect(_on_track_changed)
	canvas.status_requested.connect(_on_status)
	body.add_child(canvas)

	var panel := PanelContainer.new()
	panel.name = "Inspector"
	panel.custom_minimum_size.x = 290.0
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.96), 24, Color(1.0, 1.0, 1.0, 0.08), 1))
	body.add_child(panel)
	var tools := VBoxContainer.new()
	tools.name = "InspectorContent"
	tools.add_theme_constant_override("separation", 8)
	panel.add_child(tools)
	tools.add_child(DesignSystem.label("ONE LINE. YOUR CIRCUIT.", 15, DesignSystem.MINT))
	# TabContainer reserves its content from the native font-height tab strip,
	# not from a larger custom_minimum_size applied to its internal TabBar. On
	# accessibility scale that made the 48 px DRAW/WORLD touch strip paint over
	# the first rows of inspector content. Keep the touch strip as a real sibling
	# in this VBox so layout allocation and clipping can never overlap.
	_mode_tabs = TabBar.new()
	_mode_tabs.name = "InspectorModeTabs"
	_mode_tabs.custom_minimum_size.y = 48.0
	_mode_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_tabs.add_theme_font_size_override("font_size", 14)
	_mode_tabs.add_tab("DRAW")
	_mode_tabs.add_tab("WORLD")
	_mode_tabs.tab_changed.connect(_on_inspector_mode_changed)
	tools.add_child(_mode_tabs)
	_tabs = TabContainer.new()
	_tabs.name = "InspectorTabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tabs_visible = false
	_tabs.tab_changed.connect(_on_inspector_content_changed)
	tools.add_child(_tabs)
	var draw_scroll := ScrollContainer.new()
	draw_scroll.name = "DRAW"
	draw_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	draw_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	draw_scroll.follow_focus = true
	_tabs.add_child(draw_scroll)
	var draw_tab := VBoxContainer.new()
	draw_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	draw_tab.add_theme_constant_override("separation", 7)
	draw_scroll.add_child(draw_tab)
	var help := DesignSystem.label(AUTHORING_HELP_TEXT, 15, DesignSystem.MUTED)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size.y = 68.0
	draw_tab.add_child(help)

	var history := HBoxContainer.new()
	history.add_theme_constant_override("separation", 10)
	draw_tab.add_child(history)
	undo_button = DesignSystem.screen_button("UNDO")
	undo_button.name = "Undo"
	undo_button.custom_minimum_size = Vector2(100.0, 48.0)
	undo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	undo_button.pressed.connect(func() -> void: canvas.undo())
	history.add_child(undo_button)
	redo_button = DesignSystem.screen_button("REDO")
	redo_button.name = "Redo"
	redo_button.custom_minimum_size = Vector2(100.0, 48.0)
	redo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	redo_button.pressed.connect(func() -> void: canvas.redo())
	history.add_child(redo_button)

	_clear_button = DesignSystem.button("CLEAR", false, true)
	_clear_button.name = "Clear"
	_clear_button.custom_minimum_size = Vector2(0.0, 48.0)
	_clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clear_button.pressed.connect(func() -> void: canvas.clear_track())
	draw_tab.add_child(_clear_button)
	auto_close_button = DesignSystem.button("SNAP GAP CLOSED", false, true)
	auto_close_button.name = "SnapGapClosed"
	auto_close_button.custom_minimum_size = Vector2(0.0, 48.0)
	auto_close_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_close_button.disabled = true
	auto_close_button.tooltip_text = "Accept the highlighted short seam. Undo restores the original stroke."
	auto_close_button.pressed.connect(_accept_auto_close)
	draw_tab.add_child(auto_close_button)
	_demo_button = DesignSystem.button("LOAD DEMO LOOP", false, true)
	_demo_button.name = "LoadDemoLoop"
	_demo_button.custom_minimum_size = Vector2(0.0, 48.0)
	_demo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_demo_button.pressed.connect(func() -> void: canvas.load_demo_loop())
	draw_tab.add_child(_demo_button)
	var draw_note := DesignSystem.label("Use WORLD to configure race direction, scale, width, pits, scenery, and bridges.", 14, DesignSystem.MUTED)
	draw_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	draw_tab.add_child(draw_note)

	var world_scroll := ScrollContainer.new()
	world_scroll.name = "WORLD"
	world_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	world_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	world_scroll.follow_focus = true
	_tabs.add_child(world_scroll)
	var world := VBoxContainer.new()
	world.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	world.add_theme_constant_override("separation", 8)
	world_scroll.add_child(world)
	name_field = LineEdit.new()
	name_field.text = "My Circuit"
	name_field.max_length = 80
	name_field.placeholder_text = "CIRCUIT NAME"
	name_field.custom_minimum_size.y = 48.0
	world.add_child(name_field)
	length_option = _option_row(world, "LENGTH", ["SHORT", "STANDARD", "LONG"], 1)
	width_option = _option_row(world, "ROAD WIDTH", ["NARROW", "STANDARD", "WIDE"], 1)
	direction_option = _option_row(world, "DIRECTION", ["CLOCKWISE", "COUNTER-CLOCKWISE"], 0)
	pit_option = _option_row(world, "PIT LANE", ["NONE", "LEFT", "RIGHT"], 0)
	var density_row := HBoxContainer.new()
	density_row.add_child(DesignSystem.label("SCENERY", 14, DesignSystem.MUTED))
	density_slider = HSlider.new()
	density_slider.min_value = 0.2
	density_slider.max_value = 1.0
	density_slider.step = 0.1
	density_slider.value = 0.6
	density_slider.custom_minimum_size.y = 48.0
	density_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	density_row.add_child(density_slider)
	density_label = DesignSystem.label("60%", 13, DesignSystem.WHITE)
	density_slider.value_changed.connect(func(value: float) -> void: density_label.text = "%d%%" % roundi(value * 100.0))
	density_row.add_child(density_label)
	world.add_child(density_row)
	bridge_toggle = CheckButton.new()
	bridge_toggle.text = "BUILD SAFE BRIDGES AT CROSSINGS"
	bridge_toggle.button_pressed = true
	bridge_toggle.custom_minimum_size.y = 48.0
	bridge_toggle.tooltip_text = "Every intentional self-crossing is declared and assigned one elevated branch."
	world.add_child(bridge_toggle)
	var theme_note := DesignSystem.label("THEME  •  SUNLIT FOREST", 13, DesignSystem.MINT)
	world.add_child(theme_note)
	status_label = DesignSystem.label("Touch or click the canvas to begin.", 16, DesignSystem.MUTED)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size.y = 50.0
	tools.add_child(status_label)
	_start_fix_panel = PanelContainer.new()
	_start_fix_panel.visible = false
	_start_fix_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.12, 0.095, 0.045, 0.98), 16, DesignSystem.GOLD, 2))
	tools.add_child(_start_fix_panel)
	var start_fix_content := VBoxContainer.new()
	start_fix_content.add_theme_constant_override("separation", 7)
	_start_fix_panel.add_child(start_fix_content)
	_start_fix_label = DesignSystem.label("", 13, DesignSystem.WHITE)
	_start_fix_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	start_fix_content.add_child(_start_fix_label)
	var start_fix_actions := HBoxContainer.new()
	start_fix_actions.add_theme_constant_override("separation", 8)
	start_fix_content.add_child(start_fix_actions)
	var accept_start_fix := DesignSystem.button("MOVE GRID HERE", true, true)
	accept_start_fix.custom_minimum_size = Vector2(100.0, 48.0)
	accept_start_fix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	accept_start_fix.pressed.connect(_accept_start_fix)
	start_fix_actions.add_child(accept_start_fix)
	var reject_start_fix := DesignSystem.button("KEEP EDITING", false, true)
	reject_start_fix.custom_minimum_size = Vector2(100.0, 48.0)
	reject_start_fix.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reject_start_fix.pressed.connect(_cancel_start_fix)
	start_fix_actions.add_child(reject_start_fix)
	confirm_button = DesignSystem.button("BUILD CIRCUIT  ›", true)
	confirm_button.name = "BuildCircuit"
	confirm_button.custom_minimum_size.x = 0.0
	confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_button.disabled = true
	confirm_button.pressed.connect(_confirm_track)
	tools.add_child(confirm_button)
	_update_actions()
	# Autowrapped copy briefly reports a tall minimum while the orphaned layout
	# has zero width. Refit once construction settles so that transient minimum
	# never becomes a permanent offset outside a landscape phone viewport.
	safe.call_deferred("set_anchors_and_offsets_preset", Control.PRESET_FULL_RECT)

func _option_row(parent: VBoxContainer, title: String, choices: Array[String], selected: int) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_child(DesignSystem.label(title, 14, DesignSystem.MUTED))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(150.0, 48.0)
	for choice in choices:
		option.add_item(choice)
	option.select(selected)
	row.add_child(option)
	parent.add_child(row)
	return option


func _on_inspector_mode_changed(tab_index: int) -> void:
	if _tabs != null and _tabs.current_tab != tab_index:
		_tabs.current_tab = tab_index


func _on_inspector_content_changed(tab_index: int) -> void:
	# Keep programmatic navigation (tests, restored state, controller focus) in
	# lockstep with the visible mobile selector without creating signal loops.
	if _mode_tabs != null and _mode_tabs.current_tab != tab_index:
		_mode_tabs.current_tab = tab_index


func _sync_editing_controls() -> void:
	if editing_definition == null:
		return
	name_field.text = editing_definition.track_name
	var width_values := [30.0, 36.0, 44.0]
	var closest_width := 0
	var closest_difference := INF
	for index in width_values.size():
		var difference := absf(float(width_values[index]) - editing_definition.track_width)
		if difference < closest_difference:
			closest_difference = difference
			closest_width = index
	width_option.select(closest_width)
	direction_option.select(1 if editing_definition.direction == TrackDefinitionType.DIRECTION_COUNTER_CLOCKWISE else 0)
	pit_option.select(["none", "left", "right"].find(str(editing_definition.pit_side)))
	density_slider.value = editing_definition.decoration_density
	density_label.text = "%d%%" % roundi(editing_definition.decoration_density * 100.0)
	var estimated := maxf(logical_loop_length(
		editing_definition.control_points,
		authority_canvas_size_for(editing_definition)
	), 1.0)
	var ratio := editing_definition.target_length / estimated
	length_option.select(0 if ratio < 0.9 else (2 if ratio > 1.12 else 1))

func _on_track_changed(point_count: int, is_closed: bool) -> void:
	if _pending_start_fix_definition != null:
		_clear_start_fix_review(false)
	var seam_needs_acceptance := canvas.will_snap_close()
	if not is_closed or seam_needs_acceptance:
		_auto_close_accepted = false
	var state_text := "GAP REVIEW" if seam_needs_acceptance else ("LOOP READY" if is_closed else "OPEN")
	count_label.text = "%d POINTS  •  %s" % [point_count, state_text]
	count_label.add_theme_color_override(
		"font_color",
		DesignSystem.GOLD if seam_needs_acceptance else (DesignSystem.MINT if is_closed else DesignSystem.MUTED)
	)
	confirm_button.disabled = point_count < TrackCanvas.MIN_POINT_COUNT or not is_closed or seam_needs_acceptance
	_update_actions()

func _on_status(message: String, is_error: bool) -> void:
	status_label.text = message
	status_label.add_theme_color_override("font_color", DesignSystem.CORAL if is_error else DesignSystem.MUTED)

func _update_actions() -> void:
	if undo_button == null:
		return
	undo_button.disabled = not canvas.can_undo()
	redo_button.disabled = not canvas.can_redo()
	auto_close_button.disabled = not canvas.will_snap_close()

func _accept_auto_close() -> void:
	if canvas.accept_auto_close():
		_auto_close_accepted = true
		_play_sfx(&"confirm")
		_vibrate_feedback(35, 0.25)


static func inherit_edit_identity(definition: TrackDefinition, previous: TrackDefinition) -> void:
	if definition == null or previous == null:
		return
	definition.track_id = previous.track_id
	definition.author_id = previous.author_id
	definition.created_at_timestamp = previous.created_at_timestamp
	definition.deterministic_seed = previous.deterministic_seed
	definition.start_finish_distance = previous.start_finish_distance


static func proposal_preview_distance(current_distance: float, proposed_distance: float) -> float:
	return proposed_distance - current_distance


static func authority_canvas_size_for(previous: TrackDefinition = null) -> Vector2:
	if previous != null and QuantizationType.is_finite_vector2(previous.canvas_size) \
			and previous.canvas_size.x > 0.0 and previous.canvas_size.y > 0.0:
		# Existing definitions retain their stored authority envelope so editing
		# cannot silently reshape or re-hash a legacy saved circuit.
		return QuantizationType.vector2(previous.canvas_size)
	return AUTHORING_AUTHORITY_CANVAS_SIZE


static func logical_loop_length(points: PackedVector2Array, authority_size: Vector2) -> float:
	if points.size() < 2 or not QuantizationType.is_finite_vector2(authority_size) \
			or authority_size.x <= 0.0 or authority_size.y <= 0.0:
		return 0.0
	var length := 0.0
	for index in range(1, points.size()):
		length += ((points[index] - points[index - 1]) * authority_size).length()
	if points[0] != points[-1]:
		length += ((points[0] - points[-1]) * authority_size).length()
	return length


static func create_authority_definition(
		loop: PackedVector2Array,
		previous: TrackDefinition,
		track_width: float,
		track_name: String,
		length_scale: float
	) -> TrackDefinition:
	var authority_size := authority_canvas_size_for(previous)
	var definition := TrackDefinitionType.create(
		loop, authority_size, track_width, track_name
	)
	definition.target_length = QuantizationType.scalar(clampf(
		logical_loop_length(loop, authority_size) * length_scale,
		900.0,
		3000.0
	))
	definition.refresh_content_hash()
	return definition

func _confirm_track() -> void:
	var authority_size := authority_canvas_size_for(editing_definition)
	var loop := canvas.build_normalized_loop(false, authority_size)
	if loop.is_empty():
		_on_status("Close the line inside the glowing start gate before building the circuit.", true)
		_vibrate_feedback(90, 0.45)
		return
	confirm_button.disabled = true
	_on_status("Validating curvature, bounds, crossings, and the start grid…", false)
	var track_width: float = float([30.0, 36.0, 44.0][width_option.selected])
	var track_name := name_field.text.strip_edges()
	if track_name.is_empty():
		track_name = "My Circuit"
	var length_scale: float = float([0.82, 1.0, 1.22][length_option.selected])
	var definition := create_authority_definition(
		loop, editing_definition, track_width, track_name, length_scale
	)
	definition.decoration_density = QuantizationType.scalar(density_slider.value, 0.000001)
	definition.direction = TrackDefinitionType.DIRECTION_COUNTER_CLOCKWISE if direction_option.selected == 1 else TrackDefinitionType.DIRECTION_CLOCKWISE
	definition.pit_side = [TrackDefinitionType.PIT_NONE, TrackDefinitionType.PIT_LEFT, TrackDefinitionType.PIT_RIGHT][pit_option.selected]
	definition.theme = &"forest"
	var timestamp := int(Time.get_unix_time_from_system())
	definition.created_at_timestamp = timestamp
	definition.updated_at_timestamp = timestamp
	if editing_definition != null:
		inherit_edit_identity(definition, editing_definition)
		# The visible WORLD controls intentionally replace mutable world settings.
	else:
		definition.deterministic_seed = int(definition.calculated_content_hash().left(8).hex_to_int())
		definition.track_id = ""
		definition.track_id = definition.derived_track_id()
	var result := _compile_with_declared_bridges(definition)
	# A finger-drawn seam rarely lands on a full grid straight. Never move the
	# authored grid silently: preview the exact deterministic proposal and wait
	# for an explicit acceptance.
	if result.track != null and result.report.has_code(&"geometry.start_straight_too_short"):
		_begin_start_fix_review(definition, result)
		return
	_finalize_track(definition, result)


func _compile_with_declared_bridges(definition: TrackDefinition) -> TrackCompileResult:
	# Crossings are never guessed silently: the WORLD toggle is the explicit
	# player choice to declare every detected branch pair as a safe bridge.
	definition.bridge_crossings.clear()
	definition.refresh_content_hash()
	var result: TrackCompileResult = TrackCompilerType.compile(definition)
	if result.track == null or not bridge_toggle.button_pressed:
		return result
	var crossings := TrackValidatorType.find_crossings(result.track)
	for crossing_index in crossings.size():
		var crossing: Dictionary = crossings[crossing_index]
		definition.bridge_crossings.append(BridgeDefinitionType.new(
			"bridge-%02d" % (crossing_index + 1),
			QuantizationType.scalar(float(crossing["distance_a"])),
			QuantizationType.scalar(float(crossing["distance_b"])),
			BridgeDefinitionType.OVERPASS_A if crossing_index % 2 == 0 else BridgeDefinitionType.OVERPASS_B
		))
	if not crossings.is_empty():
		definition.refresh_content_hash()
		result = TrackCompilerType.compile(definition)
	return result


func _begin_start_fix_review(definition: TrackDefinition, result: TrackCompileResult) -> void:
	_pending_start_fix_definition = definition.copy()
	_pending_start_fix_distance = result.track.suggested_start_finish_distance
	var query := RaceTrackQueryType.from_compiled(result.track)
	# Compiled route distance zero is the authored gate because the compiler has
	# already rotated its samples by definition.start_finish_distance. Convert
	# the absolute proposal back into this preview's route-relative distance.
	var current_sample := query.sample_at_distance(0.0)
	var proposed_sample := query.sample_at_distance(
		proposal_preview_distance(definition.start_finish_distance, _pending_start_fix_distance)
	)
	if current_sample.is_empty() or proposed_sample.is_empty():
		_pending_start_fix_definition = null
		confirm_button.disabled = false
		_on_status("The proposed grid position could not be previewed safely. Adjust the line and try again.", true)
		_play_sfx(&"error")
		return
	canvas.show_start_fix_preview(
		current_sample.get("position", Vector2.ZERO),
		proposed_sample.get("position", Vector2.ZERO)
	)
	_start_fix_label.text = "GRID POSITION REVIEW\nCoral is your current gate. Mint is the nearest safe 12-car straight. The road shape will not change."
	_start_fix_panel.visible = true
	_set_authoring_enabled(false)
	_on_status("Review the coral-to-mint grid move, then accept it or keep editing.", false)
	_play_sfx(&"click")


func _accept_start_fix() -> void:
	if _pending_start_fix_definition == null:
		return
	var definition := _pending_start_fix_definition
	definition.start_finish_distance = QuantizationType.scalar(_pending_start_fix_distance)
	_clear_start_fix_review(false)
	var result := _compile_with_declared_bridges(definition)
	if result.track != null and result.report.has_code(&"geometry.start_straight_too_short"):
		_set_authoring_enabled(true)
		_on_status("That grid proposal is no longer safe. Adjust the loop and validate again.", true)
		_play_sfx(&"error")
		return
	_play_sfx(&"confirm")
	_vibrate_feedback(35, 0.25)
	_finalize_track(definition, result)


func _cancel_start_fix() -> void:
	if _pending_start_fix_definition == null:
		return
	_clear_start_fix_review(true)
	_on_status("Grid move cancelled. Adjust the start area or validate again when ready.", false)


func _clear_start_fix_review(reenable: bool) -> void:
	_pending_start_fix_definition = null
	_pending_start_fix_distance = 0.0
	if _start_fix_panel != null:
		_start_fix_panel.visible = false
	if canvas != null:
		canvas.clear_start_fix_preview()
	if reenable:
		_set_authoring_enabled(true)


func _set_authoring_enabled(enabled: bool) -> void:
	canvas.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	_mode_tabs.visible = enabled
	_tabs.visible = enabled
	name_field.editable = enabled
	length_option.disabled = not enabled
	width_option.disabled = not enabled
	direction_option.disabled = not enabled
	pit_option.disabled = not enabled
	density_slider.editable = enabled
	bridge_toggle.disabled = not enabled
	_clear_button.disabled = not enabled
	_demo_button.disabled = not enabled
	for tab_index in _tabs.get_tab_count():
		_tabs.set_tab_disabled(tab_index, not enabled)
		_mode_tabs.set_tab_disabled(tab_index, not enabled)
	if enabled:
		_on_track_changed(canvas.points.size(), canvas.is_loop_closed())
	else:
		undo_button.disabled = true
		redo_button.disabled = true
		auto_close_button.disabled = true
		confirm_button.disabled = true


func _finalize_track(definition: TrackDefinition, result: TrackCompileResult) -> void:
	if not result.succeeded():
		_set_authoring_enabled(true)
		_on_status(_first_validation_error(result), true)
		_play_sfx(&"error")
		_vibrate_feedback(110, 0.55)
		return
	var world_plan := WorldPlannerType.plan(definition, result.track)
	if not world_plan.get("valid", false):
		_set_authoring_enabled(true)
		_on_status("The circuit geometry compiled, but its world features could not be generated safely.", true)
		_play_sfx(&"error")
		_vibrate_feedback(110, 0.55)
		return
	var services: Object = persistence_service_override \
		if persistence_service_override != null else get_node_or_null("/root/GameServices")
	if services == null:
		_set_authoring_enabled(true)
		_on_status("Local profile services are unavailable. The circuit was not changed.", true)
		_play_sfx(&"error")
		return
	var save_result: Dictionary = services.call("save_track", definition, {
		"display_name": definition.track_name,
		"theme": str(definition.theme),
		"point_count": definition.control_points.size(),
	})
	if not save_result.get("ok", false):
		_set_authoring_enabled(true)
		_on_status(str(save_result.get("message", "The circuit could not be saved locally.")), true)
		_play_sfx(&"error")
		_vibrate_feedback(110, 0.55)
		return
	# Race exactly the bytes installed in the atomic local save. Repository
	# metadata normalization may refresh timestamps/content hashes.
	var persisted: TrackDefinition = services.call("get_track", definition.track_id)
	if persisted != null:
		definition = persisted
		result = TrackCompilerType.compile(definition)
	if not result.succeeded():
		_set_authoring_enabled(true)
		_on_status("The saved circuit failed its verification read-back.", true)
		_play_sfx(&"error")
		_vibrate_feedback(110, 0.55)
		return
	var turns_auto_smoothed := result.report.has_code(&"geometry.turns_auto_smoothed")
	_on_status(
		"Sharp corners rounded automatically. Building the deterministic race world…"
		if turns_auto_smoothed else
		"Circuit validated. Building the deterministic race world…",
		false
	)
	_play_sfx(&"confirm")
	_vibrate_feedback(45, 0.30)
	if bool(payload.get("multiplayer_return", false)):
		navigate_requested.emit("multiplayer", multiplayer_completion_payload(
			definition, str(payload.get("return_room_code", ""))
		))
		return
	navigate_requested.emit("tour", {
		"track_definition_json": definition.canonical_json(true),
		"source_hash": result.track.source_hash,
		"compiled_hash": result.track.compile_hash,
		"source": "studio",
		"auto_closed": _auto_close_accepted,
		"auto_smoothed": turns_auto_smoothed,
		"display_name": definition.track_name,
		"location": "CUSTOM CREATION",
		"accent": DesignSystem.MINT.to_html(),
		"laps": 3,
		"difficulty": "standard",
		"collisions": true,
	})


func _return_without_building() -> void:
	if bool(payload.get("multiplayer_return", false)):
		navigate_requested.emit("multiplayer", multiplayer_cancel_payload(str(payload.get("return_room_code", ""))))
	else:
		navigate_requested.emit("home", {})


static func multiplayer_completion_payload(definition: TrackDefinition, room_code: String) -> Dictionary:
	if definition == null:
		return {}
	return {
		"room_track_definition_json": definition.canonical_json(true),
		"return_room_code": room_code.strip_edges().to_upper(),
	}


static func multiplayer_cancel_payload(room_code: String) -> Dictionary:
	return {"return_room_code": room_code.strip_edges().to_upper()}

func _first_validation_error(result: TrackCompileResult) -> String:
	for issue in result.report.issues:
		if issue.severity_name() == "error":
			return issue.message
	return "This line cannot form a safe circuit yet. Try a wider, smoother loop."

func _vibrate_feedback(duration_ms: int, amplitude: float) -> void:
	var services := get_node_or_null("/root/GameServices")
	if services != null and services.call("settings").vibration_enabled:
		Input.vibrate_handheld(duration_ms, clampf(amplitude, 0.0, 1.0))


func _play_sfx(cue_id: StringName) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play_sfx"):
		audio.call("play_sfx", cue_id)
