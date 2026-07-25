class_name RoadSurfaceCatalog
extends RefCounted
## Released road-surface profiles shared by track authoring, deterministic
## vehicle authority, and presentation. A profile changes tyre/rolling behavior
## without changing the car itself, so human, AI, replay, and network clients
## always consume the same surface contract.

const SMOOTH_ASPHALT: StringName = &"smooth_asphalt"
const WEATHERED_ASPHALT: StringName = &"weathered_asphalt"
const BUMPY_ASPHALT: StringName = &"bumpy_asphalt"
const COMPACT_GRAVEL: StringName = &"compact_gravel"
const MUD: StringName = &"mud"

const STYLES: Array[StringName] = [
	SMOOTH_ASPHALT,
	WEATHERED_ASPHALT,
	BUMPY_ASPHALT,
	COMPACT_GRAVEL,
	MUD,
]

# Physics multipliers are intentionally broad enough to be readable without
# making any released surface impossible for the deterministic AI to finish.
# Roughness is presentation-only suspension travel in physical metres.
const PROFILES := {
	SMOOTH_ASPHALT: {
		"style": SMOOTH_ASPHALT,
		"label": "SMOOTH ASPHALT",
		"short_label": "SMOOTH",
		"description": "Clean racing asphalt with maximum grip and the calmest ride.",
		"visual_effect": "clean_dry",
		"road_color": Color("293139"),
		"runoff_color": Color("8e896a"),
		"texture_tint": Color("e7eaed"),
		"detail_dark_color": Color("343b40"),
		"detail_light_color": Color("e8ecee"),
		"visual_detail_strength": 0.08,
		"roughness": 0.94,
		"normal_scale": 0.42,
		"uv_repeats_per_meter": 0.25,
		"traction_multiplier": 1.0,
		"braking_multiplier": 1.0,
		"lateral_capacity_multiplier": 1.0,
		"lateral_grip_multiplier": 1.0,
		"ai_speed_factor": 1.0,
		"drive_efficiency_multiplier": 1.0,
		"surface_speed_drag": 0.0,
		"rolling_resistance": 0.0,
		"bump_amplitude_meters": 0.002,
		"bump_harmonics": Vector3i(19, 37, 61),
		"loose_surface": false,
	},
	WEATHERED_ASPHALT: {
		"style": WEATHERED_ASPHALT,
		"label": "WEATHERED ASPHALT",
		"short_label": "WEATHERED",
		"description": "Rain-soaked worn asphalt with wet patches, light spray, and reduced grip.",
		"visual_effect": "light_rain",
		"road_color": Color("303534"),
		"runoff_color": Color("938a6d"),
		"texture_tint": Color("c9c4b8"),
		"detail_dark_color": Color("292a29"),
		"detail_light_color": Color("d9cfb8"),
		"visual_detail_strength": 0.62,
		"roughness": 0.72,
		"normal_scale": 0.78,
		"uv_repeats_per_meter": 0.31,
		"traction_multiplier": 0.80,
		"braking_multiplier": 0.78,
		"lateral_capacity_multiplier": 0.80,
		"lateral_grip_multiplier": 0.82,
		"ai_speed_factor": 0.84,
		"drive_efficiency_multiplier": 0.93,
		"surface_speed_drag": 0.018,
		"rolling_resistance": 2.8,
		"bump_amplitude_meters": 0.026,
		"bump_harmonics": Vector3i(23, 47, 83),
		"loose_surface": false,
	},
	BUMPY_ASPHALT: {
		"style": BUMPY_ASPHALT,
		"label": "BUMPY ASPHALT",
		"short_label": "BUMPY",
		"description": "Patched asphalt that works the suspension and rewards controlled steering.",
		"visual_effect": "asphalt_debris",
		"road_color": Color("444746"),
		"runoff_color": Color("8b8068"),
		"texture_tint": Color("a9aaa6"),
		"detail_dark_color": Color("202426"),
		"detail_light_color": Color("c2c4c0"),
		"visual_detail_strength": 0.96,
		"roughness": 1.0,
		"normal_scale": 1.18,
		"uv_repeats_per_meter": 0.38,
		"traction_multiplier": 0.82,
		"braking_multiplier": 0.80,
		"lateral_capacity_multiplier": 0.78,
		"lateral_grip_multiplier": 0.80,
		"ai_speed_factor": 0.83,
		"drive_efficiency_multiplier": 0.84,
		"surface_speed_drag": 0.032,
		"rolling_resistance": 4.0,
		"bump_amplitude_meters": 0.085,
		"bump_harmonics": Vector3i(29, 59, 101),
		"loose_surface": false,
	},
	COMPACT_GRAVEL: {
		"style": COMPACT_GRAVEL,
		"label": "COMPACT GRAVEL",
		"short_label": "GRAVEL",
		"description": "Fast hard-packed gravel with progressive slides, dust, and longer braking zones.",
		"visual_effect": "gravel_spray",
		"road_color": Color("82775e"),
		"runoff_color": Color("6f674f"),
		"texture_tint": Color("b9aa88"),
		"detail_dark_color": Color("5c503c"),
		"detail_light_color": Color("d8c18d"),
		"visual_detail_strength": 1.0,
		"roughness": 1.0,
		"normal_scale": 1.34,
		"uv_repeats_per_meter": 0.44,
		"traction_multiplier": 0.62,
		"braking_multiplier": 0.58,
		"lateral_capacity_multiplier": 0.60,
		"lateral_grip_multiplier": 0.62,
		# Gravel remains visibly slower, but the AI pace margin must account for
		# a full 12-car field entering a narrow alternating-apex section together.
		"ai_speed_factor": 0.66,
		"drive_efficiency_multiplier": 0.76,
		"surface_speed_drag": 0.050,
		"rolling_resistance": 7.0,
		"bump_amplitude_meters": 0.055,
		"bump_harmonics": Vector3i(31, 67, 109),
		"loose_surface": true,
	},
	MUD: {
		"style": MUD,
		"label": "MUD",
		"short_label": "MUD",
		"description": "Rutted wet mud with very low traction, heavy drag, clods, and dark wheel spray.",
		"visual_effect": "mud_clods_and_spray",
		"road_color": Color("463426"),
		"runoff_color": Color("5b4b37"),
		"texture_tint": Color("76583f"),
		"detail_dark_color": Color("2a1d15"),
		"detail_light_color": Color("755236"),
		"visual_detail_strength": 1.0,
		"roughness": 1.0,
		"normal_scale": 1.48,
		"uv_repeats_per_meter": 0.34,
		"traction_multiplier": 0.48,
		"braking_multiplier": 0.38,
		"lateral_capacity_multiplier": 0.42,
		"lateral_grip_multiplier": 0.45,
		"ai_speed_factor": 0.55,
		"drive_efficiency_multiplier": 0.70,
		"surface_speed_drag": 0.070,
		"rolling_resistance": 7.5,
		"bump_amplitude_meters": 0.065,
		"bump_harmonics": Vector3i(17, 41, 73),
		"loose_surface": true,
	},
}


