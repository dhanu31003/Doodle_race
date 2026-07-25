class_name TrackValidator
extends RefCounted
## Schema and compiled-geometry checks. Codes are stable API for editor UI.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const FixedMathType := preload("res://game/core/fixed_math.gd")
const ValidationReportType := preload("res://game/track/validation/validation_report.gd")


static func validate_definition(definition: TrackDefinition) -> ValidationReport:
	if definition == null:
		var missing := ValidationReportType.new()
		missing.add_error(&"definition.missing", "Track definition is missing.")
		return missing
	return definition.validate_schema()


static func validate_compiled(
		definition: TrackDefinition,
		compiled: CompiledTrack
	) -> ValidationReport:
	var report := ValidationReportType.new()
	if compiled == null:
		report.add_error(&"compiled.missing", "Compiled track output is missing.")
		return report
	if compiled.centerline.size() < GameLimitsType.MIN_RESAMPLED_POINTS:
		report.add_error(&"geometry.sample_count_low", "Compiled centerline has too few samples.", "centerline")
		return report
	if not _validate_parallel_arrays(compiled, report):
		return report
	_validate_length_and_closure(definition, compiled, report)
	_validate_direction(definition, compiled, report)
	_validate_bounds(definition, compiled, report)
	_validate_radius(definition, compiled, report)
	_validate_surface_clearance(definition, compiled, report)
	_validate_start_and_pit(definition, compiled, report)
	_validate_crossings(definition, compiled, report)
	return report


static func _validate_parallel_arrays(
		compiled: CompiledTrack,
		report: ValidationReport
	) -> bool:
	var expected := compiled.centerline.size()
	var sizes := {
		"left_edge": compiled.left_edge.size(),
		"right_edge": compiled.right_edge.size(),
		"tangents": compiled.tangents.size(),
		"normals": compiled.normals.size(),
		"curvatures": compiled.curvatures.size(),
		"radii": compiled.radii.size(),
		"arc_distances": compiled.arc_distances.size(),
	}
	for field in sizes:
		if int(sizes[field]) != expected:
			report.add_error(&"geometry.parallel_array_size_mismatch", "Compiled geometry arrays must share the centerline sample count.", str(field), {"actual": sizes[field], "expected": expected})
	if not report.is_valid():
		return false
	for index in expected:
		for point in [
			compiled.centerline[index], compiled.left_edge[index], compiled.right_edge[index],
			compiled.tangents[index], compiled.normals[index],
		]:
			if not _is_finite_scalar(point.x) or not _is_finite_scalar(point.y):
				report.add_error(&"geometry.non_finite_sample", "Compiled geometry contains a non-finite vector.", "centerline[%d]" % index)
				return false
		if not _is_finite_scalar(compiled.curvatures[index]) \
				or is_nan(compiled.radii[index]) \
				or not _is_finite_scalar(compiled.arc_distances[index]):
			report.add_error(&"geometry.non_finite_sample", "Compiled geometry contains a non-finite scalar.", "curvatures[%d]" % index)
			return false
	return true


