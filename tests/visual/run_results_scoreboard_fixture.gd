extends SceneTree
## Render proof that offline classification keeps updating after the player flag.

const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const RaceEntryType := preload("res://game/race/race_entry.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var output_prefix := "/tmp/raceglyph-results"
	var fixture_size := Vector2i(1280, 720)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output-prefix="):
			output_prefix = argument.trim_prefix("--output-prefix=")
		elif argument.begins_with("--size="):
			var parts := argument.trim_prefix("--size=").split("x")
			if parts.size() == 2:
				fixture_size = Vector2i(maxi(int(parts[0]), 480), maxi(int(parts[1]), 320))
	root.size = fixture_size
	var screen := RaceScreenType.new()
	screen.set_payload({"visual_fixture": true, "grid_size": 12})
	screen.size = Vector2(fixture_size)
	root.add_child(screen)
	for _frame in 4:
		await process_frame
	if screen.director == null or screen.director.entries.size() != 12:
		push_error("Result fixture could not create the full offline grid.")
		quit(1)
		return
	screen.director.phase = screen.director.PHASE_RACING
	screen.director.race_time = 83.716
	var player = screen.director.entry(&"player")
	player.status = RaceEntryType.STATUS_FINISHED
	player.finish_order = 1
	player.finish_time = 83.716
	for index in range(1, 5):
		var early = screen.director.entries[index]
		early.status = RaceEntryType.STATUS_FINISHED
		early.finish_order = index + 1
		early.finish_time = 83.716 + float(index) * 1.375
	screen._finish_race()
	screen._refresh_results_panel_if_changed(true)
	for _frame in 4:
		await process_frame
	var live_path := output_prefix + "-live.png"
	var live_error := root.get_texture().get_image().save_png(live_path)

	for index in range(5, screen.director.entries.size()):
		var finisher = screen.director.entries[index]
		finisher.status = RaceEntryType.STATUS_FINISHED
		finisher.finish_order = index + 1
		finisher.finish_time = 83.716 + float(index) * 1.375
	screen.director.phase = screen.director.PHASE_RESULTS
	screen._refresh_results_panel_if_changed(true)
	for _frame in 4:
		await process_frame
	var final_path := output_prefix + "-final.png"
	var final_error := root.get_texture().get_image().save_png(final_path)
	print("RESULT_SCOREBOARD_VISUAL live=%s final=%s live_error=%d final_error=%d classified=%d" % [
		live_path,
		final_path,
		live_error,
		final_error,
		screen._classified_count(),
	])
	screen.queue_free()
	await process_frame
	var audio := root.get_node_or_null("Audio")
	if audio != null:
		audio.call("shutdown")
	await create_timer(0.08).timeout
	quit(0 if live_error == OK and final_error == OK else 1)
