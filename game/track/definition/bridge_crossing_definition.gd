class_name BridgeCrossingDefinition
extends RefCounted
## Declares which branch is elevated at one intentional self-crossing.
## Distances are measured clockwise/forward from the start line on the compiled
## centerline, making the declaration independent of spline sample count.

const OVERPASS_A: StringName = &"a"
const OVERPASS_B: StringName = &"b"

var crossing_id: String = ""
var distance_a: float = 0.0
var distance_b: float = 0.0
var overpass: StringName = OVERPASS_A


func _init(
		id: String = "",
		first_distance: float = 0.0,
		second_distance: float = 0.0,
		overpass_branch: StringName = OVERPASS_A
	) -> void:
	crossing_id = id
	distance_a = first_distance
	distance_b = second_distance
	overpass = overpass_branch


static func from_dictionary(data: Dictionary) -> BridgeCrossingDefinition:
	return BridgeCrossingDefinition.new(
		str(data.get("crossing_id", "")),
		_safe_float(data.get("distance_a")),
		_safe_float(data.get("distance_b")),
		StringName(str(data.get("overpass", "a")))
	)


func to_dictionary() -> Dictionary:
	return {
		"crossing_id": crossing_id,
		"distance_a": distance_a,
		"distance_b": distance_b,
		"overpass": str(overpass),
	}


func copy() -> BridgeCrossingDefinition:
	return BridgeCrossingDefinition.from_dictionary(to_dictionary())


static func _safe_float(value: Variant) -> float:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return float(value)
	return 0.0
