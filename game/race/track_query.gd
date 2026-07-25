class_name RaceTrackQuery
extends RefCounted
## Defensive, read-only runtime projection API over a CompiledTrack centerline.
##
## A position alone is ambiguous at a self-crossing. Runtime consumers therefore
## carry the previous route distance and bridge collision layer into contextual
## projections. This keeps the overpass and underpass as separate race surfaces
## while leaving the authoritative simulation two-dimensional.

const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const BridgePlannerType := preload("res://game/track/features/bridge_plan_builder.gd")
const TrackValidatorType := preload("res://game/track/validation/track_validator.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")

const MAX_SAMPLES: int = 8192
const MIN_WIDTH: float = 1.0
const MAX_WIDTH: float = 4096.0
const COLLISION_LAYER_GROUND: int = 1
const COLLISION_LAYER_ELEVATED: int = 2
const COLLISION_MASK_TRANSITION: int = COLLISION_LAYER_GROUND | COLLISION_LAYER_ELEVATED

var centerline: PackedVector2Array = PackedVector2Array()
var radii: PackedFloat64Array = PackedFloat64Array()
var corner_sections: Array[Dictionary] = []
var straight_sections: Array[Dictionary] = []
var bridge_zones: Array[Dictionary] = []
var road_surface: StringName = RoadSurfaceCatalogType.SMOOTH_ASPHALT
var deterministic_seed: int = 0
var track_width: float = 0.0
var total_length: float = 0.0
var error: StringName = &"not_configured"

var _segment_starts: PackedFloat64Array = PackedFloat64Array()
var _segment_lengths: PackedFloat64Array = PackedFloat64Array()


static func from_compiled(compiled: Variant) -> RaceTrackQuery:
	var query := RaceTrackQuery.new()
	if compiled == null or not compiled is Object:
		query.error = &"missing_compiled_track"
		return query
	var source_points: Variant = _property_value(compiled, &"centerline")
	var source_width: Variant = _property_value(compiled, &"track_width")
	var source_radii: Variant = _property_value(compiled, &"radii")
	var source_corners: Variant = _property_value(compiled, &"corner_sections")
	var source_straights: Variant = _property_value(compiled, &"straight_sections")
	if not source_points is PackedVector2Array:
		query.error = &"invalid_centerline_type"
		return query
	query.configure(
		source_points,
		_float_or(source_width, 0.0),
		source_radii if source_radii is PackedFloat64Array else PackedFloat64Array(),
		source_corners if source_corners is Array else [],
		source_straights if source_straights is Array else []
	)
	if not query.is_valid() or not compiled is CompiledTrack:
		return query
	query.road_surface = RoadSurfaceCatalogType.sanitized_style(
		StringName(str(_property_value(compiled, &"road_surface")))
	)
	query.deterministic_seed = int(_property_value(compiled, &"deterministic_seed"))
	var runtime_bridge_plan := query._derive_runtime_bridge_plan(compiled)
	if not bool(runtime_bridge_plan.get("valid", false)):
		query.error = StringName(str(runtime_bridge_plan.get("error", "invalid_bridge_plan")))
		query._reset_invalid()
		return query
	if not query.configure_bridge_plan(runtime_bridge_plan.get("plan", {})):
		query.error = &"invalid_bridge_plan"
		query._reset_invalid()
	return query


