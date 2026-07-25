extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const Mapper := preload("res://game/presentation3d/world_coordinate_mapper.gd")
const Builder := preload("res://game/presentation3d/track_mesh_builder_3d.gd")
const Catalog := preload("res://game/content/predefined_track_catalog.gd")
const Compiler := preload("res://game/track/generation/track_compiler.gd")
const TrackQuery := preload("res://game/race/track_query.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	_test_coordinate_contract(test)
	_test_invalid_track_contract(test)
	_test_closed_flat_track_mesh(test)
	_test_surface_material_profiles(test)
	_test_bridge_elevation_mesh(test)
	await process_frame
	var result: Dictionary = test.result("presentation_3d_track_mesh")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _test_coordinate_contract(test: RefCounted) -> void:
	test.assert_near(
		Mapper.authority_scalar_to_meters(10.0), 3.0, 0.000001,
		"authority scalar conversion uses the shared 0.30 metre scale"
	)
	test.assert_near(
		Mapper.bridge_height_units_to_meters(6000.0), 6.0, 0.000001,
		"bridge fixed units are explicitly converted from millimetres"
	)
	test.assert_near(
		Mapper.elevation_level_to_meters(0.5), 3.0, 0.000001,
		"normalized bridge elevation maps to physical metres"
	)
	var mapped := Mapper.authority_position_to_world(Vector2(10.0, -5.0), 0.5, 0.04)
	test.assert_near(mapped.x, 3.0, 0.000001, "authority X maps to world X")
	test.assert_near(mapped.y, 3.04, 0.000001, "elevation and ride offset map to world Y")
	test.assert_near(mapped.z, -1.5, 0.000001, "authority Y maps to world Z")
	var east := Mapper.authority_transform(Vector2.ZERO, 0.0).basis * Vector3.RIGHT
	var south := Mapper.authority_transform(Vector2.ZERO, PI * 0.5).basis * Vector3.RIGHT
	var west := Mapper.authority_transform(Vector2.ZERO, PI).basis * Vector3.RIGHT
	test.assert_near(east.distance_to(Vector3.RIGHT), 0.0, 0.000001, "zero heading faces world +X")
	test.assert_near(south.distance_to(Vector3(0.0, 0.0, 1.0)), 0.0, 0.000001, "positive quarter turn faces world +Z")
	test.assert_near(west.distance_to(Vector3.LEFT), 0.0, 0.000001, "half turn faces world -X")
	var roots := Mapper.static_root_transforms()
	test.assert_equal(roots["track_root"], Transform3D.IDENTITY, "track root remains fixed in world space")
	test.assert_equal(roots["scenery_root"], Transform3D.IDENTITY, "scenery root remains fixed in world space")


func _test_invalid_track_contract(test: RefCounted) -> void:
	var invalid := TrackQuery.new()
	var result := Builder.build(invalid)
	test.assert_false(bool(result.get("ok", true)), "invalid race queries fail closed")
	test.assert_equal(
		str(result.get("error", {}).get("code", "")), "track_invalid",
		"invalid race query exposes a stable error code"
	)
	test.assert_equal(
		result.get("static_transforms", {}).get("track_root"), Transform3D.IDENTITY,
		"failure still preserves the fixed-world transform contract"
	)
	invalid = null
	result.clear()


func _test_closed_flat_track_mesh(test: RefCounted) -> void:
	var fixture := _compiled_query("builtin-evergreen-oval")
	test.assert_true(bool(fixture.get("valid", false)), "flat 3D mesh fixture compiles")
	if not bool(fixture.get("valid", false)):
		return
	var query: RaceTrackQuery = fixture["query"]
	var centerline_before := query.centerline.duplicate()
	var total_length_before := query.total_length
	var first := Builder.build(query)
	var repeated := Builder.build(query)
	test.assert_true(bool(first.get("ok", false)), "valid flat track builds a 3D mesh")
	test.assert_true(bool(repeated.get("ok", false)), "same flat track rebuild succeeds deterministically")
	if not bool(first.get("ok", false)) or not bool(repeated.get("ok", false)):
		return
	var mesh: ArrayMesh = first["mesh"]
	var repeated_mesh: ArrayMesh = repeated["mesh"]
	var stats: Dictionary = first["stats"]
	var segment_count := int(stats["segment_count"])
	test.assert_equal(mesh.get_surface_count(), 4, "track mesh exposes four material surfaces")
	var expected_names := ["runoff", "asphalt", "kerbs", "edge_lines"]
	for surface_index in expected_names.size():
		test.assert_equal(
			mesh.surface_get_name(surface_index), expected_names[surface_index],
			"track mesh surface order is stable: %s" % expected_names[surface_index]
		)
	test.assert_equal(int(stats["surface_count"]), 4, "inspectable stats report every surface")
	test.assert_equal(int(stats["triangles"]), segment_count * 12, "triangle budget is exact and bounded")
	test.assert_equal(int(stats["vertices"]), segment_count * 20 + 4, "vertex budget is exact and bounded")
	test.assert_true(
		_all_surface_front_faces_match_normals(mesh),
		"Godot-clockwise triangle fronts agree with stored upward surface normals"
	)
	test.assert_near(
		float(stats["closed_seam_error_meters"]), 0.0, 0.00001,
		"asphalt ribbon closes without a spatial seam"
	)
	test.assert_true(
		float(stats["outer_width_meters"]) > float(stats["road_width_meters"]),
		"runoff construction is wider than the asphalt road"
	)
	test.assert_near(
		float(stats["minimum_surface_y_meters"]), Mapper.ROAD_SURFACE_Y_METERS,
		0.00001, "flat asphalt rests at the canonical road height"
	)
	test.assert_near(
		float(stats["maximum_surface_y_meters"]), Mapper.ROAD_SURFACE_Y_METERS,
		0.00001, "flat asphalt has no invented elevation"
	)
	test.assert_equal(query.centerline, centerline_before, "mesh generation does not mutate track geometry")
	test.assert_near(query.total_length, total_length_before, 0.000001, "mesh generation does not mutate lap authority")
	var asphalt_arrays: Array = mesh.surface_get_arrays(1)
	var repeated_asphalt_arrays: Array = repeated_mesh.surface_get_arrays(1)
	var asphalt_vertices: PackedVector3Array = asphalt_arrays[Mesh.ARRAY_VERTEX]
	var asphalt_normals: PackedVector3Array = asphalt_arrays[Mesh.ARRAY_NORMAL]
	var asphalt_uvs: PackedVector2Array = asphalt_arrays[Mesh.ARRAY_TEX_UV]
	var asphalt_tangents: PackedFloat32Array = asphalt_arrays[Mesh.ARRAY_TANGENT]
	test.assert_equal(
		asphalt_vertices, repeated_asphalt_arrays[Mesh.ARRAY_VERTEX],
		"same authority produces byte-stable asphalt vertices"
	)
	test.assert_near(
		asphalt_vertices[0].distance_to(asphalt_vertices[-2]), 0.0, 0.00001,
		"left asphalt edge closes exactly"
	)
	test.assert_near(
		asphalt_vertices[1].distance_to(asphalt_vertices[-1]), 0.0, 0.00001,
		"right asphalt edge closes exactly"
	)
	var upward_normals := true
	for normal in asphalt_normals:
		if normal.y < 0.94 or is_nan(normal.y) or is_inf(normal.y):
			upward_normals = false
			break
	test.assert_true(upward_normals, "flat circuit normals are finite and upward-facing")
	var maximum_uv := Vector2.ZERO
	for uv in asphalt_uvs:
		maximum_uv.x = maxf(maximum_uv.x, uv.x)
		maximum_uv.y = maxf(maximum_uv.y, uv.y)
	test.assert_true(
		maximum_uv.x > 1.0 and maximum_uv.y > 1.0,
		"asphalt UVs tile in physical metres across and along the circuit"
	)
	test.assert_equal(
		asphalt_tangents.size(), asphalt_vertices.size() * 4,
		"asphalt provides one complete tangent for every normal-mapped vertex"
	)
	var runoff_aabb: AABB = stats["surfaces"][0]["aabb"]
	var asphalt_aabb: AABB = stats["surfaces"][1]["aabb"]
	test.assert_true(
		runoff_aabb.size.x >= asphalt_aabb.size.x and runoff_aabb.size.z >= asphalt_aabb.size.z,
		"runoff bounds enclose the asphalt footprint"
	)
	var kerb_material := mesh.surface_get_material(2) as StandardMaterial3D
	test.assert_true(
		kerb_material != null and kerb_material.vertex_color_use_as_albedo,
		"kerb surface consumes deterministic red/white vertex colors"
	)
	var asphalt_material := mesh.surface_get_material(1)
	test.assert_true(asphalt_material != null, "asphalt surface owns a complete 3D material")
	var diffuse_available := ResourceLoader.exists(
		Builder.ASPHALT_DIFFUSE_TEXTURE_PATH, "Texture2D"
	)
	var normal_available := ResourceLoader.exists(
		Builder.ASPHALT_NORMAL_TEXTURE_PATH, "Texture2D"
	)
	if asphalt_material is ShaderMaterial:
		var surface_shader := asphalt_material as ShaderMaterial
		test.assert_true(
			surface_shader.get_shader_parameter("road_albedo") != null,
			"released road shader receives the imported diffuse texture"
		)
		test.assert_true(
			surface_shader.get_shader_parameter("road_normal") != null,
			"released road shader receives the imported normal texture"
		)
		test.assert_equal(
			int(surface_shader.get_shader_parameter("surface_style")), 0,
			"smooth asphalt selects the clean shader branch"
		)
		test.assert_near(
			float(surface_shader.get_shader_parameter("roughness_value")),
			Builder.ASPHALT_TEXTURE_ROUGHNESS,
			0.000001, "smooth asphalt retains a dry, physically plausible roughness"
		)
	elif asphalt_material is StandardMaterial3D:
		var fallback_road := asphalt_material as StandardMaterial3D
		test.assert_equal(
			fallback_road.albedo_texture != null, diffuse_available,
			"fallback asphalt diffuse follows import availability"
		)
		test.assert_equal(
			fallback_road.normal_texture != null, normal_available,
			"fallback asphalt normal follows import availability"
		)
	var fallback_material := Builder._asphalt_material(
		"res://tests/presentation3d/missing_asphalt_diffuse.jpg",
		"res://tests/presentation3d/missing_asphalt_normal.jpg"
	)
	test.assert_true(
		fallback_material.albedo_texture == null,
		"missing asphalt diffuse keeps the deterministic color fallback"
	)
	test.assert_true(
		not fallback_material.normal_enabled and fallback_material.normal_texture == null,
		"missing asphalt normal disables normal mapping without an error"
	)
	test.assert_equal(
		first["static_transforms"]["track_root"], Transform3D.IDENTITY,
		"built track root remains static"
	)
	test.assert_equal(
		first["static_transforms"]["scenery_root"], Transform3D.IDENTITY,
		"built scenery root remains static"
	)
	first.clear()
	repeated.clear()
	fixture.clear()


func _test_bridge_elevation_mesh(test: RefCounted) -> void:
	var fixture := _compiled_query("builtin-nightfall-crossing")
	test.assert_true(bool(fixture.get("valid", false)), "bridge 3D mesh fixture compiles")
	if not bool(fixture.get("valid", false)):
		return
	var query: RaceTrackQuery = fixture["query"]
	test.assert_true(not query.bridge_zones.is_empty(), "bridge fixture exposes an elevated route zone")
	var result := Builder.build(query, {"sample_step_authority": 3.0})
	test.assert_true(bool(result.get("ok", false)), "bridge circuit builds a closed 3D mesh")
	if not bool(result.get("ok", false)):
		return
	var mesh: ArrayMesh = result["mesh"]
	var stats: Dictionary = result["stats"]
	test.assert_near(
		float(stats["minimum_surface_y_meters"]), Mapper.ROAD_SURFACE_Y_METERS,
		0.001, "underpass asphalt remains on the ground plane"
	)
	test.assert_near(
		float(stats["maximum_surface_y_meters"]),
		Mapper.BRIDGE_HEIGHT_METERS + Mapper.ROAD_SURFACE_Y_METERS,
		0.001, "overpass asphalt reaches the six-metre deck"
	)
	test.assert_near(
		float(stats["closed_seam_error_meters"]), 0.0, 0.00001,
		"elevated circuit remains spatially closed"
	)
	var zone: Dictionary = query.bridge_zones[0]
	var overpass_distance := float(zone["overpass_distance"])
	var overpass_sample := query.sample_at_distance(overpass_distance)
	var overpass_world := Mapper.authority_position_to_world(
		overpass_sample["position"], float(overpass_sample["elevation_level"]),
		Mapper.ROAD_SURFACE_Y_METERS
	)
	test.assert_near(
		overpass_world.y,
		Mapper.BRIDGE_HEIGHT_METERS + Mapper.ROAD_SURFACE_Y_METERS,
		0.001, "vehicle and track adapters agree on deck height"
	)
	var asphalt_arrays: Array = mesh.surface_get_arrays(1)
	var normals: PackedVector3Array = asphalt_arrays[Mesh.ARRAY_NORMAL]
	var saw_ramp_normal := false
	for normal in normals:
		if absf(normal.x) > 0.015 or absf(normal.z) > 0.015:
			saw_ramp_normal = true
			break
	test.assert_true(saw_ramp_normal, "bridge ramps expose sloped surface normals")
	test.assert_true(
		_all_surface_front_faces_match_normals(mesh),
		"bridge and ramp fronts remain visible with back-face culling enabled"
	)
	test.assert_true(
		mesh.get_aabb().size.y >= Mapper.BRIDGE_HEIGHT_METERS - 0.1,
		"mesh bounds include ground and elevated race surfaces"
	)
	result.clear()
	fixture.clear()


func _test_surface_material_profiles(test: RefCounted) -> void:
	var smooth_fixture := _compiled_query("builtin-evergreen-oval")
	var gravel_fixture := _compiled_query("builtin-copper-canyon")
	var mud_fixture := _compiled_query("builtin-riverbend")
	test.assert_true(
		bool(smooth_fixture.get("valid", false))
			and bool(gravel_fixture.get("valid", false))
			and bool(mud_fixture.get("valid", false)),
		"released surface material fixtures compile"
	)
	if not bool(smooth_fixture.get("valid", false)) \
			or not bool(gravel_fixture.get("valid", false)) \
			or not bool(mud_fixture.get("valid", false)):
		return
	var smooth := Builder.build(smooth_fixture["query"])
	var gravel := Builder.build(gravel_fixture["query"])
	var mud := Builder.build(mud_fixture["query"])
	var mobile_mud := Builder.build(
		mud_fixture["query"], {"mobile_surface_budget": true}
	)
	test.assert_true(
		bool(smooth.get("ok", false)) and bool(gravel.get("ok", false)) \
			and bool(mud.get("ok", false)) and bool(mobile_mud.get("ok", false)),
		"smooth, gravel, desktop mud, and mobile mud build complete 3D meshes"
	)
	if not bool(smooth.get("ok", false)) or not bool(gravel.get("ok", false)) \
			or not bool(mud.get("ok", false)) or not bool(mobile_mud.get("ok", false)):
		return
	var smooth_mesh: ArrayMesh = smooth["mesh"]
	var gravel_mesh: ArrayMesh = gravel["mesh"]
	var mud_mesh: ArrayMesh = mud["mesh"]
	var mobile_mud_mesh: ArrayMesh = mobile_mud["mesh"]
	var smooth_road := smooth_mesh.surface_get_material(1) as ShaderMaterial
	var gravel_road := gravel_mesh.surface_get_material(1) as ShaderMaterial
	var mud_road := mud_mesh.surface_get_material(1) as ShaderMaterial
	var mobile_mud_road := mobile_mud_mesh.surface_get_material(1) as ShaderMaterial
	test.assert_true(
		smooth_road != null and gravel_road != null and mud_road != null \
				and mobile_mud_road != null,
		"each surface owns an inspectable road material"
	)
	if smooth_road != null and gravel_road != null and mud_road != null \
			and mobile_mud_road != null:
		test.assert_true(
			smooth_road.get_shader_parameter("base_tint") \
				!= gravel_road.get_shader_parameter("base_tint") \
				and gravel_road.get_shader_parameter("base_tint") \
				!= mud_road.get_shader_parameter("base_tint"),
			"asphalt, gravel, and mud have visibly distinct material tints"
		)
		test.assert_true(
			float(mud_road.get_shader_parameter("roughness_value")) \
				> float(smooth_road.get_shader_parameter("roughness_value")),
			"mud has a rougher material response than smooth asphalt"
		)
		test.assert_true(
			float(gravel_road.get_shader_parameter("normal_strength")) \
				> float(smooth_road.get_shader_parameter("normal_strength")) \
				and float(mud_road.get_shader_parameter("normal_strength")) \
				> float(gravel_road.get_shader_parameter("normal_strength")),
			"loose surfaces progressively strengthen the road normal texture"
		)
		test.assert_equal(
			int(gravel_road.get_shader_parameter("surface_style")), 3,
			"gravel selects its aggregate shader branch"
		)
		test.assert_equal(
			int(mud_road.get_shader_parameter("surface_style")), 4,
			"mud selects its rut and damp-patch shader branch"
		)
		test.assert_true(
			bool(mobile_mud["stats"].get("mobile_surface_budget", false))
					and bool(mobile_mud_road.get_shader_parameter("mobile_surface_budget")),
			"mobile mud explicitly selects the low-ALU no-normal-sample shader branch"
		)
	var smooth_uvs: PackedVector2Array = smooth_mesh.surface_get_arrays(1)[Mesh.ARRAY_TEX_UV]
	var gravel_uvs: PackedVector2Array = gravel_mesh.surface_get_arrays(1)[Mesh.ARRAY_TEX_UV]
	test.assert_true(
		_maximum_uv_y(gravel_uvs) / float(gravel["stats"]["lap_length_meters"]) \
			> _maximum_uv_y(smooth_uvs) / float(smooth["stats"]["lap_length_meters"]),
		"gravel uses a denser texture repeat than smooth asphalt"
	)
	test.assert_equal(
		str(gravel["stats"]["road_surface"]), "compact_gravel",
		"mesh diagnostics retain the authoritative gravel profile"
	)
	test.assert_equal(
		str(mud["stats"]["road_surface"]), "mud",
		"mesh diagnostics retain the authoritative mud profile"
	)


func _maximum_uv_y(uvs: PackedVector2Array) -> float:
	var maximum := 0.0
	for uv in uvs:
		maximum = maxf(maximum, uv.y)
	return maximum


func _all_surface_front_faces_match_normals(mesh: ArrayMesh) -> bool:
	for surface_index in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for triangle_offset in range(0, indices.size(), 3):
			var first := indices[triangle_offset]
			var second := indices[triangle_offset + 1]
			var third := indices[triangle_offset + 2]
			# Godot considers clockwise winding front-facing, so its visible-side
			# geometric normal is the reverse of the conventional CCW cross product.
			var visible_normal := (
				vertices[third] - vertices[first]
			).cross(vertices[second] - vertices[first]).normalized()
			if visible_normal.length_squared() <= 0.000001:
				return false
			var stored_normal := (
				normals[first] + normals[second] + normals[third]
			).normalized()
			if visible_normal.dot(stored_normal) < 0.35:
				return false
	return true


func _compiled_query(track_id: String) -> Dictionary:
	var record := Catalog.by_id(track_id)
	var definition: TrackDefinition = record.get("definition")
	var compiled: TrackCompileResult = Compiler.compile(definition)
	if not compiled.succeeded() or compiled.track == null:
		return {"valid": false}
	var query: RaceTrackQuery = TrackQuery.from_compiled(compiled.track)
	return {
		"valid": query.is_valid(),
		"definition": definition,
		"compiled": compiled.track,
		"query": query,
	}
