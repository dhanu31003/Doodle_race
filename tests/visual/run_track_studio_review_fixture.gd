extends SceneTree
## Visual QA fixture for the standalone WORLD & ROAD inspector.

const TrackStudioType := preload("res://game/ui/screens/track_studio.gd")


func _initialize() -> void:
	call_deferred("_build_fixture")


func _build_fixture() -> void:
	var output := "/tmp/raceglyph-track-studio-world.png"
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
	screen.name_field.text = "Aurora Bend"
	screen._mode_tabs.current_tab = 1
	screen._on_inspector_mode_changed(1)
	for _frame in 12:
		await process_frame
	var image := root.get_texture().get_image()
	var error := image.save_png(output)
	print("TRACK_STUDIO_WORLD_VISUAL output=%s save_error=%d grid_review_nodes=%d" % [
		output,
		error,
		screen.find_children("*Grid*Review*", "Control", true, false).size(),
	])
	quit(0 if error == OK else 1)
