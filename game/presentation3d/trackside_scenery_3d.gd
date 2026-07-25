class_name TracksideScenery3D
extends Node3D
## Deterministic, fixed world-space track dressing. Kenney Racing Kit scenes
## are preferred; simple primitives keep the circuit readable if an import is
## unavailable on a target platform.

const Mapper := preload("res://game/presentation3d/world_coordinate_mapper.gd")
const TrackBuilder := preload("res://game/presentation3d/track_mesh_builder_3d.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const KENNEY_ASSET_ROOT := "res://assets/final/3d/trackside/kenney_racing/"
const NATURE_ASSET_ROOT := "res://assets/final/3d/trackside/quaternius_nature/"

const BARRIER_ASSETS := ["barrierRed.gltf", "barrierWhite.gltf"]
const NATURE_TREE_ASSETS := [
	"BirchTree_1.gltf", "MapleTree_1.gltf",
	"BirchTree_3.gltf", "MapleTree_3.gltf",
]
const NATURE_BUSH_ASSET := "Bush.gltf"
const FALLBACK_RED := Color("d83b48")
const FALLBACK_WHITE := Color("edf1ee")
const FALLBACK_TRUNK := Color("72513c")
const FALLBACK_FOLIAGE := Color("2f7744")
const FALLBACK_STRUCTURE := Color("8a929a")
const SIGN_COLORS := [
	Color("17354b"), Color("285676"), Color("a83d46"), Color("2f746d"),
]
const CROWD_COLORS := [
	Color("315d84"), Color("b94f58"), Color("d3a23e"), Color("3c8873"),
	Color("7359a0"), Color("c7c4b8"), Color("c96d43"), Color("456fac"),
]
const GRANDSTAND_CLUSTER_FRACTIONS := [0.065, 0.320, 0.700]
const CROWD_CLUSTER_FRACTIONS := [0.065, 0.320, 0.480, 0.700]
const CROWD_TERRACE_INNER_OFFSET := 5.80
const CROWD_TERRACE_STEP_DEPTH := 1.45
const MINIMUM_FIXED_PROP_CLEARANCE_METERS := 0.5
const CLEARANCE_INDEX_CELL_SIZE_AUTHORITY := 64.0
const CLEARANCE_QUERY_MARGIN_METERS := 6.0

var _scene_cache: Dictionary = {}
var _mesh_asset_cache: Dictionary = {}
var _material_cache: Dictionary = {}
var _procedural_mesh_cache: Dictionary = {}
var _low_graphics := false
var _high_contrast := false
var _clearance_records: Array[Dictionary] = []
var _layout_records: Array[Dictionary] = []
var _layout_hash := ""
var _presentation_stats: Dictionary = {}
var _clearance_centerline := PackedVector2Array()
var _clearance_segment_cells: Dictionary = {}


func configure(
		track: RaceTrackQuery,
		low_graphics: bool = false,
		high_contrast: bool = false
	) -> void:
	_clear_children()
	_clearance_records.clear()
	_layout_records.clear()
	_layout_hash = ""
	_clearance_centerline.clear()
	_clearance_segment_cells.clear()
	_reset_presentation_stats()
	_low_graphics = low_graphics
	_high_contrast = high_contrast
	transform = Mapper.static_root_transforms()["scenery_root"]
	if track == null or not track.is_valid():
		return
	_prepare_clearance_index(track)
	_build_safety_barriers(track)
	_build_fences(track)
	_build_fictional_signage(track)
	_build_start_gantry(track)
	_build_hero_props(track)
	_build_spectators(track)
	_build_vegetation(track)
	_layout_hash = CanonicalJsonType.stringify(_layout_records).sha256_text()


func clear_scenery() -> void:
	_clear_children()
	_clearance_records.clear()
	_layout_records.clear()
	_layout_hash = ""
	_clearance_centerline.clear()
	_clearance_segment_cells.clear()
	_reset_presentation_stats()


func debug_clearance_snapshot() -> Dictionary:
	var minimum := INF
	var violations: Array[Dictionary] = []
	var counts_by_kind: Dictionary = {}
	for record in _clearance_records:
		var kind := str(record.get("kind", "unknown"))
		counts_by_kind[kind] = int(counts_by_kind.get(kind, 0)) + 1
		var clearance := float(record.get("clearance_meters", -INF))
		minimum = minf(minimum, clearance)
		if clearance < 0.5:
			violations.append(record.duplicate())
	return {
		"valid": not _clearance_records.is_empty() and violations.is_empty(),
		"prop_count": _clearance_records.size(),
		"minimum_clearance_meters": minimum if not _clearance_records.is_empty() else 0.0,
		"required_clearance_meters": 0.5,
		"counts_by_kind": counts_by_kind,
		"layout_hash": _layout_hash,
		"presentation_stats": _presentation_stats.duplicate(true),
		"render_node_count": _render_node_count(),
		"collision_object_count": find_children(
			"*", "CollisionObject3D", true, false
		).size(),
		"animation_player_count": find_children(
			"*", "AnimationPlayer", true, false
		).size(),
		"skeleton_count": find_children("*", "Skeleton3D", true, false).size(),
		"violations": violations,
	}


func _reset_presentation_stats() -> void:
	_presentation_stats = {
		"billboard_batches": 0,
		"billboard_instances": 0,
		"grandstand_batches": 0,
		"grandstand_instances": 0,
		"crowd_batches": 0,
		"crowd_instances": 0,
		"crowd_triangles": 0,
		"crowd_shadow_casters": 0,
		"minimum_spectator_top_meters": 0.0,
		"maximum_spectator_top_meters": 0.0,
		"billboard_shadow_casters": 0,
		"terrace_batches": 0,
		"terrace_instances": 0,
		"terrace_triangles": 0,
		"terrace_shadow_casters": 0,
		"safety_barrier_candidates": 0,
		"safety_barrier_instances": 0,
		"safety_barrier_skipped": 0,
		"catch_fence_candidates": 0,
		"catch_fence_instances": 0,
		"catch_fence_skipped": 0,
		"tree_batches": 0,
		"tree_instances": 0,
		"bush_batches": 0,
		"bush_instances": 0,
		"vegetation_render_nodes": 0,
	}


func _render_node_count() -> int:
	return find_children("*", "MeshInstance3D", true, false).size() \
			+ find_children("*", "MultiMeshInstance3D", true, false).size()


func _build_safety_barriers(track: RaceTrackQuery) -> void:
	var lap_length_m := track.total_length * Mapper.WORLD_UNIT_TO_METERS
	# Mobile keeps a continuous two-sided wall by fitting each authored profile
	# to a longer span; fewer MultiMesh instances reduce culling/object work on
	# mid-range GPUs without introducing a visual gap.
	var target_spacing := 12.0 if _low_graphics else 5.1
	var segment_count := clampi(ceili(lap_length_m / target_spacing), 48, 240)
	var segment_length := lap_length_m / float(segment_count) * 1.055
	var target_size := Vector3(segment_length, 0.86, 0.48)
	# Closely overlapping, real barrier-profile segments form a continuous wall.
	# The extra 1.5 metres is measured from the full asphalt + kerb + runoff envelope.
	var outer_offset := _track_envelope_meters(track) + 1.5
	var envelope := _track_envelope_meters(track)
	var transforms_by_asset: Array = [[], []]
	var accepted_instances := 0
	var skipped_instances := 0
	for index in segment_count:
		var distance := track.total_length * float(index) / float(segment_count)
		var asset_index := index % BARRIER_ASSETS.size()
		var asset_name: String = BARRIER_ASSETS[asset_index]
		var mesh_data := _mesh_asset_data(asset_name, KENNEY_ASSET_ROOT)
		if mesh_data.is_empty():
			continue
		var bounds: AABB = mesh_data["bounds"]
		var fit := _fit_asset_transform(bounds, target_size)
		for side in [-1.0, 1.0]:
			var placement := _trackside_transform(
				track, distance, side, outer_offset, 0.035, Vector3.ONE
			) * fit
			# Tight switchbacks and rosettes can put the nominal outside wall inside
			# a different part of the circuit. Query the complete route before
			# accepting the instance; an intentional short opening is safer and
			# visually cleaner than a wall crossing neighbouring asphalt/runoff.
			var clearance := _topology_aabb_clearance_meters(
				track, placement, bounds
			)
			if clearance < MINIMUM_FIXED_PROP_CLEARANCE_METERS:
				skipped_instances += 1
				continue
			(transforms_by_asset[asset_index] as Array).append(placement)
			accepted_instances += 1
			_record_known_clearance(
				"safety_barrier", "SafetyBarrier_%d_%d" % [index, int(side)],
				clearance, envelope
			)
	for asset_index in BARRIER_ASSETS.size():
		_add_asset_multimesh(
			"SafetyBarrierBand_%d" % asset_index,
			BARRIER_ASSETS[asset_index], KENNEY_ASSET_ROOT,
			transforms_by_asset[asset_index] as Array, true
		)
	_presentation_stats["safety_barrier_candidates"] = segment_count * 2
	_presentation_stats["safety_barrier_instances"] = accepted_instances
	_presentation_stats["safety_barrier_skipped"] = skipped_instances


func _build_fences(track: RaceTrackQuery) -> void:
	var lap_length_m := track.total_length * Mapper.WORLD_UNIT_TO_METERS
	# Fence panels are likewise length-fitted, so a coarser mobile cadence remains
	# physically continuous while avoiding hundreds of tiny render instances.
	var target_spacing := 14.0 if _low_graphics else 5.8
	var segment_count := clampi(ceili(lap_length_m / target_spacing), 36, 210)
	var segment_length := lap_length_m / float(segment_count) * 1.04
	var target_size := Vector3(segment_length, 2.75, 0.10)
	var outer_offset := _track_envelope_meters(track) + 4.9
	var envelope := _track_envelope_meters(track)
	var mesh_data := _mesh_asset_data("fenceStraight.gltf", KENNEY_ASSET_ROOT)
	if mesh_data.is_empty():
		return
	var bounds: AABB = mesh_data["bounds"]
	var fit := _fit_asset_transform(bounds, target_size)
	var transforms: Array = []
	var accepted_instances := 0
	var skipped_instances := 0
	for index in segment_count:
		var distance := track.total_length * (float(index) + 0.5) / float(segment_count)
		for side in [-1.0, 1.0]:
			var placement := _trackside_transform(
				track, distance, side, outer_offset, 0.02, Vector3.ONE
			) * fit
			var clearance := _topology_aabb_clearance_meters(
				track, placement, bounds
			)
			if clearance < MINIMUM_FIXED_PROP_CLEARANCE_METERS:
				skipped_instances += 1
				continue
			transforms.append(placement)
			accepted_instances += 1
			_record_known_clearance(
				"catch_fence", "CatchFence_%d_%d" % [index, int(side)],
				clearance, envelope
			)
	_add_asset_multimesh(
		"ContinuousCatchFence", "fenceStraight.gltf", KENNEY_ASSET_ROOT,
		transforms, false
	)
	_presentation_stats["catch_fence_candidates"] = segment_count * 2
	_presentation_stats["catch_fence_instances"] = accepted_instances
	_presentation_stats["catch_fence_skipped"] = skipped_instances


func _build_fictional_signage(track: RaceTrackQuery) -> void:
	# Large, matte project-color boards read at racing speed.  Panel, posts, and
	# accent are one original low-poly mesh, split into three spatial MultiMeshes
	# so off-camera thirds of the circuit can be culled.  No real marks, sponsor
	# copy, or reference-game artwork is used.
	var sign_count := 18 if _low_graphics else 48
	var billboard_mesh := _billboard_mesh()
	var billboard_bounds := billboard_mesh.get_aabb()
	var outer_offset := _track_envelope_meters(track) + 6.8
	var transforms_by_zone: Array = [[], [], []]
	var colors_by_zone: Array = [[], [], []]
	var accepted_signs := 0
	for index in sign_count:
		var fraction := fmod(0.052 + float(index) * 0.38196601125, 1.0)
		var distance := track.total_length * fraction
		var side := -1.0 if index % 4 < 2 else 1.0
		# Keep venue-side sightlines open: a timing board near a crowd cluster is
		# moved across the circuit instead of sitting directly in front of people.
		for cluster_index in CROWD_CLUSTER_FRACTIONS.size():
			var cluster_fraction: float = CROWD_CLUSTER_FRACTIONS[cluster_index]
			var fraction_delta := absf(fraction - cluster_fraction)
			fraction_delta = minf(fraction_delta, 1.0 - fraction_delta)
			var venue_side := -1.0 if cluster_index % 2 == 0 else 1.0
			if fraction_delta <= 0.025 and is_equal_approx(side, venue_side):
				side = -side
				break
		var placement := _trackside_transform(
			track, distance, side, outer_offset, 0.02, Vector3.ONE
		)
		if _aabb_clearance_meters(
			track, placement, billboard_bounds, true
		) < 0.75:
			continue
		var zone_index := mini(floori(fraction * 3.0), 2)
		(transforms_by_zone[zone_index] as Array).append(placement)
		(colors_by_zone[zone_index] as Array).append(
			SIGN_COLORS[index % SIGN_COLORS.size()]
		)
		_record_layout(
			"fictional_billboard", placement,
			SIGN_COLORS[index % SIGN_COLORS.size()]
		)
		accepted_signs += 1
		_record_aabb_clearance(
			track, distance, placement, billboard_bounds, "fictional_billboard",
			"FictionalBillboard_%d" % index, true
		)
	var billboard_batches := 0
	for zone_index in transforms_by_zone.size():
		var transforms: Array = transforms_by_zone[zone_index] as Array
		if transforms.is_empty():
			continue
		_add_colored_mesh_multimesh(
			"FictionalBillboardZone_%d" % zone_index,
			billboard_mesh, transforms, colors_by_zone[zone_index] as Array,
			170.0 if _low_graphics else 300.0
		)
		billboard_batches += 1
	_presentation_stats["billboard_batches"] = billboard_batches
	_presentation_stats["billboard_instances"] = accepted_signs


func _build_start_gantry(track: RaceTrackQuery) -> void:
	var distance := track.total_length * 0.018
	var support_offset := _track_envelope_meters(track) + 1.65
	var structure_material := _material(Color("303941"), 0.64)
	for side in [-1.0, 1.0]:
		var support := _box_prop(Vector3(0.34, 6.15, 0.34), structure_material, true)
		support.name = "StartGantrySupport_%d" % int(side)
		support.transform = _trackside_transform(
			track, distance, side, support_offset, 0.02, Vector3.ONE
		)
		_add_fixed_prop(support, track, distance, "start_gantry_support")

	var gantry := Node3D.new()
	gantry.name = "StartLightGantry"
	gantry.transform = _centerline_transform(track, distance, 0.0, Vector3.ONE)
	var crossbar := MeshInstance3D.new()
	var crossbar_mesh := BoxMesh.new()
	crossbar_mesh.size = Vector3(0.48, 0.46, support_offset * 2.0 + 0.45)
	crossbar.mesh = crossbar_mesh
	crossbar.position.y = 6.02
	crossbar.material_override = structure_material
	gantry.add_child(crossbar)
	var sign_panel := MeshInstance3D.new()
	var sign_panel_mesh := BoxMesh.new()
	sign_panel_mesh.size = Vector3(0.18, 0.88, minf(support_offset * 1.72, 9.2))
	sign_panel.mesh = sign_panel_mesh
	sign_panel.position = Vector3(-0.28, 5.94, 0.0)
	sign_panel.material_override = _material(Color("142b3e"), 0.58)
	gantry.add_child(sign_panel)
	for facing in [-1.0, 1.0]:
		var gantry_label := Label3D.new()
		gantry_label.name = "OriginalGantryLabel"
		gantry_label.text = "RACEGLYPH   •   SECTOR 1"
		gantry_label.font_size = 64
		gantry_label.pixel_size = 0.0054
		gantry_label.outline_size = 7
		gantry_label.modulate = Color("eef6f3")
		gantry_label.outline_modulate = Color("112333")
		gantry_label.position = Vector3(-0.385 * facing, 5.94, 0.0)
		gantry_label.rotation_degrees.y = -90.0 * facing
		gantry.add_child(gantry_label)
	for stripe_side in [-1.0, 1.0]:
		var accent := MeshInstance3D.new()
		var accent_mesh := BoxMesh.new()
		accent_mesh.size = Vector3(0.205, 0.88, 0.16)
		accent.mesh = accent_mesh
		accent.position = Vector3(
			-0.285, 5.94, stripe_side * minf(support_offset * 0.83, 4.42)
		)
		accent.material_override = _material(Color("35d6b4"), 0.48)
		gantry.add_child(accent)
	var light_material := _material(Color("b6252f"), 0.42)
	light_material.emission_enabled = true
	light_material.emission = Color("6d1018")
	light_material.emission_energy_multiplier = 0.75
	for light_index in 5:
		var pod := MeshInstance3D.new()
		var pod_mesh := SphereMesh.new()
		pod_mesh.radius = 0.14
		pod_mesh.height = 0.28
		pod.mesh = pod_mesh
		pod.position = Vector3(-0.39, 5.30, (float(light_index) - 2.0) * 0.62)
		pod.material_override = light_material
		gantry.add_child(pod)
	add_child(gantry)
	# The crossbar is intentionally overhead. Track its vertical clearance rather
	# than treating it like a ground-level intrusion into the lateral envelope.
	_clearance_records.append({
		"name": "StartLightGantryCrossbar",
		"kind": "overhead_gantry",
		"clearance_mode": "vertical",
		"minimum_vertical_meters": 5.54,
		"track_envelope_meters": _track_envelope_meters(track),
		"clearance_meters": 3.54,
	})


func _build_hero_props(track: RaceTrackQuery) -> void:
	var building_offset := _track_envelope_meters(track) + 12.0
	var pit_count := 3 if _low_graphics else 5
	var pit_asset_names := ["pitsOfficeCorner.gltf", "pitsOffice.gltf"]
	var pit_transforms_by_asset: Array = [[], []]
	for index in pit_count:
		var fraction := 0.875 + float(index) * 0.0215
		var distance := track.total_length * fraction
		var asset_index := 0 if index == 0 else 1
		var asset_name: String = pit_asset_names[asset_index]
		var mesh_data := _mesh_asset_data(asset_name, KENNEY_ASSET_ROOT)
		if mesh_data.is_empty():
			continue
		var bounds: AABB = mesh_data["bounds"]
		var scale_amount := 9.6 if index == 0 else 9.2
		var placement := _trackside_transform(
			track, distance, -1.0, building_offset, 0.02, Vector3.ONE
		) * _fit_asset_transform(bounds, bounds.size * scale_amount)
		if _aabb_clearance_meters(track, placement, bounds, true) < 0.75:
			continue
		(pit_transforms_by_asset[asset_index] as Array).append(placement)
		_record_layout("pit_building_%d" % asset_index, placement, Color.WHITE)
		_record_aabb_clearance(
			track, distance, placement, bounds, "pit_building",
			"PitBuilding_%d" % index, true
		)
	for asset_index in pit_asset_names.size():
		_add_asset_multimesh(
			"PitBuildingBatch_%d" % asset_index,
			pit_asset_names[asset_index], KENNEY_ASSET_ROOT,
			pit_transforms_by_asset[asset_index] as Array, false
		)

	# Grandstands are fitted and batched by their two licensed Kenney meshes.
	# This moves the venue closer to the fence, increases visible seating, and
	# reduces four-or-more independent render objects to two shared batches.
	var stand_count_per_cluster := 2 if _low_graphics else 3
	var stand_asset_names := ["grandStandCovered.gltf", "grandStand.gltf"]
	var transforms_by_cluster_asset: Array = []
	for unused_cluster in GRANDSTAND_CLUSTER_FRACTIONS.size():
		transforms_by_cluster_asset.append([[], []])
	var grandstand_offset := _track_envelope_meters(track) + 10.4
	var accepted_stands := 0
	for cluster_index in GRANDSTAND_CLUSTER_FRACTIONS.size():
		# The opening venue sits on the unobstructed half of the chase-camera
		# composition, away from the top-right camera and pause controls.
		var side := -1.0 if cluster_index % 2 == 0 else 1.0
		for stand_index in stand_count_per_cluster:
			var centered_index := float(stand_index) \
					- float(stand_count_per_cluster - 1) * 0.5
			var fraction: float = GRANDSTAND_CLUSTER_FRACTIONS[cluster_index] \
					+ centered_index * 0.018
			var distance := track.total_length * fraction
			var asset_index := 0 if stand_index == 0 else 1
			var asset_name: String = stand_asset_names[asset_index]
			var mesh_data := _mesh_asset_data(asset_name, KENNEY_ASSET_ROOT)
			if mesh_data.is_empty():
				continue
			var bounds: AABB = mesh_data["bounds"]
			var target_size := Vector3(16.4, 7.4, 8.0) \
					if asset_index == 0 else Vector3(15.8, 6.3, 7.6)
			var placement := _trackside_transform(
				track, distance, side, grandstand_offset, 0.02, Vector3.ONE
			) * _fit_asset_transform(bounds, target_size)
			if _aabb_clearance_meters(track, placement, bounds, true) < 0.75:
				continue
			var cluster_assets: Array = \
					transforms_by_cluster_asset[cluster_index] as Array
			(cluster_assets[asset_index] as Array).append(placement)
			_record_layout("grandstand_%d" % asset_index, placement, Color.WHITE)
			accepted_stands += 1
			_record_aabb_clearance(
				track, distance, placement, bounds, "grandstand",
				"Grandstand_%d_%d" % [cluster_index, stand_index], true
			)
	var grandstand_batches := 0
	for cluster_index in transforms_by_cluster_asset.size():
		var cluster_assets: Array = \
				transforms_by_cluster_asset[cluster_index] as Array
		for asset_index in stand_asset_names.size():
			var transforms: Array = cluster_assets[asset_index] as Array
			if transforms.is_empty():
				continue
			_add_asset_multimesh(
				"GrandstandBatch_%d_%d" % [cluster_index, asset_index],
				stand_asset_names[asset_index], KENNEY_ASSET_ROOT,
				transforms, false, 250.0 if _low_graphics else 420.0
			)
			grandstand_batches += 1
	_presentation_stats["grandstand_batches"] = grandstand_batches
	_presentation_stats["grandstand_instances"] = accepted_stands


func _build_spectators(track: RaceTrackQuery) -> void:
	# Four compact crowd zones let the renderer cull most spectators on long
	# circuits.  Each person is the same original 36-triangle mesh with a cheap
	# per-instance color: no skeletons, animation players, colliders, shadows, or
	# frame-time CPU work.  The first rows stand safely behind the catch fence;
	# raised rows visually occupy the batched grandstands.
	var person_mesh := _spectator_mesh()
	var person_bounds := person_mesh.get_aabb()
	var terrace_mesh := _spectator_terrace_mesh()
	var terrace_bounds := terrace_mesh.get_aabb()
	var crowd_per_cluster := 40 if _low_graphics else 96
	var front_count := 14 if _low_graphics else 24
	var front_columns := 7 if _low_graphics else 12
	var stand_rows := 2 if _low_graphics else 4
	var envelope := _track_envelope_meters(track)
	var accepted_spectators := 0
	var crowd_batches := 0
	var accepted_terraces := 0
	var minimum_spectator_top := INF
	var maximum_spectator_top := 0.0
	for cluster_index in CROWD_CLUSTER_FRACTIONS.size():
		var cluster_fraction: float = CROWD_CLUSTER_FRACTIONS[cluster_index]
		var side := -1.0 if cluster_index % 2 == 0 else 1.0
		var cluster_distance := track.total_length * cluster_fraction
		var cluster_footprint := AABB(
			Vector3(-20.0, 0.0, -0.35), Vector3(40.0, 5.2, 6.2)
		)
		var cluster_transform := _trackside_transform(
			track, cluster_distance, side,
			envelope + CROWD_TERRACE_INNER_OFFSET,
			0.0, Vector3.ONE
		)
		# One conservative whole-track footprint query replaces hundreds of
		# per-person nearest-track searches. Unsafe custom/bridge layouts simply
		# omit this decorative cluster; race authority is never blocked.
		if _aabb_clearance_meters(
			track, cluster_transform, cluster_footprint, true
		) < 0.75:
			continue
		_add_colored_mesh_multimesh(
			"SpectatorTerrace_%d" % cluster_index,
			terrace_mesh, [cluster_transform], [Color.WHITE],
			100.0 if _low_graphics else 210.0
		)
		accepted_terraces += 1
		_record_layout("spectator_terrace", cluster_transform, Color.WHITE)
		_record_aabb_clearance(
			track, cluster_distance, cluster_transform, terrace_bounds,
			"spectator_terrace", "SpectatorTerrace_%d" % cluster_index, true
		)
		var transforms: Array = []
		var colors: Array[Color] = []
		for index in front_count:
			var row := floori(float(index) / float(front_columns))
			var column := index % front_columns
			var fraction := cluster_fraction + (
				float(column) - float(front_columns - 1) * 0.5
			) * 0.00155 + float(row) * 0.00035
			var distance := track.total_length * fraction
			var scale_amount := 0.90 + float(
				(index + cluster_index * 3) % 6
			) * 0.035
			var lateral_offset := envelope + 6.15 + float(row) * 0.62
			var terrace_depth := lateral_offset - envelope \
					- CROWD_TERRACE_INNER_OFFSET
			var vertical_offset := _terrace_surface_height(terrace_depth) \
					- person_bounds.position.y * scale_amount + 0.015
			var placement := _trackside_transform(
				track, distance, side, lateral_offset,
				vertical_offset,
				Vector3.ONE * scale_amount
			)
			var spectator_top := vertical_offset \
					+ person_bounds.end.y * scale_amount
			minimum_spectator_top = minf(minimum_spectator_top, spectator_top)
			maximum_spectator_top = maxf(maximum_spectator_top, spectator_top)
			transforms.append(placement)
			var person_color: Color = CROWD_COLORS[
				(index + cluster_index * 2) % CROWD_COLORS.size()
			]
			colors.append(person_color)
			accepted_spectators += 1
			_record_known_clearance(
				"trackside_spectator",
				"TracksideSpectator_%d_%d" % [cluster_index, index],
				lateral_offset - envelope \
						- person_bounds.size.z * scale_amount * 0.5,
				envelope
			)
			_record_layout("trackside_spectator", placement, person_color)

		var raised_count := crowd_per_cluster - front_count
		var raised_columns := ceili(float(raised_count) / float(stand_rows))
		for index in raised_count:
			var row := floori(float(index) / float(raised_columns))
			var column := index % raised_columns
			var fraction := cluster_fraction + (
				float(column) - float(raised_columns - 1) * 0.5
			) * 0.00155 + float(row) * 0.00022
			var distance := track.total_length * fraction
			var scale_amount := 0.88 + float(
				(index + cluster_index * 5) % 7
			) * 0.032
			var lateral_offset := envelope + 8.55 + float(row) * 0.62
			var terrace_depth := lateral_offset - envelope \
					- CROWD_TERRACE_INNER_OFFSET
			var vertical_offset := _terrace_surface_height(terrace_depth) \
					- person_bounds.position.y * scale_amount + 0.015
			var placement := _trackside_transform(
				track, distance, side, lateral_offset,
				vertical_offset,
				Vector3.ONE * scale_amount
			)
			var spectator_top := vertical_offset \
					+ person_bounds.end.y * scale_amount
			minimum_spectator_top = minf(minimum_spectator_top, spectator_top)
			maximum_spectator_top = maxf(maximum_spectator_top, spectator_top)
			transforms.append(placement)
			var person_color: Color = CROWD_COLORS[
				(index + cluster_index * 3 + 2) % CROWD_COLORS.size()
			]
			colors.append(person_color)
			accepted_spectators += 1
			_record_known_clearance(
				"grandstand_spectator",
				"GrandstandSpectator_%d_%d" % [cluster_index, index],
				lateral_offset - envelope \
						- person_bounds.size.z * scale_amount * 0.5,
				envelope
			)
			_record_layout("grandstand_spectator", placement, person_color)

		if transforms.is_empty():
			continue
		_add_colored_mesh_multimesh(
			"CrowdZone_%d" % cluster_index, person_mesh,
			transforms, colors, 100.0 if _low_graphics else 190.0
		)
		crowd_batches += 1
	_presentation_stats["crowd_batches"] = crowd_batches
	_presentation_stats["crowd_instances"] = accepted_spectators
	_presentation_stats["crowd_triangles"] = \
		_mesh_triangle_count(person_mesh) * accepted_spectators
	_presentation_stats["minimum_spectator_top_meters"] = \
		minimum_spectator_top if accepted_spectators > 0 else 0.0
	_presentation_stats["maximum_spectator_top_meters"] = \
		maximum_spectator_top
	_presentation_stats["terrace_batches"] = accepted_terraces
	_presentation_stats["terrace_instances"] = accepted_terraces
	_presentation_stats["terrace_triangles"] = \
		_mesh_triangle_count(terrace_mesh) * accepted_terraces


static func _terrace_surface_height(local_depth: float) -> float:
	var step_index := clampi(
		floori(maxf(local_depth, 0.0) / CROWD_TERRACE_STEP_DEPTH), 0, 3
	)
	return 1.60 + float(step_index) * 0.55


func _build_vegetation(track: RaceTrackQuery) -> void:
	_build_trees(track)
	_build_bushes(track)


func _build_trees(track: RaceTrackQuery) -> void:
	var tree_count := 34 if _low_graphics else 88
	var base_offset := _track_envelope_meters(track) + 12.5
	var available_assets := 2 if _low_graphics else NATURE_TREE_ASSETS.size()
	# Spatially batch the authored tree meshes instead of retaining one imported
	# scene graph per tree. Mobile uses a deterministic 2x2 world grid; standard
	# uses 3x3 so its denser forest does not submit a full circuit quadrant when
	# only one tree is visible. Both remain effective on crossing circuits.
	var grid_axis_count := 2 if _low_graphics else 3
	var zone_count := grid_axis_count * grid_axis_count
	var transforms_by_asset_zone: Array = []
	for asset_index in available_assets:
		var zones: Array = []
		for unused_zone in zone_count:
			zones.append([])
		transforms_by_asset_zone.append(zones)
	var placement_records: Array[Dictionary] = []
	var minimum_origin := Vector3(INF, INF, INF)
	var maximum_origin := Vector3(-INF, -INF, -INF)
	for index in tree_count:
		var fraction := fmod(float(index) * 0.61803398875 + 0.137, 1.0)
		var distance := track.total_length * fraction
		var side := -1.0 if index % 4 < 2 else 1.0
		var lateral_jitter := float((index * 17) % 17) * 1.48
		var asset_index := index % available_assets
		var asset_name: String = NATURE_TREE_ASSETS[asset_index]
		var mesh_data := _mesh_asset_data(asset_name, NATURE_ASSET_ROOT)
		if mesh_data.is_empty():
			continue
		var bounds: AABB = mesh_data["bounds"]
		var scale_amount := 0.74 + float((index * 7) % 9) * 0.042
		var placement := _trackside_transform(
			track, distance, side, base_offset + lateral_jitter,
			0.0, Vector3.ONE * scale_amount
		)
		placement.basis = placement.basis * Basis(
			Vector3.UP, fmod(float(index) * 0.731, TAU)
		)
		# Imported scenes were previously floor-centred by _instantiate_asset().
		# Apply the same normalization before using the raw mesh in a MultiMesh.
		placement = placement * _fit_asset_transform(bounds, bounds.size)
		var clearance := _topology_aabb_clearance_meters(
			track, placement, bounds
		)
		if clearance < MINIMUM_FIXED_PROP_CLEARANCE_METERS:
			continue
		placement_records.append({
			"asset_index": asset_index,
			"transform": placement,
		})
		minimum_origin = minimum_origin.min(placement.origin)
		maximum_origin = maximum_origin.max(placement.origin)
		_record_known_clearance(
			"tree", "Tree_%d" % index, clearance,
			_track_envelope_meters(track)
		)
	for record in placement_records:
		var placement: Transform3D = record["transform"]
		var asset_index := int(record["asset_index"])
		var zone_index := _spatial_grid_index(
			placement.origin, minimum_origin, maximum_origin, grid_axis_count
		)
		var asset_zones: Array = transforms_by_asset_zone[asset_index] as Array
		(asset_zones[zone_index] as Array).append(placement)
	var tree_batches := 0
	for asset_index in available_assets:
		var asset_zones: Array = transforms_by_asset_zone[asset_index] as Array
		for zone_index in zone_count:
			var zone_transforms: Array = asset_zones[zone_index] as Array
			if zone_transforms.is_empty():
				continue
			_add_asset_multimesh(
				"TreeBatch_%d_%d" % [asset_index, zone_index],
				NATURE_TREE_ASSETS[asset_index], NATURE_ASSET_ROOT,
				zone_transforms, true,
				220.0 if _low_graphics else 300.0
			)
			tree_batches += 1
	_presentation_stats["tree_batches"] = tree_batches
	_presentation_stats["tree_instances"] = placement_records.size()
	_presentation_stats["vegetation_render_nodes"] = tree_batches


func _build_bushes(track: RaceTrackQuery) -> void:
	var bush_count := 18 if _low_graphics else 56
	var base_offset := _track_envelope_meters(track) + 7.1
	var mesh_data := _mesh_asset_data(NATURE_BUSH_ASSET, NATURE_ASSET_ROOT)
	if mesh_data.is_empty():
		return
	var bounds: AABB = mesh_data["bounds"]
	var placements: Array[Transform3D] = []
	var minimum_origin := Vector3(INF, INF, INF)
	var maximum_origin := Vector3(-INF, -INF, -INF)
	for index in bush_count:
		var fraction := fmod(float(index) * 0.754877666 + 0.061, 1.0)
		var distance := track.total_length * fraction
		var side := -1.0 if index % 3 == 0 else 1.0
		var lateral_jitter := float((index * 11) % 9) * 0.82
		var scale_amount := 1.32 + float((index * 5) % 7) * 0.11
		var placement := _trackside_transform(
			track, distance, side, base_offset + lateral_jitter,
			0.02, Vector3.ONE * scale_amount
		)
		placement.basis = placement.basis * Basis(
			Vector3.UP, fmod(float(index) * 0.947, TAU)
		)
		placement = placement * _fit_asset_transform(bounds, bounds.size)
		var clearance := _topology_aabb_clearance_meters(
			track, placement, bounds
		)
		if clearance < MINIMUM_FIXED_PROP_CLEARANCE_METERS:
			continue
		placements.append(placement)
		minimum_origin = minimum_origin.min(placement.origin)
		maximum_origin = maximum_origin.max(placement.origin)
		_record_known_clearance(
			"bush", "TracksideBush_%d" % index, clearance,
			_track_envelope_meters(track)
		)
	var grid_axis_count := 2 if _low_graphics else 3
	var transforms_by_zone: Array = []
	for unused_zone in grid_axis_count * grid_axis_count:
		transforms_by_zone.append([])
	for placement in placements:
		(transforms_by_zone[
			_spatial_grid_index(
				placement.origin, minimum_origin, maximum_origin, grid_axis_count
			)
		] as Array).append(placement)
	var bush_batches := 0
	for zone_index in transforms_by_zone.size():
		var zone_transforms: Array = transforms_by_zone[zone_index] as Array
		if zone_transforms.is_empty():
			continue
		_add_asset_multimesh(
			"BushBatch_%d" % zone_index,
			NATURE_BUSH_ASSET, NATURE_ASSET_ROOT,
			zone_transforms, true,
			100.0 if _low_graphics else 160.0
		)
		bush_batches += 1
	_presentation_stats["bush_batches"] = bush_batches
	_presentation_stats["bush_instances"] = placements.size()
	_presentation_stats["vegetation_render_nodes"] = \
		int(_presentation_stats.get("tree_batches", 0)) + bush_batches


static func _spatial_grid_index(
		origin: Vector3,
		minimum_origin: Vector3,
		maximum_origin: Vector3,
		axis_count: int
	) -> int:
	var safe_axis_count := maxi(axis_count, 1)
	var span := maximum_origin - minimum_origin
	var normalized_x := (origin.x - minimum_origin.x) / maxf(span.x, 0.001)
	var normalized_z := (origin.z - minimum_origin.z) / maxf(span.z, 0.001)
	var x_index := clampi(
		floori(normalized_x * float(safe_axis_count)), 0, safe_axis_count - 1
	)
	var z_index := clampi(
		floori(normalized_z * float(safe_axis_count)), 0, safe_axis_count - 1
	)
	return z_index * safe_axis_count + x_index


func _centerline_transform(
		track: RaceTrackQuery,
		distance: float,
		vertical_offset: float,
		scale_value: Vector3
	) -> Transform3D:
	var sample := track.sample_at_distance(distance)
	var tangent := Mapper.authority_direction_to_world(
		sample.get("tangent", Vector2.RIGHT)
	)
	var normal := Mapper.authority_direction_to_world(
		sample.get("normal", Vector2.UP)
	)
	var basis := Basis(tangent, Vector3.UP, normal).orthonormalized().scaled(scale_value)
	var position := Mapper.authority_position_to_world(
		sample.get("position", Vector2.ZERO),
		float(sample.get("elevation_level", 0.0)), vertical_offset
	)
	return Transform3D(basis, position)


func _trackside_transform(
		track: RaceTrackQuery,
		distance: float,
		side: float,
		lateral_offset_meters: float,
		vertical_offset: float,
		scale_value: Vector3
	) -> Transform3D:
	var sample := track.sample_at_distance(distance)
	var tangent := Mapper.authority_direction_to_world(
		sample.get("tangent", Vector2.RIGHT)
	)
	var normal := Mapper.authority_direction_to_world(
		sample.get("normal", Vector2.UP)
	)
	var side_sign := -1.0 if side < 0.0 else 1.0
	# Reversing both planar axes on the opposite side keeps a proper, non-mirrored basis.
	var basis := Basis(
		tangent * side_sign, Vector3.UP, normal * side_sign
	).orthonormalized().scaled(scale_value)
	var position := Mapper.authority_position_to_world(
		sample.get("position", Vector2.ZERO),
		float(sample.get("elevation_level", 0.0)), vertical_offset
	) + normal * side_sign * lateral_offset_meters
	return Transform3D(basis, position)


func _asset_or_barrier(asset_name: String, color: Color) -> Node3D:
	var holder := _instantiate_asset(asset_name)
	if holder != null:
		return holder
	var fallback := Node3D.new()
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.28, 0.34)
	mesh_instance.mesh = box
	mesh_instance.position = Vector3(0.0, 0.14, 0.0)
	mesh_instance.material_override = _material(color, 0.82)
	fallback.add_child(mesh_instance)
	return fallback


