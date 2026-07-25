extends Control
## Private-room product flow. Nothing here runs a public matchmaker: players
## explicitly create or join a six-character room on the configured endpoint.

signal navigate_requested(route: String, payload: Dictionary)

const Limits := preload("res://game/network/network_limits.gd")
const Endpoint := preload("res://game/network/client/network_endpoint.gd")
const Catalog := preload("res://game/content/predefined_track_catalog.gd")
const Compiler := preload("res://game/track/generation/track_compiler.gd")
const VehicleCatalog := preload("res://game/content/vehicle_catalog.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")

var payload: Dictionary = {}
var session: PrivateMultiplayerSession
var _fixture_mode := false
var _busy := false
var _navigated_to_race := false
var _track_choices: Array[Dictionary] = []
var _selected_definition: TrackDefinition

var _root: VBoxContainer
var _status: Label
var _name_edit: LineEdit
var _code_edit: LineEdit
var _host_edit: LineEdit
var _port_spin: SpinBox
var _scheme_option: OptionButton
var _create_button: Button
var _join_button: Button
var _roster_list: VBoxContainer
var _track_option: OptionButton
var _laps_option: OptionButton
var _collisions_toggle: CheckButton
var _track_detail: Label
var _track_hash: Label
var _select_track_button: Button
var _studio_button: Button
var _ready_button: Button
var _start_button: Button
var _lock_button: Button
var _room_code_label: Label
var _room_state_label: Label
var _reconnect_button: Button
var _kick_panel: PanelContainer
var _kick_label: Label
var _pending_kick_id := ""
var _config_update_guard := false
var _fixture_race_config: Dictionary = Limits.default_race_config()
var _fixture_join_locked := true


func set_payload(value: Dictionary) -> void:
	payload = value.duplicate(true)


func _ready() -> void:
	session = get_node_or_null("/root/NetworkSession")
	_fixture_mode = bool(payload.get("visual_fixture", false)) and (session == null or not session.is_joined())
	_build_shell()
	if _fixture_mode:
		_build_lobby(_fixture_snapshot())
	elif session != null and session.is_joined():
		_connect_session_signals()
		_build_lobby(session.public_snapshot())
		if payload.has("room_track_definition_json"):
			call_deferred("_publish_returned_room_track")
	else:
		_connect_session_signals()
		_build_entry()


func _exit_tree() -> void:
	_disconnect_session_signals()


func _process(_delta: float) -> void:
	if _fixture_mode or session == null or not session.is_joined():
		return
	_refresh_lobby(session.public_snapshot())


func on_application_paused() -> void:
	if not _fixture_mode and session != null:
		session.on_application_paused()


func on_application_resumed() -> void:
	if not _fixture_mode and session != null:
		session.on_application_resumed()


func _build_shell() -> void:
	var safe := DesignSystem.make_margin(38, 24, 38, 24)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)
	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", 14)
	safe.add_child(_root)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	_root.add_child(top)
	var back := DesignSystem.screen_button("‹ PADDOCK")
	back.pressed.connect(_back_or_leave)
	top.add_child(back)
	var title := DesignSystem.title("PRIVATE ROOM", 38)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_status = DesignSystem.label("LOCAL / PRIVATE BACKEND", 14, DesignSystem.MINT)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_status)


func _clear_body() -> void:
	while _root.get_child_count() > 1:
		var child := _root.get_child(1)
		_root.remove_child(child)
		child.queue_free()


func _build_entry() -> void:
	_clear_body()
	set_process(false)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 20)
	_root.add_child(body)
	body.add_child(_build_identity_card())
	body.add_child(_build_join_card())
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 14)
	_root.add_child(foot)
	var privacy := DesignSystem.label(
		"Anonymous random install identity • no hardware ID • room credentials stay in memory",
		13, DesignSystem.MUTED
	)
	privacy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	privacy.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	foot.add_child(privacy)
	var offline := DesignSystem.button("PLAY OFFLINE INSTEAD", false, true)
	offline.pressed.connect(func() -> void: navigate_requested.emit("tracks", {}))
	foot.add_child(offline)
	_status.text = "LOCAL / PRIVATE BACKEND • OFFLINE PLAY UNAFFECTED"
	_status.add_theme_color_override("font_color", DesignSystem.MINT)


func _build_identity_card() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.05
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.035, 0.075, 0.135, 0.97), 28, Color(0.37, 1.0, 0.82, 0.18), 1
	))
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 14)
	panel.add_child(content)
	content.add_child(DesignSystem.label("YOUR DRIVER", 15, DesignSystem.MINT))
	content.add_child(DesignSystem.title("RACE WITH FRIENDS", 34))
	var explanation := DesignSystem.label(
		"Create a short-code room for up to 12 drivers. Every device builds the selected circuit locally and must match its fingerprint before Ready unlocks.",
		17, DesignSystem.MUTED
	)
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.custom_minimum_size.y = 76.0
	content.add_child(explanation)
	content.add_child(DesignSystem.label("DRIVER NAME  •  1–24 CHARACTERS", 12, DesignSystem.MUTED))
	_name_edit = _line_edit("Driver", Limits.MAX_DISPLAY_NAME_LENGTH)
	content.add_child(_name_edit)
	_create_button = DesignSystem.button("CREATE PRIVATE ROOM  ›", true, true)
	_create_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_create_button.pressed.connect(_create_room)
	content.add_child(_create_button)
	return panel


