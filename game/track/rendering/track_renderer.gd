class_name TrackRenderer
extends Control

const SAMPLES_PER_SEGMENT := 12
const ROAD_WIDTH := 58.0
const WorldPlannerType := preload("res://game/track/features/track_world_feature_planner.gd")
const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")
const TREE_TEXTURE: Texture2D = preload("res://assets/final/scenery/tree_canopy.svg")
const GRANDSTAND_TEXTURE: Texture2D = preload("res://assets/final/scenery/grandstand.svg")
const PIT_BUILDING_TEXTURE: Texture2D = preload("res://assets/final/scenery/pit_building.svg")
const GANTRY_TEXTURE: Texture2D = preload("res://assets/final/scenery/track_gantry.svg")
const BARRIER_TEXTURE: Texture2D = preload("res://assets/final/scenery/modular_barrier.svg")

# Track previews and tours share the active race's bright forest treatment.
# UI panels retain the dark design system; only the physical world is sunlit.
const WORLD_GRASS := Color("478153")
const WORLD_GRASS_LIGHT := Color("5d985e")
const WORLD_GRASS_DARK := Color("356b47")
const WORLD_GRAVEL := Color("a59b78")
const WORLD_ASPHALT := Color("2b3540")

var normalized_points := PackedVector2Array()
var track_definition: TrackDefinition
var compiled_track: CompiledTrack
var world_plan: Dictionary = {}
var curve := PackedVector2Array()
var curve_distances := PackedFloat64Array()
var track_length := 1.0
var display_track_length := 1.0
var road_width := ROAD_WIDTH
var _world_scale := 1.0
var _world_offset := Vector2.ZERO
var _tour_camera_enabled := false
var _tour_progress := 0.0
var _view_center := Vector2.ZERO
var _view_zoom := 1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_rebuild)
	if normalized_points.is_empty():
		normalized_points = default_track()
	_rebuild()

func set_track_points(points: PackedVector2Array) -> void:
	track_definition = null
	compiled_track = null
	world_plan.clear()
	_reset_view()
	normalized_points = points.duplicate()
	if normalized_points.size() > 1 and normalized_points[0].distance_to(normalized_points[-1]) < 0.0001:
		normalized_points.remove_at(normalized_points.size() - 1)
	_rebuild()

func set_compiled_track(value: CompiledTrack) -> void:
	track_definition = null
	compiled_track = value
	world_plan.clear()
	_reset_view()
	_rebuild()

func set_track_world(definition: TrackDefinition, value: CompiledTrack) -> bool:
	## Backward-compatible presentation entry point. Existing callers may keep
	## using set_compiled_track; Studio/select/tour callers get the complete
	## deterministic post-compile world through this method.
	track_definition = definition
	compiled_track = value
	world_plan = WorldPlannerType.plan(definition, value)
	_reset_view()
	_rebuild()
	return bool(world_plan.get("valid", false))

func get_world_plan() -> Dictionary:
	return world_plan.duplicate(true)

func get_minimap_plan() -> Dictionary:
	var value: Variant = world_plan.get("minimap", {})
	return value.duplicate(true) if value is Dictionary else {}

func get_tour_plan() -> Dictionary:
	var value: Variant = world_plan.get("track_tour", {})
	return value.duplicate(true) if value is Dictionary else {}

func set_tour_progress(progress: float) -> bool:
	var tour_value: Variant = world_plan.get("track_tour", {})
	if not tour_value is Dictionary:
		return false
	var tour: Dictionary = tour_value
	var path: Variant = tour.get("camera_path", [])
	if not bool(tour.get("valid", false)) or not path is Array or path.size() < 2:
		return false
	_tour_progress = fposmod(progress, 1.0)
	_tour_camera_enabled = true
	_update_tour_camera(path)
	queue_redraw()
	return true

func clear_tour_camera() -> void:
	_reset_view()
	queue_redraw()

func world_to_display(world_position: Vector2, apply_tour_view: bool = true) -> Vector2:
	var display_position := _world_to_display_raw(world_position)
	return _view_point(display_position) if apply_tour_view else display_position