func _asset_or_fence(asset_name: String) -> Node3D:
	var holder := _instantiate_asset(asset_name)
	if holder != null:
		return holder
	var fallback := Node3D.new()
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.42, 0.04)
	mesh_instance.mesh = box
	mesh_instance.position = Vector3(0.0, 0.21, 0.0)
	mesh_instance.material_override = _material(Color("9da7ae"), 0.68)
	fallback.add_child(mesh_instance)
	return fallback


func _asset_or_tree(asset_name: String, nature_asset: bool = false) -> Node3D:
	var asset_root := NATURE_ASSET_ROOT if nature_asset else KENNEY_ASSET_ROOT
	var holder := _instantiate_asset(asset_name, asset_root)
	if holder != null:
		return holder
	var fallback := Node3D.new()
	var trunk := MeshInstance3D.new()
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.07
	trunk_mesh.bottom_radius = 0.11
	trunk_mesh.height = 0.72
	trunk.mesh = trunk_mesh
	trunk.position.y = 0.36
	trunk.material_override = _material(FALLBACK_TRUNK, 0.9)
	fallback.add_child(trunk)
	var crown := MeshInstance3D.new()
	var crown_mesh := SphereMesh.new()
	crown_mesh.radius = 0.48
	crown_mesh.height = 0.9
	crown.mesh = crown_mesh
	crown.position.y = 0.98
	crown.material_override = _material(
		Color("246a35") if _high_contrast else FALLBACK_FOLIAGE, 0.92
	)
	fallback.add_child(crown)
	return fallback


