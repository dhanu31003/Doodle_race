class_name CurvatureSafeSmoother
extends RefCounted
## Deterministically rounds undersized corners on an already arc-length sampled
## closed route. The authoring path remains the target: only the minimum amount
## of cyclic fairing needed to satisfy the vehicle/road radius is applied.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const FixedMathType := preload("res://game/core/fixed_math.gd")
const SplineType := preload("res://game/track/generation/closed_spline_resampler.gd")

const ACCEPTANCE_MARGIN := 1.015
const BOX_BLUR_PASSES := 3
const MAX_RECOVERY_SAMPLES := GameLimitsType.MAX_RESAMPLED_POINTS
const INTERACTIVE_RECOVERY_SAMPLES := 1024
const SAMPLES_PER_REQUIRED_RADIUS := 24.0
const LOCAL_ROUNDING_MAX_PASSES := 28
const LOCAL_ROUNDING_BLEND := 0.38


static func round_to_minimum_radius(
		input: PackedVector2Array,
		target_length: float,
		minimum_radius: float,
		canvas_size: Vector2,
		track_width: float
	) -> Dictionary:
	var minimum_before := _minimum_radius(input)
	var unchanged := {
		"points": input.duplicate(),
		"adjusted": false,
		"succeeded": false,
		"passes": 0,
		"minimum_before": minimum_before,
		"minimum_after": minimum_before,
		"maximum_displacement": 0.0,
		"candidate_evaluations": 0,
		"fairing_radius_samples": 0,
		"fallback_method": "",
		"fallback_harmonics": 0,
		"local_rounding_passes": 0,
		"source_sample_count": input.size(),
		"output_sample_count": input.size(),
	}
	if input.size() < GameLimitsType.MIN_RESAMPLED_POINTS \
			or not _all_finite(input) \
			or not is_finite(target_length) \
			or target_length <= GameLimitsType.GEOMETRY_EPSILON \
			or not is_finite(minimum_radius) \
			or minimum_radius <= GameLimitsType.GEOMETRY_EPSILON:
		return unchanged
	var required := minimum_radius * ACCEPTANCE_MARGIN
	if minimum_before >= required:
		unchanged["succeeded"] = true
		unchanged["minimum_before"] = minimum_before
		unchanged["minimum_after"] = minimum_before
		return unchanged
	var maximum_by_radius := floori(
		target_length * SAMPLES_PER_REQUIRED_RADIUS / maxf(minimum_radius, 1.0)
	)
	var minimum_by_spacing := ceili(target_length / GameLimitsType.MAX_SAMPLE_SPACING)
	var desired_recovery_count := mini(input.size(), INTERACTIVE_RECOVERY_SAMPLES)
	if maximum_by_radius < input.size():
		desired_recovery_count = mini(maximum_by_radius, INTERACTIVE_RECOVERY_SAMPLES)
	var minimum_recovery_count := mini(
		input.size(),
		maxi(GameLimitsType.MIN_RESAMPLED_POINTS, minimum_by_spacing)
	)
	var recovery_count := clampi(
		desired_recovery_count,
		minimum_recovery_count,
		input.size()
	)
	var recovery_source := input
	if recovery_count < input.size():
		recovery_source = SplineType.resample_polyline_to_count(input, recovery_count)
	var base_points := _normalize_route(recovery_source, target_length)
	if base_points.is_empty():
		return unchanged
	var safe_rect := Rect2(
		Vector2.ONE * track_width * 0.5,
		canvas_size - Vector2.ONE * track_width
	)
	# First touch only samples that actually violate the radius envelope. This is
	# the visual contract expected by freehand authoring: a needle point becomes
	# a short curve, while long straights, switchbacks, and unusual large-scale
	# silhouettes remain exactly where the player drew them.
	var local_recovery := _locally_round_sharp_samples(
		base_points, target_length, required, safe_rect, input[0], track_width
	)
	var evaluations := int(local_recovery.get("candidate_evaluations", 0))
	if bool(local_recovery.get("succeeded", false)):
		var local_points: PackedVector2Array = local_recovery.get(
			"points", PackedVector2Array()
		)
		return {
			"points": local_points,
			"adjusted": true,
			"succeeded": true,
			"passes": int(local_recovery.get("passes", 0)),
			"minimum_before": minimum_before,
			"minimum_after": float(local_recovery.get("minimum_after", 0.0)),
			"maximum_displacement": _maximum_index_displacement(input, local_points),
			"candidate_evaluations": evaluations,
			"fairing_radius_samples": 1,
			"fallback_method": "local_corner_rounding",
			"fallback_harmonics": 0,
			"local_rounding_passes": int(local_recovery.get("passes", 0)),
			"source_sample_count": input.size(),
			"output_sample_count": local_points.size(),
		}
	# Three cyclic box filters approximate a Gaussian fairing kernel. Searching
	# its radius exponentially then by bisection gives the same scale of corner
	# rounding that formerly required thousands of normalize/resample/analyze
	# passes, with O(N log N) work and a small bounded number of allocations.
	var maximum_blur_radius := maxi(1, (base_points.size() - 1) / 6)
	var lower_unsafe_radius := 0
	var upper_safe_radius := -1
	var best: Dictionary = {}
	var recovery_spacing := target_length / float(base_points.size())
	var probe_radius := clampi(
		ceili(required / maxf(recovery_spacing, GameLimitsType.GEOMETRY_EPSILON)),
		1,
		maximum_blur_radius
	)
	var initial_probe_was_safe := false
	var first_probe := true
	while probe_radius <= maximum_blur_radius:
		var candidate := _candidate_at_radius(
			base_points, probe_radius, target_length, required, safe_rect, input[0]
		)
		evaluations += 1
		if bool(candidate.get("succeeded", false)):
			initial_probe_was_safe = first_probe
			upper_safe_radius = probe_radius
			best = candidate
			break
		lower_unsafe_radius = probe_radius
		first_probe = false
		if probe_radius == maximum_blur_radius:
			break
		probe_radius = mini(probe_radius * 2, maximum_blur_radius)
	if upper_safe_radius >= 0:
		var refinement_budget := 2 if initial_probe_was_safe else 6
		while upper_safe_radius - lower_unsafe_radius > 1 and refinement_budget > 0:
			var middle_radius := (lower_unsafe_radius + upper_safe_radius) / 2
			var candidate := _candidate_at_radius(
				base_points, middle_radius, target_length, required, safe_rect, input[0]
			)
			evaluations += 1
			refinement_budget -= 1
			if bool(candidate.get("succeeded", false)):
				upper_safe_radius = middle_radius
				best = candidate
			else:
				lower_unsafe_radius = middle_radius
		var points: PackedVector2Array = best.get("points", PackedVector2Array())
		return {
			"points": points,
			"adjusted": true,
			"succeeded": true,
			"passes": BOX_BLUR_PASSES,
			"minimum_before": minimum_before,
			"minimum_after": float(best.get("minimum_after", 0.0)),
			"maximum_displacement": _maximum_index_displacement(input, points),
			"candidate_evaluations": evaluations,
			"fairing_radius_samples": upper_safe_radius,
			"fallback_method": "",
			"fallback_harmonics": 0,
			"local_rounding_passes": 0,
			"source_sample_count": input.size(),
			"output_sample_count": points.size(),
		}
	# Highly articulated touch strokes can contain many opposing corners. A
	# single global blur then either leaves one cusp behind or erases so much
	# route length that normalizing it back to the requested lap no longer fits
	# the canvas. Projecting the equal-arc route onto a bounded set of low
	# Fourier harmonics is a deterministic whole-loop repair: it retains the
	# authored large-scale rhythm while removing only frequencies that cannot
	# satisfy the road/radius envelope. Every candidate is independently
	# checked for finite values, bounds, resolvable point-crossing topology and
	# road clearance. Clean crossings remain available to Studio's explicit
	# bridge-declaration pass; ambiguous contact/overlap never does.
	var fallback_source := base_points
	var fallback_count := mini(
		base_points.size(),
		maxi(
			INTERACTIVE_RECOVERY_SAMPLES,
			ceili(target_length / GameLimitsType.MAX_SAMPLE_SPACING)
		)
	)
	if fallback_count < base_points.size():
		fallback_source = SplineType.resample_polyline_to_count(
			base_points, fallback_count
		)
	var fallback := _harmonic_safe_fallback(
		fallback_source,
		input,
		target_length,
		required,
		safe_rect,
		track_width
	)
	evaluations += int(fallback.get("candidate_evaluations", 0))
	if bool(fallback.get("succeeded", false)):
		var fallback_points: PackedVector2Array = fallback.get(
			"points", PackedVector2Array()
		)
		return {
			"points": fallback_points,
			"adjusted": true,
			"succeeded": true,
			"passes": BOX_BLUR_PASSES,
			"minimum_before": minimum_before,
			"minimum_after": float(fallback.get("minimum_after", 0.0)),
			"maximum_displacement": _maximum_index_displacement(
				input, fallback_points
			),
			"candidate_evaluations": evaluations,
			"fairing_radius_samples": 0,
			"fallback_method": "harmonic_projection",
			"fallback_harmonics": int(fallback.get("harmonics", 0)),
			"local_rounding_passes": 0,
			"source_sample_count": input.size(),
			"output_sample_count": fallback_points.size(),
		}
	unchanged["minimum_before"] = minimum_before
	unchanged["minimum_after"] = float(best.get("minimum_after", minimum_before))
	unchanged["candidate_evaluations"] = evaluations
	unchanged["fallback_fit_failures"] = int(fallback.get("fit_failures", 0))
	unchanged["fallback_radius_failures"] = int(fallback.get("radius_failures", 0))
	unchanged["fallback_topology_failures"] = int(fallback.get("topology_failures", 0))
	unchanged["fallback_best_minimum_radius"] = float(fallback.get("best_minimum_radius", 0.0))
	# Never return the progressively modified but still-unsafe candidate. The
	# compiler treats succeeded=false as a hard recovery failure, so neither the
	# original sharp route nor a half-recovered route can leak into race data.
	return unchanged


