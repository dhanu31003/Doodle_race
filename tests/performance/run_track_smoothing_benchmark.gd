extends SceneTree
## Release-bound benchmark for the maximum supported centerline sample count.

const TestCaseType := preload("res://tests/support/test_case.gd")
const GameLimitsType := preload("res://game/config/game_limits.gd")
const SmootherType := preload("res://game/track/generation/curvature_safe_smoother.gd")
const SplineType := preload("res://game/track/generation/closed_spline_resampler.gd")
const AnalyzerType := preload("res://game/track/generation/track_geometry_analyzer.gd")
const DefinitionType := preload("res://game/track/definition/track_definition.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")

const SAMPLE_COUNT := GameLimitsType.MAX_RESAMPLED_POINTS
const TARGET_LENGTH := 24000.0
const TRACK_WIDTH := 512.0
const REQUIRED_RADIUS := TRACK_WIDTH * GameLimitsType.MIN_RADIUS_TO_WIDTH_RATIO
const CANVAS_SIZE := Vector2(8192.0, 8192.0)


func _initialize() -> void:
	var test := TestCaseType.new()
	var source := _maximum_rectangle()
	var started_usec := Time.get_ticks_usec()
	var first := SmootherType.round_to_minimum_radius(
		source, TARGET_LENGTH, REQUIRED_RADIUS, CANVAS_SIZE, TRACK_WIDTH
	)
	var elapsed_milliseconds := float(Time.get_ticks_usec() - started_usec) / 1000.0
	var second := SmootherType.round_to_minimum_radius(
		source, TARGET_LENGTH, REQUIRED_RADIUS, CANVAS_SIZE, TRACK_WIDTH
	)
	var points: PackedVector2Array = first.get("points", PackedVector2Array())
	test.assert_true(bool(first.get("succeeded", false)), "maximum-size sharp rectangle must recover")
	test.assert_true(bool(first.get("adjusted", false)), "maximum-size sharp rectangle exercises fairing")
	test.assert_true(points.size() <= SmootherType.MAX_RECOVERY_SAMPLES, "maximum input compiles onto the bounded verified recovery lattice")
	test.assert_true(points.size() >= GameLimitsType.MIN_RESAMPLED_POINTS, "bounded recovery lattice retains sufficient canonical samples")
	test.assert_true(elapsed_milliseconds <= 250.0, "maximum-size recovery %.3fms must stay within the 250ms interaction budget" % elapsed_milliseconds)
	test.assert_equal(points, second.get("points", PackedVector2Array()), "maximum-size recovery is byte-deterministic")
	test.assert_true(float(first.get("maximum_displacement", INF)) <= REQUIRED_RADIUS, "adaptive maximum-size rounding remains within the unsafe corner envelope")
	if not points.is_empty():
		var analysis := AnalyzerType.analyze(points)
		var minimum_radius := _minimum_finite_radius(analysis.radii)
		test.assert_true(minimum_radius >= REQUIRED_RADIUS, "maximum-size final lattice meets the measured radius envelope")
		test.assert_near(SplineType.closed_length(points), TARGET_LENGTH, 2.0, "maximum-size final lattice retains target length")
		test.assert_true(SplineType.closed_length(points) / float(points.size()) <= GameLimitsType.MAX_SAMPLE_SPACING, "adaptive lattice honors the maximum published sample spacing")
		test.assert_equal(analysis.winding, &"clockwise", "maximum-size recovery retains authored direction")
		test.assert_true(points[0].distance_to(source[0]) <= REQUIRED_RADIUS * 0.25, "maximum-size recovery keeps the start seam anchored")
		test.assert_true(_inside_track_inset(points), "maximum-size recovery keeps the full road inside canvas bounds")
	var full_started_usec := Time.get_ticks_usec()
	var full_lattice := SmootherType.round_to_minimum_radius(
		source,
		TARGET_LENGTH,
		GameLimitsType.MIN_TURN_RADIUS,
		CANVAS_SIZE,
		GameLimitsType.MIN_TRACK_WIDTH
	)
	var full_milliseconds := float(Time.get_ticks_usec() - full_started_usec) / 1000.0
	var full_points: PackedVector2Array = full_lattice.get("points", PackedVector2Array())
	test.assert_true(bool(full_lattice.get("succeeded", false)), "long/narrow maximum lattice recovers")
	test.assert_true(
		full_points.size() <= SmootherType.INTERACTIVE_RECOVERY_SAMPLES,
		"long/narrow circuit uses the bounded interactive recovery lattice"
	)
	test.assert_true(full_milliseconds <= 250.0, "full-lattice recovery %.3fms stays within the 250ms interaction budget" % full_milliseconds)
	if not full_points.is_empty():
		var full_analysis := AnalyzerType.analyze(full_points)
		test.assert_true(_minimum_finite_radius(full_analysis.radii) >= GameLimitsType.MIN_TURN_RADIUS, "full-lattice final output meets its measured radius")
		test.assert_near(SplineType.closed_length(full_points), TARGET_LENGTH, 4.0, "full-lattice output retains target length")
		test.assert_true(
			SplineType.closed_length(full_points) / float(full_points.size())
					<= GameLimitsType.MAX_SAMPLE_SPACING,
			"bounded full-lattice output retains legal published spacing"
		)
		test.assert_equal(full_analysis.winding, &"clockwise", "full-lattice output retains direction")
		test.assert_true(full_points[0].distance_to(source[0]) <= GameLimitsType.MIN_TURN_RADIUS, "full-lattice output keeps the start seam anchored")
		test.assert_true(
			int(full_lattice.get("fairing_radius_samples", 0)) == 1
					and str(full_lattice.get("fallback_method", "")) != "harmonic_projection",
			"full-lattice rounding uses only the one-sample local point pass"
		)
	var definition := _maximum_compiler_definition()
	var compile_started_usec := Time.get_ticks_usec()
	var compiled := CompilerType.compile(definition, 1.0)
	var compile_milliseconds := float(Time.get_ticks_usec() - compile_started_usec) / 1000.0
	var overlap_milliseconds := 0.0
	var crossing_milliseconds := 0.0
	var hash_milliseconds := 0.0
	if compiled.track != null:
		var overlap_started := Time.get_ticks_usec()
		ValidatorType.find_surface_overlaps(compiled.track, 1, definition.bridge_crossings)
		overlap_milliseconds = float(Time.get_ticks_usec() - overlap_started) / 1000.0
		var crossing_started := Time.get_ticks_usec()
		ValidatorType.find_crossings(compiled.track)
		crossing_milliseconds = float(Time.get_ticks_usec() - crossing_started) / 1000.0
		var hash_started := Time.get_ticks_usec()
		compiled.track.refresh_compile_hash()
		hash_milliseconds = float(Time.get_ticks_usec() - hash_started) / 1000.0
	test.assert_true(compiled.track != null, "production compiler accepts the maximum-sample sharp circuit: %s" % str(compiled.report.to_dictionary()))
	test.assert_true(compiled.report.is_valid(), "production maximum-sample sharp circuit is fully valid: %s" % str(compiled.report.to_dictionary()))
	test.assert_true(compile_milliseconds <= 250.0, "production maximum-sample compile %.3fms stays within the 250ms interaction budget" % compile_milliseconds)
	test.assert_true(compiled.report.has_code(&"geometry.turns_auto_smoothed"), "production benchmark actually exercises automatic corner recovery")
	test.assert_false(compiled.report.has_code(&"geometry.turn_radius_too_small"), "production benchmark final output passes the radius validator")
	if compiled.track != null:
		test.assert_true(compiled.track.centerline.size() <= SmootherType.INTERACTIVE_RECOVERY_SAMPLES, "high-radius production compile publishes the interactive verified lattice")
		test.assert_true(compiled.track.sample_spacing >= GameLimitsType.MIN_SAMPLE_SPACING and compiled.track.sample_spacing <= GameLimitsType.MAX_SAMPLE_SPACING, "production compiler preserves the declared sample-spacing contract")
		test.assert_true(_minimum_finite_radius(compiled.track.radii) >= REQUIRED_RADIUS, "production compiler measures the final radius on its published lattice")
		test.assert_equal(compiled.track.direction, &"clockwise", "production maximum-sample compile retains direction")
		test.assert_false(compiled.report.has_code(&"geometry.track_out_of_bounds"), "production maximum-sample compile stays in bounds")
		test.assert_false(compiled.report.has_code(&"geometry.road_surface_overlap"), "production maximum-sample compile retains road clearance")
	print("MAX_SMOOTHING_PROOF samples=%d elapsed_ms=%.3f evaluations=%d blur_radius=%d minimum_radius=%.3f required_radius=%.3f seam_displacement=%.3f" % [
		points.size(),
		elapsed_milliseconds,
		int(first.get("candidate_evaluations", 0)),
		int(first.get("fairing_radius_samples", 0)),
		_minimum_finite_radius(AnalyzerType.analyze(points).radii) if not points.is_empty() else 0.0,
		REQUIRED_RADIUS,
		points[0].distance_to(source[0]) if not points.is_empty() else INF,
	])
	print("MAX_COMPILER_PROOF source_samples=%d output_samples=%d sample_spacing=%.3f elapsed_ms=%.3f overlap_ms=%.3f crossing_ms=%.3f hash_ms=%.3f minimum_radius=%.3f maximum_displacement=%.3f" % [
		_auto_smoothing_count(compiled, "source_sample_count"),
		compiled.track.centerline.size() if compiled.track != null else 0,
		compiled.track.sample_spacing if compiled.track != null else INF,
		compile_milliseconds,
		overlap_milliseconds,
		crossing_milliseconds,
		hash_milliseconds,
		_minimum_finite_radius(compiled.track.radii) if compiled.track != null else 0.0,
		_auto_smoothing_float(compiled, "maximum_displacement"),
	])
	print("FULL_LATTICE_PROOF samples=%d elapsed_ms=%.3f evaluations=%d blur_radius=%d minimum_radius=%.3f" % [
		full_points.size(),
		full_milliseconds,
		int(full_lattice.get("candidate_evaluations", 0)),
		int(full_lattice.get("fairing_radius_samples", 0)),
		_minimum_finite_radius(AnalyzerType.analyze(full_points).radii) if not full_points.is_empty() else 0.0,
	])
	var result := test.result("maximum_track_smoothing_performance")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _maximum_rectangle() -> PackedVector2Array:
	var output := PackedVector2Array()
	output.resize(SAMPLE_COUNT)
	for index in SAMPLE_COUNT:
		output[index] = _rectangle_point(float(index) * TARGET_LENGTH / float(SAMPLE_COUNT))
	return output