static func _is_finite_scalar(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


static func _validate_direction(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		report: ValidationReport
	) -> void:
	var area := FixedMathType.signed_polygon_area(compiled.centerline)
	if absf(area) <= GameLimitsType.GEOMETRY_EPSILON:
		report.add_warning(&"geometry.direction_ambiguous", "Self-crossing track has no single geometric winding; authored route order is preserved.", "direction")
		return
	var actual: StringName = &"clockwise" if area > 0.0 else &"counter_clockwise"
	if actual != definition.direction:
		report.add_error(&"geometry.direction_mismatch", "Compiled winding does not match the requested race direction.", "direction", {"actual": str(actual), "requested": str(definition.direction)})


static func find_crossings(compiled: CompiledTrack) -> Array[Dictionary]:
	var crossings: Array[Dictionary] = []
	var points := compiled.centerline
	var count := points.size()
	if count < 4:
		return crossings
	var cell_size := maxf(compiled.track_width * 2.0, 32.0)
	var buckets: Dictionary = {}
	var checked_pairs: Dictionary = {}
	for segment_a in count:
		var a_start := points[segment_a]
		var a_end := points[(segment_a + 1) % count]
		var minimum := Vector2(minf(a_start.x, a_end.x), minf(a_start.y, a_end.y))
		var maximum := Vector2(maxf(a_start.x, a_end.x), maxf(a_start.y, a_end.y))
		var min_cell := Vector2i(floori(minimum.x / cell_size), floori(minimum.y / cell_size))
		var max_cell := Vector2i(floori(maximum.x / cell_size), floori(maximum.y / cell_size))
		for cell_x in range(min_cell.x, max_cell.x + 1):
			for cell_y in range(min_cell.y, max_cell.y + 1):
				var cell_key := "%d:%d" % [cell_x, cell_y]
				var bucket: Array = buckets.get(cell_key, [])
				for segment_b_variant in bucket:
					var segment_b := int(segment_b_variant)
					if _segments_are_adjacent(segment_a, segment_b, count):
						continue
					var pair_key := "%d:%d" % [mini(segment_a, segment_b), maxi(segment_a, segment_b)]
					if checked_pairs.has(pair_key):
						continue
					checked_pairs[pair_key] = true
					var b_start := points[segment_b]
					var b_end := points[(segment_b + 1) % count]
					if not FixedMathType.segments_intersect(a_start, a_end, b_start, b_end):
						continue
					var intersection := _line_intersection(a_start, a_end, b_start, b_end)
					crossings.append({
						"segment_a": segment_a,
						"segment_b": segment_b,
						"distance_a": _distance_on_segment(compiled, segment_a, intersection),
						"distance_b": _distance_on_segment(compiled, segment_b, intersection),
						"position": intersection,
					})
				bucket.append(segment_a)
				buckets[cell_key] = bucket
	return crossings


static func find_surface_overlaps(
	compiled: CompiledTrack,
	maximum_results: int = 8,
	bridge_declarations: Array = []
	) -> Array[Dictionary]:
	var overlaps: Array[Dictionary] = []
	if compiled == null or compiled.centerline.size() < 4 or compiled.track_width <= 0.0:
		return overlaps
	var points := compiled.centerline
	var count := points.size()
	var clearance := compiled.track_width * 0.96
	var cell_size := maxf(compiled.track_width * 2.0, 32.0)
	var local_neighbor_count := maxi(
		2,
		ceili(compiled.track_width / maxf(compiled.sample_spacing, 1.0)) * 2
	)
	var buckets: Dictionary = {}
	var checked_pairs: Dictionary = {}
	for segment_a in count:
		var a_start := points[segment_a]
		var a_end := points[(segment_a + 1) % count]
		var minimum := Vector2(minf(a_start.x, a_end.x), minf(a_start.y, a_end.y)) - Vector2.ONE * clearance
		var maximum := Vector2(maxf(a_start.x, a_end.x), maxf(a_start.y, a_end.y)) + Vector2.ONE * clearance
		var min_cell := Vector2i(floori(minimum.x / cell_size), floori(minimum.y / cell_size))
		var max_cell := Vector2i(floori(maximum.x / cell_size), floori(maximum.y / cell_size))
		for cell_x in range(min_cell.x, max_cell.x + 1):
			for cell_y in range(min_cell.y, max_cell.y + 1):
				var cell_key := "%d:%d" % [cell_x, cell_y]
				var bucket: Array = buckets.get(cell_key, [])
				for segment_b_variant in bucket:
					var segment_b := int(segment_b_variant)
					if _segments_are_nearby_on_lap(segment_a, segment_b, count, local_neighbor_count):
						continue
					var pair_key := "%d:%d" % [mini(segment_a, segment_b), maxi(segment_a, segment_b)]
					if checked_pairs.has(pair_key):
						continue
					checked_pairs[pair_key] = true
					var b_start := points[segment_b]
					var b_end := points[(segment_b + 1) % count]
					# True crossings are handled by bridge declarations. This pass is for
					# road surfaces that overlap without a geometric crossing.
					if FixedMathType.segments_intersect(a_start, a_end, b_start, b_end):
						continue
					var distance := _segment_distance(a_start, a_end, b_start, b_end)
					if distance < clearance:
						if _segments_in_declared_bridge_window(
							segment_a, segment_b, compiled, bridge_declarations
						):
							continue
						overlaps.append({
							"segment_a": segment_a,
							"segment_b": segment_b,
							"distance": distance,
							"required_clearance": clearance,
						})
						if overlaps.size() >= maximum_results:
							return overlaps
				bucket.append(segment_a)
				buckets[cell_key] = bucket
	return overlaps


static func _validate_length_and_closure(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		report: ValidationReport
	) -> void:
	var length_tolerance := maxf(compiled.sample_spacing * 2.0, definition.target_length * 0.005)
	if absf(compiled.total_length - definition.target_length) > length_tolerance:
		report.add_error(&"geometry.target_length_mismatch", "Compiled length differs from the requested target.", "total_length", {"actual": compiled.total_length, "target": definition.target_length})
	var closure_gap := compiled.centerline[-1].distance_to(compiled.centerline[0])
	if closure_gap > compiled.sample_spacing * 1.75:
		report.add_error(&"geometry.closure_gap", "Closed centerline has an excessive final gap.", "centerline", {"gap": closure_gap})
	var seam_angle := absf(rad_to_deg(compiled.tangents[-1].angle_to(compiled.tangents[0])))
	if seam_angle > 20.0:
		report.add_error(&"geometry.closure_tangent_discontinuity", "Track tangent is discontinuous at the seam.", "centerline", {"angle_degrees": seam_angle})


static func _validate_bounds(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		report: ValidationReport
	) -> void:
	for index in compiled.centerline.size():
		for point in [compiled.left_edge[index], compiled.right_edge[index]]:
			if point.x < 0.0 or point.y < 0.0 \
					or point.x > definition.canvas_size.x or point.y > definition.canvas_size.y:
				report.add_error(&"geometry.track_out_of_bounds", "Track edge leaves the authoring canvas.", "centerline[%d]" % index, {"point": [point.x, point.y]})
				return


static func _validate_radius(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		report: ValidationReport
	) -> void:
	var minimum_allowed := maxf(
		GameLimitsType.MIN_TURN_RADIUS,
		definition.track_width * GameLimitsType.MIN_RADIUS_TO_WIDTH_RATIO
	)
	var minimum_actual := INF
	for radius in compiled.radii:
		if not is_inf(radius):
			minimum_actual = minf(minimum_actual, radius)
	if minimum_actual < minimum_allowed:
		report.add_error(&"geometry.turn_radius_too_small", "Track contains a turn tighter than the safe minimum radius.", "curvatures", {"actual_minimum": minimum_actual, "required_minimum": minimum_allowed})



static func _validate_surface_clearance(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		report: ValidationReport
	) -> void:
	var declarations: Array = [] if definition == null else definition.bridge_crossings
	var overlaps := find_surface_overlaps(compiled, 1, declarations)
	if not overlaps.is_empty():
		report.add_error(
			&"geometry.road_surface_overlap",
			"Two separate road sections are too close and their surfaces overlap.",
			"centerline",
			overlaps[0]
		)


static func _segments_in_declared_bridge_window(
	first_segment: int,
	second_segment: int,
	compiled: CompiledTrack,
	bridge_declarations: Array
	) -> bool:
	if bridge_declarations.is_empty() or compiled.arc_distances.size() != compiled.centerline.size():
		return false
	var first_distance := _segment_mid_distance(compiled, first_segment)
	var second_distance := _segment_mid_distance(compiled, second_segment)
	var deck_half_length := clampf(compiled.track_width * 0.8, 18.0, 72.0)
	# Keep this congruent with BridgePlanBuilder's ramp envelope. One sample of
	# padding accounts for a segment whose midpoint sits just outside the window.
	var ramp_half_length := clampf(
		compiled.track_width * 2.0,
		deck_half_length + 24.0,
		192.0
	) + compiled.sample_spacing
	for declaration_variant in bridge_declarations:
		if declaration_variant == null or not declaration_variant is BridgeCrossingDefinition:
			continue
		var declaration: BridgeCrossingDefinition = declaration_variant
		var direct := _circular_distance(
			first_distance, declaration.distance_a, compiled.total_length
		) <= ramp_half_length and _circular_distance(
			second_distance, declaration.distance_b, compiled.total_length
		) <= ramp_half_length
		var swapped := _circular_distance(
			first_distance, declaration.distance_b, compiled.total_length
		) <= ramp_half_length and _circular_distance(
			second_distance, declaration.distance_a, compiled.total_length
		) <= ramp_half_length
		if direct or swapped:
			return true
	return false


static func _segment_mid_distance(compiled: CompiledTrack, segment_index: int) -> float:
	var start := compiled.arc_distances[segment_index]
	var next_index := (segment_index + 1) % compiled.centerline.size()
	var segment_length := compiled.total_length - start \
		if next_index == 0 else compiled.arc_distances[next_index] - start
	return fposmod(start + segment_length * 0.5, compiled.total_length)


static func _circular_distance(first: float, second: float, lap_length: float) -> float:
	if lap_length <= GameLimitsType.GEOMETRY_EPSILON:
		return absf(first - second)
	var direct := absf(fposmod(first, lap_length) - fposmod(second, lap_length))
	return minf(direct, lap_length - direct)


static func _validate_start_and_pit(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		report: ValidationReport
	) -> void:
	var straight_length := _straight_length_from_start(compiled)
	var length_epsilon := maxf(0.001, compiled.sample_spacing * 0.0001)
	if straight_length + length_epsilon < GameLimitsType.START_STRAIGHT_LENGTH:
		report.add_error(&"geometry.start_straight_too_short", "Start/finish grid is not on a sufficiently straight section.", "start_finish_distance", {"actual": straight_length, "required": GameLimitsType.START_STRAIGHT_LENGTH, "suggested_distance": compiled.suggested_start_finish_distance})
	if definition.pit_side != TrackDefinition.PIT_NONE:
		var best_length := float(_best_straight(compiled).get("length", 0.0))
		if best_length + length_epsilon < GameLimitsType.PIT_STRAIGHT_LENGTH:
			report.add_error(&"geometry.pit_straight_missing", "A pit lane requires a longer straight section.", "pit_side", {"actual": best_length, "required": GameLimitsType.PIT_STRAIGHT_LENGTH})


static func _validate_crossings(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		report: ValidationReport
	) -> void:
	var actual := find_crossings(compiled)
	var matched := PackedByteArray()
	matched.resize(definition.bridge_crossings.size())
	var tolerance := maxf(compiled.sample_spacing * 3.0, compiled.track_width)
	for crossing in actual:
		var declaration_index := _matching_bridge_index(definition, crossing, tolerance, matched)
		if declaration_index < 0:
			report.add_error(&"geometry.undeclared_crossing", "Track contains an undeclared self-crossing.", "centerline", crossing)
		else:
			matched[declaration_index] = 1
	for index in definition.bridge_crossings.size():
		if matched[index] == 0:
			report.add_error(&"geometry.bridge_crossing_not_found", "Declared bridge does not match a geometric crossing.", "bridge_crossings[%d]" % index)


static func _straight_length_from_start(compiled: CompiledTrack) -> float:
	if compiled.centerline.is_empty():
		return 0.0
	var base_tangent := compiled.tangents[0]
	var allowed_angle := deg_to_rad(GameLimitsType.START_STRAIGHT_MAX_ANGLE_DEGREES)
	var length := 0.0
	for index in compiled.centerline.size():
		if absf(base_tangent.angle_to(compiled.tangents[index])) > allowed_angle:
			break
		length += compiled.centerline[index].distance_to(
			compiled.centerline[(index + 1) % compiled.centerline.size()]
		)
	return length


static func _best_straight(compiled: CompiledTrack) -> Dictionary:
	var best: Dictionary = {}
	for section in compiled.straight_sections:
		if best.is_empty() or float(section.get("length", 0.0)) > float(best.get("length", 0.0)):
			best = section
	return best


static func _matching_bridge_index(
		definition: TrackDefinition,
		actual: Dictionary,
		tolerance: float,
		already_matched: PackedByteArray
	) -> int:
	var actual_a := float(actual["distance_a"])
	var actual_b := float(actual["distance_b"])
	for index in definition.bridge_crossings.size():
		if already_matched[index] == 1:
			continue
		var declared := definition.bridge_crossings[index]
		var direct := absf(declared.distance_a - actual_a) <= tolerance \
			and absf(declared.distance_b - actual_b) <= tolerance
		var swapped := absf(declared.distance_a - actual_b) <= tolerance \
			and absf(declared.distance_b - actual_a) <= tolerance
		if direct or swapped:
			return index
	return -1


static func _segments_are_adjacent(first: int, second: int, count: int) -> bool:
	return first == second or (first + 1) % count == second or (second + 1) % count == first


static func _segments_are_nearby_on_lap(
		first: int,
		second: int,
		count: int,
		neighbor_count: int
	) -> bool:
	var direct := absi(first - second)
	var wrapped := count - direct
	return mini(direct, wrapped) <= neighbor_count


static func _segment_distance(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	return minf(
		minf(_point_segment_distance(a, c, d), _point_segment_distance(b, c, d)),
		minf(_point_segment_distance(c, a, b), _point_segment_distance(d, a, b))
	)


static func _point_segment_distance(point: Vector2, start: Vector2, end: Vector2) -> float:
	var segment := end - start
	var length_squared := segment.length_squared()
	if length_squared <= GameLimitsType.GEOMETRY_EPSILON:
		return point.distance_to(start)
	var amount := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * amount)


static func _line_intersection(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> Vector2:
	var direction_a := b - a
	var direction_b := d - c
	var denominator := FixedMathType.cross_2d(direction_a, direction_b)
	if absf(denominator) <= GameLimitsType.GEOMETRY_EPSILON:
		return (a + b + c + d) * 0.25
	var amount := FixedMathType.cross_2d(c - a, direction_b) / denominator
	return a + direction_a * amount


static func _distance_on_segment(
		compiled: CompiledTrack,
		segment_index: int,
		point: Vector2
	) -> float:
	return compiled.arc_distances[segment_index] \
		+ compiled.centerline[segment_index].distance_to(point)
