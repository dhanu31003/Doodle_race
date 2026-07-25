extends SceneTree
## Captures the real RaceScreen for one released road surface.
## Example:
## godot --path . --script res://tests/visual/run_road_surface_visual_fixture.gd \
##   -- --track=builtin-riverbend --output=/tmp/raceglyph-mud.png --mobile-tier

const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	var track_id := "builtin-riverbend"
	var output := "/tmp/raceglyph-road-surface.png"
	var mobile_tier := false
	var surface_progress := 0.65
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--track="):
			track_id = argument.trim_prefix("--track=")
		elif argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
		elif argument == "--mobile-tier":
			mobile_tier = true
		elif argument.begins_with("--surface-progress="):
			surface_progress = clampf(
				float(argument.trim_prefix("--surface-progress=")), 0.0, 1.0
			)
	var record := CatalogType.by_id(track_id)
	var definition: TrackDefinition = record.get("definition")
	if definition == null:
		push_error("Unknown road-surface fixture: %s" % track_id)
		quit(1)
		return
	root.size = Vector2i(1280, 720)
	var screen := RaceScreenType.new()
	screen.set_payload({
		"track_definition_json": definition.canonical_json(true),
		"display_name": str(record.get("name", track_id)),
		"laps": 3,
		"difficulty": "standard",
		"collisions": true,
		"visual_fixture": true,
	})
	screen.size = Vector2(1280.0, 720.0)
	root.add_child(screen)
	for _frame in 30:
		await process_frame
	if screen.perspective_view == null or screen.race_query == null:
		push_error("Surface fixture could not initialize the true 3D race view")
		quit(1)
		return
	if mobile_tier:
		screen.perspective_view.configure_accessibility(true, false, false, 0.0)
	# Give every car real forward velocity for wheel-spray presentation while
	# keeping their deterministic grid transforms and the normal HUD/camera.
	if screen.director != null:
		for entry in screen.director.entries:
			if entry != null and entry.state != null:
				var sample := screen.race_query.sample_at_distance(entry.state.track_distance)
				entry.state.velocity = Vector2(sample.get("tangent", Vector2.RIGHT)) * 150.0
				entry.state.is_grounded = true
				entry.previous_state = entry.state.duplicate_state()
		screen.perspective_view.update_race(
			screen.director.entry(screen.PLAYER_ID),
			screen.director.entries,
			RaceInput.new(0.0, 0.72, 0.0),
			1.0
		)
	for _frame in 45:
		await process_frame
	# Freeze authority only after the normal scene has settled, then apply the
	# requested coating stage long enough for a deterministic rendered frame.
	screen.set_process(false)
	screen.set_physics_process(false)
	for visual in screen.perspective_view._vehicles.values():
		if visual != null and is_instance_valid(visual) \
				and visual.has_method("set_surface_lap_progress"):
			visual.call("set_surface_lap_progress", surface_progress)
	await process_frame
	var image := root.get_texture().get_image()
	var error := image.save_png(output)
	var snapshot: Dictionary = screen.perspective_view.debug_snapshot()
	print("ROAD_SURFACE_VISUAL track=%s style=%s output=%s save_error=%d car_style=%s coating=%s coating_count=%d visible_count=%d mud=%.3f opacity=%.3f effects=%s" % [
		track_id,
		str(screen.race_query.road_surface),
		output,
		error,
		str(snapshot.get("player_road_surface", "")),
		str(snapshot.get("player_surface_coating_visible", false)),
		int(snapshot.get("player_surface_coating_count", 0)),
		int(snapshot.get("player_surface_coating_visible_count", 0)),
		float(snapshot.get("player_mud_accumulation", 0.0)),
		float(snapshot.get("player_surface_coating_opacity", 0.0)),
		str(snapshot.get("road_surface_effects", {})),
	])
	quit(0 if error == OK else 1)