func _asset_or_structure(asset_name: String, color: Color) -> Node3D:
	var holder := _instantiate_asset(asset_name)
	if holder != null:
		_apply_structure_materials(holder)
		return holder
	var fallback := Node3D.new()
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.48, 0.82)
	mesh_instance.mesh = box
	mesh_instance.position.y = 0.24
	mesh_instance.material_override = _material(color, 0.78)
	fallback.add_child(mesh_instance)
	return fallback


func _apply_structure_materials(root_node: Node3D) -> void:
	for mesh_node in root_node.find_children("*", "MeshInstance3D", true, false):
		var instance := mesh_node as MeshInstance3D
		if instance.mesh == null:
			continue
		for surface_index in instance.mesh.get_surface_count():
			var source_material := instance.mesh.surface_get_material(surface_index)
			var source_name := "default"
			if source_material != null:
				source_name = source_material.resource_name.to_lower()
			instance.set_surface_override_material(
				surface_index, _structure_material(source_name)
			)


func _structure_material(source_name: String) -> StandardMaterial3D:
	var cache_key := "structure_" + source_name
	if _material_cache.has(cache_key):
		return _material_cache[cache_key] as StandardMaterial3D
	var material := StandardMaterial3D.new()
	if "glass" in source_name:
		material.albedo_color = Color("29495b")
		material.metallic = 0.24
		material.roughness = 0.22
	elif "red" in source_name:
		material.albedo_color = Color("a9363d")
		material.metallic = 0.04
		material.roughness = 0.68
	elif "road" in source_name:
		material.albedo_color = Color("30363a")
		material.roughness = 0.93
	elif "grey" in source_name:
		material.albedo_color = Color("a3aaad")
		material.metallic = 0.06
		material.roughness = 0.78
	else:
		material.albedo_color = Color("5c666d")
		material.metallic = 0.12
		material.roughness = 0.72
	_material_cache[cache_key] = material
	return material


