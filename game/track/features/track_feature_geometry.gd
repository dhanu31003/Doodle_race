class_name TrackFeatureGeometry
extends RefCounted
## Defensive, deterministic geometry helpers shared by track-world planners.
##
## Feature builders intentionally validate their input instead of assuming the
## compiler was the only caller. This keeps previews and network-loaded tracks
## from turning malformed parallel arrays into runtime indexing faults.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")

const MAX_INPUT_SAMPLES: int = GameLimitsType.MAX_RESAMPLED_POINTS
const MAX_POLYLINE_SAMPLES: int = 256


static func validate_compiled(compiled: CompiledTrack) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	if compiled == null:
		errors.append(error(&"features.compiled_missing", "Compiled track is missing.", "compiled"))
		return errors
	var count := compiled.centerline.size()
	if count < 4 or count > MAX_INPUT_SAMPLES:
		errors.append(error(
			&"features.sample_count_invalid",
			"Feature planning requires 4 to %d centerline samples." % MAX_INPUT_SAMPLES,
			"centerline"
		))
		return errors
	var parallel_sizes := {
		"left_edge": compiled.left_edge.size(),
		"right_edge": compiled.right_edge.size(),
		"tangents": compiled.tangents.size(),
		"normals": compiled.normals.size(),
		"curvatures": compiled.curvatures.size(),
		"radii": compiled.radii.size(),
		"arc_distances": compiled.arc_distances.size(),
	}
	for field_name in parallel_sizes:
		if int(parallel_sizes[field_name]) != count:
			errors.append(error(
				&"features.parallel_array_mismatch",
				"Compiled geometry arrays must share the centerline sample count.",
				str(field_name),
				{"actual": int(parallel_sizes[field_name]), "expected": count}
			))
	if not errors.is_empty():
		return errors
	if not is_finite_scalar(compiled.total_length) or compiled.total_length <= GameLimitsType.GEOMETRY_EPSILON:
		errors.append(error(&"features.total_length_invalid", "Compiled lap length must be finite and positive.", "total_length"))
	if not is_finite_scalar(compiled.track_width) or compiled.track_width <= GameLimitsType.GEOMETRY_EPSILON:
		errors.append(error(&"features.track_width_invalid", "Compiled track width must be finite and positive.", "track_width"))
	if not is_finite_scalar(compiled.sample_spacing) or compiled.sample_spacing <= GameLimitsType.GEOMETRY_EPSILON:
		errors.append(error(&"features.sample_spacing_invalid", "Compiled sample spacing must be finite and positive.", "sample_spacing"))
	if not errors.is_empty():
		return errors
	var previous_distance := -1.0
	for index in count:
		var vectors := [
			compiled.centerline[index], compiled.left_edge[index], compiled.right_edge[index],
			compiled.tangents[index], compiled.normals[index],
		]
		for vector_value in vectors:
			if not is_finite_vector2(vector_value):
				errors.append(error(
					&"features.non_finite_vector",
					"Compiled geometry contains a non-finite vector.",
					"centerline[%d]" % index
				))
				return errors
		if compiled.tangents[index].length_squared() <= GameLimitsType.GEOMETRY_EPSILON \
				or compiled.normals[index].length_squared() <= GameLimitsType.GEOMETRY_EPSILON:
			errors.append(error(
				&"features.direction_vector_invalid",
				"Compiled tangent and normal vectors must be non-zero.",
				"tangents[%d]" % index
			))
			return errors
		var arc_distance := compiled.arc_distances[index]
		if not is_finite_scalar(arc_distance) or arc_distance < 0.0 \
				or arc_distance + GameLimitsType.GEOMETRY_EPSILON < previous_distance:
			errors.append(error(
				&"features.arc_distances_invalid",
				"Compiled arc distances must be finite, non-negative, and monotonic.",
				"arc_distances[%d]" % index
			))
			return errors
		if not is_finite_scalar(compiled.curvatures[index]) or is_nan(compiled.radii[index]):
			errors.append(error(
				&"features.non_finite_scalar",
				"Compiled curvature/radius data is malformed.",
				"curvatures[%d]" % index
			))
			return errors
		previous_distance = arc_distance
	if absf(compiled.arc_distances[0]) > GameLimitsType.COORDINATE_QUANTUM \
			or compiled.arc_distances[-1] >= compiled.total_length:
		errors.append(error(
			&"features.arc_domain_invalid",
			"Arc distances must start at zero and remain below total lap length.",
			"arc_distances"
		))
	return errors