func default_track() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.38, 0.14), Vector2(0.55, 0.14), Vector2(0.71, 0.20),
		Vector2(0.82, 0.34), Vector2(0.80, 0.48), Vector2(0.70, 0.58),
		Vector2(0.82, 0.72), Vector2(0.64, 0.84), Vector2(0.45, 0.78),
		Vector2(0.28, 0.84), Vector2(0.15, 0.70), Vector2(0.20, 0.55),
		Vector2(0.14, 0.41), Vector2(0.22, 0.27)
	])

func _rebuild() -> void:
	curve.clear()
	curve_distances.clear()
	_world_scale = 1.0
	_world_offset = Vector2.ZERO
	if size.x < 100.0 or size.y < 100.0:
		queue_redraw()
		return
	var horizontal_padding := clampf(size.x * 0.065, 30.0, 68.0)
	var vertical_padding := clampf(size.y * 0.075, 26.0, 72.0)
	var padded := Rect2(
		Vector2(horizontal_padding, vertical_padding),
		size - Vector2(horizontal_padding * 2.0, vertical_padding * 2.0)
	)
	if compiled_track != null and compiled_track.centerline.size() >= 4:
		_build_compiled_curve(padded)
		_rebuild_distance_table()
		_refresh_view_after_rebuild()
		queue_redraw()
		return
	var source := normalized_points
	if source.size() < 4:
		source = default_track()
	var base := PackedVector2Array()
	for point in source:
		base.append(padded.position + point * padded.size)
	var count := base.size()
	for i in range(count):
		var p0 := base[(i - 1 + count) % count]
		var p1 := base[i]
		var p2 := base[(i + 1) % count]
		var p3 := base[(i + 2) % count]
		for step in range(SAMPLES_PER_SEGMENT):
			var t := float(step) / float(SAMPLES_PER_SEGMENT)
			curve.append(_catmull_rom(p0, p1, p2, p3, t))
	if not curve.is_empty():
		curve.append(curve[0])
	road_width = ROAD_WIDTH
	_rebuild_distance_table()
	track_length = display_track_length
	_refresh_view_after_rebuild()
	queue_redraw()

func _build_compiled_curve(padded: Rect2) -> void:
	var authored_size := compiled_track.canvas_size
	if authored_size.x <= 0.0 or authored_size.y <= 0.0:
		return
	var scale_factor := minf(padded.size.x / authored_size.x, padded.size.y / authored_size.y)
	var offset := padded.get_center() - authored_size * scale_factor * 0.5
	_world_scale = scale_factor
	_world_offset = offset
	for point in compiled_track.centerline:
		curve.append(offset + point * scale_factor)
	if not curve.is_empty():
		curve.append(curve[0])
	road_width = maxf(compiled_track.track_width * scale_factor, 18.0)
	track_length = maxf(compiled_track.total_length, 1.0)

func _rebuild_distance_table() -> void:
	curve_distances.resize(curve.size())
	display_track_length = 0.0
	if curve.is_empty():
		return
	curve_distances[0] = 0.0
	for index in range(1, curve.size()):
		display_track_length += curve[index - 1].distance_to(curve[index])
		curve_distances[index] = display_track_length
	display_track_length = maxf(display_track_length, 1.0)

