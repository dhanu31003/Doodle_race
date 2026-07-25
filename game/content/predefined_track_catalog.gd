class_name PredefinedTrackCatalog
extends RefCounted
## Deterministic first-party circuits shipped with the offline game.

const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackValidatorType := preload("res://game/track/validation/track_validator.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")

const CONTENT_TIMESTAMP := 1_784_820_000

# Built-in definitions need one deterministic compile to resolve their grid and
# optional bridge declarations. Keep only canonical JSON in the cache so every
# caller still receives an isolated mutable definition instead of sharing state.
static var _canonical_definition_cache: Dictionary = {}


static func records() -> Array[Dictionary]:
	return [
		{
			"track_id": "builtin-evergreen-oval",
			"name": "EVERGREEN TRIDENT",
			"location": "MISTWOOD PARK",
			"description": "A welcoming three-lobed forest circuit whose broad opposing sweepers introduce unusual lines without punishing new drivers.",
			"difficulty": 1,
			"archetype": "asymmetric-trident",
			"road_surface": RoadSurfaceCatalogType.SMOOTH_ASPHALT,
			"accent": Color("5fffd0"),
			"target_length": 4000.0,
			"width": 48.0,
			"canvas_size": Vector2(3000.0, 2000.0),
			"pit_side": "none",
			"density": 0.72,
			"seed": 73191,
			"points": _radial_circuit_points(3, 0.33, 0.055, 0.72, 0.35, 0.010),
		},
		{
			"track_id": "builtin-crescent-run",
			"name": "CRESCENT HAMMERHEAD",
			"location": "MOONLAKE RESERVE",
			"description": "A lakefront crescent wraps around a central hammerhead, mixing open sweepers with a deceptive double-apex return.",
			"difficulty": 2,
			"archetype": "crescent-hammerhead",
			"road_surface": RoadSurfaceCatalogType.WEATHERED_ASPHALT,
			"accent": Color("51c8ff"),
			"target_length": 4200.0,
			"width": 46.0,
			"canvas_size": Vector2(3000.0, 2000.0),
			"pit_side": "right",
			"density": 0.82,
			"seed": 81173,
			"points": [
				Vector2(0.14, 0.22), Vector2(0.37, 0.14), Vector2(0.69, 0.15),
				Vector2(0.85, 0.25), Vector2(0.90, 0.43), Vector2(0.85, 0.64),
				Vector2(0.69, 0.78), Vector2(0.52, 0.73), Vector2(0.55, 0.58),
				Vector2(0.68, 0.47), Vector2(0.61, 0.34), Vector2(0.46, 0.31),
				Vector2(0.36, 0.43), Vector2(0.34, 0.60), Vector2(0.23, 0.76),
				Vector2(0.11, 0.67), Vector2(0.08, 0.48), Vector2(0.09, 0.32),
			],
		},
		{
			"track_id": "builtin-northstar-gp",
			"name": "NORTHSTAR CROWN",
			"location": "POLARIS RIDGE",
			"description": "Five flowing ridge crests form a crown-shaped rhythm where every approach changes the next braking line.",
			"difficulty": 3,
			"archetype": "five-lobe-crown",
			"road_surface": RoadSurfaceCatalogType.BUMPY_ASPHALT,
			"accent": Color("b99cff"),
			"target_length": 4300.0,
			"width": 46.0,
			"canvas_size": Vector2(3000.0, 2000.0),
			"pit_side": "none",
			"density": 0.66,
			"seed": 271828,
			"points": _radial_circuit_points(5, 0.315, 0.095, 0.72, -0.28, 0.018),
		},
		{
			"track_id": "builtin-riverbend",
			"name": "RIVER KNOT",
			"location": "SILVER CURRENT",
			"description": "Two opposing river bends interlock without crossing, ending in a tightening hook beside the pit straight.",
			"difficulty": 3,
			"archetype": "interlocking-river-knot",
			"road_surface": RoadSurfaceCatalogType.MUD,
			"accent": Color("ffc857"),
			"target_length": 4100.0,
			"width": 47.0,
			"canvas_size": Vector2(3000.0, 2000.0),
			"pit_side": "left",
			"density": 0.76,
			"seed": 141421,
			"points": [
				Vector2(0.13, 0.20), Vector2(0.37, 0.14), Vector2(0.65, 0.16),
				Vector2(0.84, 0.25), Vector2(0.88, 0.41), Vector2(0.78, 0.51),
				Vector2(0.62, 0.48), Vector2(0.54, 0.37), Vector2(0.43, 0.34),
				Vector2(0.34, 0.44), Vector2(0.39, 0.57), Vector2(0.55, 0.60),
				Vector2(0.66, 0.69), Vector2(0.58, 0.81), Vector2(0.36, 0.84),
				Vector2(0.18, 0.76), Vector2(0.09, 0.61), Vector2(0.08, 0.39),
			],
		},
		{
			"track_id": "builtin-nightfall-crossing",
			"name": "FOREST CROSSING",
			"location": "AURORA FOREST",
			"description": "A flowing figure-eight whose sunlit overpass separates two high-speed forest approaches.",
			"difficulty": 4,
			"archetype": "elevated-figure-eight",
			"road_surface": RoadSurfaceCatalogType.SMOOTH_ASPHALT,
			"accent": Color("62f5e2"),
			"target_length": 4600.0,
			"width": 46.0,
			"canvas_size": Vector2(3000.0, 2000.0),
			"pit_side": "none",
			"density": 0.88,
			"seed": 48271,
			"bridge_overpass": "b",
			"direction": "clockwise",
			"points": _nightfall_crossing_points(),
		},
		{
			"track_id": "builtin-copper-canyon",
			"name": "COPPER ROSETTE",
			"location": "EMBER PASS",
			"description": "Seven canyon apexes spiral through alternating cambers; the narrow road rewards deliberate placement.",
			"difficulty": 4,
			"archetype": "seven-apex-rosette",
			"road_surface": RoadSurfaceCatalogType.COMPACT_GRAVEL,
			"accent": Color("ff6b72"),
			"target_length": 4400.0,
			"width": 44.0,
			"canvas_size": Vector2(3000.0, 2000.0),
			"pit_side": "none",
			"density": 0.58,
			"seed": 314159,
			"points": _radial_circuit_points(7, 0.32, 0.042, 0.73, 0.19, 0.008),
		},
	]


