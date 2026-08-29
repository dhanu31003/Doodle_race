extends SceneTree
## Visual proof that mobile world options open as a release-only scroll sheet.

const TrackStudioType := preload("res://game/ui/screens/track_studio.gd")


func _initialize() -> void:
	call_deferred("_build_fixture")


func _build_fixture() -> void:
	var output := "/tmp/raceglyph-touch-option.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
	root.size = Vector2i(1280, 720)
	var screen := TrackStudioType.new()
	screen.size = Vector2(1280.0, 720.0)
	root.add_child(screen)
	await process_frame
	await process_frame
	screen.canvas.load_demo_loop()
	screen._mode_tabs.current_tab = 1
	screen._on_inspector_mode_changed(1)
	await process_frame
	screen.surface_option._open_options()
	for unused in 4:
		await process_frame
	var contract: Dictionary = screen.surface_option.debug_touch_contract()
	var error := root.get_texture().get_image().save_png(output)
	print("TOUCH_OPTION_VISUAL output=%s save_error=%d release_mode=%d scroll_deadzone=%d" % [
		output, error, int(contract["selection_action_mode"]),
		int(contract["scroll_deadzone"]),
	])
	quit(0 if error == OK else 1)