func _asset_or_gantry(asset_name: String) -> Node3D:
	var holder := _instantiate_asset(asset_name)
	if holder != null:
		return holder
	var fallback := Node3D.new()
	var crossbar := MeshInstance3D.new()
	var crossbar_mesh := BoxMesh.new()
	crossbar_mesh.size = Vector3(0.16, 0.16, 1.4)
	crossbar.mesh = crossbar_mesh
	crossbar.position.y = 0.54
	crossbar.material_override = _material(Color("343b42"), 0.72)
	fallback.add_child(crossbar)
	for side in [-0.62, 0.62]:
		var upright := MeshInstance3D.new()
		var upright_mesh := BoxMesh.new()
		upright_mesh.size = Vector3(0.14, 1.08, 0.14)
		upright.mesh = upright_mesh
		upright.position = Vector3(0.0, 0.0, side)
		upright.material_override = _material(Color("343b42"), 0.72)
		fallback.add_child(upright)
	return fallback


func _box_prop(
		size: Vector3,
		material: StandardMaterial3D,
		bottom_anchored: bool = false
	) -> Node3D:
	var root := Node3D.new()
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.position.y = size.y * 0.5 if bottom_anchored else 0.0
	mesh_instance.material_override = material
	root.add_child(mesh_instance)
	return root