static func _locally_round_sharp_samples(
		base_points: PackedVector2Array,
		target_length: float,
		required_radius: float,
		safe_rect: Rect2,
		seam_anchor: Vector2,
		track_width: float
	) -> Dictionary:
	var points := base_points.duplicate()
	var evaluations := 0
	for pass_index in LOCAL_ROUNDING_MAX_PASSES:
		var count := points.size()
		var severity := PackedFloat32Array()
		severity.resize(count)
		var unsafe_count := 0
		for index in count:
			var radius := _radius_at_index(points, index)
			if radius < required_radius:
				severity[index] = clampf(
					(required_radius - radius) / maxf(required_radius, 0.001),
					0.0, 1.0
				)
				unsafe_count += 1
		if unsafe_count == 0:
			break
		var rounded := points.duplicate()
		for index in count:
			# Spread one sample beyond the failing vertex so a pointed tip becomes
			# a short arc instead of transferring its kink to the next sample.
			var influence := maxf(
				severity[index],
				maxf(
					severity[(index - 1 + count) % count] * 0.45,
					severity[(index + 1) % count] * 0.45
				)
			)
			if influence <= 0.0:
				continue
			var midpoint := (
				points[(index - 1 + count) % count]
				+ points[(index + 1) % count]
			) * 0.5
			rounded[index] = QuantizationType.vector2(
				points[index].lerp(
					midpoint,
					LOCAL_ROUNDING_BLEND * (0.35 + influence * 0.65)
				)
			)
		points = _normalize_route(rounded, target_length)
		if points.is_empty():
			return {"succeeded": false, "candidate_evaluations": evaluations}
		points = _anchor_or_fit_inside(points, seam_anchor, safe_rect)
		if points.is_empty():
			return {"succeeded": false, "candidate_evaluations": evaluations}
		evaluations += 1
		var minimum_after := _minimum_radius(points)
		if minimum_after >= required_radius:
			return {
				"points": points,
				"succeeded": true,
				"passes": pass_index + 1,
				"minimum_after": minimum_after,
				"candidate_evaluations": evaluations,
			}
	return {
		"succeeded": false,
		"candidate_evaluations": evaluations,
		"minimum_after": _minimum_radius(points),
	}