func _build_join_card() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.047, 0.095, 0.17, 0.97), 28, Color(1.0, 1.0, 1.0, 0.10), 1
	))
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 12)
	panel.add_child(content)
	content.add_child(DesignSystem.label("JOIN BY INVITE", 15, DesignSystem.CYAN))
	content.add_child(DesignSystem.title("ENTER ROOM CODE", 30))
	_name_edit = _name_edit if _name_edit != null else _line_edit("Driver", Limits.MAX_DISPLAY_NAME_LENGTH)
	_code_edit = _line_edit("", Limits.ROOM_CODE_LENGTH)
	_code_edit.placeholder_text = "------"
	_code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_edit.add_theme_font_size_override("font_size", 31)
	_code_edit.text_changed.connect(_sanitize_room_code)
	content.add_child(_code_edit)
	var code_help := DesignSystem.label("Example A7K9Q2 • not an active room", 11, DesignSystem.MUTED)
	code_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(code_help)
	_join_button = DesignSystem.button("JOIN ROOM", true, true)
	_join_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_button.pressed.connect(_join_room)
	content.add_child(_join_button)
	var split := HSeparator.new()
	content.add_child(split)
	content.add_child(DesignSystem.label("LOCAL BACKEND ENDPOINT", 12, DesignSystem.MUTED))
	var endpoint_row := HBoxContainer.new()
	endpoint_row.add_theme_constant_override("separation", 8)
	content.add_child(endpoint_row)
	var defaults := Endpoint.from_runtime_overrides()
	_host_edit = _line_edit(str(defaults["host"]), 253)
	_host_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_edit.tooltip_text = "Desktop local default is 127.0.0.1; Android emulator local default is 10.0.2.2."
	endpoint_row.add_child(_host_edit)
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1
	_port_spin.max_value = 65_535
	_port_spin.step = 1
	_port_spin.value = int(defaults["port"])
	_port_spin.custom_minimum_size.x = 112.0
	endpoint_row.add_child(_port_spin)
	_scheme_option = OptionButton.new()
	_scheme_option.add_item("HTTP")
	_scheme_option.add_item("HTTPS")
	_scheme_option.select(1 if str(defaults["scheme"]) == "https" else 0)
	_scheme_option.custom_minimum_size.x = 92.0
	endpoint_row.add_child(_scheme_option)
	var warning := DesignSystem.label("Development endpoint only. No public service is configured in this build.", 12, DesignSystem.GOLD)
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(warning)
	return panel


func _build_lobby(snapshot: Dictionary) -> void:
	_clear_body()
	set_process(true)
	var room_bar := PanelContainer.new()
	room_bar.add_theme_stylebox_override("panel", _compact_panel(Color(0.035, 0.075, 0.135, 0.97), DesignSystem.MINT))
	_root.add_child(room_bar)
	var room_row := HBoxContainer.new()
	room_row.add_theme_constant_override("separation", 12)
	room_bar.add_child(room_row)
	room_row.add_child(DesignSystem.label("INVITE CODE", 13, DesignSystem.MUTED))
	_room_code_label = DesignSystem.label(str(snapshot.get("room_code", "------")), 28, DesignSystem.WHITE)
	_room_code_label.add_theme_constant_override("outline_size", 4)
	_room_code_label.add_theme_color_override("font_outline_color", DesignSystem.INK)
	room_row.add_child(_room_code_label)
	var copy := DesignSystem.button("COPY", false, true)
	copy.custom_minimum_size.x = 96.0
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(_room_code_label.text)
		_status.text = "ROOM CODE COPIED"
		var audio := get_node_or_null("/root/Audio")
		if audio != null:
			audio.call("play_sfx", &"confirm")
	)
	room_row.add_child(copy)
	var room_spacer := Control.new()
	room_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_row.add_child(room_spacer)
	_room_state_label = DesignSystem.label("LOBBY", 15, DesignSystem.GOLD)
	_room_state_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	room_row.add_child(_room_state_label)
	_reconnect_button = DesignSystem.button("RECONNECT", true, true)
	_reconnect_button.custom_minimum_size.x = 130.0
	_reconnect_button.visible = false
	_reconnect_button.pressed.connect(_reconnect)
	room_row.add_child(_reconnect_button)

	var body_scroll := ScrollContainer.new()
	body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root.add_child(body_scroll)
	var body := HBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	body_scroll.add_child(body)
	body.add_child(_build_track_card(snapshot))
	body.add_child(_build_roster_card())
	_build_kick_panel()
	_refresh_lobby(snapshot)