func _billboard_mesh() -> ArrayMesh:
	if _procedural_mesh_cache.has("billboard"):
		return _procedural_mesh_cache["billboard"] as ArrayMesh
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(_instance_color_material("billboard", 0.88))
	_append_box_surface(
		surface, Vector3(0.0, 3.05, 0.0), Vector3(7.2, 2.30, 0.18),
		Color.WHITE
	)
	for post_side in [-1.0, 1.0]:
		_append_box_surface(
			surface, Vector3(post_side * 2.72, 1.55, 0.0),
			Vector3(0.22, 3.10, 0.22), Color("354046")
		)
	# Original timing-bar graphics remain legible from both directions without
	# one Label3D or material per board.
	for face in [-1.0, 1.0]:
		_append_box_surface(
			surface, Vector3(0.0, 3.58, face * 0.13),
			Vector3(6.25, 0.30, 0.08), Color("65dcc5")
		)
		_append_box_surface(
			surface, Vector3(0.0, 2.92, face * 0.13),
			Vector3(5.25, 0.18, 0.08), Color("10283a")
		)
		for marker_index in 6:
			_append_box_surface(
				surface,
				Vector3((float(marker_index) - 2.5) * 0.82, 3.18, face * 0.13),
				Vector3(0.54, 0.44, 0.08),
				Color("edf3ed") if marker_index % 2 == 0 else Color("17354b")
			)
	var mesh := surface.commit() as ArrayMesh
	_procedural_mesh_cache["billboard"] = mesh
	return mesh