func _catmull_rom(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

func get_track_point(progress: float, lane_offset: float = 0.0) -> Vector2:
	if curve.size() < 2:
		return size * 0.5
	var distance := fposmod(progress, 1.0) * display_track_length
	var index := _segment_for_distance(distance)
	var segment_length := maxf(curve_distances[index + 1] - curve_distances[index], 0.0001)
	var fraction := clampf((distance - curve_distances[index]) / segment_length, 0.0, 1.0)
	var center := curve[index].lerp(curve[index + 1], fraction)
	var tangent := (curve[index + 1] - curve[index]).normalized()
	return _view_point(center + Vector2(-tangent.y, tangent.x) * lane_offset)

func get_track_tangent(progress: float) -> Vector2:
	if curve.size() < 2:
		return Vector2.RIGHT
	var distance := fposmod(progress, 1.0) * display_track_length
	var index := _segment_for_distance(distance)
	return (curve[index + 1] - curve[index]).normalized()

func _segment_for_distance(distance: float) -> int:
	var low := 0
	var high := curve_distances.size() - 2
	while low <= high:
		var middle := int((low + high) / 2)
		if curve_distances[middle + 1] <= distance:
			low = middle + 1
		elif curve_distances[middle] > distance:
			high = middle - 1
		else:
			return middle
	return clampi(low, 0, curve.size() - 2)

func get_track_length() -> float:
	return track_length

func _world_to_display_raw(world_position: Vector2) -> Vector2:
	return _world_offset + world_position * _world_scale

func _view_point(display_position: Vector2) -> Vector2:
	return size * 0.5 + (display_position - _view_center) * _view_zoom

func _view_transform() -> Transform2D:
	return Transform2D(
		Vector2(_view_zoom, 0.0),
		Vector2(0.0, _view_zoom),
		size * 0.5 - _view_center * _view_zoom
	)

func _reset_view() -> void:
	_tour_camera_enabled = false
	_tour_progress = 0.0
	_view_center = size * 0.5
	_view_zoom = 1.0

func _refresh_view_after_rebuild() -> void:
	if not _tour_camera_enabled:
		_view_center = size * 0.5
		_view_zoom = 1.0
		return
	var tour_value: Variant = world_plan.get("track_tour", {})
	if not tour_value is Dictionary:
		_reset_view()
		return
	var tour: Dictionary = tour_value
	var path: Variant = tour.get("camera_path", [])
	if path is Array and path.size() >= 2:
		_update_tour_camera(path)
	else:
		_reset_view()

func _update_tour_camera(path: Array) -> void:
	var scaled := _tour_progress * float(path.size())
	var first_index := posmod(floori(scaled), path.size())
	var second_index := (first_index + 1) % path.size()
	var amount := scaled - floorf(scaled)
	var first: Dictionary = path[first_index]
	var second: Dictionary = path[second_index]
	var first_center: Vector2 = first.get("camera_center", Vector2.ZERO)
	var second_center: Vector2 = second.get("camera_center", first_center)
	_view_center = _world_to_display_raw(first_center.lerp(second_center, amount))
	_view_zoom = clampf(
		lerpf(float(first.get("zoom", 1.0)), float(second.get("zoom", 1.0)), amount),
		1.0,
		1.65
	)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), WORLD_GRASS)
	_draw_ground_pattern()
	if curve.size() < 2:
		return
	draw_set_transform_matrix(_view_transform())
	_draw_scenery()
	_draw_pit_environment()
	_draw_pit_lane()
	_draw_road()
	_draw_checkpoints()
	_draw_bridges()
	_draw_start_grid()
	draw_set_transform_matrix(Transform2D.IDENTITY)

func _draw_ground_pattern() -> void:
	var stripe := Color(WORLD_GRASS_LIGHT, 0.20)
	for x in range(-int(size.y), int(size.x), 54):
		draw_line(Vector2(float(x), 0.0), Vector2(float(x) + size.y, size.y), stripe, 26.0)
	# Fine cross-cut mowing texture breaks up broad empty areas while remaining
	# quiet enough that the circuit is still the strongest shape at phone scale.
	for y in range(18, int(size.y), 72):
		draw_line(
			Vector2(0.0, float(y)), Vector2(size.x, float(y) + 24.0),
			Color(WORLD_GRASS_DARK, 0.10), 12.0, true
		)

func _draw_scenery() -> void:
	var scenery := _subplan("scenery")
	if bool(scenery.get("valid", false)):
		var placements: Variant = scenery.get("placements", [])
		if placements is Array:
			for placement_variant in placements:
				if placement_variant is Dictionary:
					_draw_scenery_placement(placement_variant)
		return
	_draw_legacy_scenery()

func _draw_scenery_placement(placement: Dictionary) -> void:
	var world_position: Variant = placement.get("position")
	if not world_position is Vector2:
		return
	var position := _world_to_display_raw(world_position)
	var asset_key := str(placement.get("asset_key", ""))
	var scale_factor := clampf(float(placement.get("scale", 1.0)), 0.6, 1.5)
	var rotation := float(placement.get("rotation", 0.0))
	var base_size := clampf(road_width * 1.75, 36.0, 66.0) * scale_factor
	if _contains_any(asset_key, ["tree", "pine", "birch", "shrub", "fern", "cactus"]):
		var tint := Color(0.88, 0.98, 0.88) if asset_key.begins_with("night/") else Color.WHITE
		_draw_asset(TREE_TEXTURE, position, Vector2(base_size, base_size), rotation, tint)
	elif _contains_any(asset_key, ["marshal", "post"]):
		_draw_asset(
			GRANDSTAND_TEXTURE,
			position,
			Vector2(base_size * 0.92, base_size * 0.46),
			rotation,
			Color(0.92, 0.98, 1.0)
		)
	elif _contains_any(asset_key, ["flag", "banner"]):
		_draw_flag_cluster(position, rotation, base_size)
	elif _contains_any(asset_key, ["light", "neon", "holographic"]):
		_draw_track_light(position, base_size, asset_key)
	elif _contains_any(asset_key, ["rock", "stone"]):
		_draw_rock(position, rotation, base_size)
	else:
		_draw_asset(BARRIER_TEXTURE, position, Vector2(base_size * 1.5, base_size * 0.38), rotation)