func _build_track_card(snapshot: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.35
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.035, 0.075, 0.135, 0.97), 26, Color(0.37, 1.0, 0.82, 0.16), 1
	))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	panel.add_child(content)
	content.add_child(DesignSystem.label("CIRCUIT AUTHORITY", 14, DesignSystem.MINT))
	_track_option = OptionButton.new()
	_track_option.custom_minimum_size.y = 44.0
	_track_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track_choices = _available_tracks()
	for choice in _track_choices:
		_track_option.add_item(str(choice["label"]))
	_track_option.item_selected.connect(_select_track_choice)
	content.add_child(_track_option)
	var rules := HBoxContainer.new()
	rules.add_theme_constant_override("separation", 8)
	content.add_child(rules)
	var rules_label := DesignSystem.label("RACE RULES", 12, DesignSystem.GOLD)
	rules_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rules_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rules.add_child(rules_label)
	_laps_option = OptionButton.new()
	_laps_option.custom_minimum_size = Vector2(112.0, 38.0)
	for lap_count in Limits.ALLOWED_MULTIPLAYER_LAPS:
		_laps_option.add_item("%d %s" % [lap_count, "LAP" if lap_count == 1 else "LAPS"], lap_count)
	_laps_option.item_selected.connect(_race_laps_selected)
	rules.add_child(_laps_option)
	_collisions_toggle = CheckButton.new()
	_collisions_toggle.text = "COLLISIONS"
	_collisions_toggle.custom_minimum_size.y = 38.0
	DesignSystem.apply_font_size(_collisions_toggle, 12)
	_collisions_toggle.toggled.connect(_race_collisions_toggled)
	rules.add_child(_collisions_toggle)
	rules.tooltip_text = "Host-owned race rules. Any real change resets every driver's Ready state."
	_track_detail = DesignSystem.label("", 16, DesignSystem.WHITE)
	_track_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_track_detail.custom_minimum_size.y = 58.0
	content.add_child(_track_detail)
	var fingerprint_card := PanelContainer.new()
	fingerprint_card.add_theme_stylebox_override("panel", _compact_panel(Color(0.02, 0.045, 0.08, 0.95), Color(1.0, 1.0, 1.0, 0.09)))
	content.add_child(fingerprint_card)
	_track_hash = DesignSystem.label("LOCAL COMPILE PENDING", 13, DesignSystem.MUTED)
	_track_hash.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	fingerprint_card.add_child(_track_hash)
	_select_track_button = DesignSystem.button("HOST: SYNC THIS CIRCUIT", true, true)
	_select_track_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_select_track_button.pressed.connect(_submit_track)
	content.add_child(_select_track_button)
	_studio_button = DesignSystem.button("HOST: DRAW ROOM CIRCUIT", false, true)
	_studio_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_button.pressed.connect(_open_room_track_studio)
	content.add_child(_studio_button)
	var rule := HSeparator.new()
	content.add_child(rule)
	var contract := DesignSystem.label(
		"Every driver compiles the definition locally. Ready remains locked unless source hash, generator version and compiled fingerprint match exactly.",
		13, DesignSystem.MUTED
	)
	contract.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(contract)
	if not _track_choices.is_empty():
		_select_track_choice(0)
	var host := bool(snapshot.get("local_player_id", "") == snapshot.get("host_id", "")) or _fixture_mode
	_track_option.disabled = not host
	_select_track_button.visible = host
	_studio_button.visible = host
	return panel


func _build_roster_card() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 470.0
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.047, 0.095, 0.17, 0.97), 26, Color(1.0, 1.0, 1.0, 0.10), 1
	))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	panel.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	var title := DesignSystem.label("STARTING GRID", 14, DesignSystem.CYAN)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	heading.add_child(DesignSystem.label("MAX 12", 12, DesignSystem.MUTED))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_roster_list = VBoxContainer.new()
	_roster_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roster_list.add_theme_constant_override("separation", 7)
	scroll.add_child(_roster_list)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	content.add_child(actions)
	# These actions are visible only to the host. Repeating "HOST" in every
	# label forced three 190 px compact-button minima into a 722 px row at the
	# 1.30x text ceiling, wider than a landscape phone after safe margins.
	_lock_button = DesignSystem.button("LOCK GRID", false, true)
	_lock_button.custom_minimum_size.x = 0.0
	_lock_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lock_button.tooltip_text = "Host: freeze the roster, circuit, and rules."
	_lock_button.pressed.connect(_toggle_room_lock)
	actions.add_child(_lock_button)
	_ready_button = DesignSystem.button("READY", false, true)
	_ready_button.custom_minimum_size.x = 0.0
	_ready_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ready_button.pressed.connect(_toggle_ready)
	actions.add_child(_ready_button)
	_start_button = DesignSystem.button("START RACE", true, true)
	_start_button.custom_minimum_size.x = 0.0
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_button.tooltip_text = "Host: start once every driver is verified and ready."
	_start_button.pressed.connect(_start_race)
	actions.add_child(_start_button)
	var leave := DesignSystem.button("LEAVE ROOM", false, true)
	leave.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leave.add_theme_color_override("font_color", DesignSystem.CORAL)
	leave.pressed.connect(_leave_room)
	content.add_child(leave)
	return panel