static func is_supported(style: StringName) -> bool:
	return PROFILES.has(style)


static func sanitized_style(style: StringName) -> StringName:
	return style if is_supported(style) else SMOOTH_ASPHALT


static func profile(style: StringName) -> Dictionary:
	return PROFILES[sanitized_style(style)]


static func display_label(style: StringName, compact: bool = false) -> String:
	var values := profile(style)
	return str(values["short_label"] if compact else values["label"])


static func selection_labels(compact: bool = false) -> Array[String]:
	var labels: Array[String] = []
	for style in STYLES:
		labels.append(display_label(style, compact))
	return labels


static func style_at_index(index: int) -> StringName:
	return STYLES[clampi(index, 0, STYLES.size() - 1)]


static func style_index(style: StringName) -> int:
	var index := STYLES.find(sanitized_style(style))
	return maxi(index, 0)


static func bump_height_meters(
		style: StringName,
		distance_along: float,
		total_length: float,
		seed: int
	) -> float:
	var values := profile(style)
	var amplitude := float(values["bump_amplitude_meters"])
	if amplitude <= 0.0 or is_nan(distance_along) or is_inf(distance_along) \
			or is_nan(total_length) or is_inf(total_length) or total_length <= 0.0:
		return 0.0
	# Integer lap harmonics guarantee an exact closed seam. The seed only shifts
	# phase, so every client and replay sees the same bounded suspension input.
	var phase := TAU * float(posmod(seed, 4093)) / 4093.0
	var progress := fposmod(distance_along, total_length) / total_length
	var harmonics: Vector3i = values["bump_harmonics"]
	var wave := (
		sin(TAU * progress * float(harmonics.x) + phase) * 0.52
		+ sin(TAU * progress * float(harmonics.y) + phase * 1.71) * 0.31
		+ sin(TAU * progress * float(harmonics.z) - phase * 0.63) * 0.17
	)
	return clampf(wave * amplitude, -amplitude, amplitude)