func configure(
		points: PackedVector2Array,
		width: float,
		source_radii: PackedFloat64Array = PackedFloat64Array(),
		source_corners: Array = [],
		source_straights: Array = []
	) -> bool:
	error = &""
	centerline = PackedVector2Array()
	radii = PackedFloat64Array()
	corner_sections = []
	straight_sections = []
	bridge_zones = []
	road_surface = RoadSurfaceCatalogType.SMOOTH_ASPHALT
	deterministic_seed = 0
	_segment_starts = PackedFloat64Array()
	_segment_lengths = PackedFloat64Array()
	total_length = 0.0
	track_width = 0.0
	if points.size() < 3 or points.size() > MAX_SAMPLES:
		error = &"centerline_sample_count_out_of_bounds"
		return false
	if not _finite(width) or width < MIN_WIDTH or width > MAX_WIDTH:
		error = &"track_width_out_of_bounds"
		return false
	for point in points:
		if not _finite_vector(point):
			error = &"non_finite_centerline"
			return false
	centerline = points.duplicate()
	track_width = width
	_segment_starts.resize(centerline.size())
	_segment_lengths.resize(centerline.size())
	for index in centerline.size():
		_segment_starts[index] = total_length
		var segment_length := centerline[index].distance_to(centerline[(index + 1) % centerline.size()])
		if not _finite(segment_length) or segment_length <= 0.000001:
			error = &"degenerate_centerline_segment"
			_reset_invalid()
			return false
		_segment_lengths[index] = segment_length
		total_length += segment_length
	if not _finite(total_length) or total_length <= 0.001:
		error = &"invalid_track_length"
		_reset_invalid()
		return false
	if source_radii.size() == centerline.size():
		radii = source_radii.duplicate()
	else:
		radii.resize(centerline.size())
		radii.fill(INF)
	corner_sections = _sanitized_sections(source_corners)
	straight_sections = _sanitized_sections(source_straights)
	return true


func surface_profile() -> Dictionary:
	return RoadSurfaceCatalogType.profile(road_surface)


func surface_bump_height_meters(distance_along: float) -> float:
	return RoadSurfaceCatalogType.bump_height_meters(
		road_surface, distance_along, total_length, deterministic_seed
	)


func configure_bridge_plan(plan: Dictionary) -> bool:
	bridge_zones = []
	if not bool(plan.get("valid", false)):
		return false
	var crossings: Variant = plan.get("crossings", [])
	if not crossings is Array or crossings.size() > BridgePlannerType.MAX_BRIDGES:
		return false
	for crossing_variant in crossings:
		if not crossing_variant is Dictionary:
			return false
		var crossing: Dictionary = crossing_variant
		var branch_a: Variant = crossing.get("branch_a", {})
		var branch_b: Variant = crossing.get("branch_b", {})
		var collision: Variant = crossing.get("collision", {})
		var deck: Variant = crossing.get("deck", {})
		var ramps: Variant = crossing.get("ramps", [])
		if not branch_a is Dictionary or not branch_b is Dictionary \
				or not collision is Dictionary or not deck is Dictionary or not ramps is Array:
			return false
		var distance_a := _float_or(branch_a.get("lap_distance"), -1.0)
		var distance_b := _float_or(branch_b.get("lap_distance"), -1.0)
		var layer_a := int(collision.get("branch_a_layer", 0))
		var layer_b := int(collision.get("branch_b_layer", 0))
		if distance_a < 0.0 or distance_a >= total_length \
				or distance_b < 0.0 or distance_b >= total_length \
				or not _valid_collision_layer(layer_a) or not _valid_collision_layer(layer_b) \
				or layer_a == layer_b:
			return false
		var overpass_branch := str(crossing.get("overpass_branch", ""))
		var overpass_distance := distance_a if overpass_branch == "a" else distance_b
		var underpass_distance := distance_b if overpass_branch == "a" else distance_a
		var deck_half_length := _float_or(deck.get("half_length"), -1.0)
		if (overpass_branch != "a" and overpass_branch != "b") \
				or deck_half_length <= 0.0 or deck_half_length >= total_length * 0.5:
			return false
		var ramp_half_length := deck_half_length
		for ramp_variant in ramps:
			if not ramp_variant is Dictionary or str(ramp_variant.get("branch", "")) != overpass_branch:
				continue
			var profile: Variant = ramp_variant.get("profile", [])
			if not profile is Array:
				return false
			for profile_variant in profile:
				if not profile_variant is Dictionary:
					return false
				var profile_distance := _float_or(profile_variant.get("distance"), -1.0)
				if profile_distance < 0.0 or profile_distance >= total_length:
					return false
				ramp_half_length = maxf(
					ramp_half_length,
					circular_distance(overpass_distance, profile_distance)
				)
		if ramp_half_length >= total_length * 0.5:
			return false
		bridge_zones.append({
			"crossing_id": str(crossing.get("crossing_id", "")),
			"position": crossing.get("position", Vector2.ZERO),
			"branch_a_distance": distance_a,
			"branch_b_distance": distance_b,
			"branch_a_layer": layer_a,
			"branch_b_layer": layer_b,
			"overpass_branch": overpass_branch,
			"overpass_distance": overpass_distance,
			"underpass_distance": underpass_distance,
			"deck_half_length": deck_half_length,
			"ramp_half_length": ramp_half_length,
		})
	bridge_zones.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		var first_distance := float(first["overpass_distance"])
		var second_distance := float(second["overpass_distance"])
		if not is_equal_approx(first_distance, second_distance):
			return first_distance < second_distance
		return str(first["crossing_id"]) < str(second["crossing_id"])
	)
	return true


