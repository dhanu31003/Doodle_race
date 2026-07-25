class_name TrackMeshBuilder3D
extends RefCounted
## Deterministic, presentation-only circuit mesh generation. The builder reads
## RaceTrackQuery but never changes race authority or creates physics bodies.

const Mapper := preload("res://game/presentation3d/world_coordinate_mapper.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")
const ROAD_SURFACE_SHADER: Shader = preload(
	"res://game/presentation3d/shaders/road_surface.gdshader"
)

const DEFAULT_SAMPLE_STEP_AUTHORITY: float = 6.0
const MIN_SAMPLE_STEP_AUTHORITY: float = 1.0
const MAX_SAMPLE_STEP_AUTHORITY: float = 24.0
const MIN_SEGMENTS: int = 24
const MAX_SEGMENTS: int = 4096

const RUNOFF_MINIMUM_WIDTH_METERS: float = 3.2
const RUNOFF_TRACK_WIDTH_FACTOR: float = 0.26
const CURB_WIDTH_METERS: float = 0.56
const EDGE_LINE_WIDTH_METERS: float = 0.14
const EDGE_LINE_INSET_METERS: float = 0.06
const KERB_STRIPE_LENGTH_METERS: float = 2.4

const ASPHALT_DIFFUSE_TEXTURE_PATH := \
		"res://assets/final/3d/materials/clean_asphalt_diff_1k.jpg"
const ASPHALT_NORMAL_TEXTURE_PATH := \
		"res://assets/final/3d/materials/clean_asphalt_nor_gl_1k.jpg"
const ASPHALT_TEXTURE_REPEATS_PER_METER: float = 0.25
const ASPHALT_TEXTURE_TINT := Color("e7eaed")
const ASPHALT_TEXTURE_ROUGHNESS: float = 0.94
const ASPHALT_NORMAL_SCALE: float = 0.52

const RUNOFF_Y_OFFSET_METERS: float = 0.015
const ASPHALT_Y_OFFSET_METERS: float = Mapper.ROAD_SURFACE_Y_METERS
const KERB_Y_OFFSET_METERS: float = 0.055
const EDGE_LINE_Y_OFFSET_METERS: float = 0.062

const ASPHALT_COLOR := Color("292f36")
const RUNOFF_COLOR := Color("8e896a")
const KERB_LIGHT_COLOR := Color("f3f3ec")
const KERB_RED_COLOR := Color("df394b")
const EDGE_LINE_COLOR := Color("f5f5ed")


