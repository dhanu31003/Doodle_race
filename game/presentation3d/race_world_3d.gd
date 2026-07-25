class_name RaceWorld3D
extends Control
## True three-dimensional race presentation driven by the existing deterministic
## two-dimensional authority. Track, terrain, and scenery stay fixed at world
## identity; interpolated cars and an authored vehicle-mounted camera move
## through that world.

const Mapper := preload("res://game/presentation3d/world_coordinate_mapper.gd")
const TrackBuilder := preload("res://game/presentation3d/track_mesh_builder_3d.gd")
const CameraRigType := preload("res://game/presentation3d/camera_rig_3d.gd")
const SceneryType := preload("res://game/presentation3d/trackside_scenery_3d.gd")
const CollisionSparkPoolType := preload(
	"res://game/presentation3d/collision_spark_pool_3d.gd"
)
const RoadSurfaceEffectsType := preload(
	"res://game/presentation3d/road_surface_effects_3d.gd"
)

const CAMERA_COCKPIT: StringName = &"cockpit"
const CAMERA_CHASE: StringName = &"chase"
const CAR_VISUAL_PATH := "res://game/presentation3d/formula_car_visual_3d.gd"
const DAY_HDRI_PATH := \
		"res://assets/final/3d/environment/kloofendal_43d_clear_puresky_1k.hdr"
const GRASS_DIFFUSE_PATH := \
		"res://assets/final/3d/materials/sparse_grass_diff_1k.jpg"
const GRASS_NORMAL_PATH := \
		"res://assets/final/3d/materials/sparse_grass_nor_gl_1k.jpg"
const VEHICLE_RIDE_HEIGHT_METERS := 0.075
const VEHICLE_GRADE_PROBE_AUTHORITY_UNITS := 9.0
const MAX_GROUNDED_PITCH_RADIANS := deg_to_rad(28.0)
const MAX_AIRBORNE_PITCH_RADIANS := deg_to_rad(10.0)

const AI_COLORS := [
	Color("ff5364"), Color("40bff5"), Color("ffc342"), Color("9b7cff"),
	Color("3fdb83"), Color("23ced5"), Color("ff81ae"), Color("f28b3d"),
	Color("b8dc45"), Color("3978e8"), Color("eceff2"),
]

var camera_mode: StringName = CAMERA_CHASE

var _track: RaceTrackQuery
var _player: RaceEntry
var _entries: Array[RaceEntry] = []
var _command: RaceInput
var _alpha := 1.0
var _player_color := Color("18d8a0")
var _entry_colors: Dictionary = {}
var _low_graphics := false
var _reduced_motion := false
var _high_contrast := false
var _screen_shake_strength := 0.35

var _viewport_container: SubViewportContainer
var _viewport: SubViewport
var _world_root: Node3D
var _ground_root: Node3D
var _track_root: Node3D
var _scenery_root: TracksideScenery3D
var _vehicle_root: Node3D
var _collision_spark_pool: CollisionSparkPool3D
var _road_surface_effects: RoadSurfaceEffects3D
var _camera_rig: FormulaCameraRig3D
var _world_environment: WorldEnvironment
var _sun: DirectionalLight3D
var _vehicles: Dictionary = {}
var _vehicle_recovery_serials: Dictionary = {}
var _vehicle_contact_serials: Dictionary = {}
var _car_visual_script: Script
var _scene_built := false
var _hdri_active := false
var _last_track_stats: Dictionary = {}
var _player_visual_id := ""
var _last_recovery_snap_id := ""
var _last_player_recovery_snap_serial := -1
var _recovery_snap_count := 0
var _vehicle_render_budget_apply_count := 0
var _static_world_rebuild_count := 0
var _mobile_remote_animation_phase := 0
var _remote_animation_update_count := 0
var _remote_animation_skip_count := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_ensure_scene()
	if not resized.is_connected(_sync_viewport_size):
		resized.connect(_sync_viewport_size)
	_sync_viewport_size()


func configure(
		track: RaceTrackQuery,
		mode: StringName = CAMERA_CHASE,
		player_color: Color = Color("18d8a0")
	) -> void:
	_ensure_scene()
	_track = track
	_player_color = player_color
	_player = null
	_entries.clear()
	_command = null
	_mobile_remote_animation_phase = 0
	_remote_animation_update_count = 0
	_remote_animation_skip_count = 0
	_clear_vehicles()
	set_camera_mode(mode)
	_rebuild_static_world()
	if _track != null and _track.is_valid():
		var start := _track.sample_at_distance(0.0)
		var heading := Vector2(start.get("tangent", Vector2.RIGHT)).angle()
		var start_transform := Mapper.authority_transform(
			start.get("position", Vector2.ZERO), heading,
			float(start.get("elevation_level", 0.0)), VEHICLE_RIDE_HEIGHT_METERS
		)
		_camera_rig.update_target(start_transform, 0.0, 0.0, 0)
		_camera_rig.clear_socket_targets()
		_camera_rig.snap_to_target()


func configure_accessibility(
		low_graphics: bool,
		reduced_motion: bool,
		high_contrast: bool,
		screen_shake_strength: float = 0.35
	) -> void:
	_ensure_scene()
	var previous_mobile_budget := _uses_mobile_render_budget()
	var scenery_quality_changed := _low_graphics != low_graphics \
			or _high_contrast != high_contrast
	var motion_profile_changed := _reduced_motion != reduced_motion
	_low_graphics = low_graphics
	_reduced_motion = reduced_motion
	_high_contrast = high_contrast
	_screen_shake_strength = 0.0 if reduced_motion else clampf(
		screen_shake_strength, 0.0, 1.0
	)
	var mobile_budget_changed := previous_mobile_budget \
			!= _uses_mobile_render_budget()
	if mobile_budget_changed:
		_apply_vehicle_render_budgets()
	_camera_rig.configure_accessibility(_reduced_motion, _screen_shake_strength)
	_apply_render_quality()
	_configure_daylight()
	if mobile_budget_changed and _track != null and _track.is_valid():
		# Track tessellation and scenery density both depend on this profile. This
		# runs only when settings/device tier changes—not during race frames.
		_rebuild_static_world()
	elif scenery_quality_changed and _track != null and _track.is_valid():
		_scenery_root.configure(
			_track, _uses_mobile_render_budget(), _high_contrast
		)
	if not mobile_budget_changed and motion_profile_changed \
			and _track != null and _track.is_valid():
		_road_surface_effects.configure(
			_track, _uses_mobile_render_budget(), _reduced_motion
		)