func _draw_legacy_scenery() -> void:
	for i in range(0, curve.size() - 1, 7):
		var tangent := (curve[i + 1] - curve[i]).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		var side := -1.0 if (i / 7) % 2 == 0 else 1.0
		var distance := road_width * 0.5 + 45.0 + float((i * 17) % 52)
		var position := curve[i] + normal * side * distance
		var radius := 8.0 + float((i * 11) % 8)
		draw_circle(position + Vector2(3.0, 5.0), radius + 2.0, Color(0.0, 0.0, 0.0, 0.22))
		draw_circle(position, radius, Color("164f3f"))
		draw_circle(position + Vector2(-3.0, -3.0), radius * 0.62, Color("2e7a55"))
	if curve.size() > 25:
		var grandstand_anchor := get_track_point(0.06, -112.0)
		draw_rect(Rect2(grandstand_anchor - Vector2(46.0, 18.0), Vector2(92.0, 36.0)), Color(0.04, 0.08, 0.14, 0.78), true)
		for seat in range(11):
			draw_circle(grandstand_anchor + Vector2(-38.0 + seat * 7.5, -3.0 + float(seat % 2) * 8.0), 2.4, [DesignSystem.CYAN, DesignSystem.CORAL, DesignSystem.GOLD][seat % 3])

func _draw_pit_environment() -> void:
	var pit := _subplan("pit_lane")
	if not bool(pit.get("valid", false)) or not bool(pit.get("enabled", false)) \
			or compiled_track == null:
		return
	var samples: Variant = pit.get("lane_samples", [])
	if not samples is Array or samples.is_empty():
		return
	var middle: Variant = samples[int(samples.size()) / 2]
	if not middle is Dictionary or not middle.get("position") is Vector2:
		return
	var normal: Vector2 = middle.get("normal", Vector2.UP)
	var tangent: Vector2 = middle.get("tangent", Vector2.RIGHT)
	var side_sign := 1.0 if str(pit.get("side", "none")) == "left" else -1.0
	var building_world: Vector2 = middle["position"] \
			+ normal * side_sign * compiled_track.track_width * 1.22
	var building_position := _world_to_display_raw(building_world)
	var building_width := clampf(road_width * 5.2, 96.0, 178.0)
	_draw_asset(
		PIT_BUILDING_TEXTURE,
		building_position,
		Vector2(building_width, building_width * 0.5),
		tangent.angle()
	)
	var barrier_offset := Vector2(-tangent.y, tangent.x) * -side_sign * building_width * 0.28
	for direction in [-1.0, 1.0]:
		_draw_asset(
			BARRIER_TEXTURE,
			building_position + tangent * direction * building_width * 0.42 + barrier_offset,
			Vector2(building_width * 0.42, building_width * 0.105),
			tangent.angle()
		)

func _draw_pit_lane() -> void:
	var pit := _subplan("pit_lane")
	if not bool(pit.get("valid", false)) or not bool(pit.get("enabled", false)):
		return
	var lane := _display_world_polyline(pit.get("lane_polyline", PackedVector2Array()))
	if lane.size() < 2:
		return
	var planned_width := float(pit.get("lane_width", 0.0)) * _world_scale
	var lane_width := clampf(planned_width, 9.0, maxf(10.0, road_width * 0.68))
	draw_polyline(lane, Color("315b3b"), lane_width + 16.0, true)
	draw_polyline(lane, WORLD_GRAVEL, lane_width + 9.0, true)
	draw_polyline(lane, WORLD_ASPHALT, lane_width, true)
	var left_edge := _offset_polyline(lane, lane_width * 0.52)
	var right_edge := _offset_polyline(lane, -lane_width * 0.52)
	draw_polyline(left_edge, Color(0.95, 0.98, 1.0, 0.72), 2.0, true)
	draw_polyline(right_edge, Color(0.95, 0.98, 1.0, 0.72), 2.0, true)
	var boxes: Variant = pit.get("boxes", [])
	if boxes is Array:
		for box_variant in boxes:
			if box_variant is Dictionary:
				_draw_pit_box(box_variant)

