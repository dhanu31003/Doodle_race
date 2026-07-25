extends SceneTree
## Visual QA fixture for the selectable first-party bridge circuit.

const TrackSelectScreenType := preload("res://game/ui/screens/track_select_screen.gd")
const TRACK_ID := "builtin-nightfall-crossing"


func _initialize() -> void:
	call_deferred("_build_fixture")


func _build_fixture() -> void:
	root.size = Vector2i(1280, 720)
	var screen := TrackSelectScreenType.new()
	screen.size = Vector2(1280.0, 720.0)
	root.add_child(screen)
	await process_frame
	screen._select_track(TRACK_ID)