func _refresh_lobby(snapshot: Dictionary) -> void:
	if _room_code_label == null or not is_instance_valid(_room_code_label):
		return
	_room_code_label.text = str(snapshot.get("room_code", "------"))
	var state := str(snapshot.get("state", "LOBBY"))
	var join_locked := bool(snapshot.get("join_locked", false))
	_room_state_label.text = "%s • %s" % [
		state.replace("_", " "), "GRID LOCKED" if join_locked else "GRID OPEN",
	]
	_room_state_label.add_theme_color_override("font_color", DesignSystem.CORAL if state == "CLOSED" else DesignSystem.GOLD)
	var connection := str(snapshot.get("connection", "online"))
	_reconnect_button.visible = connection == "reconnecting" or connection == "failed"
	if connection == "reconnecting":
		var seconds := ceili(float(snapshot.get("reconnect_remaining_ms", 0)) / 1000.0)
		_status.text = "CONNECTION PAUSED • %d s TO RECONNECT" % seconds
		_status.add_theme_color_override("font_color", DesignSystem.GOLD)
	elif connection == "failed":
		_status.text = "CONNECTION LOST • RETRY OR LEAVE"
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
	else:
		_status.text = "%d / 12 DRIVERS • %s • %s" % [
			int(snapshot.get("member_count", 0)),
			str(snapshot.get("endpoint_label", "PRIVATE")),
			"JOIN LOCKED" if join_locked else "INVITES OPEN",
		]
		_status.add_theme_color_override("font_color", DesignSystem.MINT)
	_refresh_roster(snapshot)
	var host := str(snapshot.get("host_id", "")) == str(snapshot.get("local_player_id", "")) or _fixture_mode
	_sync_race_config_controls(snapshot, host, state)
	if _select_track_button != null:
		_select_track_button.visible = host
		_select_track_button.disabled = not host or join_locked or _busy
		_track_option.disabled = not host or join_locked or _busy
	if _studio_button != null:
		_studio_button.visible = host
		_studio_button.disabled = not host or join_locked or _busy
	var local := _member_for(snapshot.get("members", []), str(snapshot.get("local_player_id", "")))
	var verified := bool(local.get("generation_verified", false))
	var ready := bool(local.get("ready", false))
	_ready_button.text = "NOT READY" if ready else ("READY" if verified else "WAITING FOR CIRCUIT")
	_ready_button.disabled = not verified or state in ["COUNTDOWN", "RACING", "CLOSED"]
	_lock_button.visible = host
	_lock_button.text = "UNLOCK GRID" if join_locked else "LOCK GRID"
	_lock_button.disabled = _busy or state in ["COUNTDOWN", "RACING", "RESULTS", "CLOSED"]
	_lock_button.tooltip_text = (
		"Unlock invitations and circuit/rule editing." if join_locked
		else "Freeze the roster, circuit, and rules. Drivers can then set Ready."
	)
	_start_button.visible = host
	_start_button.disabled = not _fixture_can_start(snapshot) if _fixture_mode else not session.can_start()
	if state == "COUNTDOWN" and not _navigated_to_race:
		_navigate_to_network_race()


func _refresh_roster(snapshot: Dictionary) -> void:
	if _roster_list == null:
		return
	for child in _roster_list.get_children():
		child.queue_free()
	var members: Array = snapshot.get("members", [])
	members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("slot", 99)) < int(b.get("slot", 99)))
	for member in members:
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", _compact_panel(
			Color(0.035, 0.075, 0.135, 0.88),
			DesignSystem.MINT if bool(member.get("ready", false)) else Color(1.0, 1.0, 1.0, 0.08)
		))
		_roster_list.add_child(row)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 9)
		row.add_child(line)
		var slot := DesignSystem.label("%02d" % (int(member.get("slot", 0)) + 1), 13, DesignSystem.MUTED)
		slot.custom_minimum_size.x = 28.0
		line.add_child(slot)
		var name := str(member.get("display_name", "DRIVER"))
		if bool(member.get("is_host", false)):
			name += "  •  HOST"
		var name_label := DesignSystem.label(name, 15, DesignSystem.WHITE)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(name_label)
		var car_id := str(member.get("car_id", VehicleCatalog.DEFAULT_CAR_ID))
		var team_id := str(member.get("team_id", VehicleCatalog.DEFAULT_TEAM_ID))
		var vehicle := VehicleCatalog.by_car_id(car_id)
		var cosmetic_text := "%s • %s" % [str(vehicle.get("name", "PRIME")), str(vehicle.get("team", "VECTOR WORKS"))]
		var cosmetic_color: Color = vehicle.get("accent", DesignSystem.CYAN) \
			if VehicleCatalog.is_valid_pair(car_id, team_id) else DesignSystem.CORAL
		line.add_child(DesignSystem.label(cosmetic_text, 10, cosmetic_color))
		var sync_text := "MISMATCH" if not bool(member.get("generation_verified", false)) else "VERIFIED"
		var sync_color := DesignSystem.CORAL if sync_text == "MISMATCH" else DesignSystem.CYAN
		if not bool(member.get("connected", true)):
			sync_text = "RECONNECTING"
			sync_color = DesignSystem.GOLD
		line.add_child(DesignSystem.label(sync_text, 11, sync_color))
		line.add_child(DesignSystem.label("READY" if bool(member.get("ready", false)) else "—", 12, DesignSystem.MINT if bool(member.get("ready", false)) else DesignSystem.MUTED))
		var local_is_host := str(snapshot.get("host_id", "")) == str(snapshot.get("local_player_id", "")) or _fixture_mode
		var removable := local_is_host \
			and str(member.get("player_id", "")) != str(snapshot.get("local_player_id", "")) \
			and not bool(snapshot.get("join_locked", false)) \
			and str(snapshot.get("state", "")) not in ["COUNTDOWN", "RACING", "RESULTS", "CLOSED"]
		if removable:
			var remove := DesignSystem.button("KICK", false, true)
			remove.custom_minimum_size = Vector2(62.0, 32.0)
			DesignSystem.apply_font_size(remove, 11)
			remove.add_theme_color_override("font_color", DesignSystem.CORAL)
			var target_id := str(member.get("player_id", ""))
			var target_name := str(member.get("display_name", "DRIVER"))
			remove.pressed.connect(func() -> void: _arm_kick(target_id, target_name))
			line.add_child(remove)
	for empty_slot in range(members.size(), Limits.MAX_PLAYERS):
		if empty_slot >= 6:
			break
		_roster_list.add_child(DesignSystem.label("%02d   INVITE SLOT OPEN" % (empty_slot + 1), 13, Color(0.6, 0.68, 0.76, 0.50)))


