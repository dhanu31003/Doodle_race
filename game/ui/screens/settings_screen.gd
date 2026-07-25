extends Control

signal navigate_requested(route: String, payload: Dictionary)

var _settings: GameSettings
var _status: Label
var _confirm_button: Button
var _cancel_button: Button
var _pending_action := ""
var _slider_save_timer: Timer


func _ready() -> void:
	var services := _services()
	var loaded: Variant = services.call("settings") if services != null else null
	_settings = loaded if loaded is GameSettings else GameSettings.new()
	_build()


func _build() -> void:
	_slider_save_timer = Timer.new()
	_slider_save_timer.one_shot = true
	_slider_save_timer.wait_time = 0.18
	_slider_save_timer.timeout.connect(_persist)
	add_child(_slider_save_timer)
	var safe := DesignSystem.make_margin(42, 28, 42, 30)
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
	var title := DesignSystem.title("SETTINGS & ACCESSIBILITY", 36)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_status = DesignSystem.label("Saved locally on this device", 14, DesignSystem.MINT)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_status)

	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 18)
	root.add_child(columns)
	var left := _settings_panel("AUDIO & CONTROLS")
	var right := _settings_panel("DISPLAY & ACCESSIBILITY")
	columns.add_child(left["panel"])
	columns.add_child(right["panel"])
	var left_content: VBoxContainer = left["content"]
	var right_content: VBoxContainer = right["content"]

	_add_slider(left_content, "MASTER VOLUME", 0.0, 1.0, 0.01, _settings.master_volume, func(value: float) -> void: _settings.master_volume = value)
	_add_slider(left_content, "MUSIC", 0.0, 1.0, 0.01, _settings.music_volume, func(value: float) -> void: _settings.music_volume = value)
	_add_slider(left_content, "ENGINE", 0.0, 1.0, 0.01, _settings.engine_volume, func(value: float) -> void: _settings.engine_volume = value)
	_add_slider(left_content, "RACE EFFECTS", 0.0, 1.0, 0.01, _settings.sfx_volume, func(value: float) -> void: _settings.sfx_volume = value)
	_add_slider(left_content, "AMBIENCE", 0.0, 1.0, 0.01, _settings.ambience_volume, func(value: float) -> void: _settings.ambience_volume = value)
	_add_slider(left_content, "INTERFACE", 0.0, 1.0, 0.01, _settings.ui_volume, func(value: float) -> void: _settings.ui_volume = value)
	_add_toggle(left_content, "MUTE ALL AUDIO", _settings.muted, func(value: bool) -> void: _settings.muted = value)

	var scheme_row := HBoxContainer.new()
	scheme_row.add_child(DesignSystem.label("TOUCH STEERING", 15, DesignSystem.MUTED))
	var scheme_spacer := Control.new()
	scheme_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scheme_row.add_child(scheme_spacer)
	var schemes := OptionButton.new()
	schemes.custom_minimum_size = Vector2(180.0, 44.0)
	for text in ["BUTTONS", "WHEEL", "TILT"]:
		schemes.add_item(text)
	var selected := [GameSettings.CONTROL_BUTTONS, GameSettings.CONTROL_WHEEL, GameSettings.CONTROL_TILT].find(_settings.touch_control_scheme)
	schemes.select(maxi(selected, 0))
	schemes.item_selected.connect(func(index: int) -> void:
		_settings.touch_control_scheme = [GameSettings.CONTROL_BUTTONS, GameSettings.CONTROL_WHEEL, GameSettings.CONTROL_TILT][index]
		_persist()
	)
	scheme_row.add_child(schemes)
	left_content.add_child(scheme_row)
	_add_slider(left_content, "CONTROL SIZE", GameSettings.MIN_CONTROL_SIZE, GameSettings.MAX_CONTROL_SIZE, 0.05, _settings.touch_control_size, func(value: float) -> void: _settings.touch_control_size = value)
	_add_slider(left_content, "CONTROL OPACITY", GameSettings.MIN_CONTROL_OPACITY, GameSettings.MAX_CONTROL_OPACITY, 0.05, _settings.touch_control_opacity, func(value: float) -> void: _settings.touch_control_opacity = value)
	_add_slider(left_content, "CONTROL REACH HEIGHT", 0.0, 1.0, 0.05, _settings.touch_control_vertical_offset, func(value: float) -> void: _settings.touch_control_vertical_offset = value)
	_add_slider(left_content, "TILT SENSITIVITY", 0.25, 2.5, 0.05, _settings.tilt_sensitivity, func(value: float) -> void: _settings.tilt_sensitivity = value)
	_add_slider(left_content, "TILT DEAD ZONE", 0.0, 0.40, 0.01, _settings.tilt_dead_zone, func(value: float) -> void: _settings.tilt_dead_zone = value)
	_add_toggle(left_content, "LEFT-HANDED LAYOUT", _settings.left_handed_controls, func(value: bool) -> void: _settings.left_handed_controls = value)
	_add_toggle(left_content, "VIBRATION", _settings.vibration_enabled, func(value: bool) -> void: _settings.vibration_enabled = value)
	var calibrate := DesignSystem.button("CALIBRATE TILT", false, true)
	calibrate.pressed.connect(_calibrate_tilt)
	left_content.add_child(calibrate)

	_add_toggle(right_content, "REDUCED MOTION", _settings.reduced_motion, func(value: bool) -> void: _settings.reduced_motion = value)
	var camera_row := HBoxContainer.new()
	camera_row.add_child(DesignSystem.label("DEFAULT RACE CAMERA", 15, DesignSystem.MUTED))
	var camera_spacer := Control.new()
	camera_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	camera_row.add_child(camera_spacer)
	var cameras := OptionButton.new()
	cameras.custom_minimum_size = Vector2(190.0, 44.0)
	cameras.add_item("CHASE VIEW")
	cameras.add_item("COCKPIT VIEW")
	cameras.select(1 if _settings.camera_view == GameSettings.CAMERA_COCKPIT else 0)
	cameras.item_selected.connect(func(index: int) -> void:
		_settings.camera_view = GameSettings.CAMERA_COCKPIT if index == 1 else GameSettings.CAMERA_CHASE
		_persist()
	)
	camera_row.add_child(cameras)
	right_content.add_child(camera_row)
	_add_toggle(right_content, "HIGH CONTRAST", _settings.high_contrast, func(value: bool) -> void: _settings.high_contrast = value)
	_add_toggle(right_content, "NON-COLOR RACE CUES", _settings.color_safe_differentiation, func(value: bool) -> void: _settings.color_safe_differentiation = value)
	_add_toggle(right_content, "LOW GRAPHICS MODE", _settings.low_graphics, func(value: bool) -> void: _settings.low_graphics = value)
	_add_toggle(right_content, "BATTERY SAVER • 30 FPS", _settings.battery_saver, func(value: bool) -> void: _settings.battery_saver = value)
	_add_slider(right_content, "UI SCALE", GameSettings.MIN_UI_SCALE, GameSettings.MAX_UI_SCALE, 0.05, _settings.ui_scale, func(value: float) -> void: _settings.ui_scale = value)
	_add_slider(right_content, "SCREEN SHAKE", 0.0, 1.0, 0.05, _settings.screen_shake, func(value: float) -> void: _settings.screen_shake = value)
	_add_toggle(right_content, "AUTO ACCELERATE", _settings.auto_accelerate, func(value: bool) -> void: _settings.auto_accelerate = value)
	_add_slider(right_content, "STEERING ASSIST", 0.0, 1.0, 0.05, _settings.steering_assist, func(value: float) -> void: _settings.steering_assist = value)
	_add_slider(right_content, "BRAKING ASSIST", 0.0, 1.0, 0.05, _settings.braking_assist, func(value: float) -> void: _settings.braking_assist = value)

	var danger_rule := HSeparator.new()
	right_content.add_child(danger_rule)
	var export := DesignSystem.button("EXPORT LOCAL DATA", false, true)
	export.pressed.connect(_export_local_data)
	right_content.add_child(export)
	var reset := DesignSystem.button("RESET RACE PROGRESS", false, true)
	reset.pressed.connect(func() -> void: _arm_action("reset"))
	right_content.add_child(reset)
	var delete := DesignSystem.button("DELETE ALL LOCAL DATA", false, true)
	delete.add_theme_color_override("font_color", DesignSystem.CORAL)
	delete.pressed.connect(func() -> void: _arm_action("delete"))
	right_content.add_child(delete)
	var confirmation := HBoxContainer.new()
	confirmation.add_theme_constant_override("separation", 8)
	right_content.add_child(confirmation)
	_confirm_button = DesignSystem.button("CONFIRM", true, true)
	_confirm_button.visible = false
	_confirm_button.pressed.connect(_confirm_action)
	confirmation.add_child(_confirm_button)
	_cancel_button = DesignSystem.button("CANCEL", false, true)
	_cancel_button.visible = false
	_cancel_button.pressed.connect(_cancel_action)
	confirmation.add_child(_cancel_button)