func configure_entry_colors(colors_by_participant: Dictionary) -> void:
	_entry_colors = colors_by_participant.duplicate()
	for id in _vehicles:
		var visual := _vehicles[id] as Node3D
		if visual == null or not is_instance_valid(visual):
			continue
		var entry := _entry_for_id(str(id))
		if entry != null and visual.has_method("set_team_color"):
			visual.call("set_team_color", _color_for_entry(entry))


func update_race(
		player: RaceEntry,
		entries: Array[RaceEntry],
		command: RaceInput,
		interpolation_alpha: float
	) -> void:
	_ensure_scene()
	_player = player
	_entries = entries.duplicate()
	_command = command
	_alpha = clampf(interpolation_alpha, 0.0, 1.0)
	_update_vehicle_presentations()


func set_camera_mode(mode: StringName) -> void:
	camera_mode = CAMERA_COCKPIT if mode == CAMERA_COCKPIT else CAMERA_CHASE
	if _scene_built:
		_camera_rig.set_camera_mode(camera_mode)
		_sync_player_cockpit_visibility()


func has_race_authority() -> bool:
	return _track != null and _track.is_valid() \
			and _player != null and _player.state != null


func clear_race_authority() -> void:
	_track = null
	_player = null
	_entries.clear()
	_command = null
	_alpha = 1.0
	_player_visual_id = ""
	_last_recovery_snap_id = ""
	_last_player_recovery_snap_serial = -1
	_recovery_snap_count = 0
	if not _scene_built:
		return
	_clear_vehicles()
	_clear_static_world()
	_camera_rig.clear_target()
	_camera_rig.clear_socket_targets()