func _derive_runtime_bridge_plan(compiled: CompiledTrack) -> Dictionary:
	var definition := TrackDefinitionType.new()
	for declaration_variant in compiled.bridge_crossings:
		if not declaration_variant is Dictionary:
			return {"valid": false, "error": "invalid_bridge_declaration"}
		var declaration := BridgeDefinitionType.from_dictionary(declaration_variant)
		definition.bridge_crossings.append(declaration)
	var plan := BridgePlannerType.plan(definition, compiled)
	if not bool(plan.get("valid", false)):
		var error_code := "invalid_bridge_plan"
		var errors: Variant = plan.get("errors", [])
		if errors is Array and not errors.is_empty() and errors[0] is Dictionary:
			error_code = str(errors[0].get("code", error_code))
		return {"valid": false, "error": error_code, "plan": plan}
	# The planner already rejects undeclared geometry. Keep this explicit audit
	# assertion close to the adapter so a future planner contract change cannot
	# silently reintroduce ambiguous race projections.
	if compiled.bridge_crossings.is_empty() and not TrackValidatorType.find_crossings(compiled).is_empty():
		return {"valid": false, "error": "undeclared_runtime_crossing", "plan": plan}
	return {"valid": true, "plan": plan}


func is_valid() -> bool:
	return error == &"" and centerline.size() >= 3 and total_length > 0.0


func nearest(position: Vector2) -> Dictionary:
	if not is_valid() or not _finite_vector(position):
		return {}
	return _nearest_internal(position, false, 0.0, 0, 0.0)


func nearest_continuous(
	position: Vector2,
	distance_hint: float,
	collision_layer_hint: int = 0,
	maximum_route_delta: float = -1.0
	) -> Dictionary:
	if not is_valid() or not _finite_vector(position) or not _finite(distance_hint):
		return {}
	var route_limit := maximum_route_delta
	if not _finite(route_limit) or route_limit <= 0.0:
		route_limit = maxf(track_width * 2.5, 48.0)
	route_limit = clampf(route_limit, 0.001, total_length * 0.5)
	if route_limit >= total_length * 0.5 - 0.000001:
		return nearest(position)
	return _nearest_internal(
		position,
		true,
		wrap_distance(distance_hint),
		collision_layer_hint if _valid_collision_layer(collision_layer_hint) else 0,
		route_limit
	)


