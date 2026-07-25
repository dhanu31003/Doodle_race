class_name TrackCompiler
extends RefCounted
## Deterministic authoring-to-runtime compilation pipeline.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const COMPILER_VERSION: int = GameLimitsType.TRACK_COMPILER_VERSION
const QuantizationType := preload("res://game/core/quantization.gd")
const FixedMathType := preload("res://game/core/fixed_math.gd")
const StrokeCleanerType := preload("res://game/track/generation/stroke_cleaner.gd")
const SplineType := preload("res://game/track/generation/closed_spline_resampler.gd")
const CurvatureSmootherType := preload("res://game/track/generation/curvature_safe_smoother.gd")
const AnalyzerType := preload("res://game/track/generation/track_geometry_analyzer.gd")
const CompiledTrackType := preload("res://game/track/generation/compiled_track.gd")
const CompileResultType := preload("res://game/track/generation/track_compile_result.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")


static func compile(
		definition: TrackDefinition,
		sample_spacing: float = GameLimitsType.DEFAULT_SAMPLE_SPACING
	) -> TrackCompileResult:
	var result := CompileResultType.new()
	result.report.merge(ValidatorType.validate_definition(definition))
	if definition == null or not result.report.is_valid():
		return result
	if definition.generator_version != COMPILER_VERSION:
		result.report.add_error(&"compile.unsupported_generator_version", "Track requires an unsupported generator version.", "generator_version", {"actual": definition.generator_version, "supported": COMPILER_VERSION})
		return result
	var denormalized := definition.denormalized_control_points()
	var cleanup := StrokeCleanerType.clean_with_report(
		denormalized,
		maxf(GameLimitsType.DEFAULT_STROKE_MIN_SPACING, definition.track_width * 0.02),
		GameLimitsType.DEFAULT_STROKE_SIMPLIFY_TOLERANCE,
		maxf(GameLimitsType.DEFAULT_CLOSE_SNAP_DISTANCE, definition.track_width * 0.25)
	)
	if cleanup.points.size() < GameLimitsType.MIN_CONTROL_POINTS:
		result.report.add_error(&"compile.cleanup_too_few_points", "Stroke cleanup left too few control points.", "control_points", cleanup.to_dictionary())
		return result
	var dense := SplineType.sample_curve(cleanup.points)
	var raw_length := SplineType.closed_length(dense)
	if raw_length <= GameLimitsType.GEOMETRY_EPSILON:
		result.report.add_error(&"compile.zero_length", "Track curve has no usable length.", "control_points")
		return result
	var center := _centroid(dense)
	var scale_factor := definition.target_length / raw_length
	for index in dense.size():
		dense[index] = QuantizationType.vector2(center + (dense[index] - center) * scale_factor)
	var raw_analysis := AnalyzerType.analyze(dense)
	if raw_analysis.winding != &"ambiguous" and raw_analysis.winding != definition.direction:
		dense = SplineType.reversed_preserving_start(dense)
	var safe_spacing := clampf(sample_spacing, GameLimitsType.MIN_SAMPLE_SPACING, GameLimitsType.MAX_SAMPLE_SPACING)
	var centerline := SplineType.resample_polyline(
		dense, safe_spacing, definition.start_finish_distance
	)
	if centerline.size() < GameLimitsType.MIN_RESAMPLED_POINTS:
		result.report.add_error(&"compile.resample_failed", "Arc-length resampling did not produce a usable centerline.", "control_points")
		return result
	var minimum_radius := maxf(
		GameLimitsType.MIN_TURN_RADIUS,
		definition.track_width * GameLimitsType.MIN_RADIUS_TO_WIDTH_RATIO
	)
	var corner_recovery := CurvatureSmootherType.round_to_minimum_radius(
		centerline,
		definition.target_length,
		minimum_radius,
		definition.canvas_size,
		definition.track_width
	)
	if bool(corner_recovery.get("succeeded", false)):
		centerline = corner_recovery.get("points", centerline)
		if bool(corner_recovery.get("adjusted", false)):
			result.report.add_info(
				&"geometry.turns_auto_smoothed",
				"Sharp corners were rounded automatically; the circuit is ready to build.",
				"control_points",
				{
					"passes": int(corner_recovery.get("passes", 0)),
					"minimum_before": float(corner_recovery.get("minimum_before", 0.0)),
					"minimum_after": float(corner_recovery.get("minimum_after", 0.0)),
					"required_minimum": minimum_radius,
					"maximum_displacement": float(corner_recovery.get("maximum_displacement", 0.0)),
					"candidate_evaluations": int(corner_recovery.get("candidate_evaluations", 0)),
					"fairing_radius_samples": int(corner_recovery.get("fairing_radius_samples", 0)),
					"fallback_method": str(corner_recovery.get("fallback_method", "")),
					"fallback_harmonics": int(corner_recovery.get("fallback_harmonics", 0)),
					"local_rounding_passes": int(corner_recovery.get("local_rounding_passes", 0)),
					"source_sample_count": int(corner_recovery.get("source_sample_count", centerline.size())),
					"output_sample_count": int(corner_recovery.get("output_sample_count", centerline.size())),
				}
			)
	else:
		result.report.add_error(
			&"compile.corner_rounding_failed",
			"Automatic corner rounding could not produce finite safe geometry.",
			"control_points",
			{
				"minimum_before": float(corner_recovery.get("minimum_before", 0.0)),
				"minimum_after": float(corner_recovery.get("minimum_after", 0.0)),
				"required_minimum": minimum_radius,
				"fallback_fit_failures": int(corner_recovery.get("fallback_fit_failures", 0)),
				"fallback_radius_failures": int(corner_recovery.get("fallback_radius_failures", 0)),
				"fallback_topology_failures": int(corner_recovery.get("fallback_topology_failures", 0)),
				"fallback_best_minimum_radius": float(corner_recovery.get("fallback_best_minimum_radius", 0.0)),
			}
		)
		return result
	var analysis := AnalyzerType.analyze(centerline)
	var compiled := CompiledTrackType.new()
	compiled.compiler_version = COMPILER_VERSION
	compiled.source_hash = definition.calculated_content_hash()
	compiled.track_id = definition.track_id
	compiled.canvas_size = definition.canvas_size
	compiled.direction = definition.direction
	compiled.theme = definition.theme
	compiled.road_surface = definition.road_surface
	compiled.pit_side = definition.pit_side
	compiled.decoration_density = definition.decoration_density
	compiled.deterministic_seed = definition.deterministic_seed
	for crossing in definition.bridge_crossings:
		compiled.bridge_crossings.append(crossing.to_dictionary())
	compiled.track_width = QuantizationType.scalar(definition.track_width)
	compiled.sample_spacing = QuantizationType.scalar(analysis.total_length / float(centerline.size()))
	compiled.start_finish_distance = QuantizationType.scalar(definition.start_finish_distance)
	compiled.centerline = centerline
	compiled.tangents = analysis.tangents
	compiled.normals = analysis.normals
	compiled.curvatures = analysis.curvatures
	compiled.radii = analysis.radii
	compiled.arc_distances = analysis.arc_distances
	compiled.total_length = QuantizationType.scalar(analysis.total_length)
	compiled.straight_sections = analysis.straight_sections
	compiled.corner_sections = analysis.corner_sections
	var best_straight := analysis.best_straight()
	compiled.suggested_start_finish_distance = QuantizationType.scalar(fposmod(
		definition.start_finish_distance + float(best_straight.get("start_distance", 0.0)),
		maxf(compiled.total_length, GameLimitsType.GEOMETRY_EPSILON)
	))
	_build_edges(compiled)
	compiled.refresh_compile_hash()
	result.track = compiled
	result.report.merge(ValidatorType.validate_compiled(definition, compiled))
	return result


static func _centroid(points: PackedVector2Array) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	var total := Vector2.ZERO
	for point in points:
		total += point
	return total / float(points.size())


static func _build_edges(compiled: CompiledTrack) -> void:
	var half_width := compiled.track_width * 0.5
	compiled.left_edge.resize(compiled.centerline.size())
	compiled.right_edge.resize(compiled.centerline.size())
	for index in compiled.centerline.size():
		compiled.left_edge[index] = QuantizationType.vector2(
			compiled.centerline[index] + compiled.normals[index] * half_width
		)
		compiled.right_edge[index] = QuantizationType.vector2(
			compiled.centerline[index] - compiled.normals[index] * half_width
		)
