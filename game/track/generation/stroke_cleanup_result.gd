class_name StrokeCleanupResult
extends RefCounted
## Diagnostics from deterministic input-stroke sanitation.

var points: PackedVector2Array = PackedVector2Array()
var input_count: int = 0
var non_finite_removed: int = 0
var duplicates_removed: int = 0
var collinear_removed: int = 0
var spikes_removed: int = 0
var simplified_removed: int = 0
var closure_gap: float = 0.0
var is_closed: bool = false


func removed_count() -> int:
	return input_count - points.size()


func to_dictionary() -> Dictionary:
	return {
		"input_count": input_count,
		"output_count": points.size(),
		"non_finite_removed": non_finite_removed,
		"duplicates_removed": duplicates_removed,
		"collinear_removed": collinear_removed,
		"spikes_removed": spikes_removed,
		"simplified_removed": simplified_removed,
		"closure_gap": closure_gap,
		"is_closed": is_closed,
	}