static func build(track: RaceTrackQuery, options: Dictionary = {}) -> Dictionary:
	if track == null or not track.is_valid():
		return _failure(&"track_invalid", "A valid RaceTrackQuery is required.")
	var requested_step := _numeric(
		options.get("sample_step_authority", DEFAULT_SAMPLE_STEP_AUTHORITY),
		DEFAULT_SAMPLE_STEP_AUTHORITY
	)
	var sample_step := clampf(
		requested_step, MIN_SAMPLE_STEP_AUTHORITY, MAX_SAMPLE_STEP_AUTHORITY
	)
	var mobile_surface_budget := bool(options.get("mobile_surface_budget", false))
	var segment_count := clampi(
		ceili(track.total_length / sample_step), MIN_SEGMENTS, MAX_SEGMENTS
	)
	if segment_count <= 0:
		return _failure(&"segment_count_invalid", "The circuit has no meshable segments.")
	var exact_step := track.total_length / float(segment_count)
	var surface_profile := track.surface_profile()
	var road_color: Color = surface_profile.get("road_color", ASPHALT_COLOR)
	var runoff_color: Color = surface_profile.get("runoff_color", RUNOFF_COLOR)
	var texture_repeats := float(surface_profile.get(
		"uv_repeats_per_meter", ASPHALT_TEXTURE_REPEATS_PER_METER
	))
	var road_half_width_m := track.track_width * 0.5 * Mapper.WORLD_UNIT_TO_METERS
	var runoff_width_m := maxf(
		RUNOFF_MINIMUM_WIDTH_METERS,
		track.track_width * Mapper.WORLD_UNIT_TO_METERS * RUNOFF_TRACK_WIDTH_FACTOR
	)
	var outer_half_width_m := road_half_width_m + CURB_WIDTH_METERS + runoff_width_m

	var runoff := _build_smooth_ribbon(
		track, segment_count, exact_step,
		outer_half_width_m, -outer_half_width_m,
		RUNOFF_Y_OFFSET_METERS, runoff_color, 0.055
	)
	var asphalt := _build_smooth_ribbon(
		track, segment_count, exact_step,
		road_half_width_m, -road_half_width_m,
		ASPHALT_Y_OFFSET_METERS, road_color,
		texture_repeats
	)
	var kerbs := _build_kerb_ribbons(
		track, segment_count, exact_step, road_half_width_m
	)
	var edge_lines := _build_edge_line_ribbons(
		track, segment_count, exact_step, road_half_width_m
	)

	var mesh := ArrayMesh.new()
	var surface_stats: Array[Dictionary] = []
	surface_stats.append(_append_surface(
		mesh, "runoff", runoff, _standard_material(runoff_color, false, 0.96)
	))
	surface_stats.append(_append_surface(
		mesh, "asphalt", asphalt, _road_surface_material(
			surface_profile, road_half_width_m * 2.0, texture_repeats,
			mobile_surface_budget
		)
	))
	surface_stats.append(_append_surface(
		mesh, "kerbs", kerbs, _standard_material(Color.WHITE, true, 0.78)
	))
	surface_stats.append(_append_surface(
		mesh, "edge_lines", edge_lines,
		_standard_material(EDGE_LINE_COLOR, false, 0.74)
	))

	if mesh.get_surface_count() != 4:
		return _failure(&"surface_build_failed", "The complete circuit mesh could not be created.")
	var asphalt_vertices: PackedVector3Array = asphalt["vertices"]
	var elevation_range := _vertical_range(asphalt_vertices)
	var total_vertices := 0
	var total_triangles := 0
	for surface in surface_stats:
		total_vertices += int(surface["vertices"])
		total_triangles += int(surface["triangles"])
	var seam_error := 0.0
	if asphalt_vertices.size() >= 4:
		seam_error = maxf(
			asphalt_vertices[0].distance_to(asphalt_vertices[-2]),
			asphalt_vertices[1].distance_to(asphalt_vertices[-1])
		)
	var transforms := Mapper.static_root_transforms()
	return {
		"ok": true,
		"mesh": mesh,
		"stats": {
			"road_surface": str(track.road_surface),
			"road_surface_label": RoadSurfaceCatalogType.display_label(track.road_surface),
			"mobile_surface_budget": mobile_surface_budget,
			"segment_count": segment_count,
			"sample_step_authority": exact_step,
			"lap_length_authority": track.total_length,
			"lap_length_meters": track.total_length * Mapper.WORLD_UNIT_TO_METERS,
			"road_width_meters": track.track_width * Mapper.WORLD_UNIT_TO_METERS,
			"runoff_width_each_side_meters": runoff_width_m,
			"outer_width_meters": outer_half_width_m * 2.0,
			"surface_count": mesh.get_surface_count(),
			"surfaces": surface_stats,
			"vertices": total_vertices,
			"triangles": total_triangles,
			"closed_seam_error_meters": seam_error,
			"minimum_surface_y_meters": elevation_range.x,
			"maximum_surface_y_meters": elevation_range.y,
			"static_transforms": transforms,
		},
		"static_transforms": transforms,
	}


static func static_root_transforms() -> Dictionary:
	return Mapper.static_root_transforms()


