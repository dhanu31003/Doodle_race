class_name FixedMath
extends RefCounted
## Small geometry primitives shared by compilation and validation.

const QuantizationType := preload("res://game/core/quantization.gd")


static func wrap_index(index: int, size: int) -> int:
	if size <= 0:
		return 0
	return posmod(index, size)


static func cross_2d(a: Vector2, b: Vector2) -> float:
	return a.x * b.y - a.y * b.x


static func orientation(a: Vector2, b: Vector2, c: Vector2) -> float:
	return cross_2d(b - a, c - a)


static func signed_polygon_area(points: PackedVector2Array) -> float:
	if points.size() < 3:
		return 0.0
	var twice_area := 0.0
	for index in points.size():
		var next_index := (index + 1) % points.size()
		twice_area += points[index].x * points[next_index].y
		twice_area -= points[next_index].x * points[index].y
	return twice_area * 0.5


static func distance_squared_fixed(
		a: Vector2,
		b: Vector2,
		scale: int = 1000
	) -> int:
	var fixed_a := QuantizationType.vector2_to_fixed(a, scale)
	var fixed_b := QuantizationType.vector2_to_fixed(b, scale)
	var delta_x: int = fixed_a.x - fixed_b.x
	var delta_y: int = fixed_a.y - fixed_b.y
	return delta_x * delta_x + delta_y * delta_y


static func distance_to_segment_squared(point: Vector2, start: Vector2, end: Vector2) -> float:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0:
		return point.distance_squared_to(start)
	var amount: float = clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(start + segment * amount)


static func point_on_segment(
		point: Vector2,
		start: Vector2,
		end: Vector2,
		epsilon: float = 0.000001
	) -> bool:
	if absf(orientation(start, end, point)) > epsilon:
		return false
	return point.x >= minf(start.x, end.x) - epsilon \
		and point.x <= maxf(start.x, end.x) + epsilon \
		and point.y >= minf(start.y, end.y) - epsilon \
		and point.y <= maxf(start.y, end.y) + epsilon


static func segments_intersect(
		a_start: Vector2,
		a_end: Vector2,
		b_start: Vector2,
		b_end: Vector2,
		epsilon: float = 0.000001
	) -> bool:
	var o1 := orientation(a_start, a_end, b_start)
	var o2 := orientation(a_start, a_end, b_end)
	var o3 := orientation(b_start, b_end, a_start)
	var o4 := orientation(b_start, b_end, a_end)
	if ((o1 > epsilon and o2 < -epsilon) or (o1 < -epsilon and o2 > epsilon)) \
			and ((o3 > epsilon and o4 < -epsilon) or (o3 < -epsilon and o4 > epsilon)):
		return true
	if absf(o1) <= epsilon and point_on_segment(b_start, a_start, a_end, epsilon):
		return true
	if absf(o2) <= epsilon and point_on_segment(b_end, a_start, a_end, epsilon):
		return true
	if absf(o3) <= epsilon and point_on_segment(a_start, b_start, b_end, epsilon):
		return true
	if absf(o4) <= epsilon and point_on_segment(a_end, b_start, b_end, epsilon):
		return true
	return false


static func normalized_or(value: Vector2, fallback: Vector2 = Vector2.RIGHT) -> Vector2:
	if value.length_squared() <= 0.000000000001:
		return fallback
	return value.normalized()

