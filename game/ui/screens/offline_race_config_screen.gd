extends Control

signal navigate_requested(route: String, payload: Dictionary)

const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackRendererType := preload("res://game/track/rendering/track_renderer.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")

const DEFAULT_LAPS := 3
const DEFAULT_DIFFICULTY := "standard"
const DEFAULT_GRID_SIZE := 12
const MIN_GRID_SIZE := 2
const MAX_GRID_SIZE := 12
const ALLOWED_LAPS := [3, 5, 8]
const ALLOWED_DIFFICULTIES := ["relaxed", "standard", "expert"]

var payload: Dictionary = {}
var _laps := DEFAULT_LAPS
var _difficulty := DEFAULT_DIFFICULTY
var _grid_size := DEFAULT_GRID_SIZE
var _collisions := true
var _renderer: TrackRenderer
var _summary_label: Label
var _status_label: Label
var _start_button: Button


func set_payload(value: Dictionary) -> void:
	payload = value.duplicate(true)


static func validated_lap_count(value: Variant) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return DEFAULT_LAPS
	if is_nan(float(value)) or is_inf(float(value)):
		return DEFAULT_LAPS
	var requested := int(value)
	return requested if requested in ALLOWED_LAPS else DEFAULT_LAPS


static func validated_difficulty(value: Variant) -> String:
	var requested := str(value).strip_edges().to_lower()
	return requested if requested in ALLOWED_DIFFICULTIES else DEFAULT_DIFFICULTY


static func validated_grid_size(value: Variant) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return DEFAULT_GRID_SIZE
	if is_nan(float(value)) or is_inf(float(value)):
		return DEFAULT_GRID_SIZE
	return clampi(roundi(float(value)), MIN_GRID_SIZE, MAX_GRID_SIZE)


static func validated_collisions(value: Variant) -> bool:
	return bool(value) if typeof(value) == TYPE_BOOL else true


static func configured_payload(
	base: Dictionary,
	laps: Variant,
	difficulty: Variant,
	grid_size: Variant,
	collisions: Variant
	) -> Dictionary:
	var output := base.duplicate(true)
	output.erase("_config_return_route")
	output["laps"] = validated_lap_count(laps)
	output["difficulty"] = validated_difficulty(difficulty)
	output["grid_size"] = validated_grid_size(grid_size)
	output["collisions"] = validated_collisions(collisions)
	return output


func _ready() -> void:
	if not payload.has("track_definition_json") and bool(payload.get("visual_fixture", false)):
		_apply_visual_fixture()
	_laps = validated_lap_count(payload.get("laps", DEFAULT_LAPS))
	_difficulty = validated_difficulty(payload.get("difficulty", DEFAULT_DIFFICULTY))
	_grid_size = validated_grid_size(payload.get("grid_size", DEFAULT_GRID_SIZE))
	_collisions = validated_collisions(payload.get("collisions", true))
	_build()
	_verify_and_render_track()
	_refresh_summary()


func _apply_visual_fixture() -> void:
	var fixture := CatalogType.race_payload("builtin-evergreen-oval", 3, "standard")
	fixture["display_name"] = "EVERGREEN OVAL"
	fixture["location"] = "MISTWOOD PARK"
	fixture["accent"] = "5fffd0"
	fixture["visual_fixture"] = true
	payload = fixture


func _build() -> void:
	var safe := DesignSystem.make_margin(42, 28, 42, 30)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	safe.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	root.add_child(header)
	var back := DesignSystem.screen_button("‹ TRACK TOUR")
	back.pressed.connect(_return_to_source)
	header.add_child(back)
	var title := DesignSystem.title("RACE SETUP", 38)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_status_label = DesignSystem.label("VERIFYING CIRCUIT…", 14, DesignSystem.MINT)
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_status_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	root.add_child(body)
	body.add_child(_build_track_card())
	body.add_child(_build_options_card())


func _build_track_card() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.035, 0.075, 0.135, 0.97), 28, Color(0.37, 1.0, 0.82, 0.16), 1
	))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	panel.add_child(content)
	var title_row := HBoxContainer.new()
	content.add_child(title_row)
	var labels := VBoxContainer.new()
	labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(labels)
	var track_name := DesignSystem.title(str(payload.get("display_name", "YOUR CIRCUIT")), 31)
	track_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	labels.add_child(track_name)
	labels.add_child(DesignSystem.label(str(payload.get("location", "CUSTOM CREATION")), 14, DesignSystem.MUTED))
	var source_name := str(payload.get("source", "offline")).replace("_", " ").to_upper()
	title_row.add_child(DesignSystem.label(source_name + " • VERIFIED", 13, DesignSystem.GOLD))
	var frame := PanelContainer.new()
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		DesignSystem.GRASS, 20, Color(1.0, 1.0, 1.0, 0.08), 1
	))
	content.add_child(frame)
	_renderer = TrackRendererType.new()
	_renderer.custom_minimum_size = Vector2(650.0, 370.0)
	_renderer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_renderer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_renderer.clip_contents = true
	frame.add_child(_renderer)
	var help := DesignSystem.label(
		"Three official timing sectors are generated from the ordered race checkpoints.",
		14,
		DesignSystem.MUTED
	)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(help)
	return panel


