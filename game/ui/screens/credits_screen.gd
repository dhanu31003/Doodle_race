extends Control

signal navigate_requested(route: String, payload: Dictionary)


func _ready() -> void:
	_build()


func _build() -> void:
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
	var title := DesignSystem.title("CREDITS & LICENSES", 36)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	var version := DesignSystem.label("RACEGLYPH • GODOT %s" % Engine.get_version_info().get("string", "4.x"), 13, DesignSystem.MINT)
	version.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(version)

	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.97), 28, Color(1.0, 1.0, 1.0, 0.08), 1))
	root.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	scroll.add_child(content)

	_add_section(content, "MADE FOR THIS GAME", DesignSystem.MINT,
		"RaceGlyph's game design, code, premium 3D Formula car, fictional liveries, interface, icons, brand geometry, and audio were created specifically for this project. The vehicle is a clean-room Blender model with original moving slicks, brakes, suspension, halo, driver controls, and animation. No real teams, drivers, sponsors, circuits, trademarks, third-party vehicle geometry or textures, fonts, recordings, melodies, or sample libraries are included.")
	_add_section(content, "CC0 3D FOUNDATIONS", DesignSystem.MINT,
		"Racing Kit 1.2 props by Kenney, selected nature props by Quaternius, and daylight/asphalt/grass sources by Poly Haven are dedicated to the public domain under CC0 1.0. RaceGlyph adds its own unbranded vehicle, world construction, material tuning, lighting, and placement. Source files, checksums, and exact license proofs are retained in the shipped asset ledger.")
	_add_section(content, "GENERATED KEY ART", DesignSystem.CYAN,
		"The splash and store key art was generated specifically for RaceGlyph with OpenAI image generation, then visually reviewed and prepared for runtime use. Its project source and final WebP are preserved in the shipped asset ledger. No real-world racing identity was requested or intentionally incorporated.")
	_add_section(content, "PRIVACY", DesignSystem.GOLD,
		"Offline play, settings, saved tracks, selected car, lap records, and results stay in the app's local sandbox. RaceGlyph has no advertising, analytics, telemetry, chat, or account requirement. Settings can export a verified copy, reset race progress, or delete all local data. Private rooms use an anonymous device-scoped identity only while that feature is used.")
	_add_section(content, "GODOT ENGINE — MIT LICENSE", DesignSystem.CORAL,
		"Copyright © 2014-present Godot Engine contributors. Copyright © 2007-2014 Juan Linietsky, Ariel Manzur.\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the ‘Software’), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED ‘AS IS’, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.")
	_add_section(content, "MULTIPLAYER SOFTWARE", DesignSystem.MUTED,
		"The app bundles the official Heroic Labs Nakama Godot client SDK 3.4.0 under the Apache License 2.0; its full license and upstream record ship with the app. The optional development/server stack uses Nakama 3.40.0 (Apache License 2.0) and PostgreSQL 17.9 (PostgreSQL License). Offline play does not require those server components. Exact source revisions, image digests, and operating notes are retained in the release ledgers.")
	var end := DesignSystem.label("LicenseRef-RaceGlyph-Original  •  Inventory verified 24 July 2026", 13, Color(0.6, 0.68, 0.76, 0.78))
	end.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(end)


func _add_section(parent: VBoxContainer, heading: String, accent: Color, body: String) -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.035, 0.075, 0.135, 0.72), 18, Color(accent, 0.18), 1))
	parent.add_child(card)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	card.add_child(content)
	content.add_child(DesignSystem.label(heading, 15, accent))
	var copy := DesignSystem.label(body, 15, DesignSystem.WHITE)
	copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.add_theme_constant_override("line_spacing", 3)
	content.add_child(copy)
