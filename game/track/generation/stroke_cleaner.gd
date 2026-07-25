class_name StrokeCleaner
extends RefCounted
## Deterministic cleanup for noisy pointer/touch samples. The output represents
## an implicitly closed ring; a duplicate final copy of the first point is never
## retained.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const FixedMathType := preload("res://game/core/fixed_math.gd")
const CleanupResultType := preload("res://game/track/generation/stroke_cleanup_result.gd")


static func clean(
		input: PackedVector2Array,
		minimum_spacing: float = GameLimitsType.DEFAULT_STROKE_MIN_SPACING,
		simplify_tolerance: float = GameLimitsType.DEFAULT_STROKE_SIMPLIFY_TOLERANCE,
		close_snap_distance: float = GameLimitsType.DEFAULT_CLOSE_SNAP_DISTANCE,
		quantum: float = GameLimitsType.COORDINATE_QUANTUM
	) -> PackedVector2Array:
	return clean_with_report(
		input, minimum_spacing, simplify_tolerance, close_snap_distance, quantum
	).points


static func clean_with_report(
		input: PackedVector2Array,
		minimum_spacing: float = GameLimitsType.DEFAULT_STROKE_MIN_SPACING,
		simplify_tolerance: float = GameLimitsType.DEFAULT_STROKE_SIMPLIFY_TOLERANCE,
		close_snap_distance: float = GameLimitsType.DEFAULT_CLOSE_SNAP_DISTANCE,
		quantum: float = GameLimitsType.COORDINATE_QUANTUM
	) -> StrokeCleanupResult:
	var result := CleanupResultType.new()
	result.input_count = input.size()
	var points := PackedVector2Array()
	var bounded_count := mini(input.size(), GameLimitsType.MAX_INPUT_STROKE_POINTS)
	var spacing_squared := maxf(minimum_spacing, 0.0) ** 2
	for index in bounded_count:
		var point := input[index]
		if not QuantizationType.is_finite_vector2(point):
			result.non_finite_removed += 1
			continue
		point = QuantizationType.vector2(point, quantum)
		if not points.is_empty() and point.distance_squared_to(points[-1]) <= spacing_squared:
			result.duplicates_removed += 1
			continue
		points.append(point)
	if input.size() > bounded_count:
		result.duplicates_removed += input.size() - bounded_count
	if points.size() >= 2:
		result.closure_gap = points[0].distance_to(points[-1])
		if result.closure_gap <= maxf(close_snap_distance, minimum_spacing):
			points.remove_at(points.size() - 1)
			result.duplicates_removed += 1
	points = _remove_spikes(points, maxf(minimum_spacing * 2.5, simplify_tolerance * 4.0), result)
	points = _remove_near_collinear(points, maxf(simplify_tolerance, 0.0), result)
	if points.size() > GameLimitsType.MIN_CONTROL_POINTS and simplify_tolerance > 0.0:
		var before_simplification := points
		var simplified := _simplify_closed(points, simplify_tolerance)
		if simplified.size() >= GameLimitsType.MIN_CONTROL_POINTS:
			result.simplified_removed += points.size() - simplified.size()
			points = simplified
		else:
			points = before_simplification
	# A closing duplicate can reappear after geometric cleanup.
	if points.size() > GameLimitsType.MIN_CONTROL_POINTS \
			and points[0].distance_squared_to(points[-1]) <= spacing_squared:
		points.remove_at(points.size() - 1)
		result.duplicates_removed += 1
	result.points = QuantizationType.packed_vector2(points, quantum)
	result.is_closed = result.points.size() >= GameLimitsType.MIN_CONTROL_POINTS
	return result


static func _remove_spikes(
		input: PackedVector2Array,
		spike_rejoin_distance: float,
		result: StrokeCleanupResult
	) -> PackedVector2Array:
	var points := input.duplicate()
	var changed := true
	var pass_count := 0
	while changed and pass_count < 4 and points.size() > GameLimitsType.MIN_CONTROL_POINTS:
		changed = false
		pass_count += 1
		for index in points.size():
			var previous := points[FixedMathType.wrap_index(index - 1, points.size())]
			var current := points[index]
			var next := points[(index + 1) % points.size()]
			var incoming := current - previous
			var outgoing := next - current
			if incoming.length_squared() <= 0.0 or outgoing.length_squared() <= 0.0:
				points.remove_at(index)
				result.spikes_removed += 1
				changed = true
				break
			var reversal := incoming.normalized().dot(outgoing.normalized()) < -0.8
			var rejoins := previous.distance_to(next) <= spike_rejoin_distance
			if reversal and rejoins:
				points.remove_at(index)
				result.spikes_removed += 1
				changed = true
				break
	return points


static func _remove_near_collinear(
		input: PackedVector2Array,
		tolerance: float,
		result: StrokeCleanupResult
	) -> PackedVector2Array:
	var points := input.duplicate()
	if tolerance <= 0.0:
		return points
	var changed := true
	var tolerance_squared := tolerance * tolerance
	while changed and points.size() > GameLimitsType.MIN_CONTROL_POINTS:
		changed = false
		for index in points.size():
			var previous := points[FixedMathType.wrap_index(index - 1, points.size())]
			var next := points[(index + 1) % points.size()]
			if FixedMathType.distance_to_segment_squared(points[index], previous, next) \
					<= tolerance_squared:
				points.remove_at(index)
				result.collinear_removed += 1
				changed = true
				break
	return points


static func _simplify_closed(input: PackedVector2Array, tolerance: float) -> PackedVector2Array:
	if input.size() <= GameLimitsType.MIN_CONTROL_POINTS:
		return input.duplicate()
	var working := input.duplicate()
	working.append(input[0])
	var keep := PackedByteArray()
	keep.resize(working.size())
	keep[0] = 1
	keep[working.size() - 1] = 1
	var stack: Array[Vector2i] = [Vector2i(0, working.size() - 1)]
	var tolerance_squared := tolerance * tolerance
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var farthest_index := -1
		var farthest_distance := tolerance_squared
		for index in range(span.x + 1, span.y):
			var distance := FixedMathType.distance_to_segment_squared(
				working[index], working[span.x], working[span.y]
			)
			if distance > farthest_distance:
				farthest_distance = distance
				farthest_index = index
		if farthest_index >= 0:
			keep[farthest_index] = 1
			stack.append(Vector2i(span.x, farthest_index))
			stack.append(Vector2i(farthest_index, span.y))
	var output := PackedVector2Array()
	for index in input.size():
		if keep[index] == 1:
			output.append(input[index])
	return output