func _nearest_internal(
	position: Vector2,
	use_context: bool,
	distance_hint: float,
	collision_layer_hint: int,
	maximum_route_delta: float
	) -> Dictionary:
	var best_distance_squared := INF
	var best_route_delta := INF
	var best_layer_match := false
	var best: Dictionary = {}
	var ambiguity_distance := maxf(0.001, track_width * 0.02)
	var candidate_indices := PackedInt32Array()
	if use_context:
		candidate_indices = _context_segment_indices(distance_hint, maximum_route_delta)
	else:
		candidate_indices.resize(centerline.size())
		for index in centerline.size():
			candidate_indices[index] = index
	for index_variant in candidate_indices:
		var index := int(index_variant)
		var candidate := _projection_for_segment(position, index)
		var route_delta := 0.0
		if use_context:
			route_delta = absf(forward_delta(distance_hint, float(candidate["distance_along"])))
			if route_delta > maximum_route_delta + _segment_lengths[index]:
				continue
		var distance_squared := float(candidate["distance_squared"])
		var layer_match := collision_layer_hint == 0 \
			or int(candidate["collision_layer"]) == collision_layer_hint \
			or (int(candidate["collision_mask"]) & collision_layer_hint) != 0
		var replace := best.is_empty() or distance_squared < best_distance_squared
		if not best.is_empty() and absf(
			sqrt(distance_squared) - sqrt(best_distance_squared)
		) <= ambiguity_distance:
			replace = route_delta < best_route_delta - 0.000001 \
				or (is_equal_approx(route_delta, best_route_delta) and layer_match and not best_layer_match) \
				or (is_equal_approx(route_delta, best_route_delta) and layer_match == best_layer_match \
					and int(candidate["segment_index"]) < int(best["segment_index"]))
		if replace:
			best = candidate
			best_distance_squared = distance_squared
			best_route_delta = route_delta
			best_layer_match = layer_match
	if best.is_empty() and use_context:
		# A valid route always has nearby samples, but fail deterministically to the
		# geometric query if a caller supplied an impossibly tiny context window.
		return _nearest_internal(position, false, 0.0, 0, 0.0)
	return best


func _context_segment_indices(distance_hint: float, route_limit: float) -> PackedInt32Array:
	var output := PackedInt32Array()
	if centerline.is_empty() or _segment_starts.size() != centerline.size() \
			or _segment_lengths.size() != centerline.size():
		return output
	var count := centerline.size()
	var center_index := _segment_index_at(wrap_distance(distance_hint))
	var seen := PackedByteArray()
	seen.resize(count)
	output.append(center_index)
	seen[center_index] = 1
	var local_distance := wrap_distance(distance_hint) - _segment_starts[center_index]

	var forward_travel := _segment_lengths[center_index] - local_distance
	var forward_index := (center_index + 1) % count
	var visited := 1
	while visited < count and forward_travel <= route_limit + 0.000001:
		if seen[forward_index] == 0:
			output.append(forward_index)
			seen[forward_index] = 1
		forward_travel += _segment_lengths[forward_index]
		forward_index = (forward_index + 1) % count
		visited += 1

	var backward_travel := local_distance
	var backward_index := posmod(center_index - 1, count)
	visited = 1
	while visited < count and backward_travel <= route_limit + 0.000001:
		if seen[backward_index] == 0:
			output.append(backward_index)
			seen[backward_index] = 1
		backward_travel += _segment_lengths[backward_index]
		backward_index = posmod(backward_index - 1, count)
		visited += 1
	return output


func sample_at_distance(distance_along: float) -> Dictionary:
	if not is_valid() or not _finite(distance_along):
		return {}
	var wrapped := wrap_distance(distance_along)
	var index := _segment_index_at(wrapped)
	var length := _segment_lengths[index]
	var amount := clampf((wrapped - _segment_starts[index]) / length, 0.0, 1.0)
	var start := centerline[index]
	var finish := centerline[(index + 1) % centerline.size()]
	var tangent := (finish - start).normalized()
	var normal := Vector2(-tangent.y, tangent.x)
	var radius := INF
	if radii.size() == centerline.size():
		radius = radii[index]
	var output := {
		"segment_index": index,
		"amount": amount,
		"position": start.lerp(finish, amount),
		"tangent": tangent,
		"normal": normal,
		"radius": radius,
		"distance_along": wrapped,
		"half_width": track_width * 0.5,
		"in_corner": _distance_in_sections(wrapped, corner_sections),
		"in_straight": _distance_in_sections(wrapped, straight_sections),
	}
	output.merge(surface_context_at_distance(wrapped), true)
	return output


func radius_at_distance(distance_along: float) -> float:
	if not is_valid() or not _finite(distance_along):
		return 0.0
	var index := _segment_index_at(wrap_distance(distance_along))
	return radii[index] if radii.size() == centerline.size() else INF


func is_corner_at_distance(distance_along: float) -> bool:
	if not is_valid() or not _finite(distance_along):
		return false
	return _distance_in_sections(wrap_distance(distance_along), corner_sections)


