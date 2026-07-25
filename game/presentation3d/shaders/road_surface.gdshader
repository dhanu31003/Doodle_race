shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D road_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D road_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 base_tint : source_color = vec4(0.9, 0.92, 0.93, 1.0);
uniform vec4 dark_tint : source_color = vec4(0.12, 0.14, 0.15, 1.0);
uniform vec4 light_tint : source_color = vec4(0.72, 0.74, 0.74, 1.0);
uniform float road_uv_width = 4.0;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.94;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.5;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.0;
uniform int surface_style = 0;
uniform bool mobile_surface_budget = false;


float surface_hash(vec2 cell) {
	return fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453123);
}


float value_noise(vec2 position) {
	vec2 cell = floor(position);
	vec2 local_position = fract(position);
	vec2 blend = local_position * local_position * (3.0 - 2.0 * local_position);
	float a = surface_hash(cell);
	float b = surface_hash(cell + vec2(1.0, 0.0));
	float c = surface_hash(cell + vec2(0.0, 1.0));
	float d = surface_hash(cell + vec2(1.0, 1.0));
	return mix(mix(a, b, blend.x), mix(c, d, blend.x), blend.y);
}


float organic_noise(vec2 position) {
	return value_noise(position) * 0.62
		+ value_noise(position * 2.07 + vec2(13.7, 5.1)) * 0.27
		+ value_noise(position * 4.13 + vec2(3.4, 17.9)) * 0.11;
}


void fragment() {
	vec3 source = texture(road_albedo, UV).rgb;
	vec3 color = source * base_tint.rgb;
	float lateral = clamp(UV.x / max(road_uv_width, 0.001), 0.0, 1.0);
	float along = UV.y;
	float local_roughness = roughness_value;
	float local_normal_strength = normal_strength;

	if (surface_style == 1) {
		// Worn wet asphalt: organic dark water film, faded aggregate and thin,
		// irregular sealed cracks. No rectangular tiles or bright white patches.
		vec2 weather_position = vec2(lateral * 7.0, along * 0.72);
		float weather = organic_noise(weather_position);
		float wet_pool = smoothstep(0.66, 0.82, organic_noise(weather_position * 0.57 + 8.0));
		float crack_field = value_noise(vec2(lateral * 17.0, along * 1.55));
		float crack = 1.0 - smoothstep(0.018, 0.065, abs(crack_field - 0.50));
		color = mix(color * (0.82 + weather * 0.13), dark_tint.rgb, wet_pool * 0.42 * detail_strength);
		color = mix(color, dark_tint.rgb * 0.72, crack * 0.48 * detail_strength);
		local_roughness = mix(local_roughness, 0.48, wet_pool * detail_strength);
	} else if (surface_style == 2) {
		// Bumpy asphalt uses dark, softly eroded repair islands and branching
		// cracks. Everything stays within asphalt values—never white checkerboards.
		vec2 bump_position = vec2(lateral * 5.8, along * 0.48);
		float broad = organic_noise(bump_position);
		float repair = smoothstep(0.50, 0.66, broad) * (1.0 - smoothstep(0.84, 0.94, broad));
		float broken_edge = organic_noise(bump_position * 2.35 + vec2(9.0, 2.0));
		repair *= smoothstep(0.25, 0.54, broken_edge);
		float crack_field = value_noise(vec2(lateral * 23.0, along * 1.35) + broad * 3.0);
		float crack = 1.0 - smoothstep(0.014, 0.052, abs(crack_field - 0.50));
		color = mix(color * (0.88 + broad * 0.10), dark_tint.rgb * 0.78, repair * 0.82 * detail_strength);
		color = mix(color, dark_tint.rgb * 0.55, crack * 0.56 * detail_strength);
		local_normal_strength *= 1.26;
	} else if (surface_style == 3) {
		// Compact gravel is granular at two scales with packed wheel lanes.
		vec2 gravel_position = vec2(lateral * 31.0, along * 5.2);
		float aggregate = organic_noise(gravel_position);
		float packed_lanes = max(
			1.0 - smoothstep(0.055, 0.14, abs(lateral - 0.34)),
			1.0 - smoothstep(0.055, 0.14, abs(lateral - 0.66))
		);
		vec3 gravel = mix(dark_tint.rgb, light_tint.rgb, 0.18 + aggregate * 0.66);
		gravel = mix(gravel, dark_tint.rgb * 0.88, packed_lanes * 0.16);
		color = mix(color, gravel, 0.94 * detail_strength);
		local_normal_strength *= 1.28;
	} else if (surface_style == 4) {
		float soil = 0.0;
		float wet_field = 0.0;
		float rut_wobble = 0.0;
		if (mobile_surface_budget) {
			// Two arithmetic fields preserve broken soil, ruts and damp patches
			// without procedural hash, sine or interpolated-noise work per pixel.
			float soil_a = abs(fract(along * 0.071 + lateral * 1.73) - 0.5) * 2.0;
			float soil_b = abs(fract(along * 0.113 - lateral * 2.31 + 0.37) - 0.5) * 2.0;
			soil = clamp(soil_a * 0.58 + soil_b * 0.42, 0.0, 1.0);
			wet_field = 1.0 - abs(soil_a - soil_b);
			rut_wobble = (soil_b - 0.5) * 0.030;
			local_normal_strength = 0.0;
		} else {
			// Desktop needs only two shared noise fields, rather than the former
			// nine value-noise evaluations spread across three organic stacks.
			vec2 mud_position = vec2(lateral * 7.5, along * 0.82);
			soil = value_noise(mud_position);
			wet_field = value_noise(mud_position * 0.61 + vec2(4.0, 15.0));
			rut_wobble = sin(along * 1.7 + wet_field * 4.0) * 0.018;
			local_normal_strength *= 1.34;
		}
		color = mix(dark_tint.rgb, light_tint.rgb, 0.12 + soil * 0.54);
		float rut_distance = min(
			abs(lateral - (0.33 + rut_wobble)),
			abs(lateral - (0.67 - rut_wobble))
		);
		float ruts = 1.0 - smoothstep(0.026, 0.075, rut_distance);
		float puddle = smoothstep(0.67, 0.82, wet_field);
		color = mix(color, dark_tint.rgb * 0.56, ruts * (0.68 + puddle * 0.22) * detail_strength);
		color = mix(color, vec3(0.025, 0.032, 0.030), puddle * 0.46 * detail_strength);
		local_roughness = mix(local_roughness, 0.42, puddle * detail_strength);
	}

	ALBEDO = color;
	ROUGHNESS = clamp(local_roughness, 0.0, 1.0);
	METALLIC = 0.0;
	if (mobile_surface_budget && surface_style == 4) {
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
	} else {
		NORMAL_MAP = texture(road_normal, UV).rgb;
	}
	NORMAL_MAP_DEPTH = local_normal_strength;
}