static func _radius_at_index(points: PackedVector2Array, index: int) -> float:
	var count := points.size()
	var previous := points[(index - 1 + count) % count]
	var current := points[index]
	var next := points[(index + 1) % count]
	var incoming := current - previous
	var outgoing := next - current
	var local_length := 0.5 * (incoming.length() + outgoing.length())
	if local_length <= GameLimitsType.GEOMETRY_EPSILON:
		return 0.0
	var signed_turn := atan2(
		incoming.x * outgoing.y - incoming.y * outgoing.x,
		incoming.dot(outgoing)
	)
	var curvature := signed_turn / local_length
	return INF if absf(curvature) <= GameLimitsType.STRAIGHT_CURVATURE_EPSILON \
			else 1.0 / absf(curvature)


static func _harmonic_safe_fallback(
		base_points: PackedVector2Array,
		original_points: PackedVector2Array,
		target_length: float,
		required_radius: float,
		safe_rect: Rect2,
		track_width: float
	) -> Dictionary:
	var evaluations := 0
	var fit_failures := 0
	var radius_failures := 0
	var topology_failures := 0
	var best_minimum_radius := 0.0
	# Descending order selects the highest-detail safe result. The list is
	# fixed rather than data-dependent so identical definitions always publish
	# byte-identical centerlines and hashes on every platform.
	for harmonic_count in [12, 10, 8, 6, 5, 4, 3, 2, 1]:
		if harmonic_count * 2 + 1 >= base_points.size():
			continue
		var projected := _project_harmonics(base_points, harmonic_count)
		evaluations += 1
		if projected.is_empty():
			continue
		projected = _normalize_route(projected, target_length)
		if projected.is_empty():
			continue
		projected = _anchor_or_fit_inside(projected, original_points[0], safe_rect)
		if projected.is_empty():
			# Preserve the same harmonic route but adapt its aspect ratio to the
			# available phone canvas. This is essential for long tangled strokes
			# whose safe low-frequency projection is slightly too tall even
			# though the canvas has ample unused horizontal room.
			projected = _fit_aspect_to_length(
				_project_harmonics(base_points, harmonic_count),
				target_length,
				safe_rect,
				original_points[0]
			)
		if projected.is_empty():
			fit_failures += 1
			continue
		var candidate_minimum_radius := _minimum_radius(projected)
		best_minimum_radius = maxf(best_minimum_radius, candidate_minimum_radius)
		if candidate_minimum_radius < required_radius:
			radius_failures += 1
			continue
		if not _surface_topology_is_safe(projected, track_width):
			topology_failures += 1
			continue
		return {
			"points": projected,
			"succeeded": true,
			"minimum_after": _minimum_radius(projected),
			"harmonics": harmonic_count,
			"candidate_evaluations": evaluations,
		}
	return {
		"succeeded": false,
		"candidate_evaluations": evaluations,
		"fit_failures": fit_failures,
		"radius_failures": radius_failures,
		"topology_failures": topology_failures,
		"best_minimum_radius": best_minimum_radius,
	}


