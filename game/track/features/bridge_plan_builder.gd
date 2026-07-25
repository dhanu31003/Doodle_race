class_name BridgePlanBuilder
extends RefCounted
## Produces renderer/physics metadata for authored self-crossing overpasses.
## The output has no engine nodes or resources and may be safely fingerprinted.

const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")

const MAX_BRIDGES: int = 16
const GROUND_COLLISION_LAYER: int = 1
const ELEVATED_COLLISION_LAYER: int = 2
const BRIDGE_HEIGHT_UNITS: int = 6000


static func plan(definition: TrackDefinition, compiled: CompiledTrack) -> Dictionary:
	var errors := FeatureGeometry.validate_compiled(compiled)
	var output := {
		"feature_version": 1,
		"valid": errors.is_empty(),
		"errors": errors,
		"crossings": [],
		"exclusion_zones": [],
		"collision_layers": {
			"ground_road": GROUND_COLLISION_LAYER,
			"elevated_road": ELEVATED_COLLISION_LAYER,
			"ramp_transition_mask": GROUND_COLLISION_LAYER | ELEVATED_COLLISION_LAYER,
		},
	}
	if definition == null:
		output["errors"].append(FeatureGeometry.error(
			&"bridge.definition_missing", "Track definition is missing.", "definition"
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)
	if not errors.is_empty():
		return FeatureGeometry.finalize(output)
	if definition.bridge_crossings.size() > MAX_BRIDGES:
		output["errors"].append(FeatureGeometry.error(
			&"bridge.declaration_cap_exceeded",
			"Bridge declarations exceed the feature-planner safety cap.",
			"bridge_crossings",
			{"actual": definition.bridge_crossings.size(), "maximum": MAX_BRIDGES}
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)

	var actual_crossings := ValidatorType.find_crossings(compiled)
	if actual_crossings.size() > MAX_BRIDGES:
		output["errors"].append(FeatureGeometry.error(
			&"bridge.crossing_cap_exceeded",
			"Detected crossings exceed the feature-planner safety cap.",
			"centerline",
			{"actual": actual_crossings.size(), "maximum": MAX_BRIDGES}
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)

	var used_actual := PackedByteArray()
	used_actual.resize(actual_crossings.size())
	var tolerance := maxf(compiled.sample_spacing * 3.0, compiled.track_width)
	var seen_ids: Dictionary = {}
	for declaration_index in definition.bridge_crossings.size():
		var declaration := definition.bridge_crossings[declaration_index]
		var declaration_error := _validate_declaration(declaration, compiled.total_length, declaration_index)
		if not declaration_error.is_empty():
			output["errors"].append(declaration_error)
			continue
		if seen_ids.has(declaration.crossing_id):
			output["errors"].append(FeatureGeometry.error(
				&"bridge.id_duplicate",
				"Bridge crossing IDs must be unique.",
				"bridge_crossings[%d].crossing_id" % declaration_index
			))
			continue
		seen_ids[declaration.crossing_id] = true
		var match := _find_best_match(declaration, actual_crossings, used_actual, compiled.total_length)
		if match.is_empty() or float(match["score"]) > tolerance:
			output["errors"].append(FeatureGeometry.error(
				&"bridge.declared_crossing_not_found",
				"Declared bridge does not match a geometric crossing.",
				"bridge_crossings[%d]" % declaration_index,
				{"tolerance": FeatureGeometry.quantize_scalar(tolerance)}
			))
			continue
		var actual_index := int(match["actual_index"])
		used_actual[actual_index] = 1
		var crossing_plan := _build_crossing_plan(
			declaration,
			actual_crossings[actual_index],
			bool(match["swapped"]),
			compiled
		)
		output["crossings"].append(crossing_plan)
		output["exclusion_zones"].append(crossing_plan["scenery_exclusion"])

	for actual_index in actual_crossings.size():
		if used_actual[actual_index] == 0:
			var actual: Dictionary = actual_crossings[actual_index]
			output["errors"].append(FeatureGeometry.error(
				&"bridge.undeclared_crossing",
				"A geometric self-crossing has no bridge declaration.",
				"centerline",
				{
					"distance_a": FeatureGeometry.quantize_scalar(float(actual.get("distance_a", 0.0))),
					"distance_b": FeatureGeometry.quantize_scalar(float(actual.get("distance_b", 0.0))),
				}
			))
	output["valid"] = output["errors"].is_empty()
	return FeatureGeometry.finalize(output)


static func _validate_declaration(
		declaration: BridgeCrossingDefinition,
		lap_length: float,
		index: int
	) -> Dictionary:
	var path := "bridge_crossings[%d]" % index
	if declaration == null:
		return FeatureGeometry.error(&"bridge.declaration_null", "Bridge declaration cannot be null.", path)
	if declaration.crossing_id.is_empty():
		return FeatureGeometry.error(&"bridge.id_missing", "Bridge crossing ID is required.", path + ".crossing_id")
	if not FeatureGeometry.is_finite_scalar(declaration.distance_a) \
			or not FeatureGeometry.is_finite_scalar(declaration.distance_b) \
			or declaration.distance_a < 0.0 or declaration.distance_b < 0.0 \
			or declaration.distance_a >= lap_length or declaration.distance_b >= lap_length:
		return FeatureGeometry.error(&"bridge.distance_invalid", "Bridge distances must lie on the compiled lap.", path)
	if declaration.overpass != BridgeDefinitionType.OVERPASS_A \
			and declaration.overpass != BridgeDefinitionType.OVERPASS_B:
		return FeatureGeometry.error(&"bridge.overpass_invalid", "Bridge overpass branch must be a or b.", path + ".overpass")
	return {}


static func _find_best_match(
		declaration: BridgeCrossingDefinition,
		actual_crossings: Array[Dictionary],
		used_actual: PackedByteArray,
		lap_length: float
	) -> Dictionary:
	var best: Dictionary = {}
	for actual_index in actual_crossings.size():
		if used_actual[actual_index] == 1:
			continue
		var actual := actual_crossings[actual_index]
		var actual_a := float(actual.get("distance_a", 0.0))
		var actual_b := float(actual.get("distance_b", 0.0))
		var direct_score := maxf(
			FeatureGeometry.circular_distance(declaration.distance_a, actual_a, lap_length),
			FeatureGeometry.circular_distance(declaration.distance_b, actual_b, lap_length)
		)
		var swapped_score := maxf(
			FeatureGeometry.circular_distance(declaration.distance_a, actual_b, lap_length),
			FeatureGeometry.circular_distance(declaration.distance_b, actual_a, lap_length)
		)
		var swapped := swapped_score < direct_score
		var score := swapped_score if swapped else direct_score
		if best.is_empty() or score < float(best["score"]):
			best = {
				"actual_index": actual_index,
				"score": score,
				"swapped": swapped,
			}
	return best


static func _build_crossing_plan(
		declaration: BridgeCrossingDefinition,
		actual: Dictionary,
		actual_is_swapped: bool,
		compiled: CompiledTrack
	) -> Dictionary:
	var branch_a_over := declaration.overpass == BridgeDefinitionType.OVERPASS_A
	# Declarations identify route branches, while the detected distances are the
	# exact current geometry. Matching can swap detector A/B, so align them here
	# before renderer-facing deck/ramp sampling.
	var actual_a := float(actual.get("distance_b" if actual_is_swapped else "distance_a", declaration.distance_a))
	var actual_b := float(actual.get("distance_a" if actual_is_swapped else "distance_b", declaration.distance_b))
	var branch_a := _branch_plan(
		&"a", declaration.distance_a, actual_a, branch_a_over, compiled
	)
	var branch_b := _branch_plan(
		&"b", declaration.distance_b, actual_b, not branch_a_over, compiled
	)
	var over_branch: Dictionary = branch_a if branch_a_over else branch_b
	var under_branch: Dictionary = branch_b if branch_a_over else branch_a
	var deck_half_length := clampf(compiled.track_width * 0.8, 18.0, 72.0)
	var ramp_half_length := clampf(compiled.track_width * 2.0, deck_half_length + 24.0, 192.0)
	var deck_samples := FeatureGeometry.sample_window(
		compiled,
		float(over_branch["lap_distance"]),
		deck_half_length,
		maxf(compiled.sample_spacing, 4.0),
		64
	)
	var deck_polyline := PackedVector2Array()
	for sample in deck_samples:
		deck_polyline.append(sample["position"])
	var shadow_offset := FeatureGeometry.quantize_vector(Vector2(
		maxf(3.0, compiled.track_width * 0.08),
		maxf(5.0, compiled.track_width * 0.12)
	))
	var shadow_polyline := PackedVector2Array()
	for point in deck_polyline:
		shadow_polyline.append(FeatureGeometry.quantize_vector(point + shadow_offset))
	var intersection_position := FeatureGeometry.quantize_vector(
		actual.get("position", Vector2.ZERO)
	)
	var over_id := str(over_branch["branch_id"])
	var under_id := str(under_branch["branch_id"])
	return {
		"crossing_id": declaration.crossing_id,
		"position": intersection_position,
		"overpass_branch": over_id,
		"underpass_branch": under_id,
		"branch_a": branch_a,
		"branch_b": branch_b,
		"draw_sequence": [
			{"kind": "road_branch", "branch": under_id, "render_order": 0},
			{"kind": "bridge_shadow", "branch": over_id, "render_order": 10},
			{"kind": "bridge_deck", "branch": over_id, "render_order": 20},
			{"kind": "bridge_rails", "branch": over_id, "render_order": 21},
		],
		"deck": {
			"branch": over_id,
			"half_length": FeatureGeometry.quantize_scalar(deck_half_length),
			"height_units": BRIDGE_HEIGHT_UNITS,
			"polyline": deck_polyline,
			"width": FeatureGeometry.quantize_scalar(compiled.track_width),
		},
		"ramps": _ramp_profiles(
			compiled,
			float(over_branch["lap_distance"]),
			over_id,
			deck_half_length,
			ramp_half_length
		),
		"shadow": {
			"polyline": shadow_polyline,
			"offset": shadow_offset,
			"width": FeatureGeometry.quantize_scalar(compiled.track_width * 1.14),
			"opacity": 0.32,
			"render_order": 10,
		},
		"collision": {
			"branch_a_layer": int(branch_a["collision_layer"]),
			"branch_b_layer": int(branch_b["collision_layer"]),
			"underpass_layer": GROUND_COLLISION_LAYER,
			"overpass_layer": ELEVATED_COLLISION_LAYER,
			"ramp_transition_mask": GROUND_COLLISION_LAYER | ELEVATED_COLLISION_LAYER,
			"height_separation_units": BRIDGE_HEIGHT_UNITS,
		},
		"scenery_exclusion": {
			"kind": "bridge",
			"id": declaration.crossing_id,
			"center": intersection_position,
			"radius": FeatureGeometry.quantize_scalar(ramp_half_length + compiled.track_width),
		},
	}


static func _branch_plan(
		branch_id: StringName,
		authored_lap_distance: float,
		geometric_lap_distance: float,
		is_elevated: bool,
		compiled: CompiledTrack
	) -> Dictionary:
	var sample := FeatureGeometry.sample_at_distance(compiled, geometric_lap_distance)
	return {
		"branch_id": str(branch_id),
		"authored_lap_distance": FeatureGeometry.quantize_scalar(authored_lap_distance),
		"lap_distance": sample.get("distance", FeatureGeometry.quantize_scalar(geometric_lap_distance)),
		"segment_index": int(sample.get("segment_index", 0)),
		"position": sample.get("position", Vector2.ZERO),
		"tangent": sample.get("tangent", Vector2.RIGHT),
		"elevation_level": 1 if is_elevated else 0,
		"height_units": BRIDGE_HEIGHT_UNITS if is_elevated else 0,
		"render_order": 20 if is_elevated else 0,
		"collision_layer": ELEVATED_COLLISION_LAYER if is_elevated else GROUND_COLLISION_LAYER,
		"collision_mask": ELEVATED_COLLISION_LAYER if is_elevated else GROUND_COLLISION_LAYER,
	}


static func _ramp_profiles(
		compiled: CompiledTrack,
		center_distance: float,
		branch_id: String,
		deck_half_length: float,
		ramp_half_length: float
	) -> Array[Dictionary]:
	var entry_points: Array[Dictionary] = []
	var exit_points: Array[Dictionary] = []
	const PROFILE_STEPS: int = 6
	for index in PROFILE_STEPS:
		var amount := float(index) / float(PROFILE_STEPS - 1)
		var entry_relative := lerpf(-ramp_half_length, -deck_half_length, amount)
		var exit_relative := lerpf(deck_half_length, ramp_half_length, amount)
		var entry_sample := FeatureGeometry.sample_at_distance(compiled, center_distance + entry_relative)
		var exit_sample := FeatureGeometry.sample_at_distance(compiled, center_distance + exit_relative)
		entry_points.append({
			"distance": entry_sample["distance"],
			"position": entry_sample["position"],
			"height_units": int(round(BRIDGE_HEIGHT_UNITS * amount)),
		})
		exit_points.append({
			"distance": exit_sample["distance"],
			"position": exit_sample["position"],
			"height_units": int(round(BRIDGE_HEIGHT_UNITS * (1.0 - amount))),
		})
	return [
		{
			"kind": "entry",
			"branch": branch_id,
			"from_layer": GROUND_COLLISION_LAYER,
			"to_layer": ELEVATED_COLLISION_LAYER,
			"profile": entry_points,
		},
		{
			"kind": "exit",
			"branch": branch_id,
			"from_layer": ELEVATED_COLLISION_LAYER,
			"to_layer": GROUND_COLLISION_LAYER,
			"profile": exit_points,
		},
	]