func _create_room() -> void:
	if _busy or session == null:
		return
	_set_busy(true, "CONNECTING TO PRIVATE BACKEND…")
	var result := await session.create_room_async(_name_edit.text, _endpoint_value())
	_set_busy(false)
	if result.get("ok", false):
		_build_lobby(session.public_snapshot())
	else:
		_show_result_error(result)


func _join_room() -> void:
	if _busy or session == null:
		return
	_set_busy(true, "CHECKING ROOM CODE…")
	var result := await session.join_room_async(_code_edit.text, _name_edit.text, _endpoint_value())
	_set_busy(false)
	if result.get("ok", false):
		_build_lobby(session.public_snapshot())
	else:
		_show_result_error(result)


func _submit_track() -> void:
	if _busy or _selected_definition == null or session == null:
		return
	_set_busy(true, "SENDING CANONICAL CIRCUIT…")
	var result := await session.select_track_async(_selected_definition)
	_set_busy(false)
	if result.get("ok", false):
		_status.text = "CIRCUIT SENT • VERIFYING EVERY DRIVER"
	else:
		_show_result_error(result)


func _open_room_track_studio() -> void:
	if _busy or session == null or not session.is_host():
		return
	var studio_payload := {"multiplayer_return": true, "return_room_code": session.room_code}
	var current: TrackDefinition = session.current_definition()
	if current != null:
		studio_payload["editing_track_json"] = current.canonical_json(true)
	navigate_requested.emit("studio", studio_payload)


func _publish_returned_room_track() -> void:
	if _fixture_mode or session == null or not session.is_joined() or not session.is_host():
		return
	var expected_room := str(payload.get("return_room_code", session.room_code)).to_upper()
	if expected_room != session.room_code:
		_status.text = "ROOM SESSION CHANGED • CIRCUIT WAS NOT PUBLISHED"
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	var definition := TrackDefinitionType.from_json(str(payload.get("room_track_definition_json", "")))
	if definition == null or not definition.validate_schema().is_valid():
		_status.text = "RETURNED CIRCUIT FAILED SCHEMA VALIDATION"
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	_set_busy(true, "PUBLISHING AUTHORED CIRCUIT TO THIS ROOM…")
	var result := await session.select_track_async(definition)
	_set_busy(false)
	if result.get("ok", false):
		_status.text = "AUTHORED CIRCUIT PUBLISHED • VERIFYING EVERY DRIVER"
		_status.add_theme_color_override("font_color", DesignSystem.MINT)
	else:
		_show_result_error(result)


func _race_laps_selected(index: int) -> void:
	if _config_update_guard or _laps_option == null or index < 0:
		return
	_submit_race_config(int(_laps_option.get_item_id(index)), _collisions_toggle.button_pressed)


func _race_collisions_toggled(enabled: bool) -> void:
	if _config_update_guard or _laps_option == null:
		return
	_submit_race_config(int(_laps_option.get_item_id(_laps_option.selected)), enabled)


func _submit_race_config(laps: int, collisions: bool) -> void:
	if _fixture_mode:
		_fixture_race_config = {"laps": laps, "collisions": collisions}
		_status.text = "RACE RULES UPDATED • READY RESET REQUIRED"
		return
	if _busy or session == null:
		return
	_set_busy(true, "UPDATING AUTHORITATIVE RACE RULES…")
	var result := await session.update_race_config_async(laps, collisions)
	_set_busy(false)
	if result.get("ok", false):
		_status.text = "RACE RULES SYNCED • READY FLAGS RESET"
	else:
		_show_result_error(result)