func debug_snapshot() -> Dictionary:
	## Stable inspection contract used by focused tests and presentation tooling.
	_ensure_scene()
	var player_visual: Node3D = _vehicles.get(_player_visual_id) as Node3D
	var player_transform := Transform3D.IDENTITY
	if player_visual != null and is_instance_valid(player_visual):
		player_transform = player_visual.global_transform
	var camera_transform := Transform3D.IDENTITY
	if _camera_rig.camera != null and is_instance_valid(_camera_rig.camera):
		camera_transform = _camera_rig.camera.global_transform
	var track_transform := _track_root.transform
	var scenery_transform := _scenery_root.transform
	var vehicle_transforms: Dictionary = {}
	var cockpit_lod_counts := {
		"player_cockpit": 0,
		"remote_exterior": 0,
	}
	var maximum_remote_meshes := 0
	var maximum_remote_nodes := 0
	var maximum_remote_triangles := 0
	var maximum_remote_shadow_casters := 0
	var minimum_remote_bounded_details := 999_999
	var remote_wheel_batch_instances := 0
	var player_cockpit_detail_visible := false
	var player_visible_cockpit_details := 0
	var player_cockpit_visibility_apply_count := 0
	var player_surface_appearance: Dictionary = {}
	for id in _vehicles:
		var vehicle := _vehicles[id] as Node3D
		if vehicle != null and is_instance_valid(vehicle):
			vehicle_transforms[str(id)] = vehicle.global_transform
			if vehicle.has_method("presentation_snapshot"):
				var vehicle_presentation: Dictionary = vehicle.call(
					"presentation_snapshot"
				)
				var lod_tier := str(vehicle_presentation.get("lod_tier", ""))
				if cockpit_lod_counts.has(lod_tier):
					cockpit_lod_counts[lod_tier] = int(cockpit_lod_counts[lod_tier]) + 1
				if str(id) == _player_visual_id:
					player_surface_appearance = vehicle_presentation.duplicate(true)
					player_cockpit_detail_visible = bool(vehicle_presentation.get(
						"cockpit_detail_visible", false
					))
					player_visible_cockpit_details = int(vehicle_presentation.get(
						"visible_cockpit_detail_count", 0
					))
					player_cockpit_visibility_apply_count = int(vehicle_presentation.get(
						"cockpit_visibility_apply_count", 0
					))
				if lod_tier == "remote_exterior":
					maximum_remote_meshes = maxi(
						maximum_remote_meshes,
						int(vehicle_presentation.get("mesh_instance_count", 0))
					)
					maximum_remote_nodes = maxi(
						maximum_remote_nodes,
						int(vehicle_presentation.get("presentation_node_count", 0))
					)
					maximum_remote_triangles = maxi(
						maximum_remote_triangles,
						int(vehicle_presentation.get("triangle_count", 0))
					)
					maximum_remote_shadow_casters = maxi(
						maximum_remote_shadow_casters,
						int(vehicle_presentation.get("remote_shadow_caster_count", 0))
					)
					minimum_remote_bounded_details = mini(
						minimum_remote_bounded_details,
						int(vehicle_presentation.get("remote_bounded_detail_count", 0))
					)
					remote_wheel_batch_instances += int(
						vehicle_presentation.get("remote_wheel_batch_instances", 0)
					)
	var player_recovery_serial := -1
	if _player != null and _player.state != null:
		player_recovery_serial = _player.state.recovery_hard_snap_serial
	return {
		"has_race_authority": has_race_authority(),
		"camera_mode": camera_mode,
		"track_root_transform": track_transform,
		"scenery_root_transform": scenery_transform,
		"track_root_origin": track_transform.origin,
		"scenery_root_origin": scenery_transform.origin,
		"player_world_transform": player_transform,
		"camera_world_transform": camera_transform,
		"vehicle_world_transforms": vehicle_transforms,
		"vehicle_count": _vehicles.size(),
		"cockpit_lod_counts": cockpit_lod_counts,
		"maximum_remote_meshes": maximum_remote_meshes,
		"maximum_remote_nodes": maximum_remote_nodes,
		"maximum_remote_triangles": maximum_remote_triangles,
		"maximum_remote_shadow_casters": maximum_remote_shadow_casters,
		"minimum_remote_bounded_details": (
			0 if minimum_remote_bounded_details == 999_999
			else minimum_remote_bounded_details
		),
		"remote_wheel_batch_instances": remote_wheel_batch_instances,
		"player_cockpit_detail_visible": player_cockpit_detail_visible,
		"player_visible_cockpit_details": player_visible_cockpit_details,
		"player_cockpit_visibility_apply_count": player_cockpit_visibility_apply_count,
		"player_road_surface": str(player_surface_appearance.get("road_surface", "")),
		"player_surface_coating_visible": bool(
			player_surface_appearance.get("surface_coating_visible", false)
		),
		"player_surface_coating_count": int(
			player_surface_appearance.get("surface_coating_count", 0)
		),
		"player_surface_coating_visible_count": int(
			player_surface_appearance.get("surface_coating_visible_count", 0)
		),
		"player_surface_coating_opacity": float(
			player_surface_appearance.get("surface_coating_opacity", 0.0)
		),
		"player_surface_lap_progress": float(
			player_surface_appearance.get("surface_lap_progress", 0.0)
		),
		"player_mud_accumulation": float(
			player_surface_appearance.get("mud_accumulation", 0.0)
		),
		"mobile_device_profile": _is_mobile_runtime(),
		"mobile_render_budget": _uses_mobile_render_budget(),
		"mobile_remote_animation_stride": 2 if _uses_mobile_render_budget() else 1,
		"remote_animation_update_count": _remote_animation_update_count,
		"remote_animation_skip_count": _remote_animation_skip_count,
		"vehicle_render_budget_apply_count": _vehicle_render_budget_apply_count,
		"static_world_rebuild_count": _static_world_rebuild_count,
		"viewport_stretch_shrink": _viewport_container.stretch_shrink,
		"viewport_msaa_3d": _viewport.msaa_3d,
		"viewport_screen_space_aa": _viewport.screen_space_aa,
		"ambient_light_energy": (
			_world_environment.environment.ambient_light_energy
			if _world_environment.environment != null else 0.0
		),
		"ambient_light_sky_contribution": (
			_world_environment.environment.ambient_light_sky_contribution
			if _world_environment.environment != null else 0.0
		),
		"background_energy_multiplier": (
			_world_environment.environment.background_energy_multiplier
			if _world_environment.environment != null else 0.0
		),
		"tonemap_exposure": (
			_world_environment.environment.tonemap_exposure
			if _world_environment.environment != null else 0.0
		),
		"adjustment_enabled": (
			_world_environment.environment.adjustment_enabled
			if _world_environment.environment != null else false
		),
		"adjustment_brightness": (
			_world_environment.environment.adjustment_brightness
			if _world_environment.environment != null else 0.0
		),
		"adjustment_contrast": (
			_world_environment.environment.adjustment_contrast
			if _world_environment.environment != null else 0.0
		),
		"adjustment_saturation": (
			_world_environment.environment.adjustment_saturation
			if _world_environment.environment != null else 0.0
		),
		"sun_light_energy": _sun.light_energy,
		"sun_shadow_max_distance": _sun.directional_shadow_max_distance,
		"fog_enabled": (
			_world_environment.environment.fog_enabled
			if _world_environment.environment != null else false
		),
		"viewport_present": _viewport != null and is_instance_valid(_viewport),
		"camera_present": _camera_rig.camera != null \
				and is_instance_valid(_camera_rig.camera),
		"environment_present": _world_environment.environment != null,
		"directional_sun_present": _sun != null and is_instance_valid(_sun),
		"recovery_serials": _vehicle_recovery_serials.duplicate(),
		"vehicle_contact_serials": _vehicle_contact_serials.duplicate(),
		"collision_sparks": (
			_collision_spark_pool.presentation_snapshot()
			if _collision_spark_pool != null and is_instance_valid(_collision_spark_pool)
			else {}
		),
		"road_surface_effects": (
			_road_surface_effects.presentation_snapshot()
			if _road_surface_effects != null and is_instance_valid(_road_surface_effects)
			else {}
		),
		"player_recovery_hard_snap_serial": player_recovery_serial,
		"player_recovery_serial": player_recovery_serial,
		"last_recovery_snap_id": _last_recovery_snap_id,
		"last_player_recovery_snap_serial": _last_player_recovery_snap_serial,
		"presentation_snap_serial": _last_player_recovery_snap_serial,
		"presentation_snap_count": _recovery_snap_count,
		"fixed_world_invariant": track_transform.is_equal_approx(Transform3D.IDENTITY) \
				and scenery_transform.is_equal_approx(Transform3D.IDENTITY),
		"hdri_active": _hdri_active,
		"track_stats": _last_track_stats.duplicate(true),
		"scenery_clearance": _scenery_root.debug_clearance_snapshot(),
	}


func debug_viewport() -> SubViewport:
	_ensure_scene()
	return _viewport


func debug_camera() -> Camera3D:
	_ensure_scene()
	return _camera_rig.camera


func debug_collision_spark_pool() -> CollisionSparkPool3D:
	_ensure_scene()
	return _collision_spark_pool


func debug_environment() -> Environment:
	_ensure_scene()
	return _world_environment.environment