static func all() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for record in records():
		var item := record.duplicate(true)
		item["definition"] = _definition_from_record(record)
		output.append(item)
	return output


static func by_id(track_id: String) -> Dictionary:
	var catalog_records := records()
	var selected: Dictionary = catalog_records[0]
	for record in catalog_records:
		if str(record["track_id"]) == track_id:
			selected = record
			break
	var item := selected.duplicate(true)
	item["definition"] = _definition_from_record(selected)
	return item


static func race_payload(track_id: String, laps: int = 3, difficulty: String = "standard") -> Dictionary:
	var item := by_id(track_id)
	var definition: TrackDefinition = item["definition"]
	var result: TrackCompileResult = TrackCompilerType.compile(definition)
	if not result.succeeded():
		return {"error": "builtin_track_invalid", "track_id": track_id}
	return {
		"track_definition_json": definition.canonical_json(true),
		"source_hash": result.track.source_hash,
		"compiled_hash": result.track.compile_hash,
		"source": "predefined",
		"laps": clampi(laps, 1, 20),
		"difficulty": difficulty if difficulty in ["relaxed", "standard", "expert"] else "standard",
	}


static func _definition_from_record(record: Dictionary) -> TrackDefinition:
	var cache_key := str(record["track_id"])
	if _canonical_definition_cache.has(cache_key):
		return TrackDefinitionType.from_json(str(_canonical_definition_cache[cache_key]))
	var points := PackedVector2Array()
	for point in record["points"]:
		points.append(point)
	var canvas_size: Vector2 = record.get("canvas_size", Vector2(1200.0, 800.0))
	var definition: TrackDefinition = TrackDefinitionType.create(
		points,
		canvas_size,
		float(record["width"]),
		str(record["name"]).capitalize(),
		str(record["track_id"]),
		int(record["seed"])
	)
	definition.direction = StringName(str(record.get("direction", TrackDefinitionType.DIRECTION_CLOCKWISE)))
	definition.target_length = QuantizationType.scalar(float(record["target_length"]))
	definition.theme = &"forest"
	definition.road_surface = RoadSurfaceCatalogType.sanitized_style(
		StringName(str(record.get("road_surface", RoadSurfaceCatalogType.SMOOTH_ASPHALT)))
	)
	definition.pit_side = StringName(str(record["pit_side"]))
	definition.decoration_density = QuantizationType.scalar(float(record["density"]), 0.000001)
	definition.created_at_timestamp = CONTENT_TIMESTAMP
	definition.updated_at_timestamp = CONTENT_TIMESTAMP
	definition.refresh_content_hash()
	var result: TrackCompileResult = TrackCompilerType.compile(definition)
	if result.track != null and result.report.has_code(&"geometry.start_straight_too_short"):
		definition.start_finish_distance = result.track.suggested_start_finish_distance
		definition.refresh_content_hash()
	if record.has("bridge_overpass"):
		# Start placement changes the route-distance origin, so resolve bridge
		# declarations only after the final start/finish location is selected.
		result = TrackCompilerType.compile(definition)
		if result.track != null:
			var actual_crossings := TrackValidatorType.find_crossings(result.track)
			for crossing_index in actual_crossings.size():
				var crossing: Dictionary = actual_crossings[crossing_index]
				definition.bridge_crossings.append(BridgeDefinitionType.new(
					"nightfall-bridge-%02d" % (crossing_index + 1),
					QuantizationType.scalar(float(crossing["distance_a"])),
					QuantizationType.scalar(float(crossing["distance_b"])),
					StringName(str(record["bridge_overpass"]))
				))
			definition.refresh_content_hash()
	_canonical_definition_cache[cache_key] = definition.canonical_json(true)
	return definition


static func _nightfall_crossing_points() -> Array[Vector2]:
	var points: Array[Vector2] = []
	const POINT_COUNT := 24
	for index in POINT_COUNT:
		var angle := PI * 0.5 + TAU * (float(index) + 0.5) / float(POINT_COUNT)
		points.append(Vector2(
			# The unequal lobes give the crossing a stable global winding after
			# arc-length resampling and corner fairing at every release scale.
			0.5 + sin(angle) * (0.34 + 0.10 * cos(angle)),
			0.5 + sin(angle) * cos(angle) * 0.34
		))
	return points


static func _radial_circuit_points(
		lobes: int,
		base_radius: float,
		wave: float,
		vertical_scale: float,
		phase: float,
		secondary_wave: float
	) -> Array[Vector2]:
	var points: Array[Vector2] = []
	const POINT_COUNT := 32
	for index in POINT_COUNT:
		var angle := -PI * 0.5 + TAU * float(index) / float(POINT_COUNT)
		var radius := base_radius \
			+ wave * cos(float(lobes) * angle + phase) \
			+ secondary_wave * sin(float(lobes - 2) * angle - phase * 0.5)
		points.append(Vector2(
			0.5 + cos(angle) * radius,
			0.5 + sin(angle) * radius * vertical_scale
		))
	return points