static func _build_smooth_ribbon(
		track: RaceTrackQuery,
		segment_count: int,
		exact_step: float,
		left_offset_m: float,
		right_offset_m: float,
		vertical_offset_m: float,
		color: Color,
		uv_repeats_per_meter: float
	) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	var indices := PackedInt32Array()
	vertices.resize((segment_count + 1) * 2)
	normals.resize(vertices.size())
	colors.resize(vertices.size())
	uvs.resize(vertices.size())
	tangents.resize(vertices.size() * 4)
	var transverse_uv_span := absf(left_offset_m - right_offset_m) \
			* uv_repeats_per_meter
	for sample_index in segment_count + 1:
		var distance := exact_step * float(sample_index)
		var sample := track.sample_at_distance(distance)
		var center := Mapper.authority_position_to_world(
			sample.get("position", Vector2.ZERO),
			float(sample.get("elevation_level", 0.0)),
			vertical_offset_m
		)
		var left_direction := Mapper.authority_direction_to_world(
			sample.get("normal", Vector2.UP)
		)
		var normal := _surface_normal(track, distance, exact_step)
		var tangent := -left_direction
		tangent = (tangent - normal * tangent.dot(normal)).normalized()
		if tangent.length_squared() <= 0.0000001:
			tangent = Vector3.RIGHT
		var vertex_index := sample_index * 2
		vertices[vertex_index] = center + left_direction * left_offset_m
		vertices[vertex_index + 1] = center + left_direction * right_offset_m
		normals[vertex_index] = normal
		normals[vertex_index + 1] = normal
		_set_tangent(tangents, vertex_index, tangent)
		_set_tangent(tangents, vertex_index + 1, tangent)
		colors[vertex_index] = color
		colors[vertex_index + 1] = color
		var longitudinal_uv := distance * Mapper.WORLD_UNIT_TO_METERS \
				* uv_repeats_per_meter
		uvs[vertex_index] = Vector2(0.0, longitudinal_uv)
		uvs[vertex_index + 1] = Vector2(transverse_uv_span, longitudinal_uv)
	for segment_index in segment_count:
		var start_left := segment_index * 2
		var start_right := start_left + 1
		var finish_left := (segment_index + 1) * 2
		var finish_right := finish_left + 1
		# Godot treats clockwise triangles as front-facing. Order the top surface
		# so its renderer-facing normal agrees with the stored upward normal.
		indices.append_array(PackedInt32Array([
			start_left, finish_right, finish_left,
			start_left, start_right, finish_right,
		]))
	return {
		"vertices": vertices,
		"normals": normals,
		"colors": colors,
		"uvs": uvs,
		"tangents": tangents,
		"indices": indices,
	}


static func _build_kerb_ribbons(
		track: RaceTrackQuery,
		segment_count: int,
		exact_step: float,
		road_half_width_m: float
	) -> Dictionary:
	var data := _empty_surface_data()
	for segment_index in segment_count:
		var start_distance := exact_step * float(segment_index)
		var finish_distance := exact_step * float(segment_index + 1)
		var stripe_index := floori(
			start_distance * Mapper.WORLD_UNIT_TO_METERS / KERB_STRIPE_LENGTH_METERS
		)
		var color := KERB_RED_COLOR if stripe_index % 2 == 0 else KERB_LIGHT_COLOR
		_append_segment_quad(
			data, track, start_distance, finish_distance,
			road_half_width_m + CURB_WIDTH_METERS, road_half_width_m,
			KERB_Y_OFFSET_METERS, color
		)
		_append_segment_quad(
			data, track, start_distance, finish_distance,
			-road_half_width_m, -road_half_width_m - CURB_WIDTH_METERS,
			KERB_Y_OFFSET_METERS, color
		)
	return data


static func _build_edge_line_ribbons(
		track: RaceTrackQuery,
		segment_count: int,
		exact_step: float,
		road_half_width_m: float
	) -> Dictionary:
	var data := _empty_surface_data()
	var outer_edge := road_half_width_m - EDGE_LINE_INSET_METERS
	var inner_edge := outer_edge - EDGE_LINE_WIDTH_METERS
	for segment_index in segment_count:
		var start_distance := exact_step * float(segment_index)
		var finish_distance := exact_step * float(segment_index + 1)
		_append_segment_quad(
			data, track, start_distance, finish_distance,
			outer_edge, inner_edge, EDGE_LINE_Y_OFFSET_METERS, EDGE_LINE_COLOR
		)
		_append_segment_quad(
			data, track, start_distance, finish_distance,
			-inner_edge, -outer_edge, EDGE_LINE_Y_OFFSET_METERS, EDGE_LINE_COLOR
		)
	return data


