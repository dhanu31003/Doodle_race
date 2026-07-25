class_name TrackAnalysis
extends RefCounted
## Derived geometry arrays share indices with the compiled centerline.

var tangents: PackedVector2Array = PackedVector2Array()
var normals: PackedVector2Array = PackedVector2Array()
var curvatures: PackedFloat64Array = PackedFloat64Array()
var radii: PackedFloat64Array = PackedFloat64Array()
var arc_distances: PackedFloat64Array = PackedFloat64Array()
var total_length: float = 0.0
var signed_area: float = 0.0
var winding: StringName = &"unknown"
var straight_sections: Array[Dictionary] = []
var corner_sections: Array[Dictionary] = []


func best_straight() -> Dictionary:
	var best: Dictionary = {}
	for section in straight_sections:
		if best.is_empty() or float(section.get("length", 0.0)) > float(best.get("length", 0.0)):
			best = section
	return best.duplicate(true)


func minimum_finite_radius() -> float:
	var minimum := INF
	for radius in radii:
		if not is_inf(radius):
			minimum = minf(minimum, radius)
	return minimum

