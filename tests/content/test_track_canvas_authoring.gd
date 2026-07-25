extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const TrackCanvasType := preload("res://game/track/authoring/track_canvas.gd")
const TrackThumbnailType := preload("res://game/ui/components/track_thumbnail.gd")
const TrackStudioType := preload("res://game/ui/screens/track_studio.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_explicit_gap_acceptance(test)
	_test_unsafe_gap_rejected(test)
	_test_exact_demo_needs_no_fix(test)
	_test_grid_move_preview_is_visual_only(test)
	_test_thumbnail_fit_is_bounded_and_aspect_safe(test)
	_test_edit_identity_never_overwrites_new_name(test)
	_test_authority_is_device_size_independent(test)
	_test_multiplayer_round_trip_payload_is_exact_and_cancel_safe(test)
	_test_corner_help_promises_automatic_recovery(test)
	return test.result("track_canvas_authoring")


func _test_explicit_gap_acceptance(test: RefCounted) -> void:
	var canvas := TrackCanvasType.new()
	canvas.size = Vector2(800.0, 500.0)
	canvas.points = _near_closed_loop(20)
	var original_count := canvas.points.size()
	test.assert_true(canvas.is_loop_closed(), "a short seam inside the gate is eligible for review")
	test.assert_true(canvas.will_snap_close(), "a non-zero short seam requires explicit acceptance")
	test.assert_true(canvas.build_normalized_loop(false).is_empty(), "unaccepted seam cannot be built silently")
	test.assert_true(canvas.accept_auto_close(), "player can explicitly accept the highlighted seam")
	test.assert_equal(canvas.points.size(), original_count + 1, "accepted seam appends an exact closing point")
	test.assert_equal(canvas.points[0], canvas.points[-1], "accepted seam closes exactly")
	test.assert_false(canvas.will_snap_close(), "accepted seam no longer requests a correction")
	test.assert_false(canvas.build_normalized_loop(false).is_empty(), "explicitly closed line becomes buildable")
	canvas.undo()
	test.assert_equal(canvas.points.size(), original_count, "auto-close is reversible through Undo")
	test.assert_true(canvas.will_snap_close(), "Undo restores the reviewed seam")
	canvas.free()


func _test_unsafe_gap_rejected(test: RefCounted) -> void:
	var canvas := TrackCanvasType.new()
	canvas.size = Vector2(800.0, 500.0)
	canvas.points = _near_closed_loop(20)
	canvas.points[-1] = Vector2(0.88, 0.86)
	test.assert_false(canvas.is_loop_closed(), "a large gap remains open")
	test.assert_false(canvas.accept_auto_close(), "a large gap cannot be auto-fixed")
	test.assert_true(canvas.build_normalized_loop(true).is_empty(), "large gap cannot bypass validation")
	canvas.free()


func _test_exact_demo_needs_no_fix(test: RefCounted) -> void:
	var canvas := TrackCanvasType.new()
	canvas.size = Vector2(800.0, 500.0)
	canvas.load_demo_loop()
	test.assert_true(canvas.is_loop_closed(), "demo circuit is exactly closed")
	test.assert_false(canvas.will_snap_close(), "exact closure needs no auto-fix")
	test.assert_false(canvas.build_normalized_loop(false).is_empty(), "exact circuit builds without correction")
	canvas.free()


func _test_grid_move_preview_is_visual_only(test: RefCounted) -> void:
	var canvas := TrackCanvasType.new()
	canvas.size = Vector2(800.0, 500.0)
	canvas.points = _near_closed_loop(20)
	var authored := canvas.points.duplicate()
	canvas.show_start_fix_preview(Vector2(110.0, 90.0), Vector2(620.0, 360.0))
	test.assert_true(canvas.has_start_fix_preview(), "grid proposal is exposed as a review overlay")
	test.assert_equal(canvas.points, authored, "grid proposal never mutates authored road points")
	canvas.clear_start_fix_preview()
	test.assert_false(canvas.has_start_fix_preview(), "grid review overlay can be rejected cleanly")
	test.assert_equal(canvas.points, authored, "rejecting grid proposal preserves authored road points")
	canvas.free()


func _test_thumbnail_fit_is_bounded_and_aspect_safe(test: RefCounted) -> void:
	var source := PackedVector2Array([
		Vector2(-100.0, 20.0),
		Vector2(300.0, 20.0),
		Vector2(300.0, 220.0),
		Vector2(-100.0, 220.0),
	])
	var fitted := TrackThumbnailType.fit_points(source, Vector2(164.0, 92.0), 11.0)
	test.assert_equal(fitted.size(), source.size(), "thumbnail preserves every compiled sample")
	for point in fitted:
		test.assert_true(point.x >= 10.999 and point.x <= 153.001, "thumbnail x stays inside padded portrait")
		test.assert_true(point.y >= 10.999 and point.y <= 81.001, "thumbnail y stays inside padded portrait")
	var source_ratio := 400.0 / 200.0
	var fitted_extent := _bounds_extent(fitted)
	test.assert_near(fitted_extent.x / fitted_extent.y, source_ratio, 0.0001, "thumbnail preserves circuit aspect ratio")
	var poisoned := source.duplicate()
	poisoned.append(Vector2(NAN, 0.0))
	test.assert_true(TrackThumbnailType.fit_points(poisoned, Vector2(164.0, 92.0)).is_empty(), "thumbnail rejects non-finite geometry")


func _test_edit_identity_never_overwrites_new_name(test: RefCounted) -> void:
	var previous := TrackDefinitionType.new()
	previous.track_id = "track-existing"
	previous.track_name = "Old Name"
	previous.author_id = "local-author"
	previous.created_at_timestamp = 123
	previous.deterministic_seed = 9876
	previous.start_finish_distance = 321.5
	var edited := TrackDefinitionType.new()
	edited.track_name = "Aurora Bend"
	TrackStudioType.inherit_edit_identity(edited, previous)
	test.assert_equal(edited.track_name, "Aurora Bend", "editing identity never overwrites the newly entered circuit name")
	test.assert_equal(edited.track_id, previous.track_id, "editing retains the stable local track identity")
	test.assert_equal(edited.author_id, previous.author_id, "editing retains author identity")
	test.assert_equal(edited.created_at_timestamp, previous.created_at_timestamp, "editing retains original creation time")
	test.assert_equal(edited.deterministic_seed, previous.deterministic_seed, "editing retains deterministic seed")
	test.assert_near(edited.start_finish_distance, previous.start_finish_distance, 0.0001, "editing preserves the authored grid before explicit review")
	test.assert_near(TrackStudioType.proposal_preview_distance(321.5, 555.0), 233.5, 0.0001, "grid proposal preview converts absolute distance into current-route distance")


func _test_authority_is_device_size_independent(test: RefCounted) -> void:
	var normalized_stroke := _dense_closed_loop(180)
	var phone_canvas := TrackCanvasType.new()
	phone_canvas.size = Vector2(450.0, 360.0)
	phone_canvas.points = normalized_stroke.duplicate()
	var desktop_canvas := TrackCanvasType.new()
	desktop_canvas.size = Vector2(1180.0, 640.0)
	desktop_canvas.points = normalized_stroke.duplicate()
	var authority_size: Vector2 = TrackStudioType.AUTHORING_AUTHORITY_CANVAS_SIZE
	var phone_loop := phone_canvas.build_normalized_loop(false, authority_size)
	var desktop_loop := desktop_canvas.build_normalized_loop(false, authority_size)
	test.assert_true(phone_loop.size() >= 8, "dense normalized phone stroke produces a buildable loop")
	test.assert_equal(phone_loop, desktop_loop, "phone and desktop simplify the same normalized stroke identically")
	var phone_definition: TrackDefinition = TrackStudioType.create_authority_definition(
		phone_loop, null, 36.0, "Authority Twin", 1.0
	)
	var desktop_definition: TrackDefinition = TrackStudioType.create_authority_definition(
		desktop_loop, null, 36.0, "Authority Twin", 1.0
	)
	test.assert_equal(phone_definition.canvas_size, authority_size, "new phone circuit uses the fixed 1280x720 authority canvas")
	test.assert_equal(desktop_definition.canvas_size, authority_size, "new desktop circuit uses the same fixed authority canvas")
	test.assert_equal(phone_definition.control_points, desktop_definition.control_points, "device twins persist identical normalized control points")
	test.assert_near(phone_definition.target_length, desktop_definition.target_length, 0.000001, "device twins derive identical logical target length")
	test.assert_equal(phone_definition.canonical_json(true), desktop_definition.canonical_json(true), "device twins have byte-identical canonical authority")
	test.assert_true(phone_definition.validate_schema().is_valid(), "device-independent authority definition passes schema validation")
	var legacy := TrackDefinitionType.new()
	legacy.canvas_size = Vector2(1024.0, 640.0)
	var edited: TrackDefinition = TrackStudioType.create_authority_definition(
		phone_loop, legacy, 36.0, "Legacy Edit", 1.0
	)
	test.assert_equal(edited.canvas_size, legacy.canvas_size, "editing retains the saved circuit authority canvas")
	phone_canvas.free()
	desktop_canvas.free()


func _test_multiplayer_round_trip_payload_is_exact_and_cancel_safe(test: RefCounted) -> void:
	var definition := TrackDefinitionType.new()
	definition.track_id = "room-authored"
	definition.track_name = "Room Authored"
	definition.control_points = PackedVector2Array([
		Vector2(0.2, 0.3), Vector2(0.4, 0.2), Vector2(0.7, 0.25),
		Vector2(0.8, 0.6), Vector2(0.55, 0.8), Vector2(0.25, 0.7), Vector2(0.2, 0.3),
	])
	definition.refresh_content_hash()
	var completed := TrackStudioType.multiplayer_completion_payload(definition, "a7k9q2")
	test.assert_equal(completed.get("return_room_code"), "A7K9Q2", "Track Studio returns to the exact normalized room code")
	test.assert_equal(completed.get("room_track_definition_json"), definition.canonical_json(true), "room publication receives the exact authored canonical definition")
	var cancelled := TrackStudioType.multiplayer_cancel_payload("a7k9q2")
	test.assert_equal(cancelled, {"return_room_code": "A7K9Q2"}, "cancelling Track Studio preserves only the same room session and publishes no track")


func _test_corner_help_promises_automatic_recovery(test: RefCounted) -> void:
	var help := TrackStudioType.AUTHORING_HELP_TEXT
	test.assert_true("rounded automatically" in help.to_lower(), "Track Studio explains automatic sharp-corner recovery")
	test.assert_false("draw one smooth loop" in help.to_lower(), "Track Studio no longer asks the player to redraw a smooth loop")


func _near_closed_loop(count: int) -> PackedVector2Array:
	var output := PackedVector2Array()
	for index in count:
		var angle := TAU * float(index) / float(count)
		output.append(Vector2(0.5 + cos(angle) * 0.28, 0.5 + sin(angle) * 0.30))
	output[-1] = output[0] + Vector2(0.025, 0.015)
	return output


func _dense_closed_loop(count: int) -> PackedVector2Array:
	var output := PackedVector2Array()
	for index in count:
		var angle := TAU * float(index) / float(count)
		output.append(Vector2(0.5 + cos(angle) * 0.34, 0.5 + sin(angle) * 0.32))
	output.append(output[0])
	return output


func _bounds_extent(points: PackedVector2Array) -> Vector2:
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return maximum - minimum