func _spectator_mesh() -> ArrayMesh:
	if _procedural_mesh_cache.has("spectator"):
		return _procedural_mesh_cache["spectator"] as ArrayMesh
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(_instance_color_material("spectator", 0.92))
	_append_box_surface(
		surface, Vector3(0.0, 0.55, 0.0), Vector3(0.36, 1.00, 0.24),
		Color.WHITE
	)
	_append_box_surface(
		surface, Vector3(0.0, 1.15, 0.0), Vector3(0.54, 0.17, 0.25),
		Color("d9ddd8")
	)
	_append_box_surface(
		surface, Vector3(0.0, 1.36, 0.0), Vector3(0.28, 0.28, 0.28),
		Color("ead2b8")
	)
	var mesh := surface.commit() as ArrayMesh
	_procedural_mesh_cache["spectator"] = mesh
	return mesh


func _spectator_terrace_mesh() -> ArrayMesh:
	if _procedural_mesh_cache.has("spectator_terrace"):
		return _procedural_mesh_cache["spectator_terrace"] as ArrayMesh
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(_instance_color_material("spectator_terrace", 0.96))
	for step_index in 4:
		var height := 1.60 + float(step_index) * 0.55
		_append_box_surface(
			surface,
			Vector3(
				0.0, height * 0.5,
				(float(step_index) + 0.5) * CROWD_TERRACE_STEP_DEPTH
			),
			Vector3(38.0, height, CROWD_TERRACE_STEP_DEPTH),
			Color("68747a") if step_index % 2 == 0 else Color("7c878a")
		)
	# A low teal nosing gives the terrace a deliberate circuit-venue identity.
	_append_box_surface(
		surface, Vector3(0.0, 1.50, -0.045), Vector3(37.2, 0.18, 0.09),
		Color("4bcab0")
	)
	var mesh := surface.commit() as ArrayMesh
	_procedural_mesh_cache["spectator_terrace"] = mesh
	return mesh


func _append_box_surface(
	surface: SurfaceTool,
	center: Vector3,
	size: Vector3,
	color: Color
	) -> void:
	var half := size * 0.5
	var corners := [
		Vector3(-half.x, -half.y, -half.z),
		Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, half.y, -half.z),
		Vector3(-half.x, half.y, -half.z),
		Vector3(-half.x, -half.y, half.z),
		Vector3(half.x, -half.y, half.z),
		Vector3(half.x, half.y, half.z),
		Vector3(-half.x, half.y, half.z),
	]
	var faces := [
		{"normal": Vector3(0.0, 0.0, -1.0), "corners": [0, 3, 2, 1]},
		{"normal": Vector3(0.0, 0.0, 1.0), "corners": [4, 5, 6, 7]},
		{"normal": Vector3(-1.0, 0.0, 0.0), "corners": [0, 4, 7, 3]},
		{"normal": Vector3(1.0, 0.0, 0.0), "corners": [1, 2, 6, 5]},
		{"normal": Vector3(0.0, -1.0, 0.0), "corners": [0, 1, 5, 4]},
		{"normal": Vector3(0.0, 1.0, 0.0), "corners": [3, 7, 6, 2]},
	]
	for face_variant in faces:
		var face: Dictionary = face_variant
		var indices: Array = face["corners"]
		for corner_index in [0, 1, 2, 0, 2, 3]:
			surface.set_normal(face["normal"] as Vector3)
			surface.set_color(color)
			surface.add_vertex(center + corners[int(indices[corner_index])])


func _instance_color_material(cache_suffix: String, roughness: float) -> StandardMaterial3D:
	var cache_key := "instance_color_%s_%.2f" % [cache_suffix, roughness]
	if _material_cache.has(cache_key):
		return _material_cache[cache_key] as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.metallic = 0.0
	material.roughness = roughness
	material.vertex_color_use_as_albedo = true
	# Every procedural venue mesh is closed and has outward-facing triangles.
	# Backface culling halves needless fence-side overdraw on mobile GPUs.
	material.cull_mode = BaseMaterial3D.CULL_BACK
	_material_cache[cache_key] = material
	return material


func _add_colored_mesh_multimesh(
	instance_name: String,
	mesh: Mesh,
	transforms: Array,
	colors: Array,
	visibility_range_end: float
	) -> void:
	if mesh == null or transforms.is_empty() or transforms.size() != colors.size():
		return
	var local_transforms := transforms
	var batch_transform := Transform3D.IDENTITY
	if visibility_range_end > 0.0:
		var absolute_bounds := _transformed_instances_aabb(mesh.get_aabb(), transforms)
		batch_transform.origin = absolute_bounds.get_center()
		var to_batch_local := batch_transform.affine_inverse()
		local_transforms = []
		for transform_variant in transforms:
			local_transforms.append(
				to_batch_local * (transform_variant as Transform3D)
			)
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.mesh = mesh
	multi_mesh.instance_count = local_transforms.size()
	for index in local_transforms.size():
		multi_mesh.set_instance_transform(
			index, local_transforms[index] as Transform3D
		)
		multi_mesh.set_instance_color(index, colors[index] as Color)
	multi_mesh.custom_aabb = _transformed_instances_aabb(
		mesh.get_aabb(), local_transforms
	)
	var multi_mesh_instance := MultiMeshInstance3D.new()
	multi_mesh_instance.name = instance_name
	multi_mesh_instance.transform = batch_transform
	multi_mesh_instance.multimesh = multi_mesh
	multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	multi_mesh_instance.visibility_range_end = visibility_range_end
	multi_mesh_instance.extra_cull_margin = 2.0
	add_child(multi_mesh_instance)