func _maximum_compiler_definition() -> TrackDefinition:
	var definition := DefinitionType.create(PackedVector2Array([
		Vector2(0.50, 0.194824), Vector2(0.927246, 0.194824),
		Vector2(0.927246, 0.805176), Vector2(0.072754, 0.805176),
		Vector2(0.072754, 0.194824),
	]), CANVAS_SIZE, TRACK_WIDTH, "Maximum Smoothing Benchmark")
	definition.target_length = 22000.0
	definition.direction = DefinitionType.DIRECTION_CLOCKWISE
	definition.refresh_content_hash()
	return definition


func _rectangle_point(distance: float) -> Vector2:
	# Starts at the middle of the top straight, then advances clockwise.
	if distance < 3500.0:
		return Vector2(4096.0 + distance, 1596.0)
	distance -= 3500.0
	if distance < 5000.0:
		return Vector2(7596.0, 1596.0 + distance)
	distance -= 5000.0
	if distance < 7000.0:
		return Vector2(7596.0 - distance, 6596.0)
	distance -= 7000.0
	if distance < 5000.0:
		return Vector2(596.0, 6596.0 - distance)
	distance -= 5000.0
	return Vector2(596.0 + distance, 1596.0)


func _minimum_finite_radius(radii: PackedFloat64Array) -> float:
	var minimum := INF
	for radius in radii:
		if not is_inf(radius):
			minimum = minf(minimum, radius)
	return minimum


func _inside_track_inset(points: PackedVector2Array) -> bool:
	var half_width := TRACK_WIDTH * 0.5
	for point in points:
		if point.x < half_width or point.y < half_width \
				or point.x > CANVAS_SIZE.x - half_width \
				or point.y > CANVAS_SIZE.y - half_width:
			return false
	return true


func _auto_smoothing_count(compiled: TrackCompileResult, key: String) -> int:
	for issue in compiled.report.issues:
		if issue.code == &"geometry.turns_auto_smoothed":
			return int(issue.details.get(key, 0))
	return 0


func _auto_smoothing_float(compiled: TrackCompileResult, key: String) -> float:
	for issue in compiled.report.issues:
		if issue.code == &"geometry.turns_auto_smoothed":
			return float(issue.details.get(key, INF))
	return INF
