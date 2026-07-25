extends Control

signal navigate_requested(route: String, payload: Dictionary)

const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackThumbnailScript := preload("res://game/ui/components/track_thumbnail.gd")

var _list: VBoxContainer
var _status: Label
var _delete_panel: PanelContainer
var _delete_label: Label
var _pending_delete_id := ""


func _ready() -> void:
	_build()
	_refresh()


func _build() -> void:
	var safe := DesignSystem.make_margin(42, 28, 42, 32)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	safe.add_child(root)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	root.add_child(top)
	var back := DesignSystem.screen_button("‹ PADDOCK")
	back.pressed.connect(func() -> void: navigate_requested.emit("home", {}))
	top.add_child(back)
	var heading := DesignSystem.title("SAVED TRACKS", 38)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(heading)
	_status = DesignSystem.label("DEVICE LOCAL", 14, DesignSystem.MINT)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_status)
	var create := DesignSystem.button("+ NEW CIRCUIT", true, true)
	create.pressed.connect(func() -> void: navigate_requested.emit("studio", {}))
	top.add_child(create)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	scroll.add_child(_list)

	_delete_panel = PanelContainer.new()
	_delete_panel.visible = false
	_delete_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.14, 0.06, 0.09, 0.98), 18, DesignSystem.CORAL, 2))
	root.add_child(_delete_panel)
	var confirmation := HBoxContainer.new()
	confirmation.add_theme_constant_override("separation", 12)
	_delete_panel.add_child(confirmation)
	_delete_label = DesignSystem.label("", 16, DesignSystem.WHITE)
	_delete_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirmation.add_child(_delete_label)
	var confirm := DesignSystem.button("DELETE", false, true)
	confirm.add_theme_color_override("font_color", DesignSystem.CORAL)
	confirm.pressed.connect(_confirm_delete)
	confirmation.add_child(confirm)
	var cancel := DesignSystem.button("CANCEL", false, true)
	cancel.pressed.connect(_cancel_delete)
	confirmation.add_child(cancel)


func _refresh() -> void:
	for child in _list.get_children():
		child.queue_free()
	var services := _services()
	if services == null or not bool(services.call("is_ready")):
		_list.add_child(_empty_state("Local profile could not be loaded. Open Settings to delete the damaged local data safely."))
		_status.text = "PROFILE NEEDS ATTENTION"
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	var entries_variant: Variant = services.call("list_track_metadata")
	var entries: Array = entries_variant if entries_variant is Array else []
	_status.text = "%d / 64 CIRCUITS" % entries.size()
	_status.add_theme_color_override("font_color", DesignSystem.MINT)
	if entries.is_empty():
		_list.add_child(_empty_state("No custom circuits yet. Draw one line in Track Studio; validated tracks are saved automatically."))
		return
	for metadata in entries:
		_list.add_child(_track_row(metadata))


func _empty_state(message: String) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 180.0
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.92), 24, Color(1.0, 1.0, 1.0, 0.08), 1))
	var label := DesignSystem.label(message, 20, DesignSystem.MUTED)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	return panel


func _track_row(metadata: Dictionary) -> Control:
	var track_id := str(metadata.get("track_id", ""))
	var display_name := str(metadata.get("display_name", "Untitled Track"))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.95), 20, Color(0.37, 1.0, 0.82, 0.12), 1))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)
	var preview := TrackThumbnailScript.new()
	var services := _services()
	var definition: TrackDefinition = services.call("get_track", track_id) if services != null else null
	if definition != null:
		var preview_result: TrackCompileResult = CompilerType.compile(definition)
		if preview_result.succeeded():
			preview.configure(preview_result.track)
	row.add_child(preview)
	var identity := VBoxContainer.new()
	identity.custom_minimum_size.x = 250.0
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(identity)
	var name_edit := LineEdit.new()
	name_edit.text = display_name
	name_edit.max_length = 80
	name_edit.add_theme_font_size_override("font_size", 20)
	identity.add_child(name_edit)
	var updated := int(metadata.get("updated_at_timestamp", 0))
	var date_text := Time.get_datetime_string_from_unix_time(updated, true).left(10) if updated > 0 else "NEW"
	identity.add_child(DesignSystem.label("%s  •  LOCAL CUSTOM CIRCUIT" % date_text, 12, DesignSystem.MUTED))

	var save_name := DesignSystem.button("SAVE NAME", false, true)
	save_name.custom_minimum_size.x = 124.0
	save_name.pressed.connect(func() -> void: _rename(track_id, name_edit.text))
	row.add_child(save_name)
	var edit := DesignSystem.button("EDIT", false, true)
	edit.custom_minimum_size.x = 106.0
	edit.pressed.connect(func() -> void: _edit(track_id))
	row.add_child(edit)
	var export := DesignSystem.button("EXPORT", false, true)
	export.custom_minimum_size.x = 110.0
	export.pressed.connect(func() -> void: _export(track_id))
	row.add_child(export)
	var tour := DesignSystem.button("TOUR", true, true)
	tour.custom_minimum_size.x = 106.0
	tour.pressed.connect(func() -> void: _tour(track_id))
	row.add_child(tour)
	var delete := DesignSystem.button("DELETE", false, true)
	delete.custom_minimum_size.x = 116.0
	delete.add_theme_color_override("font_color", DesignSystem.CORAL)
	delete.pressed.connect(func() -> void: _arm_delete(track_id, display_name))
	row.add_child(delete)
	return panel