static func _project_harmonics(
		points: PackedVector2Array,
		harmonic_count: int
	) -> PackedVector2Array:
	if points.size() < GameLimitsType.MIN_RESAMPLED_POINTS or harmonic_count < 1:
		return PackedVector2Array()
	var count := points.size()
	var center := _centroid(points)
	var cosine_coefficients: Array[Vector2] = []
	var sine_coefficients: Array[Vector2] = []
	for harmonic in range(1, harmonic_count + 1):
		var cosine_coefficient := Vector2.ZERO
		var sine_coefficient := Vector2.ZERO
		for index in count:
			var phase := TAU * float(harmonic * index) / float(count)
			var centered := points[index] - center
			cosine_coefficient += centered * cos(phase)
			sine_coefficient += centered * sin(phase)
		cosine_coefficients.append(cosine_coefficient * (2.0 / float(count)))
		sine_coefficients.append(sine_coefficient * (2.0 / float(count)))
	var output := PackedVector2Array()
	output.resize(count)
	for index in count:
		var point := center
		for harmonic_index in harmonic_count:
			var phase := TAU * float((harmonic_index + 1) * index) / float(count)
			point += cosine_coefficients[harmonic_index] * cos(phase)
			point += sine_coefficients[harmonic_index] * sin(phase)
		if not QuantizationType.is_finite_vector2(point):
			return PackedVector2Array()
		output[index] = QuantizationType.vector2(point)
	return output