func debug_track_root() -> Node3D:
	_ensure_scene()
	return _track_root


func debug_scenery_root() -> Node3D:
	_ensure_scene()
	return _scenery_root


func debug_vehicle_transform(participant_id: StringName) -> Transform3D:
	_ensure_scene()
	var visual := _vehicles.get(str(participant_id)) as Node3D
	if visual == null or not is_instance_valid(visual):
		return Transform3D.IDENTITY
	return visual.global_transform


func _ensure_scene() -> void:
	if _scene_built:
		return
	_scene_built = true
	_viewport_container = SubViewportContainer.new()
	_viewport_container.name = "RaceViewportContainer"
	_viewport_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport_container.stretch = true
	_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_viewport_container)

	_viewport = SubViewport.new()
	_viewport.name = "RaceViewport"
	_viewport.own_world_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_viewport.gui_disable_input = true
	_viewport.physics_object_picking = false
	_viewport_container.add_child(_viewport)

	_world_root = Node3D.new()
	_world_root.name = "FixedRaceWorld"
	_viewport.add_child(_world_root)

	_ground_root = Node3D.new()
	_ground_root.name = "GroundRoot"
	_world_root.add_child(_ground_root)

	_track_root = Node3D.new()
	_track_root.name = "TrackRoot"
	_track_root.transform = Transform3D.IDENTITY
	_world_root.add_child(_track_root)

	_scenery_root = SceneryType.new()
	_scenery_root.name = "SceneryRoot"
	_scenery_root.transform = Transform3D.IDENTITY
	_world_root.add_child(_scenery_root)

	_vehicle_root = Node3D.new()
	_vehicle_root.name = "VehicleRoot"
	_world_root.add_child(_vehicle_root)

	_collision_spark_pool = CollisionSparkPoolType.new()
	_collision_spark_pool.name = "CollisionSparkPool"
	_world_root.add_child(_collision_spark_pool)
	_road_surface_effects = RoadSurfaceEffectsType.new()
	_road_surface_effects.name = "RoadSurfaceEffects"
	_world_root.add_child(_road_surface_effects)

	_camera_rig = CameraRigType.new()
	_camera_rig.name = "FormulaCameraRig"
	_world_root.add_child(_camera_rig)
	_camera_rig.set_camera_mode(camera_mode)
	_camera_rig.configure_accessibility(_reduced_motion, _screen_shake_strength)

	_world_environment = WorldEnvironment.new()
	_world_environment.name = "DaylightEnvironment"
	_world_root.add_child(_world_environment)
	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(-51.0, -32.0, 0.0)
	_world_root.add_child(_sun)
	_configure_daylight()
	_apply_render_quality()
	_sync_viewport_size()


func _configure_daylight() -> void:
	if not _scene_built:
		return
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.ambient_light_color = Color("cbd6db")
	environment.ambient_light_energy = 0.47 if _high_contrast else 0.44
	environment.ambient_light_sky_contribution = 0.72
	environment.background_energy_multiplier = 0.80
	# Turn the HDR sun disc away from the starting straight so the visible dome
	# stays a crisp blue while the authored DirectionalLight3D owns scene shadows.
	environment.sky_rotation = Vector3(0.0, deg_to_rad(152.0), 0.0)
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 0.88
	environment.adjustment_enabled = true
	environment.adjustment_brightness = 0.99
	environment.adjustment_contrast = 1.13 if _high_contrast else 1.08
	environment.adjustment_saturation = 0.96
	environment.fog_enabled = not _uses_mobile_render_budget()
	environment.fog_light_color = Color("e4ecec")
	environment.fog_light_energy = 0.34
	# Only a trace of far-distance aerial perspective: racing surfaces and brake
	# markers remain crisp in the bright daytime presentation.
	environment.fog_density = 0.00014
	environment.fog_sky_affect = 0.06

	var sky := Sky.new()
	_hdri_active = false
	if ResourceLoader.exists(DAY_HDRI_PATH):
		var hdri_resource := ResourceLoader.load(DAY_HDRI_PATH)
		if hdri_resource is Texture2D:
			var panorama := PanoramaSkyMaterial.new()
			panorama.panorama = hdri_resource as Texture2D
			panorama.energy_multiplier = 0.74
			sky.sky_material = panorama
			_hdri_active = true
	if not _hdri_active:
		var procedural := ProceduralSkyMaterial.new()
		procedural.sky_top_color = Color("5b9dcc")
		procedural.sky_horizon_color = Color("c3d7dc")
		procedural.ground_bottom_color = Color("536b48")
		procedural.ground_horizon_color = Color("c1d2bd")
		procedural.sun_angle_max = 18.0
		procedural.sun_curve = 0.09
		procedural.energy_multiplier = 0.80
		sky.sky_material = procedural
	environment.sky = sky
	_world_environment.environment = environment

	_sun.light_color = Color("fff8e8")
	# High Contrast is a post-grade accessibility mode; increasing scene light
	# here previously clipped white barriers and grandstands.
	_sun.light_energy = 1.02
	_sun.shadow_enabled = true
	_sun.directional_shadow_max_distance = (
		145.0 if _low_graphics else (185.0 if _is_mobile_runtime() else 270.0)
	)
	_sun.shadow_blur = 1.35


func _apply_render_quality() -> void:
	if not _scene_built:
		return
	# Low Graphics halves only the 3D SubViewport; HUD/touch controls remain at
	# native resolution. Normal mobile mode keeps full resolution but trades 2x
	# MSAA for inexpensive FXAA, avoiding a blanket quality loss on capable phones.
	_viewport_container.stretch_shrink = 2 if _low_graphics else 1
	_viewport.msaa_3d = Viewport.MSAA_DISABLED \
			if _uses_mobile_render_budget() else Viewport.MSAA_2X
	_viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED \
			if _low_graphics else Viewport.SCREEN_SPACE_AA_FXAA
	_viewport.use_taa = false