func _rename(track_id: String, new_name: String) -> void:
	var services := _services()
	var result: Dictionary = services.call("rename_track", track_id, new_name) if services != null else {"ok": false, "message": "Local profile is unavailable."}
	if result.get("ok", false):
		_status.text = "NAME SAVED"
		_play_sfx(&"confirm")
		_refresh()
	else:
		_show_error(str(result.get("message", "Could not rename track")))


func _edit(track_id: String) -> void:
	var services := _services()
	var definition: TrackDefinition = services.call("get_track", track_id) if services != null else null
	if definition == null:
		_show_error("Saved track is missing or damaged.")
		return
	navigate_requested.emit("studio", {"editing_track_json": definition.canonical_json(true)})


func _tour(track_id: String) -> void:
	var services := _services()
	var definition: TrackDefinition = services.call("get_track", track_id) if services != null else null
	if definition == null:
		_show_error("Saved track is missing or damaged.")
		return
	var result: TrackCompileResult = CompilerType.compile(definition)
	if not result.succeeded():
		_show_error("This track needs repair in Track Studio before racing.")
		return
	navigate_requested.emit("tour", {
		"track_definition_json": definition.canonical_json(true),
		"source_hash": result.track.source_hash,
		"compiled_hash": result.track.compile_hash,
		"source": "saved",
		"display_name": definition.track_name,
		"location": "CUSTOM CREATION",
		"accent": DesignSystem.MINT.to_html(),
		"laps": 3,
		"difficulty": "standard",
		"collisions": true,
	})


func _export(track_id: String) -> void:
	var services := _services()
	var result: Dictionary = services.call("export_track", track_id) if services != null else {"ok": false, "message": "Local profile is unavailable."}
	if result.get("ok", false):
		DisplayServer.clipboard_set(str(result.get("json", "")))
		_status.text = "%s EXPORTED • JSON COPIED" % str(result.get("filename", "CIRCUIT"))
		_status.add_theme_color_override("font_color", DesignSystem.MINT)
		_status.tooltip_text = str(result.get("path", ""))
		_play_sfx(&"confirm")
	else:
		_show_error(str(result.get("message", "Could not export circuit")))


func _arm_delete(track_id: String, display_name: String) -> void:
	_pending_delete_id = track_id
	_delete_label.text = "Delete ‘%s’ from this device? This cannot be undone." % display_name
	_delete_panel.visible = true


func _cancel_delete() -> void:
	_pending_delete_id = ""
	_delete_panel.visible = false


func _confirm_delete() -> void:
	if _pending_delete_id.is_empty():
		return
	var services := _services()
	var result: Dictionary = services.call("delete_track", _pending_delete_id) if services != null else {"ok": false, "message": "Local profile is unavailable."}
	_pending_delete_id = ""
	_delete_panel.visible = false
	if result.get("ok", false):
		_play_sfx(&"confirm")
		_refresh()
	else:
		_show_error(str(result.get("message", "Could not delete track")))


func _show_error(message: String) -> void:
	_status.text = message
	_status.add_theme_color_override("font_color", DesignSystem.CORAL)
	_play_sfx(&"error")


func _services() -> Node:
	return get_node_or_null("/root/GameServices")


func _play_sfx(cue_id: StringName) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play_sfx"):
		audio.call("play_sfx", cue_id)
