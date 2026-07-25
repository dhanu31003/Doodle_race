class_name SceneryPlanBuilder
extends RefCounted
## Seeded, theme-addressable decoration placement with explicit safety zones.

const FeatureGeometry := preload("res://game/track/features/track_feature_geometry.gd")
const StableRngType := preload("res://game/core/stable_rng.gd")

const MAX_PLACEMENTS: int = 160
const MAX_ATTEMPTS: int = 4096

const THEME_CATALOGS := {
	"classic": ["broadleaf_tree", "shrub", "granite_rock", "marshal_post", "light_pole", "flag_cluster"],
	"forest": ["pine_tree", "birch_cluster", "fern_patch", "mossy_rock", "marshal_post", "trail_light"],
	"desert": ["cactus", "dry_shrub", "sandstone", "marshal_post", "solar_light", "banner"],
	"night": ["dark_pine", "neon_marker", "rock", "marshal_post", "floodlight", "holographic_flag"],
}


static func plan(
		definition: TrackDefinition,
		compiled: CompiledTrack,
		pit_plan: Dictionary = {},
		bridge_plan: Dictionary = {}
	) -> Dictionary:
	var errors := FeatureGeometry.validate_compiled(compiled)
	var output := {
		"feature_version": 1,
		"valid": errors.is_empty(),
		"errors": errors,
		"warnings": [],
		"theme": "classic",
		"seed_stream": "scenery-v1",
		"target_count": 0,
		"placements": [],
		"clearances": {},
		"rejected_counts": {
			"road": 0,
			"start": 0,
			"pit": 0,
			"bridge": 0,
			"bounds": 0,
			"spacing": 0,
		},
	}
	if definition == null:
		output["errors"].append(FeatureGeometry.error(
			&"scenery.definition_missing", "Track definition is missing.", "definition"
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)
	if not errors.is_empty():
		return FeatureGeometry.finalize(output)
	if not pit_plan.is_empty() and not bool(pit_plan.get("valid", false)):
		output["errors"].append(FeatureGeometry.error(
			&"scenery.pit_plan_invalid",
			"Scenery planning requires a valid pit plan when one is supplied.",
			"pit_plan"
		))
	if not bridge_plan.is_empty() and not bool(bridge_plan.get("valid", false)):
		output["errors"].append(FeatureGeometry.error(
			&"scenery.bridge_plan_invalid",
			"Scenery planning requires a valid bridge plan when one is supplied.",
			"bridge_plan"
		))
	if not output["errors"].is_empty():
		output["valid"] = false
		return FeatureGeometry.finalize(output)
	var density := clampf(definition.decoration_density, 0.0, 1.0)
	if not FeatureGeometry.is_finite_scalar(definition.decoration_density):
		output["errors"].append(FeatureGeometry.error(
			&"scenery.density_invalid", "Decoration density must be finite.", "decoration_density"
		))
		output["valid"] = false
		return FeatureGeometry.finalize(output)
	var theme := str(definition.theme)
	var catalog_key := theme if THEME_CATALOGS.has(theme) else "classic"
	var catalog: Array = THEME_CATALOGS[catalog_key]
	var target_count := clampi(roundi(compiled.total_length / 55.0 * density), 0, MAX_PLACEMENTS)
	var road_clearance := compiled.track_width * 0.5 + maxf(14.0, compiled.track_width * 0.18)
	var start_clearance := maxf(90.0, compiled.track_width * 2.2)
	var pit_clearance := compiled.track_width * 0.72
	var placement_spacing := maxf(16.0, compiled.track_width * 0.30)
	var start_position := compiled.centerline[0]
	var pit_polyline := _sanitized_polyline(pit_plan.get("lane_polyline", PackedVector2Array()))
	var bridge_zones := _sanitized_bridge_zones(bridge_plan.get("exclusion_zones", []))
	var road_grid := _build_road_exclusion_grid(compiled, road_clearance)
	output["theme"] = theme
	output["catalog_fallback"] = catalog_key != theme
	output["target_count"] = target_count
	output["clearances"] = {
		"road": FeatureGeometry.quantize_scalar(road_clearance),
		"start_finish": FeatureGeometry.quantize_scalar(start_clearance),
		"pit": FeatureGeometry.quantize_scalar(pit_clearance),
		"bridge_zones": bridge_zones,
		"between_placements": FeatureGeometry.quantize_scalar(placement_spacing),
	}
	if target_count == 0:
		return FeatureGeometry.finalize(output)

	var seed_material := "%s:%s:%s:scenery-v1" % [
		str(definition.deterministic_seed), compiled.track_id, compiled.source_hash
	]
	var rng := StableRngType.from_string(seed_material)
	var placements: Array[Dictionary] = []
	var maximum_attempts := mini(MAX_ATTEMPTS, maxi(64, target_count * 32))
	for attempt in maximum_attempts:
		if placements.size() >= target_count:
			break
		var lap_distance := rng.range_f(0.0, compiled.total_length)
		var road_sample := FeatureGeometry.sample_at_distance(compiled, lap_distance)
		var side := -1 if rng.chance(0.5) else 1
		var offset := road_clearance + rng.range_f(8.0, maxf(42.0, compiled.track_width * 1.55))
		var position: Vector2 = road_sample["position"] + road_sample["normal"] * float(side) * offset
		position = FeatureGeometry.quantize_vector(position)
		var rejection := _rejection_reason(
			position,
			placements,
			compiled,
			road_grid,
			start_position,
			start_clearance,
			road_clearance,
			pit_polyline,
			pit_clearance,
			bridge_zones,
			placement_spacing
		)
		if not rejection.is_empty():
			output["rejected_counts"][rejection] = int(output["rejected_counts"][rejection]) + 1
			continue
		var catalog_index := rng.range_i(0, catalog.size())
		var variant_name := str(catalog[catalog_index])
		placements.append({
			"placement_id": "scenery-%03d" % placements.size(),
			"theme": theme,
			"catalog_theme": catalog_key,
			"asset_key": "%s/%s" % [catalog_key, variant_name],
			"variant": variant_name,
			"lap_distance": road_sample["distance"],
			"side": side,
			"position": position,
			"rotation": FeatureGeometry.quantize_scalar(
				road_sample["tangent"].angle() + rng.range_f(-0.24, 0.24), 0.000001
			),
			"scale": FeatureGeometry.quantize_scalar(rng.range_f(0.82, 1.22)),
			"render_band": "trackside_near" if offset < road_clearance + 32.0 else "trackside_far",
		})
	output["placements"] = placements
	if placements.size() < target_count:
		output["warnings"].append({
			"code": "scenery.capacity_limited",
			"message": "Safety exclusions left fewer valid decoration positions than requested.",
			"context": {"placed": placements.size(), "target": target_count},
		})
	return FeatureGeometry.finalize(output)


static func _rejection_reason(
		position: Vector2,
		placements: Array[Dictionary],
		compiled: CompiledTrack,
		road_grid: Dictionary,
		start_position: Vector2,
		start_clearance: float,
		road_clearance: float,
		pit_polyline: PackedVector2Array,
		pit_clearance: float,
		bridge_zones: Array[Dictionary],
		placement_spacing: float
	) -> String:
	if compiled.canvas_size.x > 0.0 and compiled.canvas_size.y > 0.0:
		var bounds_margin := 8.0
		if position.x < bounds_margin or position.y < bounds_margin \
				or position.x > compiled.canvas_size.x - bounds_margin \
				or position.y > compiled.canvas_size.y - bounds_margin:
			return "bounds"
	if _inside_road_exclusion(position, compiled, road_grid, road_clearance):
		return "road"
	if position.distance_to(start_position) < start_clearance:
		return "start"
	if not pit_polyline.is_empty() \
			and FeatureGeometry.point_to_polyline_distance(position, pit_polyline) < pit_clearance:
		return "pit"
	for zone in bridge_zones:
		if position.distance_to(zone["center"]) < float(zone["radius"]):
			return "bridge"
	for placement in placements:
		if position.distance_to(placement["position"]) < placement_spacing:
			return "spacing"
	return ""


static func _build_road_exclusion_grid(compiled: CompiledTrack, clearance: float) -> Dictionary:
	var cell_size := maxf(32.0, clearance)
	var cells: Dictionary = {}
	for segment_index in compiled.centerline.size():
		var start := compiled.centerline[segment_index]
		var finish := compiled.centerline[(segment_index + 1) % compiled.centerline.size()]
		var minimum := Vector2(minf(start.x, finish.x), minf(start.y, finish.y)) - Vector2.ONE * clearance
		var maximum := Vector2(maxf(start.x, finish.x), maxf(start.y, finish.y)) + Vector2.ONE * clearance
		var min_cell := Vector2i(floori(minimum.x / cell_size), floori(minimum.y / cell_size))
		var max_cell := Vector2i(floori(maximum.x / cell_size), floori(maximum.y / cell_size))
		for cell_x in range(min_cell.x, max_cell.x + 1):
			for cell_y in range(min_cell.y, max_cell.y + 1):
				var key := "%d:%d" % [cell_x, cell_y]
				var bucket: Array = cells.get(key, [])
				bucket.append(segment_index)
				cells[key] = bucket
	return {"cell_size": cell_size, "cells": cells}


static func _inside_road_exclusion(
		position: Vector2,
		compiled: CompiledTrack,
		road_grid: Dictionary,
		clearance: float
	) -> bool:
	var cell_size := float(road_grid.get("cell_size", 32.0))
	var key := "%d:%d" % [floori(position.x / cell_size), floori(position.y / cell_size)]
	var cells: Dictionary = road_grid.get("cells", {})
	var bucket: Array = cells.get(key, [])
	for segment_variant in bucket:
		var segment_index := int(segment_variant)
		if FeatureGeometry.point_to_segment_distance(
			position,
			compiled.centerline[segment_index],
			compiled.centerline[(segment_index + 1) % compiled.centerline.size()]
		) < clearance:
			return true
	return false


static func _sanitized_bridge_zones(input: Variant) -> Array[Dictionary]:
	var zones: Array[Dictionary] = []
	if not input is Array:
		return zones
	for value in input:
		if not value is Dictionary:
			continue
		var center: Variant = value.get("center")
		var radius_value: Variant = value.get("radius")
		if not center is Vector2 or (typeof(radius_value) != TYPE_FLOAT and typeof(radius_value) != TYPE_INT):
			continue
		var radius := float(radius_value)
		if not FeatureGeometry.is_finite_vector2(center) \
				or not FeatureGeometry.is_finite_scalar(radius) or radius <= 0.0:
			continue
		zones.append({
			"kind": str(value.get("kind", "bridge")),
			"id": str(value.get("id", "")),
			"center": FeatureGeometry.quantize_vector(center),
			"radius": FeatureGeometry.quantize_scalar(radius),
		})
	return zones


static func _sanitized_polyline(input: Variant) -> PackedVector2Array:
	var output := PackedVector2Array()
	if input is PackedVector2Array:
		for point in input:
			if FeatureGeometry.is_finite_vector2(point):
				output.append(FeatureGeometry.quantize_vector(point))
			if output.size() >= 128:
				break
	elif input is Array:
		for value in input:
			if value is Vector2 and FeatureGeometry.is_finite_vector2(value):
				output.append(FeatureGeometry.quantize_vector(value))
			if output.size() >= 128:
				break
	return output