func _transformed_instances_aabb(bounds: AABB, transforms: Array) -> AABB:
	var combined := AABB()
	var found := false
	for transform_variant in transforms:
		var instance_transform: Transform3D = transform_variant
		for corner_index in 8:
			var point := instance_transform * bounds.get_endpoint(corner_index)
			if not found:
				combined = AABB(point, Vector3.ZERO)
				found = true
			else:
				combined = combined.expand(point)
	return combined if found else AABB()


static func _mesh_triangle_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var triangles := 0
	for surface_index in mesh.get_surface_count():
		var index_count: int = mesh.surface_get_array_index_len(surface_index)
		var vertex_count: int = mesh.surface_get_array_len(surface_index)
		triangles += index_count / 3 if index_count > 0 \
				else vertex_count / 3
	return triangles


func _mesh_asset_data(asset_name: String, asset_root: String) -> Dictionary:
	var cache_key := asset_root + asset_name
	if _mesh_asset_cache.has(cache_key):
		return Dictionary(_mesh_asset_cache[cache_key])
	var packed := _load_scene(asset_name, asset_root)
	if packed == null:
		_mesh_asset_cache[cache_key] = {}
		return {}
	var imported := packed.instantiate()
	if imported == null:
		_mesh_asset_cache[cache_key] = {}
		return {}
	var mesh_instance: MeshInstance3D
	if imported is MeshInstance3D:
		mesh_instance = imported as MeshInstance3D
	else:
		var candidates := imported.find_children("*", "MeshInstance3D", true, false)
		if not candidates.is_empty():
			mesh_instance = candidates[0] as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		imported.free()
		_mesh_asset_cache[cache_key] = {}
		return {}
	var result := {
		"mesh": mesh_instance.mesh,
		"bounds": mesh_instance.get_aabb(),
	}
	imported.free()
	_mesh_asset_cache[cache_key] = result
	return result


func _fit_asset_transform(bounds: AABB, target_size: Vector3) -> Transform3D:
	var safe_size := Vector3(
		maxf(bounds.size.x, 0.001),
		maxf(bounds.size.y, 0.001),
		maxf(bounds.size.z, 0.001)
	)
	var scale_value := Vector3(
		target_size.x / safe_size.x,
		target_size.y / safe_size.y,
		target_size.z / safe_size.z
	)
	var floor_center := Vector3(
		bounds.get_center().x, bounds.position.y, bounds.get_center().z
	)
	return Transform3D(
		Basis.from_scale(scale_value), -(floor_center * scale_value)
	)


func _add_asset_multimesh(
		instance_name: String,
		asset_name: String,
		asset_root: String,
		transforms: Array,
		cast_shadows: bool,
		visibility_range_end: float = 0.0
	) -> void:
	if transforms.is_empty():
		return
	var mesh_data := _mesh_asset_data(asset_name, asset_root)
	if mesh_data.is_empty():
		return
	var local_transforms := transforms
	var batch_transform := Transform3D.IDENTITY
	if visibility_range_end > 0.0:
		var absolute_bounds := _transformed_instances_aabb(
			mesh_data["bounds"] as AABB, transforms
		)
		batch_transform.origin = absolute_bounds.get_center()
		var to_batch_local := batch_transform.affine_inverse()
		local_transforms = []
		for transform_variant in transforms:
			local_transforms.append(
				to_batch_local * (transform_variant as Transform3D)
			)
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.mesh = mesh_data["mesh"] as Mesh
	multi_mesh.instance_count = local_transforms.size()
	for index in local_transforms.size():
		multi_mesh.set_instance_transform(
			index, local_transforms[index] as Transform3D
		)
	multi_mesh.custom_aabb = _transformed_instances_aabb(
		mesh_data["bounds"] as AABB, local_transforms
	)
	var multi_mesh_instance := MultiMeshInstance3D.new()
	multi_mesh_instance.name = instance_name
	multi_mesh_instance.transform = batch_transform
	multi_mesh_instance.multimesh = multi_mesh
	multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if cast_shadows and not _low_graphics \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if visibility_range_end > 0.0:
		multi_mesh_instance.visibility_range_end = visibility_range_end
		multi_mesh_instance.visibility_range_end_margin = minf(
			24.0, visibility_range_end * 0.12
		)
		multi_mesh_instance.visibility_range_fade_mode = \
			GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(multi_mesh_instance)


func _add_box_multimesh(
		instance_name: String,
		size: Vector3,
		material: StandardMaterial3D,
		transforms: Array,
		cast_shadows: bool
	) -> void:
	if transforms.is_empty():
		return
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.mesh = box
	multi_mesh.instance_count = transforms.size()
	for index in transforms.size():
		multi_mesh.set_instance_transform(index, transforms[index] as Transform3D)
	var multi_mesh_instance := MultiMeshInstance3D.new()
	multi_mesh_instance.name = instance_name
	multi_mesh_instance.multimesh = multi_mesh
	multi_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if cast_shadows and not _low_graphics \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(multi_mesh_instance)


func _record_known_clearance(
	kind: String,
	prop_name: String,
	clearance_meters: float,
	track_envelope_meters: float
	) -> void:
	_clearance_records.append({
		"name": prop_name,
		"kind": kind,
		"minimum_lateral_meters": track_envelope_meters + clearance_meters,
		"track_envelope_meters": track_envelope_meters,
		"clearance_meters": clearance_meters,
	})


func _record_layout(kind: String, placement: Transform3D, color: Color) -> void:
	_layout_records.append({
		"kind": kind,
		"origin": _quantized_vector(placement.origin),
		"basis_x": _quantized_vector(placement.basis.x),
		"basis_y": _quantized_vector(placement.basis.y),
		"basis_z": _quantized_vector(placement.basis.z),
		"color": color.to_html(),
	})


static func _quantized_vector(value: Vector3) -> Array[float]:
	return [
		snappedf(value.x, 0.0001),
		snappedf(value.y, 0.0001),
		snappedf(value.z, 0.0001),
	]


func _record_aabb_clearance(
	track: RaceTrackQuery,
	distance_hint: float,
	prop_transform: Transform3D,
	bounds: AABB,
	kind: String,
	prop_name: String,
	use_global_query: bool = false
	) -> void:
	var minimum := _minimum_aabb_lateral_meters(
		track, distance_hint, prop_transform, bounds, use_global_query
	)
	var envelope := _track_envelope_meters(track)
	_clearance_records.append({
		"name": prop_name,
		"kind": kind,
		"minimum_lateral_meters": minimum,
		"track_envelope_meters": envelope,
		"clearance_meters": minimum - envelope,
	})


func _aabb_clearance_meters(
	track: RaceTrackQuery,
	prop_transform: Transform3D,
	bounds: AABB,
	use_global_query: bool = false
	) -> float:
	var minimum := _minimum_aabb_lateral_meters(
		track, 0.0, prop_transform, bounds, use_global_query
	)
	return minimum - _track_envelope_meters(track)


func _prepare_clearance_index(track: RaceTrackQuery) -> void:
	_clearance_centerline = track.centerline.duplicate()
	_clearance_segment_cells.clear()
	if _clearance_centerline.size() < 3:
		return
	for segment_index in _clearance_centerline.size():
		var start := _clearance_centerline[segment_index]
		var finish := _clearance_centerline[
			(segment_index + 1) % _clearance_centerline.size()
		]
		var minimum := start.min(finish)
		var maximum := start.max(finish)
		var minimum_cell := _clearance_cell(minimum)
		var maximum_cell := _clearance_cell(maximum)
		for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
			for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
				var cell := Vector2i(cell_x, cell_y)
				var segment_indices: Array = _clearance_segment_cells.get(
					cell, []
				)
				segment_indices.append(segment_index)
				_clearance_segment_cells[cell] = segment_indices


