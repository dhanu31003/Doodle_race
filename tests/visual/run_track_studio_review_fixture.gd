extends SceneTree
## Visual QA fixture for the explicit start-grid relocation review.

const TrackStudioType := preload("res://game/ui/screens/track_studio.gd")


func _initialize() -> void:
	call_deferred("_build_fixture")


func _build_fixture() -> void:
	root.size = Vector2i(1280, 720)
	var screen := TrackStudioType.new()
	screen.size = Vector2(1280.0, 720.0)
	root.add_child(screen)
	await process_frame
	await process_frame
	screen.canvas.load_demo_loop()
	var source := screen.canvas.points.duplicate()
	if source.size() > 1 and source[0].is_equal_approx(source[-1]):
		source.remove_at(source.size() - 1)
	var shifted := PackedVector2Array()
	var curve_start := mini(15, source.size() - 1)
	for index in source.size():
		shifted.append(source[(index + curve_start) % source.size()])
	shifted.append(shifted[0])
	screen.canvas.points = shifted
	screen.canvas.track_changed.emit(shifted.size(), true)
	screen.name_field.text = "Aurora Bend"
	screen._confirm_track()