func _build_options_card() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 410.0
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.047, 0.095, 0.17, 0.98), 28, Color(1.0, 1.0, 1.0, 0.09), 1
	))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	panel.add_child(content)
	content.add_child(DesignSystem.label("OFFLINE RACE CONTROL", 15, DesignSystem.MINT))
	content.add_child(DesignSystem.label("LAP COUNT", 12, DesignSystem.MUTED))
	var laps := OptionButton.new()
	laps.custom_minimum_size.y = 43.0
	for value in ALLOWED_LAPS:
		laps.add_item("%d LAPS" % value, value)
	_select_id(laps, _laps)
	laps.item_selected.connect(func(index: int) -> void:
		_laps = laps.get_item_id(index)
		_refresh_summary()
	)
	content.add_child(laps)

	content.add_child(DesignSystem.label("AI DIFFICULTY", 12, DesignSystem.MUTED))
	var difficulty := OptionButton.new()
	difficulty.custom_minimum_size.y = 43.0
	for index in ALLOWED_DIFFICULTIES.size():
		difficulty.add_item(["RELAXED", "STANDARD", "EXPERT"][index], index)
	difficulty.select(ALLOWED_DIFFICULTIES.find(_difficulty))
	difficulty.item_selected.connect(func(index: int) -> void:
		_difficulty = ALLOWED_DIFFICULTIES[index]
		_refresh_summary()
	)
	content.add_child(difficulty)

	content.add_child(DesignSystem.label("STARTING GRID", 12, DesignSystem.MUTED))
	var grid := OptionButton.new()
	grid.custom_minimum_size.y = 43.0
	for value in range(MIN_GRID_SIZE, MAX_GRID_SIZE + 1):
		grid.add_item("%d DRIVERS  •  YOU + %d AI" % [value, value - 1], value)
	_select_id(grid, _grid_size)
	grid.item_selected.connect(func(index: int) -> void:
		_grid_size = grid.get_item_id(index)
		_refresh_summary()
	)
	content.add_child(grid)

	var collisions := CheckButton.new()
	collisions.text = "CAR-TO-CAR COLLISIONS"
	collisions.custom_minimum_size.y = 42.0
	collisions.button_pressed = _collisions
	collisions.toggled.connect(func(value: bool) -> void:
		_collisions = value
		_refresh_summary()
	)
	content.add_child(collisions)

	_summary_label = DesignSystem.label("", 15, DesignSystem.WHITE)
	_summary_label.custom_minimum_size.y = 58.0
	_summary_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary_label.add_theme_color_override("font_color", DesignSystem.GOLD)
	content.add_child(_summary_label)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(spacer)
	_start_button = DesignSystem.button("START OFFLINE RACE  ›", true, true)
	_start_button.custom_minimum_size.y = 54.0
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.pressed.connect(_start_race)
	content.add_child(_start_button)
	return panel


func _select_id(option: OptionButton, item_id: int) -> void:
	for index in option.item_count:
		if option.get_item_id(index) == item_id:
			option.select(index)
			return
	option.select(0)


func _verify_and_render_track() -> void:
	var definition: TrackDefinition = TrackDefinitionType.from_json(str(payload.get("track_definition_json", "")))
	var result: TrackCompileResult = TrackCompilerType.compile(definition)
	var failure := ""
	if result == null or not result.succeeded() or result.track == null:
		failure = "CIRCUIT VERIFICATION FAILED"
	else:
		var expected_source := str(payload.get("source_hash", result.track.source_hash))
		var expected_compile := str(payload.get("compiled_hash", result.track.compile_hash))
		if expected_source != result.track.source_hash or expected_compile != result.track.compile_hash:
			failure = "CIRCUIT HASH MISMATCH"
		elif not _renderer.set_track_world(definition, result.track):
			failure = "CIRCUIT WORLD FAILED"
	if not failure.is_empty():
		_status_label.text = failure
		_status_label.add_theme_color_override("font_color", DesignSystem.CORAL)
		_start_button.disabled = true
		_start_button.text = "RACE UNAVAILABLE"
		return
	_status_label.text = "%d m • READY" % roundi(result.track.total_length)
	_status_label.add_theme_color_override("font_color", DesignSystem.MINT)


func _refresh_summary() -> void:
	if _summary_label == null:
		return
	_summary_label.text = "%d LAPS  •  %d DRIVERS\n%s AI  •  COLLISIONS %s" % [
		_laps,
		_grid_size,
		_difficulty.to_upper(),
		"ON" if _collisions else "OFF",
	]


func _start_race() -> void:
	navigate_requested.emit(
		"race",
		configured_payload(payload, _laps, _difficulty, _grid_size, _collisions)
	)


func _return_to_source() -> void:
	var return_route := str(payload.get("_config_return_route", "tour"))
	if return_route == "tracks":
		navigate_requested.emit("tracks", {})
		return
	var return_payload := payload.duplicate(true)
	return_payload.erase("_config_return_route")
	navigate_requested.emit("tour", return_payload)