func _topology_aabb_clearance_meters(
	track: RaceTrackQuery,
	prop_transform: Transform3D,
	bounds: AABB
	) -> float:
	# The route-local nearest query is ideal for cars, but fixed venue objects
	# must also clear geometrically close sections that can be a full sector away.
	# A deterministic segment grid keeps that whole-route test cheap enough for
	# mobile race loading while preserving the same nine-point AABB sampling used
	# by the diagnostic clearance contract.
	if _clearance_centerline.size() < 3 or _clearance_segment_cells.is_empty():
		return _aabb_clearance_meters(track, prop_transform, bounds, true)
	var envelope := _track_envelope_meters(track)
	var query_radius_authority := (
		envelope + MINIMUM_FIXED_PROP_CLEARANCE_METERS
				+ CLEARANCE_QUERY_MARGIN_METERS
	) / Mapper.WORLD_UNIT_TO_METERS
	var minimum_authority := INF
	var world_transform := global_transform * prop_transform
	for x_index in 3:
		for z_index in 3:
			var local_point := Vector3(
				lerpf(bounds.position.x, bounds.end.x, float(x_index) * 0.5),
				bounds.get_center().y,
				lerpf(bounds.position.z, bounds.end.z, float(z_index) * 0.5)
			)
			var world_point := world_transform * local_point
			var authority_point := Vector2(world_point.x, world_point.z) \
					/ Mapper.WORLD_UNIT_TO_METERS
			var query_extent := Vector2.ONE * query_radius_authority
			var minimum_cell := _clearance_cell(authority_point - query_extent)
			var maximum_cell := _clearance_cell(authority_point + query_extent)
			var seen := PackedByteArray()
			seen.resize(_clearance_centerline.size())
			for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
				for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
					var segment_indices: Array = _clearance_segment_cells.get(
						Vector2i(cell_x, cell_y), []
					)
					for segment_index_variant in segment_indices:
						var segment_index := int(segment_index_variant)
						if seen[segment_index] != 0:
							continue
						seen[segment_index] = 1
						var start := _clearance_centerline[segment_index]
						var finish := _clearance_centerline[
							(segment_index + 1) % _clearance_centerline.size()
						]
						minimum_authority = minf(
							minimum_authority,
							_point_segment_distance(
								authority_point, start, finish
							)
						)
	if is_inf(minimum_authority):
		# No route segment even entered the conservative query square, so the
		# object is known to exceed the required envelope by the full margin.
		return MINIMUM_FIXED_PROP_CLEARANCE_METERS \
				+ CLEARANCE_QUERY_MARGIN_METERS
	return minimum_authority * Mapper.WORLD_UNIT_TO_METERS - envelope


static func _clearance_cell(point: Vector2) -> Vector2i:
	return Vector2i(
		floori(point.x / CLEARANCE_INDEX_CELL_SIZE_AUTHORITY),
		floori(point.y / CLEARANCE_INDEX_CELL_SIZE_AUTHORITY)
	)


static func _point_segment_distance(
	point: Vector2,
	start: Vector2,
	finish: Vector2
	) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0000000001:
		return point.distance_to(start)
	var amount := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * amount)


func _minimum_aabb_lateral_meters(
	track: RaceTrackQuery,
	distance_hint: float,
	prop_transform: Transform3D,
	bounds: AABB,
	use_global_query: bool
	) -> float:
	var minimum := INF
	var world_transform := global_transform * prop_transform
	for x_index in 3:
		for z_index in 3:
			var local_point := Vector3(
				lerpf(bounds.position.x, bounds.end.x, float(x_index) * 0.5),
				bounds.get_center().y,
				lerpf(bounds.position.z, bounds.end.z, float(z_index) * 0.5)
			)
			var world_point := world_transform * local_point
			var authority_point := Vector2(world_point.x, world_point.z) \
					/ Mapper.WORLD_UNIT_TO_METERS
			var projection := track.nearest(authority_point) \
					if use_global_query else track.nearest_continuous(
						authority_point, distance_hint, 0,
						maxf(track.track_width * 16.0, 256.0)
					)
			if not projection.is_empty():
				minimum = minf(
					minimum,
					absf(float(projection["signed_lateral"])) \
							* Mapper.WORLD_UNIT_TO_METERS
				)
	return minimum


func _instantiate_asset(
		asset_name: String,
		asset_root: String = KENNEY_ASSET_ROOT
	) -> Node3D:
	var packed: PackedScene = _load_scene(asset_name, asset_root)
	if packed == null:
		return null
	var imported := packed.instantiate()
	if imported == null:
		return null
	var holder := Node3D.new()
	var normalized_root := Node3D.new()
	normalized_root.name = "NormalizedAsset"
	holder.add_child(normalized_root)
	if imported is Node3D:
		(imported as Node3D).transform = Transform3D.IDENTITY
	normalized_root.add_child(imported)
	var bounds := _combined_local_bounds(holder)
	if bounds.size.length_squared() > 0.000001:
		normalized_root.position = -Vector3(
			bounds.get_center().x, bounds.position.y, bounds.get_center().z
		)
	if _low_graphics:
		_disable_imported_shadows(imported)
	return holder


func _add_fixed_prop(
		prop: Node3D,
		track: RaceTrackQuery,
		distance: float,
		kind: String
	) -> void:
	add_child(prop)
	var minimum_lateral := _minimum_prop_lateral_meters(prop, track, distance)
	var envelope := _track_envelope_meters(track)
	_clearance_records.append({
		"name": str(prop.name),
		"kind": kind,
		"minimum_lateral_meters": minimum_lateral,
		"track_envelope_meters": envelope,
		"clearance_meters": minimum_lateral - envelope,
	})


func _minimum_prop_lateral_meters(
		prop: Node3D,
		track: RaceTrackQuery,
		distance_hint: float
	) -> float:
	var minimum := INF
	for mesh_node in prop.find_children("*", "MeshInstance3D", true, false):
		var instance := mesh_node as MeshInstance3D
		if instance.mesh == null:
			continue
		var bounds := instance.get_aabb()
		for x_index in 3:
			for z_index in 3:
				var local_point := Vector3(
					lerpf(bounds.position.x, bounds.end.x, float(x_index) * 0.5),
					bounds.get_center().y,
					lerpf(bounds.position.z, bounds.end.z, float(z_index) * 0.5)
				)
				var world_point := instance.global_transform * local_point
				var authority_point := Vector2(world_point.x, world_point.z) \
						/ Mapper.WORLD_UNIT_TO_METERS
				var projection := track.nearest_continuous(
					authority_point, distance_hint, 0,
					maxf(track.track_width * 16.0, 256.0)
				)
				if not projection.is_empty():
					minimum = minf(
						minimum,
						absf(float(projection["signed_lateral"])) \
								* Mapper.WORLD_UNIT_TO_METERS
					)
	return minimum


func _combined_local_bounds(root_node: Node3D) -> AABB:
	return _descendant_local_bounds(root_node, Transform3D.IDENTITY, true)


func _descendant_local_bounds(
		node: Node,
		parent_transform: Transform3D,
		skip_node_transform: bool = false
	) -> AABB:
	var node_transform := parent_transform
	if node is Node3D and not skip_node_transform:
		node_transform = parent_transform * (node as Node3D).transform
	var combined := AABB()
	var found := false
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mesh_bounds := (node as MeshInstance3D).get_aabb()
		for corner_index in 8:
			var point := node_transform * mesh_bounds.get_endpoint(corner_index)
			if not found:
				combined = AABB(point, Vector3.ZERO)
				found = true
			else:
				combined = combined.expand(point)
	for child in node.get_children():
		var child_bounds := _descendant_local_bounds(child, node_transform)
		if child_bounds.size.length_squared() <= 0.000001:
			continue
		if not found:
			combined = child_bounds
			found = true
		else:
			combined = combined.merge(child_bounds)
	return combined if found else AABB()


static func _track_envelope_meters(track: RaceTrackQuery) -> float:
	var road_half_width := track.track_width * 0.5 * Mapper.WORLD_UNIT_TO_METERS
	var runoff_width := maxf(
		TrackBuilder.RUNOFF_MINIMUM_WIDTH_METERS,
		track.track_width * Mapper.WORLD_UNIT_TO_METERS \
				* TrackBuilder.RUNOFF_TRACK_WIDTH_FACTOR
	)
	return road_half_width + TrackBuilder.CURB_WIDTH_METERS + runoff_width


func _load_scene(
		asset_name: String,
		asset_root: String = KENNEY_ASSET_ROOT
	) -> PackedScene:
	var cache_key := asset_root + asset_name
	if _scene_cache.has(cache_key):
		return _scene_cache[cache_key] as PackedScene
	var path := asset_root + asset_name
	if not ResourceLoader.exists(path):
		_scene_cache[cache_key] = null
		return null
	var resource := ResourceLoader.load(path)
	if resource is PackedScene:
		_scene_cache[cache_key] = resource
		return resource as PackedScene
	_scene_cache[cache_key] = null
	return null


func _disable_imported_shadows(root: Node) -> void:
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in root.get_children():
		_disable_imported_shadows(child)


func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var cache_key := "%s_%.2f" % [color.to_html(), roughness]
	if _material_cache.has(cache_key):
		return _material_cache[cache_key] as StandardMaterial3D
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	_material_cache[cache_key] = material
	return material


func _clear_children() -> void:
	for child in get_children():
		remove_child(child)
		child.free()