func surface_context_at_distance(distance_along: float) -> Dictionary:
	var wrapped := wrap_distance(distance_along)
	var output := {
		"collision_layer": COLLISION_LAYER_GROUND,
		"collision_mask": COLLISION_LAYER_GROUND,
		"elevation_level": 0.0,
		"bridge_id": "",
		"bridge_branch": "ground",
	}
	for zone in bridge_zones:
		var over_delta := circular_distance(wrapped, float(zone["overpass_distance"]))
		var deck_half := float(zone["deck_half_length"])
		var ramp_half := float(zone["ramp_half_length"])
		if over_delta <= ramp_half + 0.000001:
			var elevation := 1.0
			var layer := COLLISION_LAYER_ELEVATED
			var mask := COLLISION_LAYER_ELEVATED
			if over_delta > deck_half:
				elevation = clampf(
					(ramp_half - over_delta) / maxf(ramp_half - deck_half, 0.000001),
					0.0,
					1.0
				)
				# The lower half of either ramp is still grounded; both halves use
				# the transition mask so cars remain collidable across the handoff.
				layer = COLLISION_LAYER_GROUND \
					if elevation <= 0.5 else COLLISION_LAYER_ELEVATED
				mask = COLLISION_MASK_TRANSITION
			output = {
				"collision_layer": layer,
				"collision_mask": mask,
				"elevation_level": elevation,
				"bridge_id": str(zone["crossing_id"]),
				"bridge_branch": "overpass",
			}
			continue
		var under_delta := circular_distance(wrapped, float(zone["underpass_distance"]))
		if under_delta <= deck_half + 0.000001 and str(output["bridge_id"]).is_empty():
			output["bridge_id"] = str(zone["crossing_id"])
			output["bridge_branch"] = "underpass"
	return output


func circular_distance(first: float, second: float) -> float:
	if not is_valid() or not _finite(first) or not _finite(second):
		return INF
	var direct := absf(wrap_distance(first) - wrap_distance(second))
	return minf(direct, total_length - direct)


func collision_layers_compatible(
	first_layer: int,
	first_mask: int,
	second_layer: int,
	second_mask: int
	) -> bool:
	if not _valid_collision_layer(first_layer) or not _valid_collision_layer(second_layer):
		return true
	var safe_first_mask := first_mask if first_mask > 0 else first_layer
	var safe_second_mask := second_mask if second_mask > 0 else second_layer
	return (safe_first_mask & second_layer) != 0 and (safe_second_mask & first_layer) != 0


func upcoming_minimum_radius(distance_along: float, lookahead: float, samples: int = 8) -> float:
	if not is_valid():
		return 0.0
	var safe_samples := clampi(samples, 1, 64)
	var safe_lookahead := clampf(lookahead, 0.0, total_length * 0.5)
	var minimum := INF
	for sample_index in range(safe_samples + 1):
		var amount := float(sample_index) / float(safe_samples)
		var sample := sample_at_distance(distance_along + safe_lookahead * amount)
		var radius := float(sample.get("radius", INF))
		if _finite(radius):
			minimum = minf(minimum, maxf(radius, 0.001))
	return minimum


func forward_delta(previous_distance: float, current_distance: float) -> float:
	if not is_valid() or not _finite(previous_distance) or not _finite(current_distance):
		return 0.0
	var delta := wrap_distance(current_distance) - wrap_distance(previous_distance)
	if delta > total_length * 0.5:
		delta -= total_length
	elif delta < -total_length * 0.5:
		delta += total_length
	return delta


func wrap_distance(distance_along: float) -> float:
	if total_length <= 0.0 or not _finite(distance_along):
		return 0.0
	return fposmod(distance_along, total_length)