func _settings_panel(heading: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.96), 24, Color(1.0, 1.0, 1.0, 0.08), 1))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 9)
	scroll.add_child(content)
	content.add_child(DesignSystem.label(heading, 15, DesignSystem.MINT))
	return {"panel": panel, "content": content}


func _add_slider(parent: VBoxContainer, title: String, minimum: float, maximum: float, step: float, current: float, setter: Callable) -> void:
	var group := VBoxContainer.new()
	group.add_theme_constant_override("separation", 2)
	parent.add_child(group)
	var row := HBoxContainer.new()
	group.add_child(row)
	row.add_child(DesignSystem.label(title, 14, DesignSystem.MUTED))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var value_label := DesignSystem.label("%d%%" % roundi(current * 100.0), 14, DesignSystem.WHITE)
	row.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = current
	slider.custom_minimum_size = Vector2(0.0, 30.0)
	slider.value_changed.connect(func(value: float) -> void:
		setter.call(value)
		value_label.text = "%d%%" % roundi(value * 100.0)
		_apply_audio_settings()
		_schedule_slider_persist()
	)
	slider.drag_ended.connect(func(_changed: bool) -> void:
		_slider_save_timer.stop()
		_persist()
	)
	group.add_child(slider)


func _schedule_slider_persist() -> void:
	if _slider_save_timer != null:
		_slider_save_timer.start()


