class_name MinimapPlanBuilder
extends RefCounted
## Fits a closed, capped world polyline and semantic markers into a UI rectangle.

const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")

const MAX_ROUTE_POINTS: int = 193
const MIN_ROUTE_POINTS: int = 17
const MAX_MARKERS: int = 32


static func plan(
		compiled: CompiledTrack,
		pit_plan: Dictionary = {},
		bridge_plan: Dictionary = {},
		target_size: Vector2 = Vector2(256.0, 160.0),
		padding: float = 12.0
	) -> Dictionary:
	var errors := FeatureGeometry.validate_compiled(compiled)
	var output := {
		"feature_version": 1,
		"valid": errors.is_empty(),
		"errors": errors,
		"target_size": FeatureGeometry.quantize_vector(target_size),
		"padding": FeatureGeometry.quantize_scalar(padding),
		"world_bounds": {},
		"world_polyline": PackedVector2Array(),
		"polyline": PackedVector2Array(),
		"markers": [],
	}
	if not errors.is_empty():
		return FeatureGeometry.finalize(output)
	if not FeatureGeometry.is_finite_vector2(target_size) or target_size.x < 48.0 \
			or target_size.y < 48.0 or target_size.x > 4096.0 or target_size.y > 4096.0 \
			or not FeatureGeometry.is_finite_scalar(padding) or padding < 0.0 \
			or padding * 2.0 >= minf(target_size.x, target_size.y):
		output["errors"].append(FeatureGeometry.error(
			&"minimap.viewport_invalid", "Minimap size/padding is outside safe bounds.", "target_size"
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)

	var open_point_count := clampi(
		ceili(compiled.total_length / maxf(compiled.sample_spacing * 4.0, compiled.total_length / 192.0)),
		MIN_ROUTE_POINTS - 1,
		MAX_ROUTE_POINTS - 1
	)
	var world_polyline := PackedVector2Array()
	for index in open_point_count:
		var distance := compiled.total_length * float(index) / float(open_point_count)
		world_polyline.append(FeatureGeometry.sample_at_distance(compiled, distance)["position"])
	world_polyline.append(world_polyline[0])
	var bounds := _bounds(world_polyline)
	var transform := _fit_transform(bounds, target_size, padding)
	var polyline := PackedVector2Array()
	for point in world_polyline:
		polyline.append(_map_point(point, transform))
	var markers := _build_markers(compiled, pit_plan, bridge_plan, transform)
	output["world_bounds"] = bounds
	output["world_polyline"] = world_polyline
	output["polyline"] = polyline
	output["markers"] = markers
	output["transform"] = transform
	output["closed"] = polyline.size() >= 2 and polyline[0] == polyline[-1]
	return FeatureGeometry.finalize(output)


static func _bounds(points: PackedVector2Array) -> Dictionary:
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return {
		"minimum": FeatureGeometry.quantize_vector(minimum),
		"maximum": FeatureGeometry.quantize_vector(maximum),
		"size": FeatureGeometry.quantize_vector(maximum - minimum),
	}


static func _fit_transform(bounds: Dictionary, target_size: Vector2, padding: float) -> Dictionary:
	var minimum: Vector2 = bounds["minimum"]
	var extent: Vector2 = bounds["size"]
	extent.x = maxf(extent.x, 0.001)
	extent.y = maxf(extent.y, 0.001)
	var available := target_size - Vector2.ONE * padding * 2.0
	var scale := minf(available.x / extent.x, available.y / extent.y)
	var drawn_size := extent * scale
	var offset := (target_size - drawn_size) * 0.5 - minimum * scale
	return {
		"scale": FeatureGeometry.quantize_scalar(scale, 0.000001),
		"offset": FeatureGeometry.quantize_vector(offset),
		"target_size": FeatureGeometry.quantize_vector(target_size),
	}


static func _map_point(point: Vector2, transform: Dictionary) -> Vector2:
	var mapped := FeatureGeometry.quantize_vector(
		point * float(transform["scale"]) + Vector2(transform["offset"])
	)
	var target_size: Vector2 = transform.get("target_size", Vector2(4096.0, 4096.0))
	return Vector2(
		clampf(mapped.x, 0.0, target_size.x),
		clampf(mapped.y, 0.0, target_size.y)
	)


static func _build_markers(
		compiled: CompiledTrack,
		pit_plan: Dictionary,
		bridge_plan: Dictionary,
		transform: Dictionary
	) -> Array[Dictionary]:
	var markers: Array[Dictionary] = []
	_add_marker(markers, "start_finish", "start", 0.0, compiled.centerline[0], transform)
	for checkpoint_index in range(1, 4):
		var distance := compiled.total_length * float(checkpoint_index) / 4.0
		var sample := FeatureGeometry.sample_at_distance(compiled, distance)
		_add_marker(
			markers, "checkpoint", "checkpoint-%d" % checkpoint_index,
			distance, sample["position"], transform
		)
	if bool(pit_plan.get("enabled", false)):
		for marker_key in ["entry", "exit"]:
			var pit_marker: Variant = pit_plan.get(marker_key, {})
			if pit_marker is Dictionary and pit_marker.get("position") is Vector2:
				_add_marker(
					markers,
					str(pit_marker.get("kind", "pit_" + marker_key)),
					"pit-" + marker_key,
					float(pit_marker.get("lap_distance", 0.0)),
					pit_marker["position"],
					transform
				)
	var crossings: Variant = bridge_plan.get("crossings", [])
	if crossings is Array:
		for crossing_variant in crossings:
			if markers.size() >= MAX_MARKERS or not crossing_variant is Dictionary:
				break
			var crossing: Dictionary = crossing_variant
			if not crossing.get("position") is Vector2:
				continue
			var branch_a: Variant = crossing.get("branch_a", {})
			var lap_distance := 0.0
			if branch_a is Dictionary:
				lap_distance = float(branch_a.get("lap_distance", 0.0))
			_add_marker(
				markers,
				"bridge",
				str(crossing.get("crossing_id", "bridge")),
				lap_distance,
				crossing["position"],
				transform
			)
	return markers


static func _add_marker(
		markers: Array[Dictionary],
		kind: String,
		marker_id: String,
		lap_distance: float,
		world_position: Vector2,
		transform: Dictionary
	) -> void:
	if markers.size() >= MAX_MARKERS:
		return
	markers.append({
		"kind": kind,
		"marker_id": marker_id,
		"lap_distance": FeatureGeometry.quantize_scalar(lap_distance),
		"world_position": FeatureGeometry.quantize_vector(world_position),
		"position": _map_point(world_position, transform),
	})
