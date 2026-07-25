class_name TrackWorldFeaturePlanner
extends RefCounted
## Single pure-data integration point for every post-compilation world feature.

const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")
const BridgePlanner := preload("res://game/track/features/bridge_plan_builder.gd")
const PitPlanner := preload("res://game/track/features/pit_lane_plan_builder.gd")
const SceneryPlanner := preload("res://game/track/features/scenery_plan_builder.gd")
const MinimapPlanner := preload("res://game/track/features/minimap_plan_builder.gd")
const TourPlanner := preload("res://game/track/features/track_tour_plan_builder.gd")


static func plan(definition: TrackDefinition, compiled: CompiledTrack) -> Dictionary:
	var bridge_plan := BridgePlanner.plan(definition, compiled)
	var pit_plan := PitPlanner.plan(definition, compiled)
	var scenery_plan := SceneryPlanner.plan(definition, compiled, pit_plan, bridge_plan)
	var minimap_plan := MinimapPlanner.plan(compiled, pit_plan, bridge_plan)
	var tour_plan := TourPlanner.plan(compiled, pit_plan, bridge_plan)
	var errors: Array[Dictionary] = []
	_collect_errors(errors, "bridges", bridge_plan)
	_collect_errors(errors, "pit_lane", pit_plan)
	_collect_errors(errors, "scenery", scenery_plan)
	_collect_errors(errors, "minimap", minimap_plan)
	_collect_errors(errors, "track_tour", tour_plan)
	return FeatureGeometry.finalize({
		"feature_version": 1,
		"valid": errors.is_empty(),
		"errors": errors,
		"source_hash": "" if compiled == null else compiled.source_hash,
		"compile_hash": "" if compiled == null else compiled.compile_hash,
		"bridges": bridge_plan,
		"pit_lane": pit_plan,
		"scenery": scenery_plan,
		"minimap": minimap_plan,
		"track_tour": tour_plan,
	})


static func _collect_errors(output: Array[Dictionary], subsystem: String, plan_data: Dictionary) -> void:
	var plan_errors: Variant = plan_data.get("errors", [])
	if not plan_errors is Array:
		output.append(FeatureGeometry.error(
			&"features.error_contract_invalid",
			"Feature planner returned malformed errors.",
			subsystem
		))
		return
	for error_variant in plan_errors:
		if not error_variant is Dictionary:
			continue
		var feature_error: Dictionary = error_variant.duplicate(true)
		feature_error["subsystem"] = subsystem
		output.append(feature_error)
