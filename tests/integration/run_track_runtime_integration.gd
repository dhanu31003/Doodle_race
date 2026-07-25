extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const GameLimitsType := preload("res://game/config/game_limits.gd")
const TrackCanvasType := preload("res://game/track/authoring/track_canvas.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackRendererType := preload("res://game/track/rendering/track_renderer.gd")
const QuantizationType := preload("res://game/core/quantization.gd")


func _initialize() -> void:
	var test := TestCaseType.new()
	_test_canvas_contract(test)
	_test_compiler_to_renderer_contract(test)
	var result := test.result("track_runtime_integration")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _test_canvas_contract(test: RefCounted) -> void:
	var canvas := TrackCanvasType.new()
	canvas.size = Vector2(1000.0, 600.0)
	canvas.load_demo_loop()
	var before_resize := canvas.build_normalized_loop(true)
	test.assert_true(canvas.is_loop_closed(), "demo track must close inside the bounded gate")
	test.assert_true(before_resize.size() >= 8, "closed demo must produce a normalized loop")
	test.assert_true(before_resize.size() <= GameLimitsType.MAX_CONTROL_POINTS, "authored definition must respect the control-point cap")
	canvas.size = Vector2(1600.0, 900.0)
	var after_resize := canvas.build_normalized_loop(true)
	test.assert_equal(after_resize, before_resize, "canvas resize must not reshape normalized authored points")

	canvas.points.clear()
	for index in 18:
		canvas.points.append(Vector2(0.08 + float(index) * 0.04, 0.5))
	test.assert_true(canvas.build_normalized_loop(true).is_empty(), "auto-close must reject an arbitrary open-line gap")

	canvas.points.clear()
	for index in canvas.MAX_CAPTURE_POINTS + 300:
		var position := Vector2(80.0, 80.0) if index % 2 == 0 else Vector2(1500.0, 820.0)
		canvas._append_point(position, index == 0)
	test.assert_equal(canvas.points.size(), canvas.MAX_CAPTURE_POINTS, "pointer capture must stop at its bounded input limit")
	canvas.free()


func _test_compiler_to_renderer_contract(test: RefCounted) -> void:
	var canvas := TrackCanvasType.new()
	canvas.size = Vector2(1200.0, 720.0)
	canvas.load_demo_loop()
	var definition: TrackDefinition = TrackDefinitionType.create(
		canvas.build_normalized_loop(true), canvas.size, 36.0, "Runtime Integration"
	)
	definition.target_length = QuantizationType.scalar(clampf(canvas.estimated_length_pixels(), 900.0, 2600.0))
	definition.track_id = ""
	definition.track_id = definition.derived_track_id()
	definition.refresh_content_hash()
	var compiled: TrackCompileResult = TrackCompilerType.compile(definition)
	if compiled.track != null and compiled.report.has_code(&"geometry.start_straight_too_short"):
		definition.start_finish_distance = compiled.track.suggested_start_finish_distance
		definition.refresh_content_hash()
		compiled = TrackCompilerType.compile(definition)
	test.assert_true(compiled.succeeded(), "studio demo must pass the production compiler: %s" % str(compiled.report.to_dictionary()))
	if not compiled.succeeded():
		canvas.free()
		return
	var second := TrackCompilerType.compile(TrackDefinitionType.from_json(definition.canonical_json(true)))
	test.assert_true(second.succeeded(), "canonical definition must compile after a wire round trip: %s" % str(second.report.to_dictionary()))
	if second.track != null:
		test.assert_equal(second.track.compile_hash, compiled.track.compile_hash, "studio and race recompilation fingerprints must match")

	var renderer := TrackRendererType.new()
	renderer.size = Vector2(1280.0, 720.0)
	renderer.set_compiled_track(compiled.track)
	test.assert_equal(renderer.curve.size(), compiled.track.centerline.size() + 1, "renderer must consume the compiler centerline directly")
	test.assert_near(renderer.get_track_length(), compiled.track.total_length, 0.001, "race timing must use logical compiled length")
	var quarter_segment := renderer._segment_for_distance(renderer.display_track_length * 0.25)
	test.assert_true(renderer.curve_distances[quarter_segment] <= renderer.display_track_length * 0.25, "arc lookup lower bound")
	test.assert_true(renderer.curve_distances[quarter_segment + 1] >= renderer.display_track_length * 0.25, "arc lookup upper bound")
	var original_length := renderer.get_track_length()
	renderer.size = Vector2(2400.0, 1080.0)
	renderer._rebuild()
	test.assert_near(renderer.get_track_length(), original_length, 0.001, "device aspect changes must not change race timing")
	renderer.free()
	canvas.free()
