extends SceneTree
## Executable landscape layout proof for both UI-scale extremes and both
## perspective race cameras. Track Studio additionally runs a complete viewport
## x UI-scale x inspector-mode matrix; scroll content is audited at its clipping
## surface, for reachability, and for pixel separation from the DRAW/WORLD strip.

const DesignSystemType := preload("res://game/ui/design_system.gd")
const MultiplayerScreenType := preload("res://game/ui/screens/multiplayer_screen.gd")
const NetworkRaceScreenType := preload("res://game/ui/screens/network_race_screen.gd")
const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const TrackStudioType := preload("res://game/ui/screens/track_studio.gd")
const SavedTracksType := preload("res://game/ui/screens/saved_tracks_screen.gd")
const SettingsScreenType := preload("res://game/ui/screens/settings_screen.gd")
const GarageScreenType := preload("res://game/ui/screens/garage_screen.gd")
const CreditsScreenType := preload("res://game/ui/screens/credits_screen.gd")
const TrackSelectScreenType := preload("res://game/ui/screens/track_select_screen.gd")
const OfflineRaceConfigScreenType := preload("res://game/ui/screens/offline_race_config_screen.gd")
const MainMenuScreenType := preload("res://game/ui/screens/main_menu.gd")
const SplashScreenType := preload("res://game/ui/screens/splash_screen.gd")
const TrackTourScreenType := preload("res://game/ui/screens/track_tour_screen.gd")

const FIXTURE_SIZE := Vector2i(1280, 720)

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = FIXTURE_SIZE
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var cases: Array[Dictionary] = [
		{"name": "multiplayer_max", "screen": "multiplayer", "scale": 1.30, "camera": "chase"},
		{"name": "network_chase_max", "screen": "network", "scale": 1.30, "camera": "chase"},
		{"name": "network_cockpit_max", "screen": "network", "scale": 1.30, "camera": "cockpit"},
		{"name": "offline_chase_max", "screen": "offline", "scale": 1.30, "camera": "chase"},
		{"name": "network_chase_min", "screen": "network", "scale": 0.85, "camera": "chase"},
		{"name": "saved_tracks_max", "screen": "saved", "scale": 1.30, "camera": "chase"},
		{"name": "settings_max", "screen": "settings", "scale": 1.30, "camera": "chase"},
		{"name": "garage_max", "screen": "garage", "scale": 1.30, "camera": "chase"},
		{"name": "credits_max", "screen": "credits", "scale": 1.30, "camera": "chase"},
		{"name": "track_select_max", "screen": "tracks", "scale": 1.30, "camera": "chase"},
		{"name": "offline_config_max", "screen": "offline_config", "scale": 1.30, "camera": "chase"},
		{"name": "main_menu_max", "screen": "home", "scale": 1.30, "camera": "chase"},
		{"name": "splash_max", "screen": "splash", "scale": 1.30, "camera": "chase"},
		{"name": "track_tour_max", "screen": "tour", "scale": 1.30, "camera": "chase"},
	]
	cases.append_array(_studio_layout_cases())
	var requested_prefix := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--case-prefix="):
			requested_prefix = argument.trim_prefix("--case-prefix=")
	if not requested_prefix.is_empty():
		var selected_cases: Array[Dictionary] = []
		for case_value in cases:
			if str(case_value.get("name", "")).begins_with(requested_prefix):
				selected_cases.append(case_value)
		cases = selected_cases
	for case_value in cases:
		await _run_case(viewport, case_value)
	DesignSystemType.configure_ui_scale(1.0)
	viewport.free()
	var audio := root.get_node_or_null("Audio")
	if audio != null:
		audio.call("shutdown")
		await create_timer(0.14, true, false, true).timeout
		audio.free()
		await process_frame
	if _failures == 0:
		print("PASS accessibility layout (%d landscape fixtures)" % cases.size())
	else:
		push_error("Accessibility layout failed in %d fixture(s)." % _failures)
	quit(_failures)