static func _append_segment_quad(
		data: Dictionary,
		track: RaceTrackQuery,
		start_distance: float,
		finish_distance: float,
		left_offset_m: float,
		right_offset_m: float,
		vertical_offset_m: float,
		color: Color
	) -> void:
	var start_sample := track.sample_at_distance(start_distance)
	var finish_sample := track.sample_at_distance(finish_distance)
	var start_center := Mapper.authority_position_to_world(
		start_sample.get("position", Vector2.ZERO),
		float(start_sample.get("elevation_level", 0.0)), vertical_offset_m
	)
	var finish_center := Mapper.authority_position_to_world(
		finish_sample.get("position", Vector2.ZERO),
		float(finish_sample.get("elevation_level", 0.0)), vertical_offset_m
	)
	var start_left_direction := Mapper.authority_direction_to_world(
		start_sample.get("normal", Vector2.UP)
	)
	var finish_left_direction := Mapper.authority_direction_to_world(
		finish_sample.get("normal", Vector2.UP)
	)
	var normal := _surface_normal(
		track, (start_distance + finish_distance) * 0.5,
		maxf(finish_distance - start_distance, 0.001)
	)
	var vertices: PackedVector3Array = data["vertices"]
	var normals: PackedVector3Array = data["normals"]
	var colors: PackedColorArray = data["colors"]
	var uvs: PackedVector2Array = data["uvs"]
	var indices: PackedInt32Array = data["indices"]
	var base := vertices.size()
	vertices.append(start_center + start_left_direction * left_offset_m)
	vertices.append(finish_center + finish_left_direction * left_offset_m)
	vertices.append(finish_center + finish_left_direction * right_offset_m)
	vertices.append(start_center + start_left_direction * right_offset_m)
	for _index in 4:
		normals.append(normal)
		colors.append(color)
	uvs.append_array(PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(0.0, 1.0),
		Vector2(1.0, 1.0), Vector2(1.0, 0.0),
	]))
	indices.append_array(PackedInt32Array([
		base, base + 2, base + 1,
		base, base + 3, base + 2,
	]))


static func _surface_normal(
		track: RaceTrackQuery,
		distance: float,
		step: float
	) -> Vector3:
	var probe := maxf(step * 0.5, 0.1)
	var previous := track.sample_at_distance(distance - probe)
	var following := track.sample_at_distance(distance + probe)
	var previous_center := Mapper.authority_position_to_world(
		previous.get("position", Vector2.ZERO),
		float(previous.get("elevation_level", 0.0))
	)
	var following_center := Mapper.authority_position_to_world(
		following.get("position", Vector2.ZERO),
		float(following.get("elevation_level", 0.0))
	)
	var tangent := (following_center - previous_center).normalized()
	var center_sample := track.sample_at_distance(distance)
	var left := Mapper.authority_direction_to_world(
		center_sample.get("normal", Vector2.UP)
	)
	var right := -left
	var normal := tangent.cross(right).normalized()
	if normal.length_squared() <= 0.0000001:
		return Vector3.UP
	if normal.y < 0.0:
		normal = -normal
	return normal


static func _append_surface(
		mesh: ArrayMesh,
		name: String,
		data: Dictionary,
		material: Material
	) -> Dictionary:
	var vertices: PackedVector3Array = data["vertices"]
	var indices: PackedInt32Array = data["indices"]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_COLOR] = data["colors"]
	arrays[Mesh.ARRAY_TEX_UV] = data["uvs"]
	var tangents: PackedFloat32Array = data.get("tangents", PackedFloat32Array())
	if not tangents.is_empty():
		arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var surface_index := mesh.get_surface_count() - 1
	mesh.surface_set_name(surface_index, name)
	mesh.surface_set_material(surface_index, material)
	return {
		"name": name,
		"vertices": vertices.size(),
		"triangles": indices.size() / 3,
		"aabb": _vertices_aabb(vertices),
	}


static func _empty_surface_data() -> Dictionary:
	return {
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"colors": PackedColorArray(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),
	}


static func _standard_material(
		color: Color,
		use_vertex_color: bool,
		roughness: float
	) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.0
	material.vertex_color_use_as_albedo = use_vertex_color
	return material