func _add_toggle(parent: VBoxContainer, title: String, current: bool, setter: Callable) -> void:
	var toggle := CheckButton.new()
	toggle.text = title
	toggle.button_pressed = current
	toggle.custom_minimum_size.y = 38.0
	toggle.add_theme_font_size_override("font_size", 15)
	toggle.toggled.connect(func(value: bool) -> void:
		setter.call(value)
		_persist()
	)
	parent.add_child(toggle)


func _persist() -> void:
	var services := _services()
	var result: Dictionary = services.call("update_settings", _settings) if services != null else {"ok": false, "message": "Local profile is unavailable."}
	if result.get("ok", false):
		_status.text = "Saved locally"
		_status.add_theme_color_override("font_color", DesignSystem.MINT)
	else:
		_status.text = str(result.get("message", "Could not save settings"))
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		_play_sfx(&"error")


func _calibrate_tilt() -> void:
	var acceleration := Input.get_accelerometer()
	_settings.tilt_calibration = Vector2(acceleration.x, acceleration.y).clamp(Vector2(-1.0, -1.0), Vector2.ONE)
	_persist()
	_status.text = "Tilt neutral captured"
	_play_sfx(&"confirm")


func _export_local_data() -> void:
	var services := _services()
	var result: Dictionary = services.call("export_local_data") if services != null else {"ok": false, "message": "Local profile is unavailable."}
	if result.get("ok", false):
		DisplayServer.clipboard_set(str(result.get("json", "")))
		_status.text = "Verified export saved • JSON copied"
		_status.tooltip_text = str(result.get("path", ""))
		_status.add_theme_color_override("font_color", DesignSystem.MINT)
		_play_sfx(&"confirm")
	else:
		_status.text = str(result.get("message", "Could not export local data"))
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		_play_sfx(&"error")


func _arm_action(action: String) -> void:
	_pending_action = action
	_confirm_button.visible = true
	_cancel_button.visible = true
	_confirm_button.text = "CONFIRM DELETE" if action == "delete" else "CONFIRM RESET"
	_status.text = "This cannot be undone. Confirm or cancel."
	_status.add_theme_color_override("font_color", DesignSystem.CORAL)


func _cancel_action() -> void:
	_pending_action = ""
	_confirm_button.visible = false
	_cancel_button.visible = false
	_status.text = "No data changed"
	_status.add_theme_color_override("font_color", DesignSystem.MUTED)


func _confirm_action() -> void:
	var services := _services()
	var method := "delete_all_local_data" if _pending_action == "delete" else "reset_progress"
	var result: Dictionary = services.call(method) if services != null else {"ok": false, "message": "Local profile is unavailable."}
	if result.get("ok", false):
		var loaded: Variant = services.call("settings")
		_settings = loaded if loaded is GameSettings else GameSettings.new()
		_status.text = "Local device data deleted • server records unaffected" if _pending_action == "delete" else "Race progress reset"
		_status.add_theme_color_override("font_color", DesignSystem.MINT)
		_play_sfx(&"confirm")
	else:
		_status.text = str(result.get("message", "Operation failed"))
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		_play_sfx(&"error")
	_pending_action = ""
	_confirm_button.visible = false
	_cancel_button.visible = false


func _services() -> Node:
	return get_node_or_null("/root/GameServices")


func _apply_audio_settings() -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("apply_settings"):
		audio.call("apply_settings", _settings.to_dictionary())


func _play_sfx(cue_id: StringName) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play_sfx"):
		audio.call("play_sfx", cue_id)