func _sync_viewport_size() -> void:
	if not _scene_built or _viewport == null:
		return
	# A stretched SubViewportContainer owns its child's render size. Writing the
	# size here would fight that contract and emits a warning on desktop/mobile.
	if _viewport_container.stretch:
		return
	_viewport.size = Vector2i(
		maxi(roundi(size.x), 2), maxi(roundi(size.y), 2)
	)


func _rebuild_static_world() -> void:
	_static_world_rebuild_count += 1
	_clear_static_world()
	if _track == null or not _track.is_valid():
		return
	_track_root.transform = Transform3D.IDENTITY
	_scenery_root.transform = Transform3D.IDENTITY
	var options := {
		"sample_step_authority": 10.0 \
				if _uses_mobile_render_budget() else 5.0,
		"mobile_surface_budget": _uses_mobile_render_budget(),
	}
	var build_result: Dictionary = TrackBuilder.build(_track, options)
	var circuit_mesh: ArrayMesh
	if build_result.get("ok", false) and build_result.get("mesh") is ArrayMesh:
		circuit_mesh = build_result["mesh"] as ArrayMesh
		_last_track_stats = Dictionary(build_result.get("stats", {})).duplicate(true)
	else:
		circuit_mesh = _fallback_track_mesh(_track)
		_last_track_stats = {
			"fallback": true,
			"reason": str(build_result.get("message", "track_builder_unavailable")),
		}
	var circuit := MeshInstance3D.new()
	circuit.name = "CircuitSurface"
	circuit.mesh = circuit_mesh
	_track_root.add_child(circuit)
	_build_ground(_track)
	_scenery_root.configure(
		_track, _uses_mobile_render_budget(), _high_contrast
	)
	_road_surface_effects.configure(
		_track, _uses_mobile_render_budget(), _reduced_motion
	)


func _build_ground(track: RaceTrackQuery) -> void:
	var bounds := _track_bounds(track)
	var margin := 240.0
	var width := maxf(bounds["max_x"] - bounds["min_x"] + margin * 2.0, 600.0)
	var depth := maxf(bounds["max_z"] - bounds["min_z"] + margin * 2.0, 600.0)
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(width, depth)
	ground_mesh.subdivide_width = 1
	ground_mesh.subdivide_depth = 1
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("6f8f53") if _high_contrast else Color("789462")
	material.roughness = 1.0
	material.texture_repeat = true
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# PlaneMesh uses a normalized UV square. Scaling UV1 converts it into a
	# roughly seven-metre physical tile and prevents a single giant grass photo.
	material.uv1_scale = Vector3(width / 8.0, depth / 8.0, 1.0)
	if ResourceLoader.exists(GRASS_DIFFUSE_PATH, "Texture2D"):
		var grass_diffuse := ResourceLoader.load(GRASS_DIFFUSE_PATH)
		if grass_diffuse is Texture2D:
			material.albedo_texture = grass_diffuse as Texture2D
	if ResourceLoader.exists(GRASS_NORMAL_PATH, "Texture2D"):
		var grass_normal := ResourceLoader.load(GRASS_NORMAL_PATH)
		if grass_normal is Texture2D:
			material.normal_enabled = true
			material.normal_texture = grass_normal as Texture2D
			material.normal_scale = 0.48
	ground_mesh.material = material
	var ground := MeshInstance3D.new()
	ground.name = "GroundPlane"
	ground.mesh = ground_mesh
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ground.position = Vector3(
		(bounds["min_x"] + bounds["max_x"]) * 0.5,
		-0.075,
		(bounds["min_z"] + bounds["max_z"]) * 0.5
	)
	_ground_root.add_child(ground)


func _track_bounds(track: RaceTrackQuery) -> Dictionary:
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	var sample_count := 128
	for index in sample_count:
		var sample := track.sample_at_distance(
			track.total_length * float(index) / float(sample_count)
		)
		var world_position := Mapper.authority_position_to_world(
			sample.get("position", Vector2.ZERO)
		)
		minimum.x = minf(minimum.x, world_position.x)
		minimum.y = minf(minimum.y, world_position.z)
		maximum.x = maxf(maximum.x, world_position.x)
		maximum.y = maxf(maximum.y, world_position.z)
	return {
		"min_x": minimum.x, "max_x": maximum.x,
		"min_z": minimum.y, "max_z": maximum.y,
	}