static func _asphalt_material(
		diffuse_path: String = ASPHALT_DIFFUSE_TEXTURE_PATH,
		normal_path: String = ASPHALT_NORMAL_TEXTURE_PATH,
		profile: Dictionary = {}
	) -> StandardMaterial3D:
	var road_color: Color = profile.get("road_color", ASPHALT_COLOR)
	var material_roughness := float(profile.get("roughness", ASPHALT_TEXTURE_ROUGHNESS))
	var material := _standard_material(
		road_color, false, material_roughness
	)
	material.texture_repeat = true
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var diffuse := _load_texture(diffuse_path)
	if diffuse != null:
		material.albedo_color = profile.get("texture_tint", ASPHALT_TEXTURE_TINT)
		material.albedo_texture = diffuse
	var normal := _load_texture(normal_path)
	if normal != null:
		material.normal_enabled = true
		material.normal_scale = float(profile.get("normal_scale", ASPHALT_NORMAL_SCALE))
		material.normal_texture = normal
	return material


static func _road_surface_material(
		profile: Dictionary,
		road_width_meters: float,
		texture_repeats_per_meter: float,
		mobile_surface_budget: bool = false
	) -> Material:
	var diffuse := _load_texture(ASPHALT_DIFFUSE_TEXTURE_PATH)
	var normal := _load_texture(ASPHALT_NORMAL_TEXTURE_PATH)
	if diffuse == null or normal == null or ROAD_SURFACE_SHADER == null:
		return _asphalt_material(
			ASPHALT_DIFFUSE_TEXTURE_PATH,
			ASPHALT_NORMAL_TEXTURE_PATH,
			profile
		)
	var material := ShaderMaterial.new()
	material.shader = ROAD_SURFACE_SHADER
	material.set_shader_parameter("road_albedo", diffuse)
	material.set_shader_parameter("road_normal", normal)
	material.set_shader_parameter("base_tint", profile.get(
		"texture_tint", ASPHALT_TEXTURE_TINT
	))
	material.set_shader_parameter("dark_tint", profile.get(
		"detail_dark_color", Color("343b40")
	))
	material.set_shader_parameter("light_tint", profile.get(
		"detail_light_color", Color("e8ecee")
	))
	material.set_shader_parameter(
		"road_uv_width",
		maxf(road_width_meters * texture_repeats_per_meter, 0.1)
	)
	material.set_shader_parameter("roughness_value", float(profile.get(
		"roughness", ASPHALT_TEXTURE_ROUGHNESS
	)))
	material.set_shader_parameter("normal_strength", float(profile.get(
		"normal_scale", ASPHALT_NORMAL_SCALE
	)))
	material.set_shader_parameter("detail_strength", float(profile.get(
		"visual_detail_strength", 0.0
	)))
	var style := StringName(str(profile.get("style", "")))
	material.set_shader_parameter("surface_style", RoadSurfaceCatalogType.style_index(style))
	material.set_shader_parameter("mobile_surface_budget", mobile_surface_budget)
	return material


static func _load_texture(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path, "Texture2D"):
		return null
	return ResourceLoader.load(path, "Texture2D") as Texture2D


static func _set_tangent(
		tangents: PackedFloat32Array,
		vertex_index: int,
		tangent: Vector3
	) -> void:
	var offset := vertex_index * 4
	tangents[offset] = tangent.x
	tangents[offset + 1] = tangent.y
	tangents[offset + 2] = tangent.z
	tangents[offset + 3] = 1.0


static func _vertices_aabb(vertices: PackedVector3Array) -> AABB:
	if vertices.is_empty():
		return AABB()
	var bounds := AABB(vertices[0], Vector3.ZERO)
	for index in range(1, vertices.size()):
		bounds = bounds.expand(vertices[index])
	return bounds


static func _vertical_range(vertices: PackedVector3Array) -> Vector2:
	if vertices.is_empty():
		return Vector2.ZERO
	var minimum := vertices[0].y
	var maximum := vertices[0].y
	for vertex in vertices:
		minimum = minf(minimum, vertex.y)
		maximum = maxf(maximum, vertex.y)
	return Vector2(minimum, maximum)


static func _failure(code: StringName, message: String) -> Dictionary:
	return {
		"ok": false,
		"error": {"code": str(code), "message": message},
		"mesh": null,
		"stats": {},
		"static_transforms": Mapper.static_root_transforms(),
	}


static func _numeric(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	var parsed := float(value)
	return fallback if is_nan(parsed) or is_inf(parsed) else parsed