static func _fit_aspect_to_length(
		points: PackedVector2Array,
		target_length: float,
		safe_rect: Rect2,
		seam_anchor: Vector2
	) -> PackedVector2Array:
	if points.is_empty() or safe_rect.size.x <= 0.0 or safe_rect.size.y <= 0.0:
		return PackedVector2Array()
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	var extent := maximum - minimum
	if extent.x <= GameLimitsType.GEOMETRY_EPSILON \
			or extent.y <= GameLimitsType.GEOMETRY_EPSILON:
		return PackedVector2Array()
	# A small deterministic inset absorbs coordinate quantization and the final
	# equal-arc normalization without allowing the road edge outside the canvas.
	const FIT_MARGIN := 0.9975
	var maximum_scale := Vector2(
		safe_rect.size.x * FIT_MARGIN / extent.x,
		safe_rect.size.y * FIT_MARGIN / extent.y
	)
	var center := _centroid(points)
	var fully_stretched := PackedVector2Array()
	fully_stretched.resize(points.size())
	for index in points.size():
		fully_stretched[index] = QuantizationType.vector2(
			center + (points[index] - center) * maximum_scale
		)
	var maximum_length := SplineType.closed_length(fully_stretched)
	if maximum_length + GameLimitsType.GEOMETRY_EPSILON < target_length:
		return PackedVector2Array()
	var scale_to_target := target_length / maximum_length
	for index in fully_stretched.size():
		fully_stretched[index] = QuantizationType.vector2(
			center + (fully_stretched[index] - center) * scale_to_target
		)
	fully_stretched = _normalize_route(fully_stretched, target_length)
	if fully_stretched.is_empty():
		return PackedVector2Array()
	return _anchor_or_fit_inside(fully_stretched, seam_anchor, safe_rect)


static func _surface_topology_is_safe(
		points: PackedVector2Array,
		track_width: float
	) -> bool:
	var count := points.size()
	if count < 4:
		return true
	var spacing := SplineType.closed_length(points) / float(count)
	var neighbor_count := maxi(
		2,
		ceili(track_width / maxf(spacing, 1.0)) * 2
	)
	var clearance := track_width * 0.96
	var crossing_pairs: Array[Vector2i] = []
	# Resolve topology first so the clearance pass can distinguish an isolated
	# unsafe near-parallel pair from the short deterministic ramp neighborhood
	# surrounding a clean point crossing.
	for first in count:
		var first_end := (first + 1) % count
		for second in range(first + 1, count):
			var direct := second - first
			if mini(direct, count - direct) <= neighbor_count:
				continue
			var second_end := (second + 1) % count
			if FixedMathType.segments_intersect(
					points[first], points[first_end],
					points[second], points[second_end]
				):
				# A clean interior point intersection is a valid preview
				# topology: Track Studio must compile it once before it can
				# explicitly declare which branch becomes the bridge. Collinear
				# overlap, tangency and endpoint contact remain unsafe.
				if not _is_proper_point_intersection(
					points[first], points[first_end],
					points[second], points[second_end]
				):
					return false
				crossing_pairs.append(Vector2i(first, second))
				if crossing_pairs.size() > GameLimitsType.MAX_BRIDGE_CROSSINGS:
					return false
	var crossing_window_segments := maxi(
		neighbor_count,
		ceili((track_width * 2.0 + spacing) / maxf(spacing, 1.0))
	)
	for first in count:
		var first_end := (first + 1) % count
		for second in range(first + 1, count):
			var direct := second - first
			if mini(direct, count - direct) <= neighbor_count:
				continue
			var second_end := (second + 1) % count
			if FixedMathType.segments_intersect(
					points[first], points[first_end],
					points[second], points[second_end]
				):
				continue
			if _segment_distance(
					points[first], points[first_end],
					points[second], points[second_end]
				) < clearance \
				and not _pair_is_in_crossing_window(
					first,
					second,
					crossing_pairs,
					count,
					crossing_window_segments
				):
				return false
	# A zero-area loop without a clean crossing is a collapsed/ambiguous shape.
	# A zero-area figure-eight is intentional and becomes safe only after the
	# Studio publishes explicit bridge declarations.
	return not crossing_pairs.is_empty() \
		or absf(FixedMathType.signed_polygon_area(points)) > GameLimitsType.GEOMETRY_EPSILON