func _draw_road() -> void:
	# Soil, gravel and kerb layers follow the same centerline as the asphalt so
	# the circuit reads as a constructed surface embedded in terrain.
	draw_polyline(curve, Color("315b3b"), road_width + 30.0, true)
	draw_polyline(curve, WORLD_GRAVEL, road_width + 20.0, true)
	draw_polyline(curve, Color("e3e1d7"), road_width + 8.0, true)
	draw_polyline(curve, WORLD_ASPHALT, road_width, true)
	for i in range(curve.size() - 1):
		if i % 4 >= 2:
			continue
		var tangent := (curve[i + 1] - curve[i]).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		var color := DesignSystem.CORAL if (i / 4) % 2 == 0 else DesignSystem.WHITE
		draw_line(curve[i] + normal * (road_width * 0.5 + 3.0), curve[i + 1] + normal * (road_width * 0.5 + 3.0), color, 7.0, true)
		draw_line(curve[i] - normal * (road_width * 0.5 + 3.0), curve[i + 1] - normal * (road_width * 0.5 + 3.0), color, 7.0, true)
	for i in range(0, curve.size() - 2, 6):
		draw_line(curve[i], curve[mini(i + 2, curve.size() - 1)], Color(0.92, 0.96, 1.0, 0.20), 1.5, true)

func _draw_checkpoints() -> void:
	if compiled_track == null:
		return
	var minimap := _subplan("minimap")
	var markers: Variant = minimap.get("markers", [])
	if not markers is Array:
		return
	for marker_variant in markers:
		if not marker_variant is Dictionary or str(marker_variant.get("kind", "")) != "checkpoint":
			continue
		var distance := float(marker_variant.get("lap_distance", 0.0))
		var sample := FeatureGeometry.sample_at_distance(compiled_track, distance)
		var position := _world_to_display_raw(sample.get("position", Vector2.ZERO))
		var tangent: Vector2 = sample.get("tangent", Vector2.RIGHT)
		var normal := Vector2(-tangent.y, tangent.x)
		draw_line(
			position - normal * road_width * 0.46,
			position + normal * road_width * 0.46,
			Color(DesignSystem.CYAN, 0.42),
			2.0,
			true
		)
		draw_circle(position + normal * road_width * 0.68, 4.5, Color(DesignSystem.CYAN, 0.72))

func _draw_bridges() -> void:
	if compiled_track == null:
		return
	var bridges := _subplan("bridges")
	if not bool(bridges.get("valid", false)):
		return
	var crossings: Variant = bridges.get("crossings", [])
	if not crossings is Array:
		return
	# Every bridge is drawn in the same global phase order so separate bridge
	# decks cannot accidentally end up below another crossing's shadow.
	for crossing_variant in crossings:
		if crossing_variant is Dictionary:
			_draw_bridge_underpass(crossing_variant)
	for crossing_variant in crossings:
		if crossing_variant is Dictionary:
			_draw_bridge_shadow(crossing_variant)
	for crossing_variant in crossings:
		if crossing_variant is Dictionary:
			_draw_bridge_ramps(crossing_variant)
	for crossing_variant in crossings:
		if crossing_variant is Dictionary:
			_draw_bridge_deck(crossing_variant)

func _draw_start_grid() -> void:
	if curve.size() < 4:
		return
	var start: Vector2 = curve[0]
	var tangent: Vector2 = (curve[2] - curve[0]).normalized()
	var normal := Vector2(-tangent.y, tangent.x)
	draw_line(start - normal * road_width * 0.5, start + normal * road_width * 0.5, DesignSystem.WHITE, 5.0, true)
	for row in range(6):
		for side_value in [-1.0, 1.0]:
			var side := float(side_value)
			# The compiler guarantees its clear start straight forward from sample
			# zero; keeping the visual grid inside that proven zone avoids boxes
			# spilling onto grass when the seam begins immediately after a turn.
			var center: Vector2 = start + tangent * (24.0 + row * 21.0) + normal * side * 13.0
			var corners := PackedVector2Array([
				center - tangent * 7.0 - normal * 5.0,
				center + tangent * 7.0 - normal * 5.0,
				center + tangent * 7.0 + normal * 5.0,
				center - tangent * 7.0 + normal * 5.0
			])
			draw_polyline(PackedVector2Array([corners[0], corners[1], corners[2], corners[3], corners[0]]), Color(1.0, 1.0, 1.0, 0.42), 1.5, true)
	var gantry_width := clampf(road_width * 2.15, 68.0, 124.0)
	_draw_asset(
		GANTRY_TEXTURE,
		start - tangent * 7.0,
		Vector2(gantry_width, gantry_width * 0.375),
		tangent.angle() + PI * 0.5
	)

