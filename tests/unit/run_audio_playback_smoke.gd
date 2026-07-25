extends SceneTree
## Short integration smoke for the real AudioStreamPlayer playback path.

const AudioManagerType := preload("res://game/audio/audio_manager.gd")


func _initialize() -> void:
	call_deferred("_run_smoke")


func _run_smoke() -> void:
	var failures: PackedStringArray = []
	var manager := AudioManagerType.new()
	root.add_child(manager)
	if not manager.play_music(&"menu_loop"):
		failures.append("menu loop did not start")
	if not manager.start_engine():
		failures.append("engine loop did not start")
	manager.update_engine(0.72, 1.0)
	if not manager.play_ambience():
		failures.append("ambience loop did not start")
	if not manager.play_sfx(&"click"):
		failures.append("click did not start")
	if manager.play_sfx(&"click"):
		failures.append("immediate repeated click bypassed storm limit")
	await create_timer(0.12).timeout
	manager.set_gameplay_paused(true)
	if manager.play_sfx(&"boost"):
		failures.append("boost played while gameplay was paused")
	if not manager.play_sfx(&"confirm"):
		failures.append("pause-menu confirmation did not play")
	await create_timer(0.48).timeout
	manager.shutdown()
	await create_timer(0.12).timeout
	manager.free()
	await process_frame
	if failures.is_empty():
		print("PASS audio_playback_smoke")
	else:
		print("FAIL audio_playback_smoke")
		for failure in failures:
			print("  - %s" % failure)
	quit(1 if not failures.is_empty() else 0)
