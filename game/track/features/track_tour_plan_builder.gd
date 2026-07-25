class_name TrackTourPlanBuilder
extends RefCounted
## Derives a bounded top-down camera flyover and human-readable track summary.

const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")

const MIN_WAYPOINTS: int = 16
const MAX_WAYPOINTS: int = 64
const MAX_HIGHLIGHTS: int = 24


static func plan(
		compiled: CompiledTrack,
		pit_plan: Dictionary = {},
		bridge_plan: Dictionary = {}
	) -> Dictionary:
	var errors := FeatureGeometry.validate_compiled(compiled)
	var output := {
		"feature_version": 1,
		"valid": errors.is_empty(),
		"errors": errors,
		"camera_path": [],
		"highlights": [],
		"summary": {},
	}
	if not errors.is_empty():
		return FeatureGeometry.finalize(output)
	var waypoint_count := clampi(
		ceili(compiled.total_length / maxf(72.0, compiled.track_width)),
		MIN_WAYPOINTS,
		MAX_WAYPOINTS
	)
	var duration := FeatureGeometry.quantize_scalar(clampf(compiled.total_length / 92.0, 8.0, 32.0))
	var camera_path: Array[Dictionary] = []
	for index in waypoint_count:
		var progress := float(index) / float(waypoint_count)
		var distance := compiled.total_length * progress
		var sample := FeatureGeometry.sample_at_distance(compiled, distance)
		var curvature := absf(compiled.curvatures[int(sample["segment_index"])])
		var corner_emphasis := clampf(curvature * compiled.track_width * 2.0, 0.0, 1.0)
		var lead := lerpf(maxf(32.0, compiled.track_width * 0.65), 12.0, corner_emphasis)
		var look_at: Vector2 = sample["position"] + sample["tangent"] * lead
		camera_path.append({
			"waypoint_index": index,
			"lap_distance": sample["distance"],
			"time": FeatureGeometry.quantize_scalar(duration * progress),
			"progress": FeatureGeometry.quantize_scalar(progress, 0.000001),
			"camera_center": sample["position"],
			"look_at": FeatureGeometry.quantize_vector(look_at),
			"zoom": FeatureGeometry.quantize_scalar(lerpf(1.42, 1.18, corner_emphasis)),
			"easing": "smoothstep",
		})

	var highlights := _build_highlights(compiled, pit_plan, bridge_plan)
	var longest_straight := _longest_straight(compiled)
	var corner_count := _valid_corner_count(compiled)
	var bridge_count := 0
	var crossings: Variant = bridge_plan.get("crossings", [])
	if crossings is Array:
		bridge_count = mini(crossings.size(), 16)
	var pit_enabled := bool(pit_plan.get("enabled", false))
	var pit_side := str(pit_plan.get("side", "none"))
	var feature_phrase := "%d bridge%s · %s" % [
		bridge_count,
		"" if bridge_count == 1 else "s",
		("%s pit" % pit_side) if pit_enabled else "no pit lane",
	]
	output["camera_path"] = camera_path
	output["loop"] = true
	output["highlights"] = highlights
	output["summary"] = {
		"track_id": compiled.track_id,
		"theme": str(compiled.theme),
		"lap_length": FeatureGeometry.quantize_scalar(compiled.total_length),
		"track_width": FeatureGeometry.quantize_scalar(compiled.track_width),
		"corner_count": corner_count,
		"longest_straight": FeatureGeometry.quantize_scalar(longest_straight),
		"bridge_count": bridge_count,
		"pit_enabled": pit_enabled,
		"pit_side": pit_side,
		"tour_duration": duration,
		"waypoint_count": waypoint_count,
		"headline": "%d m lap · %d corner%s · %s" % [
			roundi(compiled.total_length),
			corner_count,
			"" if corner_count == 1 else "s",
			feature_phrase,
		],
	}
	return FeatureGeometry.finalize(output)


static func _build_highlights(
		compiled: CompiledTrack,
		pit_plan: Dictionary,
		bridge_plan: Dictionary
	) -> Array[Dictionary]:
	var highlights: Array[Dictionary] = []
	_add_highlight(highlights, compiled, "start_finish", "start", 0.0)
	for corner_index in compiled.corner_sections.size():
		if highlights.size() >= MAX_HIGHLIGHTS:
			break
		var section_variant: Variant = compiled.corner_sections[corner_index]
		if not section_variant is Dictionary:
			continue
		var distance := float(section_variant.get("start_distance", -1.0))
		var length := float(section_variant.get("length", -1.0))
		if not FeatureGeometry.is_finite_scalar(distance) \
				or not FeatureGeometry.is_finite_scalar(length) \
				or distance < 0.0 or distance >= compiled.total_length or length <= 0.0:
			continue
		_add_highlight(
			highlights,
			compiled,
			"corner",
			"corner-%d" % corner_index,
			fposmod(distance + length * 0.5, compiled.total_length)
		)
	if bool(pit_plan.get("enabled", false)):
		for marker_key in ["entry", "exit"]:
			var marker: Variant = pit_plan.get(marker_key, {})
			if marker is Dictionary:
				_add_highlight(
					highlights,
					compiled,
					str(marker.get("kind", "pit_" + marker_key)),
					"pit-" + marker_key,
					float(marker.get("lap_distance", 0.0))
				)
	var crossings: Variant = bridge_plan.get("crossings", [])
	if crossings is Array:
		for crossing_variant in crossings:
			if highlights.size() >= MAX_HIGHLIGHTS or not crossing_variant is Dictionary:
				break
			var crossing: Dictionary = crossing_variant
			var branch_a: Variant = crossing.get("branch_a", {})
			var distance := 0.0
			if branch_a is Dictionary:
				distance = float(branch_a.get("lap_distance", 0.0))
			_add_highlight(
				highlights,
				compiled,
				"bridge",
				str(crossing.get("crossing_id", "bridge")),
				distance
			)
	return highlights


static func _add_highlight(
		highlights: Array[Dictionary],
		compiled: CompiledTrack,
		kind: String,
		highlight_id: String,
		distance: float
	) -> void:
	if highlights.size() >= MAX_HIGHLIGHTS:
		return
	var sample := FeatureGeometry.sample_at_distance(compiled, distance)
	highlights.append({
		"kind": kind,
		"highlight_id": highlight_id,
		"lap_distance": sample["distance"],
		"position": sample["position"],
	})


static func _longest_straight(compiled: CompiledTrack) -> float:
	var longest := 0.0
	for section_variant in compiled.straight_sections:
		if not section_variant is Dictionary:
			continue
		var length := float(section_variant.get("length", 0.0))
		if FeatureGeometry.is_finite_scalar(length) and length > 0.0 \
				and length <= compiled.total_length:
			longest = maxf(longest, length)
	return longest


static func _valid_corner_count(compiled: CompiledTrack) -> int:
	var count := 0
	for section_variant in compiled.corner_sections:
		if not section_variant is Dictionary:
			continue
		var distance := float(section_variant.get("start_distance", -1.0))
		var length := float(section_variant.get("length", -1.0))
		if FeatureGeometry.is_finite_scalar(distance) \
				and FeatureGeometry.is_finite_scalar(length) \
				and distance >= 0.0 and distance < compiled.total_length and length > 0.0:
			count += 1
	return mini(count, MAX_HIGHLIGHTS - 1)
