class_name AiSoakTrackCatalog
extends RefCounted
## Frozen release-soak track construction. No simulation code belongs here.

const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackValidatorType := preload("res://game/track/validation/track_validator.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const QuantizationType := preload("res://game/core/quantization.gd")

const CORPUS_PATH := "res://tests/fixtures/race/generated_track_corpus_v1.json"
const FROZEN_TIMESTAMP := 1_784_820_000


static func representative_specs() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for catalog_id in ["builtin-evergreen-oval", "builtin-copper-canyon"]:
		var item := CatalogType.by_id(catalog_id)
		output.append({
			"id": str(item["track_id"]),
			"archetype": "oval" if catalog_id.ends_with("oval") else "technical",
			"seed": int(item["seed"]),
			"definition": item["definition"],
		})
	output.append({
		"id": "generated-s-bends",
		"archetype": "s_bends",
		"seed": 8675309,
		"definition": _make_s_bend_definition(),
	})
	output.append({
		"id": "generated-bridge-eight",
		"archetype": "bridge_capable",
		"seed": 4102,
		"definition": _make_bridge_definition(),
	})
	return output


static func corpus_fixture() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CORPUS_PATH))
	return parsed if parsed is Dictionary else {}


static func corpus_definition(record: Dictionary) -> TrackDefinition:
	var base := PackedVector2Array([
		Vector2(0.22, 0.25), Vector2(0.37, 0.19), Vector2(0.52, 0.18),
		Vector2(0.68, 0.20), Vector2(0.81, 0.28), Vector2(0.87, 0.42),
		Vector2(0.85, 0.59), Vector2(0.75, 0.73), Vector2(0.60, 0.80),
		Vector2(0.40, 0.81), Vector2(0.24, 0.75), Vector2(0.14, 0.62),
		Vector2(0.13, 0.44),
	])
	var wave := float(record.get("wave", 0.03))
	var lobes := int(record.get("lobes", 3))
	var phase := float(record.get("phase", 0.0)) * TAU
	var shear := float(record.get("shear", 0.0))
	var aspect := float(record.get("aspect", 1.35))
	var x_scale := 0.91 + clampf((aspect - 1.16) / 0.41, 0.0, 1.0) * 0.09
	var points := PackedVector2Array()
	for index in base.size():
		var centered := base[index] - Vector2(0.5, 0.5)
		var theta := atan2(centered.y, centered.x)
		var radius_scale := 1.0 + wave * cos(float(lobes) * theta + phase)
		centered *= radius_scale
		centered.x *= x_scale
		centered.x += shear * centered.y
		points.append(Vector2(0.5, 0.5) + centered)
	var definition := TrackDefinitionType.create(
		points,
		Vector2(1200.0, 800.0),
		float(record.get("width", 35.0)),
		"Corpus %s" % str(record.get("id", "track")),
		str(record.get("id", "corpus-track")),
		int(record.get("seed", 1))
	)
	definition.target_length = QuantizationType.scalar(float(record.get("target_length", 1600.0)))
	definition.theme = &"forest"
	definition.pit_side = TrackDefinitionType.PIT_NONE
	definition.decoration_density = 0.7
	definition.created_at_timestamp = FROZEN_TIMESTAMP
	definition.updated_at_timestamp = FROZEN_TIMESTAMP
	return _relocate_start_and_hash(definition)


static func _make_s_bend_definition() -> TrackDefinition:
	# A smooth three-lobe harmonic creates alternating sweep direction without
	# the unsafe hairpin/cusp produced by hand-authored zig-zag points.
	return corpus_definition({
		"id": "generated-s-bends",
		"seed": 8675309,
		"aspect": 1.33,
		"wave": 0.06,
		"lobes": 3,
		"phase": 0.67,
		"shear": -0.02,
		"width": 34.0,
		"target_length": 1760.0,
	})


static func _make_bridge_definition() -> TrackDefinition:
	var points := PackedVector2Array([
		Vector2(0.16, 0.20), Vector2(0.36, 0.18), Vector2(0.77, 0.72),
		Vector2(0.86, 0.62), Vector2(0.78, 0.24), Vector2(0.63, 0.18),
		Vector2(0.24, 0.74), Vector2(0.14, 0.63),
	])
	var definition := TrackDefinitionType.create(
		points, Vector2(1200, 800), 30.0, "Bridge Eight", "generated-bridge-eight", 4102
	)
	definition.target_length = 1800.0
	definition.theme = &"forest"
	definition.created_at_timestamp = FROZEN_TIMESTAMP
	definition.updated_at_timestamp = FROZEN_TIMESTAMP
	definition = _relocate_start_and_hash(definition)
	var provisional := TrackCompilerType.compile(definition)
	if provisional.track != null:
		var crossings := TrackValidatorType.find_crossings(provisional.track)
		for index in crossings.size():
			var crossing: Dictionary = crossings[index]
			definition.bridge_crossings.append(BridgeDefinitionType.new(
				"bridge-%02d" % (index + 1),
				QuantizationType.scalar(float(crossing["distance_a"])),
				QuantizationType.scalar(float(crossing["distance_b"])),
				BridgeDefinitionType.OVERPASS_A if index % 2 == 0 else BridgeDefinitionType.OVERPASS_B
			))
	definition.refresh_content_hash()
	return definition


static func _relocate_start_and_hash(definition: TrackDefinition) -> TrackDefinition:
	definition.refresh_content_hash()
	# Resampling can move a suggested section boundary by one sample. Iterate a
	# bounded number of times so every frozen fixture lands on the compiler's
	# actual straight, without changing geometry or relaxing validation.
	for _attempt in 16:
		var provisional := TrackCompilerType.compile(definition)
		if provisional.track == null \
				or not provisional.report.has_code(&"geometry.start_straight_too_short"):
			break
		var suggestion: float = provisional.track.suggested_start_finish_distance
		if is_equal_approx(suggestion, definition.start_finish_distance):
			# A suggestion exactly on a resample boundary can retain one short
			# leading sample. Advance one compiler spacing and validate again.
			suggestion = fposmod(suggestion + 4.0, definition.target_length)
		definition.start_finish_distance = suggestion
		definition.refresh_content_hash()
	definition.refresh_content_hash()
	return definition