func _toggle_room_lock() -> void:
	var currently_locked := _fixture_join_locked if _fixture_mode else bool(session.public_snapshot().get("join_locked", false))
	if _fixture_mode:
		_fixture_join_locked = not currently_locked
		_refresh_lobby(_fixture_snapshot())
		return
	if _busy or session == null:
		return
	_set_busy(true, "UPDATING STARTING-GRID LOCK…")
	var result := await session.set_room_lock_async(not currently_locked)
	_set_busy(false)
	if not result.get("ok", false):
		_show_result_error(result)


func _toggle_ready() -> void:
	if _busy or session == null:
		return
	var local := session.local_member()
	_set_busy(true, "UPDATING READY STATE…")
	var result := await session.set_ready_async(not bool(local.get("ready", false)))
	_set_busy(false)
	if not result.get("ok", false):
		_show_result_error(result)


func _start_race() -> void:
	if _fixture_mode:
		_navigate_to_network_race()
		return
	if _busy or session == null:
		return
	_set_busy(true, "LOCKING GRID…")
	var result := await session.start_race_async()
	_set_busy(false)
	if result.get("ok", false):
		_navigate_to_network_race()
	else:
		_show_result_error(result)


func _reconnect() -> void:
	if _busy or session == null:
		return
	_set_busy(true, "RECONNECTING TO ROOM…")
	var result := await session.reconnect_async()
	_set_busy(false)
	if not result.get("ok", false):
		_show_result_error(result)


func _leave_room() -> void:
	if _fixture_mode:
		navigate_requested.emit("home", {})
		return
	if _busy or session == null:
		return
	_set_busy(true, "LEAVING ROOM…")
	await session.leave_async()
	_set_busy(false)
	navigate_requested.emit("home", {})


func _build_kick_panel() -> void:
	if _kick_panel != null and is_instance_valid(_kick_panel):
		return
	_kick_panel = PanelContainer.new()
	_kick_panel.visible = false
	_kick_panel.set_anchors_preset(Control.PRESET_CENTER)
	_kick_panel.position = Vector2(-235.0, -125.0)
	_kick_panel.custom_minimum_size = Vector2(470.0, 250.0)
	_kick_panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.12, 0.045, 0.07, 0.99), 26, DesignSystem.CORAL, 2))
	add_child(_kick_panel)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 14)
	_kick_panel.add_child(content)
	content.add_child(DesignSystem.title("REMOVE DRIVER?", 31))
	_kick_label = DesignSystem.label("", 16, DesignSystem.MUTED)
	_kick_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_kick_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_kick_label)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	content.add_child(actions)
	var cancel := DesignSystem.button("CANCEL", false, true)
	cancel.pressed.connect(func() -> void:
		_pending_kick_id = ""
		_kick_panel.visible = false
	)
	actions.add_child(cancel)
	var confirm := DesignSystem.button("KICK DRIVER", true, true)
	confirm.pressed.connect(_confirm_kick)
	actions.add_child(confirm)


func _arm_kick(player_id: String, player_name: String) -> void:
	_pending_kick_id = player_id
	_kick_label.text = "Remove %s from this private lobby? They will see a clear host-removal reason." % player_name
	_kick_panel.visible = true


func _confirm_kick() -> void:
	if _pending_kick_id.is_empty():
		return
	if _fixture_mode:
		_pending_kick_id = ""
		_kick_panel.visible = false
		_status.text = "VISUAL FIXTURE • KICK CONFIRMATION VERIFIED"
		return
	var target := _pending_kick_id
	_pending_kick_id = ""
	_kick_panel.visible = false
	_set_busy(true, "REMOVING DRIVER…")
	var result := await session.kick_member_async(target)
	_set_busy(false)
	if not result.get("ok", false):
		_show_result_error(result)


func _back_or_leave() -> void:
	if not _fixture_mode and session != null and session.is_joined():
		_leave_room()
	else:
		navigate_requested.emit("home", {})


func handle_back_request() -> void:
	_back_or_leave()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		handle_back_request()
		get_viewport().set_input_as_handled()


func _navigate_to_network_race() -> void:
	if _navigated_to_race:
		return
	_navigated_to_race = true
	var race_payload := _fixture_race_payload() if _fixture_mode else session.race_payload()
	if race_payload.is_empty():
		_navigated_to_race = false
		_status.text = "LOCAL CIRCUIT IS NOT VERIFIED"
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	navigate_requested.emit("network_race", race_payload)