func _run_case(viewport: SubViewport, case_value: Dictionary) -> void:
	DesignSystemType.configure_ui_scale(float(case_value["scale"]))
	var fixture_size: Vector2i = case_value.get("size", FIXTURE_SIZE)
	viewport.size = fixture_size
	var screen: Control
	match str(case_value["screen"]):
		"multiplayer":
			screen = MultiplayerScreenType.new()
		"offline":
			screen = RaceScreenType.new()
		"studio":
			screen = TrackStudioType.new()
		"saved":
			screen = SavedTracksType.new()
		"settings":
			screen = SettingsScreenType.new()
		"garage":
			screen = GarageScreenType.new()
		"credits":
			screen = CreditsScreenType.new()
		"tracks":
			screen = TrackSelectScreenType.new()
		"offline_config":
			screen = OfflineRaceConfigScreenType.new()
		"home":
			screen = MainMenuScreenType.new()
		"splash":
			screen = SplashScreenType.new()
		"tour":
			screen = TrackTourScreenType.new()
		_:
			screen = NetworkRaceScreenType.new()
	if screen.has_method("set_payload"):
		screen.call("set_payload", {
			"visual_fixture": true,
			"camera_view": str(case_value["camera"]),
		})
	# Match AppShell.navigate(): screens receive full-rect anchors before they
	# enter the tree, so their child safe-area anchors start with zero offsets.
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(screen)
	await process_frame
	await process_frame
	await process_frame
	DesignSystemType.apply_ui_scale(screen, float(case_value["scale"]))
	await process_frame
	await process_frame
	if screen is TrackStudioType:
		screen._mode_tabs.current_tab = int(case_value.get("studio_tab", 0))
		var safe_insets: Vector4 = case_value.get("safe_insets", Vector4.ZERO)
		if safe_insets != Vector4.ZERO:
			var safe_area := screen.get_node_or_null("SafeArea")
			if safe_area != null:
				# Deterministic stand-in for a landscape camera cutout and home
				# indicator; SafeMarginContainer's inset math has separate tests.
				safe_area.call("_apply_margins", safe_insets)
		await process_frame
		await process_frame
	var overflows := _visible_layout_overflows(screen, Vector2(fixture_size))
	overflows.append_array(_case_contract_failures(screen))
	if screen is TrackStudioType:
		var expected_tab := int(case_value.get("studio_tab", 0))
		if screen._mode_tabs.current_tab != expected_tab \
				or screen._tabs.current_tab != expected_tab:
			overflows.append("DRAW/WORLD selector and inspector content are not synchronized")
	if screen is TrackStudioType and bool(case_value.get("prove_scroll", false)):
		var reachability_failure := await _studio_reachability_failure(
			screen, int(case_value.get("studio_tab", 0))
		)
		if not reachability_failure.is_empty():
			overflows.append(reachability_failure)
	var camera_ok := true
	if screen is NetworkRaceScreenType:
		camera_ok = str(screen.perspective.camera_mode) == str(case_value["camera"])
	if not overflows.is_empty() or not camera_ok:
		_failures += 1
		push_error("LAYOUT_AUDIT FAIL %s: %s%s" % [
			str(case_value["name"]),
			"; ".join(overflows),
			"; camera mismatch" if not camera_ok else "",
		])
	else:
		print("LAYOUT_AUDIT PASS %s size=%dx%d scale=%.2f camera=%s" % [
			str(case_value["name"]), fixture_size.x, fixture_size.y,
			float(case_value["scale"]), str(case_value["camera"])
		])
	screen.set_process(false)
	screen.set_process_unhandled_input(false)
	for tween in get_processed_tweens():
		tween.kill()
	screen.free()
	await process_frame


func _visible_layout_overflows(screen: Control, fixture_size: Vector2) -> PackedStringArray:
	var output := PackedStringArray()
	var fixture_rect := Rect2(Vector2.ZERO, fixture_size).grow(2.0)
	var pending: Array[Node] = [screen]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		for child in node.get_children():
			pending.append(child)
		if not node is Control:
			continue
		var control := node as Control
		if not control.is_visible_in_tree() or _inside_scroll_content(control, screen):
			continue
		var rect := control.get_global_rect()
		if rect.size.x < 1.0 or rect.size.y < 1.0:
			continue
		if not fixture_rect.encloses(rect):
			output.append("%s=%s" % [str(control.get_path()), str(rect)])
	return output


