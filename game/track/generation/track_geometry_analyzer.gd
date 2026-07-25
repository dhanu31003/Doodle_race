class_name TrackGeometryAnalyzer
extends RefCounted
## Tangent, normal, signed-curvature, winding, straight, and corner analysis.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const FixedMathType := preload("res://game/core/fixed_math.gd")
const TrackAnalysisType := preload("res://game/track/generation/track_analysis.gd")

const STRAIGHT_CURVATURE_LIMIT: float = 1.0 / 400.0


static func analyze(samples: PackedVector2Array) -> TrackAnalysis:
	var analysis := TrackAnalysisType.new()
	var count := samples.size()
	if count < 3:
		return analysis
	analysis.tangents.resize(count)
	analysis.normals.resize(count)
	analysis.curvatures.resize(count)
	analysis.radii.resize(count)
	analysis.arc_distances.resize(count)
	var running_distance := 0.0
	for index in count:
		analysis.arc_distances[index] = running_distance
		running_distance += samples[index].distance_to(samples[(index + 1) % count])
	analysis.total_length = running_distance
	for index in count:
		var previous := samples[FixedMathType.wrap_index(index - 1, count)]
		var current := samples[index]
		var next := samples[(index + 1) % count]
		var incoming := current - previous
		var outgoing := next - current
		var tangent := FixedMathType.normalized_or(next - previous)
		analysis.tangents[index] = tangent
		analysis.normals[index] = Vector2(-tangent.y, tangent.x)
		var local_length := 0.5 * (incoming.length() + outgoing.length())
		var curvature := 0.0
		if local_length > GameLimitsType.GEOMETRY_EPSILON:
			var signed_turn := atan2(
				FixedMathType.cross_2d(incoming, outgoing), incoming.dot(outgoing)
			)
			curvature = signed_turn / local_length
		analysis.curvatures[index] = curvature
		analysis.radii[index] = INF \
			if absf(curvature) <= GameLimitsType.STRAIGHT_CURVATURE_EPSILON \
			else 1.0 / absf(curvature)
	analysis.signed_area = FixedMathType.signed_polygon_area(samples)
	# Screen-space Y points down, so positive shoelace area appears clockwise.
	if absf(analysis.signed_area) <= GameLimitsType.GEOMETRY_EPSILON:
		analysis.winding = &"ambiguous"
	else:
		analysis.winding = &"clockwise" if analysis.signed_area > 0.0 else &"counter_clockwise"
	analysis.straight_sections = _classify_sections(analysis, true)
	analysis.corner_sections = _classify_sections(analysis, false)
	return analysis


static func _classify_sections(analysis: TrackAnalysis, want_straight: bool) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var count := analysis.curvatures.size()
	if count == 0:
		return output
	var flags := PackedByteArray()
	flags.resize(count)
	var matching_count := 0
	for index in count:
		var is_straight := absf(analysis.curvatures[index]) <= STRAIGHT_CURVATURE_LIMIT
		flags[index] = 1 if is_straight == want_straight else 0
		matching_count += flags[index]
	if matching_count == 0:
		return output
	if matching_count == count:
		output.append({
			"start_index": 0,
			"end_index": count - 1,
			"start_distance": 0.0,
			"length": analysis.total_length,
		})
		return output
	# Start after a non-matching sample so wraparound runs become one section.
	var scan_start := 0
	for index in count:
		if flags[index] == 0:
			scan_start = (index + 1) % count
			break
	var active_start := -1
	var active_length := 0.0
	for offset in range(count + 1):
		var index := (scan_start + offset) % count
		var matches := offset < count and flags[index] == 1
		if matches and active_start < 0:
			active_start = index
			active_length = 0.0
		if matches:
			active_length += _edge_length_at(analysis, index)
		elif active_start >= 0:
			var end_index := FixedMathType.wrap_index(index - 1, count)
			output.append({
				"start_index": active_start,
				"end_index": end_index,
				"start_distance": analysis.arc_distances[active_start],
				"length": active_length,
			})
			active_start = -1
	return output


static func _edge_length_at(analysis: TrackAnalysis, index: int) -> float:
	var next := (index + 1) % analysis.arc_distances.size()
	if next == 0:
		return analysis.total_length - analysis.arc_distances[index]
	return analysis.arc_distances[next] - analysis.arc_distances[index]