func _select_track_choice(index: int) -> void:
	if index < 0 or index >= _track_choices.size():
		return
	_selected_definition = _track_choices[index]["definition"]
	var compiled: TrackCompileResult = Compiler.compile(_selected_definition)
	if not compiled.succeeded() or compiled.track == null:
		_track_detail.text = "This circuit failed local validation and cannot be selected."
		_track_hash.text = "LOCAL COMPILE FAILED"
		_track_hash.add_theme_color_override("font_color", DesignSystem.CORAL)
		_select_track_button.disabled = true
		return
	_track_detail.text = "%s  •  %d m  •  %s" % [
		_selected_definition.track_name,
		roundi(compiled.track.total_length),
		str(_track_choices[index].get("source", "RELEASE")).to_upper(),
	]
	_track_hash.text = "SOURCE  %s…\nCOMPILE  %s…  •  GENERATOR v%d" % [
		compiled.track.source_hash.left(14),
		compiled.track.compile_hash.left(14),
		int(_selected_definition.generator_version),
	]
	_track_hash.add_theme_color_override("font_color", DesignSystem.CYAN)
	_select_track_button.disabled = false


func _available_tracks() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for item in Catalog.all():
		output.append({
			"label": "%s  •  RELEASE CIRCUIT" % str(item["name"]),
			"definition": item["definition"],
			"source": "release",
		})
	var services := get_node_or_null("/root/GameServices")
	if services != null and bool(services.call("is_ready")):
		for metadata in services.call("list_track_metadata"):
			var definition: TrackDefinition = services.call("get_track", str(metadata.get("track_id", "")))
			if definition != null:
				output.append({
					"label": "%s  •  MY CIRCUIT" % str(metadata.get("display_name", "CUSTOM")),
					"definition": definition,
					"source": "saved custom",
				})
	return output


func _endpoint_value() -> Dictionary:
	return Endpoint.sanitize({
		"host": _host_edit.text if _host_edit != null else "",
		"port": int(_port_spin.value) if _port_spin != null else Endpoint.DEFAULT_PORT,
		"scheme": "https" if _scheme_option != null and _scheme_option.selected == 1 else "http",
		"server_key": Endpoint.DEFAULT_SERVER_KEY,
	})


func _line_edit(text: String, maximum: int) -> LineEdit:
	var edit := LineEdit.new()
	edit.text = text
	edit.max_length = maximum
	edit.custom_minimum_size.y = 48.0
	edit.add_theme_font_size_override("font_size", 18)
	return edit


func _sanitize_room_code(value: String) -> void:
	var clean := ""
	for character in value.to_upper():
		if Limits.ROOM_CODE_ALPHABET.contains(character) and clean.length() < Limits.ROOM_CODE_LENGTH:
			clean += character
	if clean != value:
		_code_edit.text = clean
		_code_edit.caret_column = clean.length()


func _set_busy(value: bool, message: String = "") -> void:
	_busy = value
	if _create_button != null:
		_create_button.disabled = value
	if _join_button != null:
		_join_button.disabled = value
	if _laps_option != null:
		_laps_option.disabled = value
	if _collisions_toggle != null:
		_collisions_toggle.disabled = value
	if not message.is_empty():
		_status.text = message
		_status.add_theme_color_override("font_color", DesignSystem.GOLD)


func _show_result_error(result: Dictionary) -> void:
	var error: Dictionary = result.get("error", {})
	if str(error.get("code", "")) == "update_required":
		_build_update_required(error)
		return
	_status.text = str(error.get("message", "Private-room request failed."))
	_status.add_theme_color_override("font_color", DesignSystem.CORAL)


func _build_update_required(error: Dictionary) -> void:
	_clear_body()
	set_process(false)
	_status.text = "UPDATE REQUIRED"
	_status.add_theme_color_override("font_color", DesignSystem.CORAL)
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(
		Color(0.10, 0.035, 0.06, 0.98), 30, DesignSystem.CORAL, 2
	))
	_root.add_child(panel)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 16)
	panel.add_child(content)
	var title := DesignSystem.title("UPDATE REQUIRED", 42)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var detail := DesignSystem.label(
		str(error.get("message", "This build is incompatible with the private-room service.")),
		18, DesignSystem.WHITE
	)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(detail)
	content.add_child(DesignSystem.label(
		"BUILD %s • PROTOCOL %d • TRACK SCHEMA %d • GENERATOR %d" % [
			Limits.APP_BUILD_ID, Limits.PROTOCOL_VERSION,
			Limits.TRACK_SCHEMA_VERSION, Limits.TRACK_GENERATOR_VERSION,
		], 13, DesignSystem.MUTED
	))
	var offline := DesignSystem.button("PLAY OFFLINE", true, true)
	offline.pressed.connect(func() -> void: navigate_requested.emit("tracks", {}))
	content.add_child(offline)


func _on_session_changed(snapshot: Dictionary) -> void:
	if session != null and session.is_joined() and _roster_list != null:
		_refresh_lobby(snapshot)


func _on_session_error(error: Dictionary) -> void:
	if str(error.get("code", "")) == "update_required":
		_build_update_required(error)
		return
	_status.text = str(error.get("message", "Private-room connection failed."))
	_status.add_theme_color_override("font_color", DesignSystem.CORAL)


func _on_countdown(_countdown: Dictionary) -> void:
	_navigate_to_network_race()