func _case_contract_failures(screen: Control) -> PackedStringArray:
	var output := PackedStringArray()
	if screen is TrackStudioType:
		var studio := screen as TrackStudioType
		var safe_area := studio.get_node_or_null("SafeArea")
		if safe_area == null:
			output.append("Track Studio does not use the platform safe-area container")
		if studio.auto_close_button.get_parent() != studio._demo_button.get_parent() \
				or studio.auto_close_button.get_index() + 1 != studio._demo_button.get_index():
			output.append("SNAP GAP CLOSED is not directly above LOAD DEMO LOOP")
		var touch_controls: Array[Control] = [
			studio.undo_button,
			studio.redo_button,
			studio._clear_button,
			studio.auto_close_button,
			studio._demo_button,
			studio.confirm_button,
			studio._mode_tabs,
		]
		for control in touch_controls:
			if control.custom_minimum_size.y < 48.0 or control.size.y < 47.5:
				output.append("mobile touch target below 48 px: %s" % str(control.get_path()))
		var draw_scroll := studio._tabs.get_node_or_null("DRAW") as ScrollContainer
		var world_scroll := studio._tabs.get_node_or_null("WORLD") as ScrollContainer
		for scroll in [draw_scroll, world_scroll]:
			if scroll == null or not scroll.follow_focus \
					or scroll.vertical_scroll_mode != ScrollContainer.SCROLL_MODE_AUTO:
				output.append("inspector tab is not touch-scroll/focus reachable")
		if studio._mode_tabs == null or studio._mode_tabs.tab_count != 2 \
				or studio._mode_tabs.get_tab_title(0) != "DRAW TRACK" \
				or studio._mode_tabs.get_tab_title(1) != "WORLD & ROAD":
			output.append("Track Studio does not expose distinct DRAW TRACK/WORLD & ROAD sections")
		else:
			var selector_rect := studio._mode_tabs.get_global_rect()
			var content_rect := studio._tabs.get_global_rect()
			var active_scroll := studio._tabs.get_current_tab_control() as ScrollContainer
			if selector_rect.intersection(content_rect).has_area():
				output.append("DRAW/WORLD selector overlaps inspector content by %s" % str(
					selector_rect.intersection(content_rect)
				))
			if active_scroll == null \
					or selector_rect.intersection(active_scroll.get_global_rect()).has_area():
				output.append("DRAW/WORLD selector overlaps the visible option scroll surface")
			for tab_index in studio._mode_tabs.tab_count:
				var tab_rect := studio._mode_tabs.get_tab_rect(tab_index)
				if tab_rect.size.y < 47.5:
					output.append("inspector mode tab below 48 px: %s" % str(tab_rect))
	elif screen is TrackTourScreenType:
		if _find_button(screen, "RESTART TOUR") != null:
			output.append("My Circuit tour still exposes RESTART TOUR")
	return output


func _studio_reachability_failure(studio: TrackStudioType, tab_index: int) -> String:
	var active_scroll := studio._tabs.get_tab_control(tab_index) as ScrollContainer
	if active_scroll == null:
		return "active Track Studio tab is not a bounded scroll surface"
	var target: Control = studio._demo_button if tab_index == 0 else studio.bridge_toggle
	active_scroll.ensure_control_visible(target)
	await process_frame
	await process_frame
	var visible_rect := active_scroll.get_global_rect().grow(1.0)
	if not visible_rect.encloses(target.get_global_rect()):
		return "mobile inspector cannot scroll its final action fully into view"
	if not Rect2(Vector2.ZERO, studio.size).grow(1.0).encloses(studio.confirm_button.get_global_rect()):
		return "BUILD CIRCUIT is not persistently reachable on mobile"
	return ""


func _studio_layout_cases() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var scales := PackedFloat32Array([0.85, 1.0, 1.30])
	var scale_names := PackedStringArray(["085", "100", "130"])
	var fixtures: Array[Dictionary] = [
		{
			"name": "1280x720",
			"size": Vector2i(1280, 720),
			"safe_insets": Vector4.ZERO,
		},
		{
			"name": "notched_960x540",
			"size": Vector2i(960, 540),
			"safe_insets": Vector4(28.0, 0.0, 28.0, 16.0),
		},
	]
	for fixture in fixtures:
		for scale_index in scales.size():
			for tab_index in 2:
				output.append({
					"name": "studio_%s_%s_scale_%s" % [
						str(fixture["name"]), "draw" if tab_index == 0 else "world",
						str(scale_names[scale_index]),
					],
					"screen": "studio",
					"scale": scales[scale_index],
					"camera": "chase",
					"size": fixture["size"],
					"safe_insets": fixture["safe_insets"],
					"studio_tab": tab_index,
					"prove_scroll": true,
				})
	return output


func _find_button(root_node: Node, text_value: String) -> Button:
	if root_node is Button and (root_node as Button).text == text_value:
		return root_node as Button
	for child in root_node.get_children():
		var found := _find_button(child, text_value)
		if found != null:
			return found
	return null


func _inside_scroll_content(control: Control, screen: Control) -> bool:
	var ancestor := control.get_parent()
	while ancestor != null and ancestor != screen:
		if ancestor is ScrollContainer:
			return true
		ancestor = ancestor.get_parent()
	return false
