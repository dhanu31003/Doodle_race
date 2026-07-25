class_name PitLanePlanBuilder
extends RefCounted
## Selects one deterministic straight and derives a complete side-aware pit lane.

const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")
const GameLimitsType := preload("res://game/config/game_limits.gd")

const MAX_LANE_SAMPLES: int = 128
const MAX_PIT_BOXES: int = 12
const MIN_PIT_BOXES: int = 1


static func plan(definition: TrackDefinition, compiled: CompiledTrack) -> Dictionary:
	var errors := FeatureGeometry.validate_compiled(compiled)
	var output := {
		"feature_version": 1,
		"valid": errors.is_empty(),
		"errors": errors,
		"enabled": false,
		"side": "none",
		"selected_straight": {},
		"entry": {},
		"exit": {},
		"lane_polyline": PackedVector2Array(),
		"lane_samples": [],
		"boxes": [],
		"exclusion_zones": [],
	}
	if definition == null:
		output["errors"].append(FeatureGeometry.error(
			&"pit.definition_missing", "Track definition is missing.", "definition"
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)
	if not errors.is_empty():
		return FeatureGeometry.finalize(output)
	var side := str(definition.pit_side)
	output["side"] = side
	if side == "none":
		return FeatureGeometry.finalize(output)
	if side != "left" and side != "right":
		output["errors"].append(FeatureGeometry.error(
			&"pit.side_invalid", "Pit side must be none, left, or right.", "pit_side"
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)
	if str(compiled.pit_side) != side:
		output["errors"].append(FeatureGeometry.error(
			&"pit.definition_compiled_mismatch",
			"Definition and compiled track disagree about pit side.",
			"pit_side",
			{"definition": side, "compiled": str(compiled.pit_side)}
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)

	var best_straight := _best_usable_straight(compiled, definition)
	if best_straight.is_empty() or float(best_straight["length"]) < GameLimitsType.PIT_STRAIGHT_LENGTH:
		output["errors"].append(FeatureGeometry.error(
			&"pit.straight_missing",
			"An enabled pit lane requires a sufficiently long compiled straight.",
			"straight_sections",
			{"required_length": GameLimitsType.PIT_STRAIGHT_LENGTH}
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)

	var straight_length := float(best_straight["length"])
	var lane_length := minf(straight_length * 0.88, 480.0)
	var straight_padding := (straight_length - lane_length) * 0.5
	var lane_start := fposmod(float(best_straight["start_distance"]) + straight_padding, compiled.total_length)
	var transition_length := minf(
		maxf(30.0, compiled.track_width * 0.65),
		lane_length * 0.22
	)
	var core_length := lane_length - transition_length * 2.0
	if core_length < maxf(48.0, compiled.track_width):
		output["errors"].append(FeatureGeometry.error(
			&"pit.core_too_short", "Selected straight cannot fit pit transitions and boxes.", "straight_sections"
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)

	var side_sign := 1.0 if side == "left" else -1.0
	var lane_offset := compiled.track_width * 0.84
	var sample_count := clampi(
		ceili(lane_length / maxf(compiled.sample_spacing, 5.0)) + 1,
		8,
		MAX_LANE_SAMPLES
	)
	var lane_samples: Array[Dictionary] = []
	var lane_polyline := PackedVector2Array()
	for index in sample_count:
		var along := lane_length * float(index) / float(sample_count - 1)
		var road_sample := FeatureGeometry.sample_at_distance(compiled, lane_start + along)
		var offset_factor := _offset_factor(along, lane_length, transition_length)
		var position: Vector2 = road_sample["position"] \
				+ road_sample["normal"] * side_sign * lane_offset * offset_factor
		position = FeatureGeometry.quantize_vector(position)
		lane_polyline.append(position)
		lane_samples.append({
			"distance": road_sample["distance"],
			"road_segment_index": road_sample["segment_index"],
			"position": position,
			"tangent": road_sample["tangent"],
			"normal": road_sample["normal"],
			"offset_factor": FeatureGeometry.quantize_scalar(offset_factor, 0.000001),
		})

	var obstruction := _find_obstruction(lane_samples, compiled)
	if not obstruction.is_empty():
		output["errors"].append(FeatureGeometry.error(
			&"pit.other_road_too_close",
			"Derived pit lane would conflict with another part of the track.",
			"straight_sections",
			obstruction
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)

	var entry_distance := lane_start
	var boxes_start := fposmod(lane_start + transition_length, compiled.total_length)
	var boxes_finish := fposmod(lane_start + transition_length + core_length, compiled.total_length)
	var exit_distance := fposmod(lane_start + lane_length, compiled.total_length)
	var box_spacing := maxf(24.0, compiled.track_width * 0.52)
	var box_count := clampi(floori(core_length / box_spacing), MIN_PIT_BOXES, MAX_PIT_BOXES)
	var boxes: Array[Dictionary] = []
	for box_index in box_count:
		var amount := (float(box_index) + 0.5) / float(box_count)
		var box_distance := fposmod(boxes_start + core_length * amount, compiled.total_length)
		var road_sample := FeatureGeometry.sample_at_distance(compiled, box_distance)
		var box_position: Vector2 = road_sample["position"] \
				+ road_sample["normal"] * side_sign * lane_offset
		boxes.append({
			"box_index": box_index,
			"lap_distance": FeatureGeometry.quantize_scalar(box_distance),
			"position": FeatureGeometry.quantize_vector(box_position),
			"rotation": FeatureGeometry.quantize_scalar(road_sample["tangent"].angle(), 0.000001),
			"length": FeatureGeometry.quantize_scalar(minf(box_spacing * 0.82, 44.0)),
			"width": FeatureGeometry.quantize_scalar(compiled.track_width * 0.36),
		})

	output["enabled"] = true
	output["selected_straight"] = {
		"start_index": int(best_straight.get("start_index", 0)),
		"end_index": int(best_straight.get("end_index", 0)),
		"start_distance": FeatureGeometry.quantize_scalar(float(best_straight["start_distance"])),
		"length": FeatureGeometry.quantize_scalar(straight_length),
	}
	output["entry"] = _marker("pit_entry", entry_distance, lane_samples[0])
	output["exit"] = _marker("pit_exit", exit_distance, lane_samples[-1])
	output["box_range"] = {
		"start_distance": FeatureGeometry.quantize_scalar(boxes_start),
		"finish_distance": FeatureGeometry.quantize_scalar(boxes_finish),
		"length": FeatureGeometry.quantize_scalar(core_length),
	}
	output["lane_offset"] = FeatureGeometry.quantize_scalar(lane_offset)
	output["lane_width"] = FeatureGeometry.quantize_scalar(compiled.track_width * 0.48)
	output["lane_polyline"] = lane_polyline
	output["lane_samples"] = lane_samples
	output["boxes"] = boxes
	output["collision"] = {
		"road_layer": 1,
		"vehicle_mask": 1,
		"entry_merge_distance": FeatureGeometry.quantize_scalar(transition_length),
		"exit_merge_distance": FeatureGeometry.quantize_scalar(transition_length),
	}
	output["exclusion_zones"] = [{
		"kind": "pit_lane",
		"polyline": lane_polyline,
		"clearance": FeatureGeometry.quantize_scalar(compiled.track_width * 0.72),
	}]
	return FeatureGeometry.finalize(output)


static func _best_usable_straight(compiled: CompiledTrack, definition: TrackDefinition) -> Dictionary:
	var best: Dictionary = {}
	for section_variant in compiled.straight_sections:
		if not section_variant is Dictionary:
			continue
		var section: Dictionary = section_variant
		var start_distance := float(section.get("start_distance", -1.0))
		var length := float(section.get("length", -1.0))
		if not FeatureGeometry.is_finite_scalar(start_distance) \
				or not FeatureGeometry.is_finite_scalar(length) \
				or start_distance < 0.0 or start_distance >= compiled.total_length \
				or length <= 0.0 or length > compiled.total_length:
			continue
		if _straight_contains_bridge(
			start_distance, length, compiled.total_length,
			definition, compiled.track_width * 2.0
		):
			continue
		if best.is_empty() or length > float(best["length"]) \
				or (is_equal_approx(length, float(best["length"])) \
				and start_distance < float(best["start_distance"])):
			best = section.duplicate(true)
	return best


static func _straight_contains_bridge(
		start_distance: float,
		length: float,
		lap_length: float,
		definition: TrackDefinition,
		margin: float
	) -> bool:
	for crossing in definition.bridge_crossings:
		if crossing == null:
			continue
		for branch_distance in [crossing.distance_a, crossing.distance_b]:
			var distance_from_start := fposmod(float(branch_distance) - start_distance, lap_length)
			if distance_from_start <= length + margin \
					or distance_from_start >= lap_length - margin:
				return true
	return false


static func _offset_factor(along: float, lane_length: float, transition_length: float) -> float:
	if along < transition_length:
		return _smoothstep(along / transition_length)
	if along > lane_length - transition_length:
		return _smoothstep((lane_length - along) / transition_length)
	return 1.0


static func _smoothstep(value: float) -> float:
	var amount := clampf(value, 0.0, 1.0)
	return amount * amount * (3.0 - 2.0 * amount)


static func _find_obstruction(lane_samples: Array[Dictionary], compiled: CompiledTrack) -> Dictionary:
	var neighbor_count := ceili(compiled.track_width * 2.0 / maxf(compiled.sample_spacing, 1.0)) + 2
	var required_clearance := compiled.track_width * 0.72
	# Entry and exit intentionally merge into the source straight, so only test
	# the full-offset middle portion against non-local road segments.
	for sample in lane_samples:
		if float(sample["offset_factor"]) < 0.92:
			continue
		var measured := FeatureGeometry.point_to_track_distance_excluding_neighbors(
			sample["position"],
			compiled,
			int(sample["road_segment_index"]),
			neighbor_count
		)
		if measured < required_clearance:
			return {
				"position": sample["position"],
				"measured_clearance": FeatureGeometry.quantize_scalar(measured),
				"required_clearance": FeatureGeometry.quantize_scalar(required_clearance),
			}
	return {}


static func _marker(kind: String, distance: float, sample: Dictionary) -> Dictionary:
	return {
		"kind": kind,
		"lap_distance": FeatureGeometry.quantize_scalar(distance),
		"position": sample.get("position", Vector2.ZERO),
		"tangent": sample.get("tangent", Vector2.RIGHT),
	}
