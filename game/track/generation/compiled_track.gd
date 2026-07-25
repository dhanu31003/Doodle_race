class_name CompiledTrack
extends RefCounted
## Immutable-by-convention deterministic output consumed by rendering/physics.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")

var compiler_version: int = GameLimitsType.TRACK_COMPILER_VERSION
var source_hash: String = ""
var compile_hash: String = ""
var track_id: String = ""
var canvas_size: Vector2 = Vector2.ZERO
var direction: StringName = &"clockwise"
var theme: StringName = &"classic"
var pit_side: StringName = &"none"
var decoration_density: float = 0.0
var deterministic_seed: int = 0
var bridge_crossings: Array[Dictionary] = []
var track_width: float = 0.0
var sample_spacing: float = 0.0
var start_finish_distance: float = 0.0
var suggested_start_finish_distance: float = 0.0
var centerline: PackedVector2Array = PackedVector2Array()
var left_edge: PackedVector2Array = PackedVector2Array()
var right_edge: PackedVector2Array = PackedVector2Array()
var tangents: PackedVector2Array = PackedVector2Array()
var normals: PackedVector2Array = PackedVector2Array()
var curvatures: PackedFloat64Array = PackedFloat64Array()
var radii: PackedFloat64Array = PackedFloat64Array()
var arc_distances: PackedFloat64Array = PackedFloat64Array()
var total_length: float = 0.0
var straight_sections: Array[Dictionary] = []
var corner_sections: Array[Dictionary] = []


func sample_count() -> int:
	return centerline.size()


func calculated_compile_hash() -> String:
	return CanonicalJsonType.sha256(to_canonical_dictionary())


func refresh_compile_hash() -> String:
	compile_hash = calculated_compile_hash()
	return compile_hash


func to_canonical_dictionary() -> Dictionary:
	return {
		"compiler_version": compiler_version,
		"source_hash": source_hash,
		"track_id": track_id,
		"canvas_size_q": _vectors_to_fixed(PackedVector2Array([canvas_size])),
		"direction": str(direction),
		"theme": str(theme),
		"pit_side": str(pit_side),
		"decoration_density_q": QuantizationType.to_fixed(decoration_density, 1_000_000),
		"deterministic_seed": deterministic_seed,
		"bridge_crossings": bridge_crossings,
		"track_width_q": QuantizationType.to_fixed(track_width),
		"sample_spacing_q": QuantizationType.to_fixed(sample_spacing),
		"start_finish_distance_q": QuantizationType.to_fixed(start_finish_distance),
		"suggested_start_finish_distance_q": QuantizationType.to_fixed(suggested_start_finish_distance),
		"centerline_q": _vectors_to_fixed(centerline),
		"left_edge_q": _vectors_to_fixed(left_edge),
		"right_edge_q": _vectors_to_fixed(right_edge),
		"tangents_q": _vectors_to_fixed(tangents, 1_000_000),
		"normals_q": _vectors_to_fixed(normals, 1_000_000),
		"curvatures_q": _floats_to_fixed(curvatures, 1_000_000_000),
		"radii_q": _radii_to_fixed(radii),
		"arc_distances_q": _floats_to_fixed(arc_distances),
		"total_length_q": QuantizationType.to_fixed(total_length),
		"straight_sections_q": _sections_to_fixed(straight_sections),
		"corner_sections_q": _sections_to_fixed(corner_sections),
	}


static func _vectors_to_fixed(values: PackedVector2Array, scale: int = 1000) -> Array:
	var output: Array = []
	for value in values:
		var fixed := QuantizationType.vector2_to_fixed(value, scale)
		output.append([fixed.x, fixed.y])
	return output


static func _floats_to_fixed(values: PackedFloat64Array, scale: int = 1000) -> Array[int]:
	var output: Array[int] = []
	for value in values:
		output.append(QuantizationType.to_fixed(value, scale))
	return output


static func _radii_to_fixed(values: PackedFloat64Array) -> Array[int]:
	var output: Array[int] = []
	for value in values:
		output.append(-1 if is_inf(value) else QuantizationType.to_fixed(value))
	return output


static func _sections_to_fixed(sections: Array[Dictionary]) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for section in sections:
		output.append({
			"start_index": int(section.get("start_index", 0)),
			"end_index": int(section.get("end_index", 0)),
			"start_distance_q": QuantizationType.to_fixed(float(section.get("start_distance", 0.0))),
			"length_q": QuantizationType.to_fixed(float(section.get("length", 0.0))),
		})
	return output
