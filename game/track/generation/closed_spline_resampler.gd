class_name ClosedSplineResampler
extends RefCounted
## Closed uniform Catmull-Rom sampling followed by equal arc-length resampling.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const FixedMathType := preload("res://game/core/fixed_math.gd")


static func resample(
		control_points: PackedVector2Array,
		spacing: float = GameLimitsType.DEFAULT_SAMPLE_SPACING,
		subdivisions: int = GameLimitsType.DEFAULT_SPLINE_SUBDIVISIONS
	) -> PackedVector2Array:
	var dense := sample_curve(control_points, subdivisions)
	return resample_polyline(dense, spacing)


static func sample_curve(
		control_points: PackedVector2Array,
		subdivisions: int = GameLimitsType.DEFAULT_SPLINE_SUBDIVISIONS
	) -> PackedVector2Array:
	if control_points.size() < GameLimitsType.MIN_CONTROL_POINTS:
		return PackedVector2Array()
	var steps := clampi(subdivisions, 4, 128)
	var dense := PackedVector2Array()
	for index in control_points.size():
		var p0 := control_points[FixedMathType.wrap_index(index - 1, control_points.size())]
		var p1 := control_points[index]
		var p2 := control_points[(index + 1) % control_points.size()]
		var p3 := control_points[(index + 2) % control_points.size()]
		for step in steps:
			var amount := float(step) / float(steps)
			dense.append(_catmull_rom(p0, p1, p2, p3, amount))
	return dense


static func resample_polyline(
		closed_points: PackedVector2Array,
		spacing: float = GameLimitsType.DEFAULT_SAMPLE_SPACING,
		offset_distance: float = 0.0
	) -> PackedVector2Array:
	if closed_points.size() < 3:
		return PackedVector2Array()
	var safe_spacing := clampf(
		spacing, GameLimitsType.MIN_SAMPLE_SPACING, GameLimitsType.MAX_SAMPLE_SPACING
	)
	var cumulative := _closed_cumulative_lengths(closed_points)
	var total_length: float = cumulative[-1]
	if total_length <= GameLimitsType.GEOMETRY_EPSILON:
		return PackedVector2Array()
	var sample_count := clampi(
		int(round(total_length / safe_spacing)),
		GameLimitsType.MIN_RESAMPLED_POINTS,
		GameLimitsType.MAX_RESAMPLED_POINTS
	)
	return resample_polyline_to_count(closed_points, sample_count, offset_distance, cumulative)


static func resample_polyline_to_count(
		closed_points: PackedVector2Array,
		sample_count: int,
		offset_distance: float = 0.0,
		precomputed_cumulative: PackedFloat64Array = PackedFloat64Array()
	) -> PackedVector2Array:
	if closed_points.size() < 3 or sample_count < 3:
		return PackedVector2Array()
	var cumulative := precomputed_cumulative
	if cumulative.size() != closed_points.size() + 1:
		cumulative = _closed_cumulative_lengths(closed_points)
	var total_length: float = cumulative[-1]
	if total_length <= GameLimitsType.GEOMETRY_EPSILON:
		return PackedVector2Array()
	var output := PackedVector2Array()
	output.resize(sample_count)
	var target_step := total_length / float(sample_count)
	var wrapped_offset := fposmod(offset_distance, total_length)
	var edge := 0
	var previous_target := -1.0
	for index in sample_count:
		var target := fposmod(wrapped_offset + float(index) * target_step, total_length)
		# Targets are monotonically increasing except for one possible offset
		# wrap. A cursor makes equal-arc resampling O(points + samples), while
		# selecting exactly the same edge as the former per-sample binary search.
		if target < previous_target:
			edge = 0
		while edge < closed_points.size() - 1 and cumulative[edge + 1] < target:
			edge += 1
		var edge_length: float = cumulative[edge + 1] - cumulative[edge]
		var point := closed_points[edge]
		if edge_length > GameLimitsType.GEOMETRY_EPSILON:
			var amount := (target - cumulative[edge]) / edge_length
			point = closed_points[edge].lerp(
				closed_points[(edge + 1) % closed_points.size()], amount
			)
		output[index] = QuantizationType.vector2(
			point
		)
		previous_target = target
	return output


static func closed_length(points: PackedVector2Array) -> float:
	if points.size() < 2:
		return 0.0
	return _closed_cumulative_lengths(points)[-1]


static func reversed_preserving_start(points: PackedVector2Array) -> PackedVector2Array:
	if points.is_empty():
		return PackedVector2Array()
	var output := PackedVector2Array()
	output.resize(points.size())
	output[0] = points[0]
	for index in range(1, points.size()):
		output[index] = points[points.size() - index]
	return output


static func _closed_cumulative_lengths(points: PackedVector2Array) -> PackedFloat64Array:
	var cumulative := PackedFloat64Array()
	cumulative.resize(points.size() + 1)
	cumulative[0] = 0.0
	for index in points.size():
		cumulative[index + 1] = cumulative[index] + points[index].distance_to(
			points[(index + 1) % points.size()]
		)
	return cumulative


static func _point_at_closed_distance(
		points: PackedVector2Array,
		cumulative: PackedFloat64Array,
		distance: float
	) -> Vector2:
	var total_length: float = cumulative[-1]
	var target := fposmod(distance, total_length)
	var low := 0
	var high := points.size() - 1
	while low < high:
		var middle := int((low + high) / 2)
		if cumulative[middle + 1] < target:
			low = middle + 1
		else:
			high = middle
	var edge := low
	var edge_length: float = cumulative[edge + 1] - cumulative[edge]
	if edge_length <= GameLimitsType.GEOMETRY_EPSILON:
		return points[edge]
	var amount := (target - cumulative[edge]) / edge_length
	return points[edge].lerp(points[(edge + 1) % points.size()], amount)


static func _catmull_rom(
		p0: Vector2,
		p1: Vector2,
		p2: Vector2,
		p3: Vector2,
		amount: float
	) -> Vector2:
	# Centripetal Catmull-Rom does not form the loops/cusps that the uniform
	# polynomial can create when a long straight meets tightly spaced curve
	# controls. That property is safety-critical for arbitrary touch strokes.
	var t0 := 0.0
	var t1 := t0 + sqrt(maxf(p0.distance_to(p1), GameLimitsType.GEOMETRY_EPSILON))
	var t2 := t1 + sqrt(maxf(p1.distance_to(p2), GameLimitsType.GEOMETRY_EPSILON))
	var t3 := t2 + sqrt(maxf(p2.distance_to(p3), GameLimitsType.GEOMETRY_EPSILON))
	if t2 - t1 <= GameLimitsType.GEOMETRY_EPSILON:
		return p1.lerp(p2, amount)
	var sample_time := lerpf(t1, t2, clampf(amount, 0.0, 1.0))
	var a1 := _time_lerp(p0, p1, t0, t1, sample_time)
	var a2 := _time_lerp(p1, p2, t1, t2, sample_time)
	var a3 := _time_lerp(p2, p3, t2, t3, sample_time)
	var b1 := _time_lerp(a1, a2, t0, t2, sample_time)
	var b2 := _time_lerp(a2, a3, t1, t3, sample_time)
	return _time_lerp(b1, b2, t1, t2, sample_time)


static func _time_lerp(
		first: Vector2,
		second: Vector2,
		first_time: float,
		second_time: float,
		sample_time: float
	) -> Vector2:
	var span := second_time - first_time
	if span <= GameLimitsType.GEOMETRY_EPSILON:
		return first
	var weight := (sample_time - first_time) / span
	return first.lerp(second, weight)
