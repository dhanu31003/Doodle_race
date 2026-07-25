extends Control

signal navigate_requested(route: String, payload: Dictionary)

var route_name := ""

func configure(route: String) -> void:
	route_name = route

func _ready() -> void:
	var safe := DesignSystem.make_margin(64, 48, 64, 48)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.95), 30, Color(0.37, 1.0, 0.82, 0.15), 1))
	safe.add_child(card)
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 18)
	card.add_child(content)
	var label_name := route_name.replace("_", " ").to_upper()
	content.add_child(DesignSystem.title(label_name, 46))
	var copy := DesignSystem.label(_copy_for_route(route_name), 20, DesignSystem.MUTED)
	copy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.custom_minimum_size.x = 680.0
	content.add_child(copy)
	var back := DesignSystem.button("BACK TO PADDOCK", true, true)
	back.pressed.connect(func() -> void: navigate_requested.emit("home", {}))
	content.add_child(back)

func _copy_for_route(route: String) -> String:
	match route:
		"multiplayer":
			return "Private room creation, short-code joining, readiness, and host controls are being wired to the verified local backend. Offline play remains available."
		"saved":
			return "Saved circuits will appear here with deterministic thumbnails, edit, export, and deletion controls."
		"garage":
			return "Choose an original team identity, car colorway, and driver profile. Performance remains fair across every team."
		"settings":
			return "Controls, accessibility, audio, graphics, haptics, and battery modes live here."
		"credits":
			return "RaceGlyph uses original project-owned artwork and open-source tools. The complete license ledger ships with every build."
		_:
			return "This screen is part of the active release plan."