static func sample_at_distance(compiled: CompiledTrack, lap_distance: float) -> Dictionary:
	var count := compiled.centerline.size()
	if count == 0 or compiled.total_length <= GameLimitsType.GEOMETRY_EPSILON:
		return {}
	var wrapped := fposmod(lap_distance, compiled.total_length)
	var index := count - 1
	for candidate in count - 1:
		if compiled.arc_distances[candidate + 1] > wrapped:
			index = candidate
			break
	var next_index := (index + 1) % count
	var start_distance := compiled.arc_distances[index]
	var segment_length := compiled.total_length - start_distance \
			if next_index == 0 else compiled.arc_distances[next_index] - start_distance
	var amount := 0.0
	if segment_length > GameLimitsType.GEOMETRY_EPSILON:
		amount = clampf((wrapped - start_distance) / segment_length, 0.0, 1.0)
	var tangent := compiled.tangents[index].lerp(compiled.tangents[next_index], amount).normalized()
	if tangent.length_squared() <= GameLimitsType.GEOMETRY_EPSILON:
		tangent = compiled.tangents[index].normalized()
	var normal := Vector2(-tangent.y, tangent.x)
	return {
		"distance": quantize_scalar(wrapped),
		"segment_index": index,
		"position": quantize_vector(compiled.centerline[index].lerp(compiled.centerline[next_index], amount)),
		"tangent": quantize_direction(tangent),
		"normal": quantize_direction(normal),
	}


static func sample_window(
		compiled: CompiledTrack,
		center_distance: float,
		half_length: float,
		preferred_spacing: float,
		maximum_samples: int = MAX_POLYLINE_SAMPLES
	) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var safe_half := maxf(0.0, half_length)
	var safe_spacing := maxf(preferred_spacing, GameLimitsType.COORDINATE_QUANTUM)
	var count := clampi(ceili((safe_half * 2.0) / safe_spacing) + 1, 2, maximum_samples)
	for index in count:
		var amount := float(index) / float(maxi(1, count - 1))
		var relative_distance := lerpf(-safe_half, safe_half, amount)
		var sample := sample_at_distance(compiled, center_distance + relative_distance)
		sample["relative_distance"] = quantize_scalar(relative_distance)
		output.append(sample)
	return output


static func circular_distance(first: float, second: float, lap_length: float) -> float:
	if lap_length <= GameLimitsType.GEOMETRY_EPSILON:
		return absf(first - second)
	var direct := absf(fposmod(first, lap_length) - fposmod(second, lap_length))
	return minf(direct, lap_length - direct)


static func point_to_track_distance(point: Vector2, compiled: CompiledTrack) -> float:
	var minimum := INF
	for index in compiled.centerline.size():
		minimum = minf(minimum, point_to_segment_distance(
			point,
			compiled.centerline[index],
			compiled.centerline[(index + 1) % compiled.centerline.size()]
		))
	return minimum


static func point_to_track_distance_excluding_neighbors(
		point: Vector2,
		compiled: CompiledTrack,
		center_segment: int,
		neighbor_count: int
	) -> float:
	var minimum := INF
	var count := compiled.centerline.size()
	for index in count:
		var direct := absi(index - center_segment)
		if mini(direct, count - direct) <= neighbor_count:
			continue
		minimum = minf(minimum, point_to_segment_distance(
			point,
			compiled.centerline[index],
			compiled.centerline[(index + 1) % count]
		))
	return minimum


static func point_to_polyline_distance(point: Vector2, polyline: PackedVector2Array) -> float:
	if polyline.is_empty():
		return INF
	if polyline.size() == 1:
		return point.distance_to(polyline[0])
	var minimum := INF
	for index in polyline.size() - 1:
		minimum = minf(minimum, point_to_segment_distance(point, polyline[index], polyline[index + 1]))
	return minimum


static func point_to_segment_distance(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= GameLimitsType.GEOMETRY_EPSILON:
		return point.distance_to(start)
	var amount := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * amount)


static func quantize_scalar(value: float, quantum: float = GameLimitsType.COORDINATE_QUANTUM) -> float:
	return QuantizationType.scalar(value, quantum)


static func quantize_vector(value: Vector2) -> Vector2:
	return QuantizationType.vector2(value)


static func quantize_direction(value: Vector2) -> Vector2:
	return QuantizationType.vector2(value, GameLimitsType.NORMALIZED_QUANTUM)


static func finalize(plan: Dictionary) -> Dictionary:
	var fingerprint_source := plan.duplicate(true)
	fingerprint_source.erase("fingerprint")
	plan["fingerprint"] = CanonicalJsonType.sha256(fingerprint_source)
	return plan


static func error(
		code: StringName,
		message: String,
		path: String = "",
		context: Dictionary = {}
	) -> Dictionary:
	return {
		"code": str(code),
		"message": message,
		"path": path,
		"context": context.duplicate(true),
	}


static func is_finite_scalar(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


static func is_finite_vector2(value: Vector2) -> bool:
	return is_finite_scalar(value.x) and is_finite_scalar(value.y)