func clamp_to_wall(
	position: Vector2,
	vehicle_radius: float,
	distance_hint: float = INF,
	collision_layer_hint: int = 0,
	maximum_route_delta: float = -1.0
	) -> Dictionary:
	var projection := nearest(position) if not _finite(distance_hint) else nearest_continuous(
		position, distance_hint, collision_layer_hint, maximum_route_delta
	)
	if projection.is_empty():
		return {}
	var lateral := float(projection["signed_lateral"])
	# The road edge is not an invisible wall: a shoulder allows recoverable
	# off-track driving before the outer safety barrier is contacted.
	var road_limit := maxf(0.1, track_width * 0.5 - maxf(vehicle_radius, 0.0))
	var shoulder_width := maxf(6.0, track_width * 0.35)
	var drive_limit := road_limit + shoulder_width
	var clamped_lateral := clampf(lateral, -drive_limit, drive_limit)
	projection["drive_limit"] = drive_limit
	projection["road_limit"] = road_limit
	projection["wall_penetration"] = maxf(absf(lateral) - drive_limit, 0.0)
	projection["clamped_position"] = projection["center"] + projection["normal"] * clamped_lateral
	return projection


func recovery_projection(
	position: Vector2,
	distance_hint: float,
	collision_layer_hint: int,
	vehicle_radius: float
	) -> Dictionary:
	return clamp_to_wall(
		position,
		vehicle_radius,
		distance_hint,
		collision_layer_hint,
		maxf(track_width * 4.0, 64.0)
	)


func _projection_for_segment(position: Vector2, index: int) -> Dictionary:
	var start := centerline[index]
	var finish := centerline[(index + 1) % centerline.size()]
	var segment := finish - start
	var amount := clampf((position - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
	var center := start + segment * amount
	var tangent := segment.normalized()
	var normal := Vector2(-tangent.y, tangent.x)
	var along := wrap_distance(_segment_starts[index] + _segment_lengths[index] * amount)
	var output := {
		"segment_index": index,
		"amount": amount,
		"center": center,
		"tangent": tangent,
		"normal": normal,
		"signed_lateral": (position - center).dot(normal),
		"distance_squared": center.distance_squared_to(position),
		"distance_along": along,
		"half_width": track_width * 0.5,
	}
	output.merge(surface_context_at_distance(along), true)
	return output


func _segment_index_at(distance_along: float) -> int:
	var low := 0
	var high := _segment_starts.size() - 1
	while low <= high:
		var middle := (low + high) / 2
		if _segment_starts[middle] <= distance_along:
			if middle == _segment_starts.size() - 1 or _segment_starts[middle + 1] > distance_along:
				return middle
			low = middle + 1
		else:
			high = middle - 1
	return 0


func _sanitized_sections(source: Array) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for item in source:
		if not item is Dictionary:
			continue
		var start := _float_or(item.get("start_distance", -1.0), -1.0)
		var length := _float_or(item.get("length", 0.0), 0.0)
		if start < 0.0 or length <= 0.0 or not _finite(start) or not _finite(length):
			continue
		output.append({"start_distance": wrap_distance(start), "length": minf(length, total_length)})
	return output


func _distance_in_sections(distance_along: float, sections: Array[Dictionary]) -> bool:
	for section in sections:
		var start := float(section["start_distance"])
		var length := float(section["length"])
		var delta := wrap_distance(distance_along - start)
		if delta <= length:
			return true
	return false


func _reset_invalid() -> void:
	centerline = PackedVector2Array()
	radii = PackedFloat64Array()
	corner_sections = []
	straight_sections = []
	bridge_zones = []
	road_surface = RoadSurfaceCatalogType.SMOOTH_ASPHALT
	deterministic_seed = 0
	_segment_starts = PackedFloat64Array()
	_segment_lengths = PackedFloat64Array()
	total_length = 0.0
	track_width = 0.0


static func _float_or(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var converted := float(value)
	return converted if _finite(converted) else fallback


static func _property_value(source: Object, property_name: StringName) -> Variant:
	for property in source.get_property_list():
		if StringName(property.get("name", "")) == property_name:
			return source.get(property_name)
	return null


static func _finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


static func _finite_vector(value: Vector2) -> bool:
	return _finite(value.x) and _finite(value.y)


static func _valid_collision_layer(value: int) -> bool:
	return value == COLLISION_LAYER_GROUND or value == COLLISION_LAYER_ELEVATED