func _fallback_track_mesh(track: RaceTrackQuery) -> ArrayMesh:
	var segment_count := clampi(ceili(track.total_length / 8.0), 32, 768)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	vertices.resize((segment_count + 1) * 2)
	normals.resize(vertices.size())
	uvs.resize(vertices.size())
	var half_width := track.track_width * 0.5 * Mapper.WORLD_UNIT_TO_METERS
	for index in segment_count + 1:
		var distance := track.total_length * float(index) / float(segment_count)
		var sample := track.sample_at_distance(distance)
		var center := Mapper.authority_position_to_world(
			sample.get("position", Vector2.ZERO),
			float(sample.get("elevation_level", 0.0)),
			Mapper.ROAD_SURFACE_Y_METERS
		)
		var left := Mapper.authority_direction_to_world(
			sample.get("normal", Vector2.UP)
		)
		var vertex := index * 2
		vertices[vertex] = center + left * half_width
		vertices[vertex + 1] = center - left * half_width
		normals[vertex] = Vector3.UP
		normals[vertex + 1] = Vector3.UP
		uvs[vertex] = Vector2(0.0, distance * Mapper.WORLD_UNIT_TO_METERS / 4.0)
		uvs[vertex + 1] = Vector2(1.0, distance * Mapper.WORLD_UNIT_TO_METERS / 4.0)
	for index in segment_count:
		var left_start := index * 2
		var right_start := left_start + 1
		var left_finish := (index + 1) * 2
		var right_finish := left_finish + 1
		indices.append_array(PackedInt32Array([
			left_start, left_finish, right_finish,
			left_start, right_finish, right_start,
		]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("292f36")
	material.roughness = 0.94
	mesh.surface_set_material(0, material)
	return mesh


func _update_vehicle_presentations() -> void:
	var active_ids: Dictionary = {}
	var frame_delta := clampf(get_process_delta_time(), 0.001, 0.1)
	var mobile_budget := _uses_mobile_render_budget()
	var remote_index := 0
	for entry in _entries:
		if entry == null or entry.state == null:
			continue
		var id := str(entry.participant_id)
		if id.is_empty():
			id = str(entry.state.vehicle_id)
		if id.is_empty():
			continue
		active_ids[id] = true
		var is_player := _is_player_entry(entry)
		var visual := _vehicle_for_entry(entry, is_player)
		var current_recovery_serial := entry.state.recovery_hard_snap_serial
		var hard_snap := false
		if _vehicle_recovery_serials.has(id):
			hard_snap = int(_vehicle_recovery_serials[id]) != current_recovery_serial
		elif entry.previous_state != null:
			hard_snap = entry.previous_state.recovery_hard_snap_serial \
					!= current_recovery_serial
		_vehicle_recovery_serials[id] = current_recovery_serial
		var current_contact_serial := maxi(entry.state.vehicle_contact_serial, 0)
		var previous_contact_serial := current_contact_serial
		if _vehicle_contact_serials.has(id):
			previous_contact_serial = int(_vehicle_contact_serials[id])
		elif entry.previous_state != null:
			previous_contact_serial = maxi(entry.previous_state.vehicle_contact_serial, 0)
		_vehicle_contact_serials[id] = current_contact_serial
		visual.visible = true
		visual.transform = _interpolated_vehicle_transform(
			entry, 1.0 if hard_snap else _alpha
		)
		# Opponent transforms remain fully interpolated every display frame. Only
		# presentation-only wheels, suspension, lights and dirt stages are evenly
		# divided across two mobile phases, preventing a full-pack CPU spike.
		var update_animation := true
		if not is_player and mobile_budget:
			update_animation = posmod(
				remote_index + _mobile_remote_animation_phase, 2
			) == 0
			remote_index += 1
			if update_animation:
				_remote_animation_update_count += 1
			else:
				_remote_animation_skip_count += 1
		elif not is_player:
			_remote_animation_update_count += 1
		if update_animation and visual.has_method("set_surface_lap_progress"):
			visual.call(
				"set_surface_lap_progress", _surface_lap_progress_for_entry(entry)
			)
		var entry_command: RaceInput = _command if is_player else null
		if update_animation and visual.has_method("apply_vehicle_state"):
			var surface_bump := 0.0
			if entry.state.is_grounded and not _reduced_motion \
					and _track != null and _track.is_valid():
				surface_bump = _track.surface_bump_height_meters(
					entry.state.track_distance
				)
			visual.call(
				"apply_vehicle_state",
				entry.state,
				entry_command,
				frame_delta,
				surface_bump
			)
		if current_contact_serial > previous_contact_serial:
			_present_vehicle_contact(entry, id, current_contact_serial)
		if is_player:
			_player_visual_id = id
			_update_player_camera(entry, visual, hard_snap)
		if hard_snap:
			_last_recovery_snap_id = id
			_recovery_snap_count += 1
			if is_player:
				_last_player_recovery_snap_serial = current_recovery_serial
	var stale_ids: Array = []
	for id in _vehicles:
		if not active_ids.has(id):
			stale_ids.append(id)
	for id in stale_ids:
		var stale := _vehicles[id] as Node3D
		_vehicles.erase(id)
		_vehicle_recovery_serials.erase(id)
		_vehicle_contact_serials.erase(id)
		if stale != null and is_instance_valid(stale):
			stale.queue_free()
	if _road_surface_effects != null and is_instance_valid(_road_surface_effects):
		_road_surface_effects.update_vehicles(
			_entries, _vehicles, _player_visual_id
		)
	_mobile_remote_animation_phase = (_mobile_remote_animation_phase + 1) % 2 \
			if mobile_budget else 0


func _surface_lap_progress_for_entry(entry: RaceEntry) -> float:
	if entry == null or entry.state == null or _track == null \
			or not _track.is_valid() or _track.total_length <= 0.0:
		return 0.0
	if entry.lap_tracker != null:
		return clampf(
			entry.classification_progress() / _track.total_length, 0.0, 1.0
		)
	return clampf(
		_track.wrap_distance(entry.state.track_distance) / _track.total_length,
		0.0,
		1.0
	)


func _vehicle_for_entry(entry: RaceEntry, is_player: bool) -> Node3D:
	var id := str(entry.participant_id)
	if id.is_empty():
		id = str(entry.state.vehicle_id)
	if _vehicles.has(id):
		return _vehicles[id] as Node3D
	var visual := _instantiate_formula_visual(_color_for_entry(entry), is_player)
	visual.name = "FormulaCar_%s" % id
	if visual.has_method("configure_surface") and _track != null and _track.is_valid():
		visual.call("configure_surface", _track.road_surface)
	_vehicle_root.add_child(visual)
	if is_player and visual.has_method("set_cockpit_detail_visible"):
		visual.call(
			"set_cockpit_detail_visible", camera_mode == CAMERA_COCKPIT
		)
	if not is_player and visual.has_method("configure_remote_render_budget"):
		_vehicle_render_budget_apply_count += 1
	_vehicles[id] = visual
	return visual


func _sync_player_cockpit_visibility() -> void:
	if _player_visual_id.is_empty():
		return
	var player_visual := _vehicles.get(_player_visual_id) as Node3D
	if player_visual != null and is_instance_valid(player_visual) \
			and player_visual.has_method("set_cockpit_detail_visible"):
		player_visual.call(
			"set_cockpit_detail_visible", camera_mode == CAMERA_COCKPIT
		)


func _apply_vehicle_render_budgets() -> void:
	var mobile_budget := _uses_mobile_render_budget()
	for id in _vehicles:
		if str(id) == _player_visual_id:
			continue
		var visual := _vehicles[id] as Node3D
		if visual != null and is_instance_valid(visual) \
				and visual.has_method("configure_remote_render_budget"):
			visual.call("configure_remote_render_budget", mobile_budget)
			_vehicle_render_budget_apply_count += 1


func _uses_mobile_render_budget() -> bool:
	return _low_graphics or _is_mobile_runtime()


static func _is_mobile_runtime() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") \
			or OS.has_feature("ios")


func _present_vehicle_contact(
		entry: RaceEntry,
		vehicle_id: String,
		contact_serial: int
	) -> void:
	if _collision_spark_pool == null or not is_instance_valid(_collision_spark_pool):
		return
	var state := entry.state
	var contact_position := Mapper.authority_position_to_world(
		state.vehicle_contact_position,
		state.track_elevation,
		VEHICLE_RIDE_HEIGHT_METERS + state.vertical_offset_meters + 0.22
	)
	var contact_normal := Mapper.authority_direction_to_world(
		state.vehicle_contact_normal
	)
	var other_id := str(state.vehicle_contact_other_id)
	var event_key := "contact:tick:%d:x:%d:y:%d" % [
		state.vehicle_contact_tick,
		roundi(state.vehicle_contact_position.x * 1000.0),
		roundi(state.vehicle_contact_position.y * 1000.0),
	]
	if state.vehicle_contact_tick < 0:
		event_key = "contact:serial:%d:x:%d:y:%d" % [
			contact_serial,
			roundi(state.vehicle_contact_position.x * 1000.0),
			roundi(state.vehicle_contact_position.y * 1000.0),
		]
	if not other_id.is_empty():
		var first_id := vehicle_id
		var second_id := other_id
		if first_id.naturalnocasecmp_to(second_id) > 0:
			first_id = other_id
			second_id = vehicle_id
		# Both participants publish the same point/tick and opposite normals. A
		# canonical pair key collapses those mirrored serials into one visual burst.
		event_key = "%s:%s:tick:%d" % [
			first_id, second_id, state.vehicle_contact_tick
		]
	_collision_spark_pool.emit_contact(
		contact_position,
		contact_normal,
		state.vehicle_contact_speed,
		event_key
	)


func _instantiate_formula_visual(color: Color, is_player: bool) -> Node3D:
	if _car_visual_script == null and ResourceLoader.exists(CAR_VISUAL_PATH):
		var script_resource := ResourceLoader.load(CAR_VISUAL_PATH)
		if script_resource is Script:
			_car_visual_script = script_resource as Script
	if _car_visual_script != null:
		var candidate: Variant = _car_visual_script.new()
		if candidate is Node3D:
			var visual := candidate as Node3D
			if visual.has_method("configure"):
				visual.call(
					"configure", color, is_player, _uses_mobile_render_budget()
				)
			return visual
	return _fallback_formula_visual(color)


func _fallback_formula_visual(color: Color) -> Node3D:
	var root := Node3D.new()
	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = color
	body_material.metallic = 0.22
	body_material.roughness = 0.48
	_add_box_part(root, "Monocoque", Vector3(2.8, 0.42, 0.82),
		Vector3(-0.05, 0.48, 0.0), body_material)
	_add_box_part(root, "Nose", Vector3(2.15, 0.20, 0.34),
		Vector3(1.75, 0.36, 0.0), body_material)
	_add_box_part(root, "FrontWing", Vector3(0.38, 0.10, 2.05),
		Vector3(2.73, 0.20, 0.0), body_material)
	_add_box_part(root, "RearWing", Vector3(0.32, 0.12, 1.55),
		Vector3(-1.72, 1.00, 0.0), body_material)
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color("111315")
	rubber.roughness = 0.9
	for wheel_position in [
		Vector3(1.35, 0.38, -0.78), Vector3(1.35, 0.38, 0.78),
		Vector3(-1.25, 0.40, -0.82), Vector3(-1.25, 0.40, 0.82),
	]:
		var wheel := MeshInstance3D.new()
		var wheel_mesh := CylinderMesh.new()
		wheel_mesh.top_radius = 0.36
		wheel_mesh.bottom_radius = 0.36
		wheel_mesh.height = 0.34
		wheel.mesh = wheel_mesh
		wheel.position = wheel_position
		wheel.rotation.x = PI * 0.5
		wheel.material_override = rubber
		root.add_child(wheel)
	return root


func _add_box_part(
		root: Node3D,
		part_name: String,
		part_size: Vector3,
		part_position: Vector3,
		material: Material
	) -> void:
	var instance := MeshInstance3D.new()
	instance.name = part_name
	var box := BoxMesh.new()
	box.size = part_size
	instance.mesh = box
	instance.position = part_position
	instance.material_override = material
	root.add_child(instance)


func _interpolated_vehicle_transform(entry: RaceEntry, alpha: float) -> Transform3D:
	var current := entry.state
	var previous := entry.previous_state if entry.previous_state != null else current
	var position := previous.position.lerp(current.position, alpha)
	var heading := lerp_angle(previous.heading, current.heading, alpha)
	var elevation := lerpf(previous.track_elevation, current.track_elevation, alpha)
	var vertical_offset := lerpf(
		previous.vertical_offset_meters, current.vertical_offset_meters, alpha
	)
	var pitch := _vehicle_pitch_radians(previous, current, alpha)
	var yaw_basis := Basis(Vector3.UP, Mapper.authority_heading_to_world_yaw(heading))
	# Formula visuals use local +X as forward. Positive local-Z rotation lifts
	# that axis, matching an uphill road grade without changing steering yaw.
	var basis := yaw_basis * Basis(Vector3.BACK, pitch)
	return Transform3D(
		basis,
		Mapper.authority_position_to_world(
			position,
			elevation,
			VEHICLE_RIDE_HEIGHT_METERS + maxf(vertical_offset, 0.0)
		)
	)


func _vehicle_pitch_radians(previous: VehicleState, current: VehicleState, alpha: float) -> float:
	if _track == null or not _track.is_valid():
		return 0.0
	var grounded := current.is_grounded \
			or (previous.is_grounded and alpha < 0.5 and current.vertical_offset_meters < 0.02)
	if not grounded:
		# Once airborne the road no longer owns the car attitude. A restrained
		# trajectory pitch makes crest launches float naturally instead of snapping
		# back to a road-aligned or perfectly flat pose.
		var velocity := previous.velocity.lerp(current.velocity, alpha)
		var horizontal_speed_mps := Mapper.authority_scalar_to_meters(velocity.length())
		var vertical_speed_mps := lerpf(
			previous.vertical_velocity_mps, current.vertical_velocity_mps, alpha
		)
		if horizontal_speed_mps <= 0.1:
			return 0.0
		return clampf(
			atan2(vertical_speed_mps, horizontal_speed_mps),
			-MAX_AIRBORNE_PITCH_RADIANS,
			MAX_AIRBORNE_PITCH_RADIANS
		)
	var distance := previous.track_distance + _track.forward_delta(
		previous.track_distance, current.track_distance
	) * alpha
	var behind := _track.sample_at_distance(
		distance - VEHICLE_GRADE_PROBE_AUTHORITY_UNITS * 0.5
	)
	var ahead := _track.sample_at_distance(
		distance + VEHICLE_GRADE_PROBE_AUTHORITY_UNITS * 0.5
	)
	if behind.is_empty() or ahead.is_empty():
		return 0.0
	var behind_world := Mapper.authority_position_to_world(
		behind.get("position", Vector2.ZERO),
		float(behind.get("elevation_level", 0.0))
	)
	var ahead_world := Mapper.authority_position_to_world(
		ahead.get("position", Vector2.ZERO),
		float(ahead.get("elevation_level", 0.0))
	)
	var grade := ahead_world - behind_world
	var horizontal_length := Vector2(grade.x, grade.z).length()
	if horizontal_length <= 0.0001:
		return 0.0
	return clampf(
		atan2(grade.y, horizontal_length),
		-MAX_GROUNDED_PITCH_RADIANS,
		MAX_GROUNDED_PITCH_RADIANS
	)


func _update_player_camera(entry: RaceEntry, visual: Node3D, hard_snap: bool) -> void:
	var current := entry.state
	var previous := entry.previous_state if entry.previous_state != null else current
	var velocity := previous.velocity.lerp(current.velocity, _alpha)
	var speed_mps := Mapper.authority_scalar_to_meters(velocity.length())
	var steering := lerpf(previous.steering_input, current.steering_input, _alpha)
	_camera_rig.update_target(
		visual.global_transform, speed_mps, steering, current.shift_ticks_remaining
	)
	var cockpit_transform: Variant = null
	var chase_transform: Variant = null
	if visual.has_method("cockpit_socket"):
		var cockpit_node: Variant = visual.call("cockpit_socket")
		if cockpit_node is Node3D:
			cockpit_transform = (cockpit_node as Node3D).global_transform
	if visual.has_method("chase_target_socket"):
		var chase_node: Variant = visual.call("chase_target_socket")
		if chase_node is Node3D:
			chase_transform = (chase_node as Node3D).global_transform
	_camera_rig.update_socket_targets(cockpit_transform, chase_transform)
	if hard_snap:
		_camera_rig.snap_to_target()


func _is_player_entry(entry: RaceEntry) -> bool:
	if _player == null:
		return entry.is_human
	return entry == _player or entry.participant_id == _player.participant_id


func _color_for_entry(entry: RaceEntry) -> Color:
	var id := entry.participant_id
	if _entry_colors.has(id) and _entry_colors[id] is Color:
		return _entry_colors[id]
	var string_id := str(id)
	if _entry_colors.has(string_id) and _entry_colors[string_id] is Color:
		return _entry_colors[string_id]
	if _is_player_entry(entry):
		return _player_color
	return AI_COLORS[absi(string_id.hash()) % AI_COLORS.size()]


func _entry_for_id(id: String) -> RaceEntry:
	for entry in _entries:
		if entry != null and str(entry.participant_id) == id:
			return entry
	return null


func _clear_vehicles() -> void:
	_vehicles.clear()
	_vehicle_render_budget_apply_count = 0
	_vehicle_recovery_serials.clear()
	_vehicle_contact_serials.clear()
	_player_visual_id = ""
	_last_recovery_snap_id = ""
	_last_player_recovery_snap_serial = -1
	_recovery_snap_count = 0
	if _collision_spark_pool != null and is_instance_valid(_collision_spark_pool):
		_collision_spark_pool.reset_pool()
	if _road_surface_effects != null and is_instance_valid(_road_surface_effects):
		_road_surface_effects.reset_effects()
	if _vehicle_root == null:
		return
	for child in _vehicle_root.get_children():
		_vehicle_root.remove_child(child)
		child.free()


func _clear_static_world() -> void:
	_last_track_stats.clear()
	if _road_surface_effects != null and is_instance_valid(_road_surface_effects):
		_road_surface_effects.reset_effects()
	if _ground_root != null:
		_clear_node_children(_ground_root)
	if _track_root != null:
		_track_root.transform = Transform3D.IDENTITY
		_clear_node_children(_track_root)
	if _scenery_root != null:
		_scenery_root.transform = Transform3D.IDENTITY
		_scenery_root.clear_scenery()


static func _clear_node_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.free()