static func _pair_is_in_crossing_window(
		first: int,
		second: int,
		crossing_pairs: Array[Vector2i],
		count: int,
		window: int
	) -> bool:
	for crossing in crossing_pairs:
		var direct := _cyclic_index_distance(first, crossing.x, count) <= window \
			and _cyclic_index_distance(second, crossing.y, count) <= window
		var swapped := _cyclic_index_distance(first, crossing.y, count) <= window \
			and _cyclic_index_distance(second, crossing.x, count) <= window
		if direct or swapped:
			return true
	return false


static func _cyclic_index_distance(first: int, second: int, count: int) -> int:
	var direct := absi(first - second)
	return mini(direct, count - direct)


static func _is_proper_point_intersection(
		first_start: Vector2,
		first_end: Vector2,
		second_start: Vector2,
		second_end: Vector2
	) -> bool:
	var first_direction := first_end - first_start
	var second_direction := second_end - second_start
	var denominator := FixedMathType.cross_2d(first_direction, second_direction)
	if absf(denominator) <= GameLimitsType.GEOMETRY_EPSILON:
		return false
	var offset := second_start - first_start
	var first_amount := FixedMathType.cross_2d(offset, second_direction) / denominator
	var second_amount := FixedMathType.cross_2d(offset, first_direction) / denominator
	const ENDPOINT_EPSILON := 0.0001
	return first_amount > ENDPOINT_EPSILON \
		and first_amount < 1.0 - ENDPOINT_EPSILON \
		and second_amount > ENDPOINT_EPSILON \
		and second_amount < 1.0 - ENDPOINT_EPSILON


static func _segment_distance(
		first_start: Vector2,
		first_end: Vector2,
		second_start: Vector2,
		second_end: Vector2
	) -> float:
	return minf(
		minf(
			_point_segment_distance(first_start, second_start, second_end),
			_point_segment_distance(first_end, second_start, second_end)
		),
		minf(
			_point_segment_distance(second_start, first_start, first_end),
			_point_segment_distance(second_end, first_start, first_end)
		)
	)


static func _point_segment_distance(
		point: Vector2,
		start: Vector2,
		end: Vector2
	) -> float:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared <= GameLimitsType.GEOMETRY_EPSILON:
		return point.distance_to(start)
	var amount := clampf(
		(point - start).dot(segment) / length_squared, 0.0, 1.0
	)
	return point.distance_to(start + segment * amount)


static func _candidate_at_radius(
		base_points: PackedVector2Array,
		blur_radius: int,
		target_length: float,
		required_radius: float,
		safe_rect: Rect2,
		seam_anchor: Vector2
	) -> Dictionary:
	var points := base_points
	for _pass_index in BOX_BLUR_PASSES:
		points = _box_blur_cyclic(points, blur_radius)
	points = _normalize_route(points, target_length)
	if points.is_empty():
		return {"succeeded": false, "minimum_after": 0.0}
	points = _anchor_or_fit_inside(points, seam_anchor, safe_rect)
	if points.is_empty():
		return {"succeeded": false, "minimum_after": _minimum_radius(points)}
	var minimum_after := _minimum_radius(points)
	return {
		"points": points,
		"succeeded": minimum_after >= required_radius,
		"minimum_after": minimum_after,
	}


static func _anchor_or_fit_inside(
		points: PackedVector2Array,
		seam_anchor: Vector2,
		safe_rect: Rect2
	) -> PackedVector2Array:
	var anchored := _translated(points, seam_anchor - points[0])
	if _entirely_inside(anchored, safe_rect):
		return anchored
	return _translate_inside(points, safe_rect)


static func _box_blur_cyclic(
		points: PackedVector2Array,
		radius: int
	) -> PackedVector2Array:
	var count := points.size()
	var safe_radius := clampi(radius, 1, maxi(1, (count - 1) / 2))
	var window_size := safe_radius * 2 + 1
	var window_sum := Vector2.ZERO
	for offset in range(-safe_radius, safe_radius + 1):
		window_sum += points[(offset + count) % count]
	var output := PackedVector2Array()
	output.resize(count)
	for index in count:
		output[index] = QuantizationType.vector2(window_sum / float(window_size))
		var outgoing := (index - safe_radius + count) % count
		var incoming := (index + safe_radius + 1) % count
		window_sum += points[incoming] - points[outgoing]
	return output