func _draw_bridge_underpass(crossing: Dictionary) -> void:
	var under_id := str(crossing.get("underpass_branch", "a"))
	var branch: Variant = crossing.get("branch_" + under_id, {})
	if not branch is Dictionary:
		return
	var distance := float(branch.get("lap_distance", 0.0))
	var samples := FeatureGeometry.sample_window(
		compiled_track,
		distance,
		compiled_track.track_width * 1.1,
		maxf(compiled_track.sample_spacing, 4.0),
		48
	)
	var segment := PackedVector2Array()
	for sample in samples:
		segment.append(_world_to_display_raw(sample["position"]))
	if segment.size() < 2:
		return
	draw_polyline(segment, Color("64727d"), road_width + 12.0, true)
	draw_polyline(segment, Color("1d252e"), road_width, true)
	draw_polyline(segment, Color(0.88, 0.93, 0.98, 0.13), 1.5, true)

func _draw_bridge_shadow(crossing: Dictionary) -> void:
	var shadow: Variant = crossing.get("shadow", {})
	if not shadow is Dictionary:
		return
	var polyline := _display_world_polyline(shadow.get("polyline", PackedVector2Array()))
	if polyline.size() < 2:
		return
	var width := maxf(float(shadow.get("width", compiled_track.track_width)) * _world_scale, road_width)
	draw_polyline(polyline, Color(0.0, 0.0, 0.0, clampf(float(shadow.get("opacity", 0.32)), 0.12, 0.55)), width + 12.0, true)

func _draw_bridge_ramps(crossing: Dictionary) -> void:
	var ramps: Variant = crossing.get("ramps", [])
	if not ramps is Array:
		return
	for ramp_variant in ramps:
		if not ramp_variant is Dictionary:
			continue
		var profile: Variant = ramp_variant.get("profile", [])
		if not profile is Array:
			continue
		var polyline := PackedVector2Array()
		for profile_point in profile:
			if profile_point is Dictionary and profile_point.get("position") is Vector2:
				polyline.append(_world_to_display_raw(profile_point["position"]))
		if polyline.size() < 2:
			continue
		draw_polyline(polyline, Color("d4dce3"), road_width + 10.0, true)
		draw_polyline(polyline, DesignSystem.ROAD, road_width, true)
		var left_rail := _offset_polyline(polyline, road_width * 0.53)
		var right_rail := _offset_polyline(polyline, -road_width * 0.53)
		draw_polyline(left_rail, Color(0.88, 0.94, 0.98, 0.85), 2.5, true)
		draw_polyline(right_rail, Color(0.88, 0.94, 0.98, 0.85), 2.5, true)

func _draw_bridge_deck(crossing: Dictionary) -> void:
	var deck: Variant = crossing.get("deck", {})
	if not deck is Dictionary:
		return
	var polyline := _display_world_polyline(deck.get("polyline", PackedVector2Array()))
	if polyline.size() < 2:
		return
	var width := maxf(float(deck.get("width", compiled_track.track_width)) * _world_scale, road_width)
	draw_polyline(polyline, Color("eef4f7"), width + 12.0, true)
	draw_polyline(polyline, Color("596671"), width + 5.0, true)
	draw_polyline(polyline, DesignSystem.ROAD, width, true)
	draw_polyline(polyline, Color(0.94, 0.98, 1.0, 0.24), 1.8, true)
	var left_rail := _offset_polyline(polyline, width * 0.54)
	var right_rail := _offset_polyline(polyline, -width * 0.54)
	draw_polyline(left_rail, DesignSystem.WHITE, 3.0, true)
	draw_polyline(right_rail, DesignSystem.WHITE, 3.0, true)