func _connect_session_signals() -> void:
	if session == null:
		_status.text = "MULTIPLAYER SESSION SERVICE IS UNAVAILABLE • OFFLINE PLAY IS READY"
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	if not session.session_changed.is_connected(_on_session_changed):
		session.session_changed.connect(_on_session_changed)
	if not session.session_error.is_connected(_on_session_error):
		session.session_error.connect(_on_session_error)
	if not session.race_countdown_received.is_connected(_on_countdown):
		session.race_countdown_received.connect(_on_countdown)


func _disconnect_session_signals() -> void:
	if session == null:
		return
	if session.session_changed.is_connected(_on_session_changed):
		session.session_changed.disconnect(_on_session_changed)
	if session.session_error.is_connected(_on_session_error):
		session.session_error.disconnect(_on_session_error)
	if session.race_countdown_received.is_connected(_on_countdown):
		session.race_countdown_received.disconnect(_on_countdown)


func _compact_panel(color: Color, border: Color) -> StyleBoxFlat:
	var style := DesignSystem.panel_style(color, 16, border, 1)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 9.0
	style.shadow_size = 4
	return style


func _member_for(members: Array, player_id: String) -> Dictionary:
	for member in members:
		if str(member.get("player_id", "")) == player_id:
			return member
	return {}


func _fixture_can_start(snapshot: Dictionary) -> bool:
	if not bool(snapshot.get("join_locked", false)):
		return false
	for member in snapshot.get("members", []):
		if not bool(member.get("connected", false)) or not bool(member.get("ready", false)):
			return false
	return true


func _fixture_snapshot() -> Dictionary:
	return {
		"connection": "online",
		"joined": true,
		"room_code": "R7G2PH",
		"room_epoch": 1,
		"local_player_id": "fixture-host",
		"display_name": "SABARI",
		"state": "READY",
		"host_id": "fixture-host",
		"member_count": 4,
		"endpoint_label": "local private fixture",
		"race_config": _fixture_race_config.duplicate(true),
		"join_locked": _fixture_join_locked,
		"members": [
			{"player_id": "fixture-host", "display_name": "SABARI", "car_id": "car-prime", "team_id": "team-vector", "slot": 0, "connected": true, "generation_verified": true, "ready": true, "is_host": true},
			{"player_id": "fixture-2", "display_name": "NOVA", "car_id": "car-aurora", "team_id": "team-aurora", "slot": 1, "connected": true, "generation_verified": true, "ready": true, "is_host": false},
			{"player_id": "fixture-3", "display_name": "APEX", "car_id": "car-cinder", "team_id": "team-cinder", "slot": 2, "connected": true, "generation_verified": true, "ready": true, "is_host": false},
			{"player_id": "fixture-4", "display_name": "MINT", "car_id": "car-jade", "team_id": "team-jade", "slot": 3, "connected": true, "generation_verified": true, "ready": true, "is_host": false},
		],
	}


func _fixture_race_payload() -> Dictionary:
	var item := Catalog.all()[0]
	var definition: TrackDefinition = item["definition"]
	var compiled: TrackCompileResult = Compiler.compile(definition)
	var snapshot := _fixture_snapshot()
	return {
		"network_mode": true,
		"visual_fixture": true,
		"track_definition_json": definition.canonical_json(true),
		"source_hash": compiled.track.source_hash,
		"compiled_hash": compiled.track.compile_hash,
		"display_name": definition.track_name,
		"room_code": snapshot["room_code"],
		"room_epoch": 1,
		"roster": snapshot["members"],
		"host_id": "fixture-host",
		"local_player_id": "fixture-host",
		"countdown": {"start_tick": 180, "roster": snapshot["members"], "race_config": snapshot["race_config"]},
		"laps": int(snapshot["race_config"]["laps"]),
		"collisions": bool(snapshot["race_config"]["collisions"]),
	}


func _sync_race_config_controls(snapshot: Dictionary, host: bool, state: String) -> void:
	if _laps_option == null or _collisions_toggle == null:
		return
	var config_value: Variant = snapshot.get("race_config", Limits.default_race_config())
	var config: Dictionary = config_value if config_value is Dictionary else Limits.default_race_config()
	var laps := int(config.get("laps", Limits.DEFAULT_MULTIPLAYER_LAPS))
	_config_update_guard = true
	for index in _laps_option.item_count:
		if int(_laps_option.get_item_id(index)) == laps:
			_laps_option.select(index)
			break
	_collisions_toggle.set_pressed_no_signal(bool(config.get("collisions", Limits.DEFAULT_MULTIPLAYER_COLLISIONS)))
	_config_update_guard = false
	var locked := bool(snapshot.get("join_locked", false)) or state in ["COUNTDOWN", "RACING", "RESULTS", "CLOSED"]
	_laps_option.disabled = not host or locked or _busy
	_collisions_toggle.disabled = not host or locked or _busy
	_laps_option.tooltip_text = "Host selects 1, 3, or 5 laps. Current authoritative rule: %d." % laps
	_collisions_toggle.tooltip_text = "Host-owned vehicle collision rule. Current state: %s." % ("on" if _collisions_toggle.button_pressed else "off")