static func _normalize_route(
		points: PackedVector2Array,
		target_length: float
	) -> PackedVector2Array:
	var current_length := SplineType.closed_length(points)
	if current_length <= GameLimitsType.GEOMETRY_EPSILON:
		return PackedVector2Array()
	var center := _centroid(points)
	var scale_factor := target_length / current_length
	var scaled := PackedVector2Array()
	scaled.resize(points.size())
	for index in points.size():
		scaled[index] = QuantizationType.vector2(
			center + (points[index] - center) * scale_factor
		)
	# Re-establish equal arc spacing after every fairing pass. This avoids a
	# deceptively safe radius caused only by clustered samples at a corner.
	return SplineType.resample_polyline_to_count(scaled, scaled.size())


static func _translate_inside(points: PackedVector2Array, safe_rect: Rect2) -> PackedVector2Array:
	if safe_rect.size.x <= 0.0 or safe_rect.size.y <= 0.0:
		return PackedVector2Array()
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	var extent := maximum - minimum
	if extent.x > safe_rect.size.x or extent.y > safe_rect.size.y:
		return PackedVector2Array()
	var translation := Vector2.ZERO
	if minimum.x < safe_rect.position.x:
		translation.x += safe_rect.position.x - minimum.x
	elif maximum.x > safe_rect.end.x:
		translation.x -= maximum.x - safe_rect.end.x
	if minimum.y < safe_rect.position.y:
		translation.y += safe_rect.position.y - minimum.y
	elif maximum.y > safe_rect.end.y:
		translation.y -= maximum.y - safe_rect.end.y
	if translation.is_zero_approx():
		return points
	return _translated(points, translation)


static func _translated(points: PackedVector2Array, translation: Vector2) -> PackedVector2Array:
	var output := PackedVector2Array()
	output.resize(points.size())
	for index in points.size():
		output[index] = QuantizationType.vector2(points[index] + translation)
	return output


static func _entirely_inside(points: PackedVector2Array, safe_rect: Rect2) -> bool:
	for point in points:
		if not safe_rect.has_point(point):
			return false
	return true


static func _minimum_radius(points: PackedVector2Array) -> float:
	if points.size() < 3:
		return 0.0
	var minimum := INF
	var count := points.size()
	for index in count:
		var previous := points[(index - 1 + count) % count]
		var current := points[index]
		var next := points[(index + 1) % count]
		var incoming := current - previous
		var outgoing := next - current
		var local_length := 0.5 * (incoming.length() + outgoing.length())
		if local_length <= GameLimitsType.GEOMETRY_EPSILON:
			continue
		var signed_turn := atan2(
			incoming.x * outgoing.y - incoming.y * outgoing.x,
			incoming.dot(outgoing)
		)
		var curvature := signed_turn / local_length
		if absf(curvature) > GameLimitsType.STRAIGHT_CURVATURE_EPSILON:
			minimum = minf(minimum, 1.0 / absf(curvature))
	return minimum


static func _centroid(points: PackedVector2Array) -> Vector2:
	var total := Vector2.ZERO
	for point in points:
		total += point
	return total / float(points.size())


static func _all_finite(points: PackedVector2Array) -> bool:
	for point in points:
		if not QuantizationType.is_finite_vector2(point):
			return false
	return true


static func _maximum_index_displacement(
		first: PackedVector2Array,
		second: PackedVector2Array
	) -> float:
	if first.size() != second.size():
		var maximum_mapped := 0.0
		for index in second.size():
			var source_index := mini(
				roundi(float(index) * float(first.size()) / float(second.size())),
				first.size() - 1
			)
			maximum_mapped = maxf(
				maximum_mapped, first[source_index].distance_to(second[index])
			)
		return maximum_mapped
	var maximum := 0.0
	for index in first.size():
		maximum = maxf(maximum, first[index].distance_to(second[index]))
	return maximum
