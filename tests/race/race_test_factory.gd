extends RefCounted
## Deterministic geometry helpers kept independent from authored-track fixtures.

const TrackQueryType := preload("res://game/race/track_query.gd")


static func create_oval(
		sample_count: int = 96,
		width: float = 44.0,
		radius_x: float = 260.0,
		radius_y: float = 170.0
	) -> RaceTrackQuery:
	var count := clampi(sample_count, 16, 512)
	var points := PackedVector2Array()
	var source_radii := PackedFloat64Array()
	points.resize(count)
	source_radii.resize(count)
	# This fixture deliberately publishes one conservative radius for its entire
	# corner section. For an ellipse, the tightest curvature radius is b^2 / a
	# at the ends of its major axis, not merely the shorter semi-axis.
	var minimum_curvature_radius := minf(
		radius_y * radius_y / radius_x,
		radius_x * radius_x / radius_y
	)
	for index in count:
		var angle := TAU * float(index) / float(count)
		var cosine := cos(angle)
		var sine := sin(angle)
		points[index] = Vector2(cosine * radius_x, sine * radius_y)
		source_radii[index] = minimum_curvature_radius
	var length := _closed_length(points)
	var corners: Array = [{"start_distance": 0.0, "length": length}]
	var straights: Array = [
		{"start_distance": length * 0.20, "length": length * 0.12},
		{"start_distance": length * 0.70, "length": length * 0.12},
	]
	var query := TrackQueryType.new()
	query.configure(points, width, source_radii, corners, straights)
	return query


static func create_large_rectangle(width: float = 60.0) -> RaceTrackQuery:
	var points := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(6000.0, 0.0),
		Vector2(6000.0, 3000.0),
		Vector2(0.0, 3000.0),
	])
	var source_radii := PackedFloat64Array([INF, INF, INF, INF])
	var length := _closed_length(points)
	var straights: Array = [{"start_distance": 0.0, "length": length}]
	var query := TrackQueryType.new()
	query.configure(points, width, source_radii, [], straights)
	return query


static func _closed_length(points: PackedVector2Array) -> float:
	var output := 0.0
	for index in points.size():
		output += points[index].distance_to(points[(index + 1) % points.size()])
	return output