func _draw_pit_box(box: Dictionary) -> void:
	var world_position: Variant = box.get("position")
	if not world_position is Vector2:
		return
	var position := _world_to_display_raw(world_position)
	var dimensions := Vector2(
		maxf(float(box.get("length", 24.0)) * _world_scale, 12.0),
		maxf(float(box.get("width", 10.0)) * _world_scale, 6.0)
	)
	var object_transform := Transform2D(float(box.get("rotation", 0.0)), position)
	draw_set_transform_matrix(_view_transform() * object_transform)
	draw_rect(Rect2(-dimensions * 0.5, dimensions), Color(0.95, 0.98, 1.0, 0.72), false, 1.5, true)
	draw_line(Vector2(-dimensions.x * 0.22, 0.0), Vector2(dimensions.x * 0.22, 0.0), Color(DesignSystem.MINT, 0.62), 1.5, true)
	draw_set_transform_matrix(_view_transform())

func _draw_asset(
		texture: Texture2D,
		position: Vector2,
		dimensions: Vector2,
		rotation: float = 0.0,
		tint: Color = Color.WHITE
	) -> void:
	if texture == null:
		return
	var object_transform := Transform2D(rotation, position)
	draw_set_transform_matrix(_view_transform() * object_transform)
	draw_texture_rect(texture, Rect2(-dimensions * 0.5, dimensions), false, tint)
	draw_set_transform_matrix(_view_transform())

func _draw_flag_cluster(position: Vector2, rotation: float, base_size: float) -> void:
	var tangent := Vector2.from_angle(rotation)
	var normal := Vector2(-tangent.y, tangent.x)
	for index in 3:
		var anchor := position + tangent * (float(index) - 1.0) * base_size * 0.22
		draw_line(anchor, anchor - normal * base_size * 0.52, Color("d8e3e9"), 2.0, true)
		var top := anchor - normal * base_size * 0.52
		var color: Color = [DesignSystem.CYAN, DesignSystem.CORAL, DesignSystem.GOLD][index]
		draw_colored_polygon(PackedVector2Array([
			top, top + tangent * base_size * 0.24,
			top + tangent * base_size * 0.18 + normal * base_size * 0.15,
			top + normal * base_size * 0.15,
		]), color)

func _draw_track_light(position: Vector2, base_size: float, asset_key: String) -> void:
	var glow := DesignSystem.CYAN if _contains_any(asset_key, ["neon", "holographic"]) else DesignSystem.GOLD
	draw_circle(position + Vector2(3.0, 5.0), base_size * 0.17, Color(0.0, 0.0, 0.0, 0.25))
	draw_circle(position, base_size * 0.22, Color(glow, 0.09))
	draw_circle(position, base_size * 0.10, Color(glow, 0.26))
	draw_circle(position, base_size * 0.045, glow)

func _draw_rock(position: Vector2, rotation: float, base_size: float) -> void:
	var tangent := Vector2.from_angle(rotation)
	draw_circle(position + Vector2(3.0, 5.0), base_size * 0.28, Color(0.0, 0.0, 0.0, 0.25))
	draw_circle(position, base_size * 0.26, Color("63727c"))
	draw_circle(position - tangent * base_size * 0.07, base_size * 0.16, Color("8a99a1"))

func _subplan(key: String) -> Dictionary:
	var value: Variant = world_plan.get(key, {})
	return value if value is Dictionary else {}

func _display_world_polyline(value: Variant) -> PackedVector2Array:
	var output := PackedVector2Array()
	if value is PackedVector2Array or value is Array:
		for point in value:
			if point is Vector2:
				output.append(_world_to_display_raw(point))
	return output

func _offset_polyline(polyline: PackedVector2Array, distance: float) -> PackedVector2Array:
	var output := PackedVector2Array()
	if polyline.size() < 2:
		return output
	output.resize(polyline.size())
	for index in polyline.size():
		var previous := polyline[maxi(0, index - 1)]
		var following := polyline[mini(polyline.size() - 1, index + 1)]
		var tangent := (following - previous).normalized()
		output[index] = polyline[index] + Vector2(-tangent.y, tangent.x) * distance
	return output

func _contains_any(value: String, needles: Array[String]) -> bool:
	for needle in needles:
		if value.contains(needle):
			return true
	return false
