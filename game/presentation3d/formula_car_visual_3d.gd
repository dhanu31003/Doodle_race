class_name FormulaCarVisual3D
extends Node3D
## Mobile-conscious, state-driven Formula car presentation.
##
## A clean-room Blender body supplies the authored 2022-era silhouette while
## lightweight primitives add the moving parts a cockpit camera must read:
## slicks, brakes, suspension, halo, yoke, driver controls, hands, telemetry and
## the regulation rear safety light. No wet-weather screen or raindrop effect is
## attached to the cockpit camera.
## Authority remains in VehicleState; this node only interpolates visuals.

const BASE_MODEL_PATH: String = "res://assets/final/3d/vehicles/formula_car_premium_original.glb"
const BASE_MODEL_SCENE: PackedScene = preload(BASE_MODEL_PATH)
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")
const AUTHORITY_UNIT_TO_METERS: float = 0.30
const FRONT_WHEEL_RADIUS: float = 0.355
const REAR_WHEEL_RADIUS: float = 0.385
const MAX_FRONT_STEER_RADIANS: float = deg_to_rad(22.0)
const MAX_STEERING_WHEEL_RADIANS: float = deg_to_rad(145.0)
const MAX_BODY_ROLL_RADIANS: float = deg_to_rad(3.2)
const MAX_BODY_PITCH_RADIANS: float = deg_to_rad(1.8)
const MAX_BODY_HEAVE_METERS: float = 0.045
const MAX_SUSPENSION_TRAVEL_METERS: float = 0.055
const IDLE_RPM: float = 4500.0
const SHIFT_LED_RPM: float = 9000.0
const REDLINE_RPM: float = 15_000.0
const SHIFT_LED_COUNT: int = 10
const PLAYER_YOKE_HEIGHT_METERS: float = 0.86
# The open survival-cell floor ends at roughly 0.54 m in the authored shell.
# Keeping every glove/cuff bound above this conservative plane prevents the
# driver's hands from disappearing through the monocoque at either steering lock.
const COCKPIT_HAND_CLEARANCE_FLOOR_METERS: float = 0.565
const REMOTE_DETAIL_RANGE_METERS: float = 78.0
const MOBILE_REMOTE_DETAIL_RANGE_METERS: float = 42.0
const PLAYER_MUD_STAGES: int = 10
const REMOTE_MUD_STAGES: int = 6
const MOBILE_REMOTE_MUD_STAGES: int = 3

static var _remote_body_mesh_cache: ArrayMesh
static var _remote_wheel_mesh_cache: ArrayMesh

@export var team_color: Color = Color("18d8a0")
@export var accent_color: Color = Color("f1f7f5")
@export var secondary_color: Color = Color("182536")
@export var driver_glove_color: Color = Color("e8443f")

var cockpit_camera_socket: Marker3D
var chase_camera_socket: Marker3D

var _body_root: Node3D
var _model_root: Node3D
var _steering_wheel_pivot: Node3D
var _dashboard_label: Label3D
var _rain_light: MeshInstance3D
var _rain_light_material: StandardMaterial3D
var _surface_coating: MultiMeshInstance3D
var _surface_coating_material: StandardMaterial3D
var _body_material: StandardMaterial3D
var _accent_material: StandardMaterial3D
var _secondary_material: StandardMaterial3D
var _carbon_material: StandardMaterial3D
var _rubber_material: StandardMaterial3D
var _rim_material: StandardMaterial3D
var _remote_wheel_material: StandardMaterial3D
var _brake_material: StandardMaterial3D
var _tyre_stripe_material: StandardMaterial3D
var _glass_material: StandardMaterial3D
var _glove_material: StandardMaterial3D
var _glove_detail_material: StandardMaterial3D
var _control_red_material: StandardMaterial3D
var _control_blue_material: StandardMaterial3D
var _control_yellow_material: StandardMaterial3D
var _control_green_material: StandardMaterial3D
var _display_bezel_material: StandardMaterial3D
var _dashboard_screen_material: StandardMaterial3D
var _shift_led_materials: Array[StandardMaterial3D] = []
var _front_steer_pivots: Array[Node3D] = []
var _wheel_steer_pivots: Array[Node3D] = []
var _wheel_spin_pivots: Array[Node3D] = []
var _wheel_suspension_pivots: Array[Node3D] = []
var _wheel_base_positions: Array[Vector3] = []
var _imported_body_meshes: Array[MeshInstance3D] = []
var _imported_body_source_mesh_count: int = 0
var _remote_body_instance: MeshInstance3D
var _remote_wheel_instances: MultiMeshInstance3D
var _remote_wheel_multimesh: MultiMesh
var _remote_wheel_scales: Array[Vector3] = []
var _remote_carbon_bar_specs: Array = []
var _cockpit_halo_guard: MultiMeshInstance3D
var _hand_roots: Array[Node3D] = []
var _driver_sleeves: Array[MeshInstance3D] = []
var _cockpit_detail_nodes: Array[Node3D] = []
var _cockpit_control_count: int = 0
var _cockpit_detail_count: int = 0
var _cockpit_detail_visible: bool = true
var _cockpit_visibility_apply_count: int = 0
var _wheel_spin_angle: float = 0.0
var _visual_steering: float = 0.0
var _visual_roll: float = 0.0
var _visual_pitch: float = 0.0
var _visual_heave: float = 0.0
var _rain_phase: float = 0.0
var _last_gear: int = 1
var _last_rpm: float = IDLE_RPM
var _last_shifting: bool = false
var _surface_style: StringName = RoadSurfaceCatalogType.SMOOTH_ASPHALT
var _surface_coating_count := 0
var _surface_lap_progress := 0.0
var _mud_accumulation := 0.0
var _surface_appearance_step := -1
var _surface_appearance_apply_count := 0
var _rain_light_active := false
var _rain_light_initialized := false
var _rain_light_material_update_count := 0
var _built: bool = false
# A directly-instantiated review/player car keeps the premium cockpit. RaceWorld
# calls configure() before add_child(), so remote roles replace this default
# before any meshes are built.
var _is_player: bool = true
var _remote_mobile_budget: bool = false
var _remote_render_budget_configured: bool = false
var _remote_render_budget_apply_count: int = 0
var _graph_stats_cache: Dictionary = {}


func _ready() -> void:
	if _built:
		return
	_build_materials()
	_build_visual()
	_graph_stats_cache = _presentation_graph_stats()
	_built = true
	set_team_color(team_color, accent_color)
	_update_dashboard(1, IDLE_RPM, false)


func configure(
		color: Color,
		is_player: bool = false,
		mobile_remote_budget: bool = false
	) -> void:
	# Role must be assigned before manual _ready/build. The former ordering built
	# the 80+ part player cockpit on every remote car, multiplying render objects
	# by the complete twelve-car field.
	_is_player = is_player
	_remote_mobile_budget = mobile_remote_budget
	if not _built:
		_ready()
	set_team_color(color, accent_color)
	if not _is_player:
		configure_remote_render_budget(_remote_mobile_budget)
	_apply_surface_appearance()


func configure_surface(style: StringName) -> void:
	var next_style := RoadSurfaceCatalogType.sanitized_style(style)
	if next_style != _surface_style:
		_surface_lap_progress = 0.0
		_mud_accumulation = 0.0
		_surface_appearance_step = -1
	_surface_style = next_style
	if not _built:
		_ready()
	_apply_surface_appearance()


func set_surface_lap_progress(progress: float) -> void:
	## Dirt is driven by validated race progress and changes only at a small
	## number of stages. This keeps the car visibly evolving without invalidating
	## materials every rendered frame when the complete field is on Mud.
	if _surface_style != RoadSurfaceCatalogType.MUD:
		return
	var safe_progress := clampf(progress, 0.0, 1.0) \
			if not is_nan(progress) and not is_inf(progress) else 0.0
	var step_count := PLAYER_MUD_STAGES if _is_player else REMOTE_MUD_STAGES
	if not _is_player and _remote_mobile_budget:
		step_count = MOBILE_REMOTE_MUD_STAGES
	var next_step := clampi(
		floori(safe_progress * float(step_count) + 0.0001), 0, step_count
	)
	if next_step == _surface_appearance_step:
		return
	_surface_appearance_step = next_step
	_surface_lap_progress = float(next_step) / float(step_count)
	# The coating becomes readable within the opening sector and reaches its
	# full brown finish before the lap ends, while the grid still starts clean.
	_mud_accumulation = smoothstep(0.02, 0.70, _surface_lap_progress)
	_apply_surface_appearance()


func apply_vehicle_state(
		state: Variant,
		command: Variant = null,
		delta: float = 0.016,
		surface_bump_meters: float = 0.0
	) -> void:
	if not _built:
		_ready()
	var safe_delta := _finite_clamped(delta, 0.0, 0.1, 0.0)
	var steering := _finite_clamped(
		_float_value(state, &"steering_input", _float_value(command, &"steer", 0.0)),
		-1.0,
		1.0,
		0.0
	)
	var throttle := _finite_clamped(_float_value(command, &"throttle", 0.0), 0.0, 1.0, 0.0)
	var brake := _finite_clamped(_float_value(command, &"brake", 0.0), 0.0, 1.0, 0.0)
	var lateral_acceleration := _finite_clamped(
		_float_value(state, &"lateral_acceleration", 0.0), -2000.0, 2000.0, 0.0
	)
	var wheel_slip := _finite_clamped(
		_float_value(state, &"wheel_slip", 0.0), 0.0, 4.0, 0.0
	)
	var rpm := _finite_clamped(
		_float_value(state, &"engine_rpm", IDLE_RPM), 0.0, 20_000.0, IDLE_RPM
	)
	var gear := clampi(_int_value(state, &"gear", 1), -1, 8)
	var shifting := _int_value(state, &"shift_ticks_remaining", 0) > 0
	var speed_mps := _speed_meters_per_second(state)
	var surface_bump := _finite_clamped(
		surface_bump_meters, -MAX_SUSPENSION_TRAVEL_METERS, MAX_SUSPENSION_TRAVEL_METERS, 0.0
	)
	var blend := 1.0 if safe_delta <= 0.0 else 1.0 - exp(-safe_delta * 13.0)

	_visual_steering = lerpf(_visual_steering, steering, blend)
	# Authority-positive steer rotates the 2D car from +X toward +Y, which maps
	# to local/world +Z. Godot-positive rotation around Y turns +X toward -Z, so
	# the front-upright yaw must carry the mapper's sign inversion. From the
	# driver's rear-facing view, positive X-axis yoke roll moves the top of the
	# yoke toward +Z (clockwise/right), matching the same authoritative turn.
	var front_angle := -_visual_steering * MAX_FRONT_STEER_RADIANS
	for pivot in _front_steer_pivots:
		pivot.rotation.y = front_angle
	if _steering_wheel_pivot != null:
		_steering_wheel_pivot.rotation.x = clampf(
			_visual_steering * MAX_STEERING_WHEEL_RADIANS,
			-MAX_STEERING_WHEEL_RADIANS,
			MAX_STEERING_WHEEL_RADIANS
		)

	var driven_radius := REAR_WHEEL_RADIUS
	if safe_delta > 0.0:
		_wheel_spin_angle = fposmod(
			_wheel_spin_angle - speed_mps / driven_radius * safe_delta, TAU
		)
	for pivot in _wheel_spin_pivots:
		pivot.rotation.z = _wheel_spin_angle

	var target_roll := clampf(
		-lateral_acceleration * 0.00075, -MAX_BODY_ROLL_RADIANS, MAX_BODY_ROLL_RADIANS
	)
	var target_pitch := clampf(
		brake * MAX_BODY_PITCH_RADIANS - throttle * deg_to_rad(0.55),
		-MAX_BODY_PITCH_RADIANS,
		MAX_BODY_PITCH_RADIANS
	)
	var target_heave := clampf(
		-brake * 0.030 - minf(speed_mps / 95.0, 1.0) * 0.010 \
				+ throttle * 0.006 + surface_bump * 0.72,
		-MAX_BODY_HEAVE_METERS,
		MAX_BODY_HEAVE_METERS
	)
	_visual_roll = lerpf(_visual_roll, target_roll, blend)
	_visual_pitch = lerpf(_visual_pitch, target_pitch, blend)
	_visual_heave = lerpf(_visual_heave, target_heave, blend)
	_body_root.position.y = _visual_heave
	_body_root.rotation.x = clampf(
		_visual_roll, -MAX_BODY_ROLL_RADIANS, MAX_BODY_ROLL_RADIANS
	)
	_body_root.rotation.z = clampf(
		_visual_pitch, -MAX_BODY_PITCH_RADIANS, MAX_BODY_PITCH_RADIANS
	)
	_update_suspension(brake, throttle, wheel_slip, surface_bump)
	if _cockpit_detail_visible:
		_update_driver_sleeves()
	_sync_remote_wheel_instances()
	_last_gear = gear
	_last_rpm = rpm
	_last_shifting = shifting
	if _cockpit_detail_visible:
		_update_dashboard(gear, rpm, shifting)
	_update_rain_light(brake, wheel_slip, safe_delta)


func set_team_color(color: Color, new_accent: Color = Color("f1f7f5")) -> void:
	team_color = _opaque_color(color, Color("18d8a0"))
	accent_color = _opaque_color(new_accent, Color("f1f7f5"))
	if _body_material != null:
		_body_material.albedo_color = team_color
	if _accent_material != null:
		_accent_material.albedo_color = accent_color
	# Material lanes on the original body are routed once during construction;
	# updating their shared materials recolours the complete fictional livery.
	_apply_surface_appearance()


func set_color(color: Color) -> void:
	set_team_color(color, accent_color)


func set_cockpit_detail_visible(value: bool) -> void:
	## The rich yoke, controls, gloves and inner tub are useful only to the
	## cockpit camera. Hiding the registered nodes in chase view removes roughly
	## ninety render objects without rebuilding the player car or changing its
	## premium exterior silhouette. Camera changes are infrequent, so this work is
	## deliberately synchronous and never runs in the per-frame presentation path.
	if not _built:
		_ready()
	if not _is_player or _cockpit_detail_visible == value:
		return
	_cockpit_detail_visible = value
	_cockpit_visibility_apply_count += 1
	for detail in _cockpit_detail_nodes:
		if detail != null and is_instance_valid(detail):
			detail.visible = value
	if value:
		_update_driver_sleeves()
		_update_dashboard(_last_gear, _last_rpm, _last_shifting)


func configure_remote_render_budget(mobile_budget: bool) -> void:
	## Remote cars keep the authored silhouette and independently animated wheels,
	## while tiny cockpit/suspension cues receive a camera-distance budget. On an
	## Remote cars use the same daylight/reflection lighting but do not multiply
	## the player's high-resolution directional shadow by an eleven-car pack.
	if not _built:
		_ready()
	if _is_player:
		return
	if _remote_render_budget_configured and _remote_mobile_budget == mobile_budget:
		return
	_remote_mobile_budget = mobile_budget
	_remote_render_budget_configured = true
	_remote_render_budget_apply_count += 1
	var detail_range := MOBILE_REMOTE_DETAIL_RANGE_METERS \
			if mobile_budget else REMOTE_DETAIL_RANGE_METERS
	_configure_remote_geometry(self, detail_range, mobile_budget)


func get_cockpit_camera_socket() -> Marker3D:
	if not _built:
		_ready()
	return cockpit_camera_socket


func get_chase_camera_socket() -> Marker3D:
	if not _built:
		_ready()
	return chase_camera_socket


func get_camera_socket(camera_name: StringName) -> Marker3D:
	if not _built:
		_ready()
	return cockpit_camera_socket if camera_name == &"cockpit" else chase_camera_socket


func cockpit_socket() -> Node3D:
	if not _built:
		_ready()
	return cockpit_camera_socket


func chase_target_socket() -> Node3D:
	if not _built:
		_ready()
	return chase_camera_socket


func presentation_snapshot() -> Dictionary:
	var active_leds := 0
	for material in _shift_led_materials:
		if material.emission_energy_multiplier > 0.25:
			active_leds += 1
	var graph_stats := _graph_stats_cache \
			if not _graph_stats_cache.is_empty() else _presentation_graph_stats()
	var remote_budget_stats := _remote_geometry_budget_snapshot()
	return {
		"built": _built,
		"base_model_path": BASE_MODEL_PATH,
		"imported_body_meshes": _imported_body_source_mesh_count,
		"remote_batched_body_draws": 1 if _remote_body_instance != null else 0,
		"remote_batched_wheel_draws": 1 if _remote_wheel_instances != null else 0,
		"remote_wheel_batch_instances": (
			_remote_wheel_multimesh.instance_count if _remote_wheel_multimesh != null else 0
		),
		"wheel_count": _wheel_spin_pivots.size(),
		"front_steer_radians": (
			_front_steer_pivots[0].rotation.y if not _front_steer_pivots.is_empty() else 0.0
		),
		"steering_wheel_radians": (
			_steering_wheel_pivot.rotation.x if _steering_wheel_pivot != null else 0.0
		),
		"authoritative_turn_input": _visual_steering,
		"front_turns_toward_local_positive_z": (
			_front_steer_pivots[0].basis.x.z > 0.0
			if not _front_steer_pivots.is_empty() else false
		),
		"yoke_turns_clockwise_for_positive_input": (
			_steering_wheel_pivot.basis.y.z > 0.0
			if _steering_wheel_pivot != null else false
		),
		"wheel_spin_radians": _wheel_spin_angle,
		"body_roll_radians": _visual_roll,
		"body_pitch_radians": _visual_pitch,
		"body_heave_meters": _visual_heave,
		"active_shift_leds": active_leds,
		"gear": _last_gear,
		"rpm": _last_rpm,
		"dashboard_text": _dashboard_label.text if _dashboard_label != null else "",
		"rain_light_energy": (
			_rain_light_material.emission_energy_multiplier
			if _rain_light_material != null else 0.0
		),
		"road_surface": str(_surface_style),
		"surface_coating_visible": (
			_surface_coating != null and _surface_coating.visible
		),
		"surface_coating_node_present": _surface_coating != null,
		"surface_coating_count": _surface_coating_count,
		"surface_coating_visible_count": (
			_surface_coating.multimesh.visible_instance_count
			if _surface_coating != null and _surface_coating.multimesh != null else 0
		),
		"surface_coating_opacity": (
			_surface_coating_material.albedo_color.a
			if _surface_coating_material != null else 0.0
		),
		"surface_lap_progress": _surface_lap_progress,
		"mud_accumulation": _mud_accumulation,
		"surface_appearance_apply_count": _surface_appearance_apply_count,
		"rain_light_material_update_count": _rain_light_material_update_count,
		"body_roughness": _body_material.roughness if _body_material != null else 0.0,
		"body_surface_color": _body_material.albedo_color \
				if _body_material != null else Color.WHITE,
		"team_color": team_color,
		"cockpit_socket": cockpit_camera_socket != null,
		"chase_socket": chase_camera_socket != null,
		"visible_gloved_hand_count": _hand_roots.size(),
		"hands_parented_to_yoke": _hands_parented_to_yoke(),
		"minimum_hand_body_y": _minimum_hand_body_y(),
		"minimum_sleeve_body_y": _minimum_sleeve_body_y(),
		"cockpit_hand_clearance_floor_y": COCKPIT_HAND_CLEARANCE_FLOOR_METERS,
		"hands_clear_cockpit_floor": (
			_minimum_hand_body_y() >= COCKPIT_HAND_CLEARANCE_FLOOR_METERS - 0.0005
		),
		"sleeves_clear_cockpit_floor": (
			_minimum_sleeve_body_y() >= COCKPIT_HAND_CLEARANCE_FLOOR_METERS - 0.0005
		),
		"cockpit_control_count": _cockpit_control_count,
		"cockpit_detail_count": _cockpit_detail_count,
		"visible_cockpit_detail_count": _visible_cockpit_detail_count(),
		"cockpit_detail_visible": _cockpit_detail_visible,
		"cockpit_halo_guard_visible": _cockpit_halo_guard != null \
				and is_instance_valid(_cockpit_halo_guard) \
				and _cockpit_halo_guard.visible,
		"cockpit_visibility_apply_count": _cockpit_visibility_apply_count,
		"cockpit_wet_fx_count": 0,
		"lod_tier": "player_cockpit" if _is_player else "remote_exterior",
		"presentation_node_count": int(graph_stats.get("node_count", 0)),
		"mesh_instance_count": int(graph_stats.get("mesh_instance_count", 0)),
		"label_3d_count": int(graph_stats.get("label_3d_count", 0)),
		"triangle_count": int(graph_stats.get("triangle_count", 0)),
		"is_player": _is_player,
		"remote_mobile_budget": _remote_mobile_budget,
		"remote_render_budget_apply_count": _remote_render_budget_apply_count,
		"remote_shadow_caster_count": int(remote_budget_stats.get("shadow_casters", 0)),
		"remote_bounded_detail_count": int(remote_budget_stats.get("bounded_details", 0)),
		"remote_unbounded_core_count": int(remote_budget_stats.get("unbounded_core", 0)),
		"remote_max_detail_range": float(remote_budget_stats.get("max_detail_range", 0.0)),
	}


func _build_materials() -> void:
	_body_material = _material(team_color, 0.48, 0.16)
	_body_material.clearcoat_enabled = true
	_body_material.clearcoat = 0.78
	_body_material.clearcoat_roughness = 0.12
	_accent_material = _material(accent_color, 0.34, 0.17)
	_accent_material.clearcoat_enabled = true
	_accent_material.clearcoat = 0.65
	_accent_material.clearcoat_roughness = 0.14
	_secondary_material = _material(secondary_color, 0.22, 0.28)
	_carbon_material = _material(Color("141c26"), 0.43, 0.26)
	_carbon_material.clearcoat_enabled = true
	_carbon_material.clearcoat = 0.46
	_carbon_material.clearcoat_roughness = 0.20
	_rubber_material = _material(Color("08090b"), 0.0, 0.82)
	_rim_material = _material(Color("2d333b"), 0.90, 0.18)
	# Remote wheels share one deliberately dark material so their tyre and forged
	# centre can live in one surface/draw while retaining a readable silhouette.
	_remote_wheel_material = _material(Color("15191e"), 0.36, 0.52)
	_brake_material = _material(Color("8b9299"), 0.93, 0.27)
	_tyre_stripe_material = _material(Color("ffd637"), 0.05, 0.44)
	_glass_material = _material(Color(0.035, 0.070, 0.095, 0.82), 0.20, 0.12)
	_glass_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glove_material = _material(driver_glove_color, 0.0, 0.50)
	_glove_material.clearcoat_enabled = true
	_glove_material.clearcoat = 0.28
	_glove_material.clearcoat_roughness = 0.32
	_glove_material.emission_enabled = true
	_glove_material.emission = driver_glove_color.darkened(0.48)
	_glove_material.emission_energy_multiplier = 0.65
	_glove_detail_material = _material(Color("111820"), 0.10, 0.45)
	_control_red_material = _emissive_material(Color("ff435d"), 1.3)
	_control_blue_material = _emissive_material(Color("38bfff"), 1.1)
	_control_yellow_material = _emissive_material(Color("ffd84a"), 1.0)
	_control_green_material = _emissive_material(Color("52f39a"), 1.0)
	_display_bezel_material = _material(Color("05090e"), 0.36, 0.18)
	_dashboard_screen_material = _emissive_material(Color("09242a"), 0.55)
	_rain_light_material = _emissive_material(Color("ff2038"), 0.05)


func _build_visual() -> void:
	_body_root = Node3D.new()
	_body_root.name = "BodyMotionRoot"
	add_child(_body_root)
	_build_imported_body()
	_build_halo_and_cockpit()
	_build_wheels_and_suspension()
	_build_steering_wheel_and_driver()
	_build_lights()
	_build_surface_coating()
	_build_camera_sockets()


func _build_imported_body() -> void:
	var instance := BASE_MODEL_SCENE.instantiate()
	if not instance is Node3D:
		return
	_model_root = instance as Node3D
	_model_root.name = "PremiumOriginalFormulaBody"
	_model_root.position = Vector3.ZERO
	_body_root.add_child(_model_root)
	_configure_imported_meshes(_model_root)
	_imported_body_source_mesh_count = _imported_body_meshes.size()
	if not _is_player:
		_batch_remote_imported_body()


func _configure_imported_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var lowered := mesh_instance.name.to_lower()
		if "paint_" in lowered:
			mesh_instance.material_override = _body_material
		elif "accent_" in lowered:
			mesh_instance.material_override = _accent_material
		elif "metal_" in lowered:
			mesh_instance.material_override = _rim_material
		else:
			mesh_instance.material_override = _carbon_material
		_imported_body_meshes.append(mesh_instance)
	for child in node.get_children():
		_configure_imported_meshes(child)


func _batch_remote_imported_body() -> void:
	# The authored GLB is split into paint/accent/carbon lanes for the hero car.
	# At racing distance those four surfaces are visually sub-pixel on a phone,
	# yet each surface still costs a draw for every nearby opponent. Merge the
	# unchanged authored geometry into one shared surface for all remote cars.
	if _model_root == null:
		return
	if _remote_body_mesh_cache == null:
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		_append_mesh_tree_to_surface(
			_model_root, Transform3D.IDENTITY, surface
		)
		var committed := surface.commit()
		if committed is ArrayMesh:
			_remote_body_mesh_cache = committed as ArrayMesh
	if _remote_body_mesh_cache == null:
		return
	_remote_body_instance = MeshInstance3D.new()
	_remote_body_instance.name = "BatchedPremiumRemoteBody"
	_remote_body_instance.mesh = _remote_body_mesh_cache
	_remote_body_instance.material_override = _body_material
	_remote_body_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_body_root.add_child(_remote_body_instance)
	_body_root.remove_child(_model_root)
	_model_root.free()
	_model_root = null
	_imported_body_meshes.clear()


func _append_mesh_tree_to_surface(
		node: Node,
		parent_transform: Transform3D,
		surface: SurfaceTool
	) -> void:
	var accumulated := parent_transform
	if node is Node3D:
		accumulated = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			for surface_index in mesh_instance.mesh.get_surface_count():
				if mesh_instance.mesh.surface_get_primitive_type(surface_index) \
						== Mesh.PRIMITIVE_TRIANGLES:
					surface.append_from(
						mesh_instance.mesh, surface_index, accumulated
					)
	for child in node.get_children():
		_append_mesh_tree_to_surface(child, accumulated, surface)


func _build_floor_and_body_detail() -> void:
	_add_box(
		_body_root, "CarbonFloor", Vector3(3.85, 0.07, 1.28),
		Vector3(-0.05, 0.18, 0.0), _carbon_material
	)
	_add_box(
		_body_root, "LeftSidepod", Vector3(1.65, 0.38, 0.42),
		Vector3(-0.27, 0.42, -0.48), _body_material
	)
	_add_box(
		_body_root, "RightSidepod", Vector3(1.65, 0.38, 0.42),
		Vector3(-0.27, 0.42, 0.48), _body_material
	)
	_add_box(
		_body_root, "LeftSidepodInlet", Vector3(0.15, 0.22, 0.31),
		Vector3(0.48, 0.48, -0.49), _carbon_material,
		Vector3(0.0, 0.0, deg_to_rad(-8.0))
	)
	_add_box(
		_body_root, "RightSidepodInlet", Vector3(0.15, 0.22, 0.31),
		Vector3(0.48, 0.48, 0.49), _carbon_material,
		Vector3(0.0, 0.0, deg_to_rad(-8.0))
	)
	_add_box(
		_body_root, "LeftFloorEdge", Vector3(2.85, 0.035, 0.055),
		Vector3(-0.20, 0.235, -0.655), _accent_material
	)
	_add_box(
		_body_root, "RightFloorEdge", Vector3(2.85, 0.035, 0.055),
		Vector3(-0.20, 0.235, 0.655), _accent_material
	)
	_add_box(
		_body_root, "NoseAccent", Vector3(2.20, 0.07, 0.105),
		Vector3(1.06, 0.59, 0.0), _accent_material
	)
	_add_box(
		_body_root, "EngineCoverFin", Vector3(1.08, 0.16, 0.040),
		Vector3(-0.72, 0.78, 0.0), _accent_material,
		Vector3(0.0, 0.0, deg_to_rad(-4.0))
	)
	_add_box(
		_body_root, "CockpitScreen", Vector3(0.40, 0.20, 0.57),
		Vector3(-0.04, 0.75, 0.0), _glass_material
	)


func _build_aero() -> void:
	_add_box(
		_body_root, "FrontWingMain", Vector3(0.34, 0.065, 2.05),
		Vector3(2.38, 0.20, 0.0), _carbon_material
	)
	_add_box(
		_body_root, "FrontWingUpper", Vector3(0.24, 0.055, 1.86),
		Vector3(2.25, 0.27, 0.0), _accent_material,
		Vector3(0.0, 0.0, deg_to_rad(-8.0))
	)
	_add_box(
		_body_root, "FrontWingMid", Vector3(0.20, 0.040, 1.58),
		Vector3(2.15, 0.325, 0.0), _carbon_material,
		Vector3(0.0, 0.0, deg_to_rad(-11.0))
	)
	_add_box(
		_body_root, "FrontWingLeftEndplate", Vector3(0.42, 0.27, 0.045),
		Vector3(2.34, 0.30, -1.03), _carbon_material
	)
	_add_box(
		_body_root, "FrontWingRightEndplate", Vector3(0.42, 0.27, 0.045),
		Vector3(2.34, 0.30, 1.03), _carbon_material
	)
	_add_box(
		_body_root, "RearWingMain", Vector3(0.15, 0.060, 1.70),
		Vector3(-1.97, 1.08, 0.0), _carbon_material,
		Vector3(0.0, 0.0, deg_to_rad(6.0))
	)
	_add_box(
		_body_root, "RearWingAccentFlap", Vector3(0.105, 0.028, 1.56),
		Vector3(-1.93, 1.115, 0.0), _accent_material,
		Vector3(0.0, 0.0, deg_to_rad(9.0))
	)
	_add_box(
		_body_root, "RearWingLower", Vector3(0.14, 0.050, 1.48),
		Vector3(-1.86, 0.92, 0.0), _carbon_material
	)
	_add_box(
		_body_root, "RearWingLeftEndplate", Vector3(0.30, 0.50, 0.042),
		Vector3(-1.95, 0.92, -0.86), _carbon_material,
		Vector3(0.0, 0.0, deg_to_rad(5.0))
	)
	_add_box(
		_body_root, "RearWingRightEndplate", Vector3(0.30, 0.50, 0.042),
		Vector3(-1.95, 0.92, 0.86), _carbon_material,
		Vector3(0.0, 0.0, deg_to_rad(5.0))
	)
	_add_box(
		_body_root, "RearWingLeftEdge", Vector3(0.17, 0.035, 0.055),
		Vector3(-1.94, 1.17, -0.86), _accent_material
	)
	_add_box(
		_body_root, "RearWingRightEdge", Vector3(0.17, 0.035, 0.055),
		Vector3(-1.94, 1.17, 0.86), _accent_material
	)
	_add_box(
		_body_root, "RearWingLeftPylon", Vector3(0.10, 0.73, 0.08),
		Vector3(-1.72, 0.75, -0.34), _carbon_material
	)
	_add_box(
		_body_root, "RearWingRightPylon", Vector3(0.10, 0.73, 0.08),
		Vector3(-1.72, 0.75, 0.34), _carbon_material
	)
	for z in [-0.48, -0.24, 0.0, 0.24, 0.48]:
		_add_box(
			_body_root, "DiffuserStrake", Vector3(0.62, 0.17, 0.035),
			Vector3(-1.76, 0.19, z), _carbon_material,
			Vector3(0.0, 0.0, deg_to_rad(9.0))
		)


func _build_halo_and_cockpit() -> void:
	# The forward halo is essential in the driver's view, but from the elevated
	# chase camera its three upper bars read as a large floating triangle. Keep
	# those guards in the cockpit-only visibility set for the player. The lower
	# cockpit rails remain part of the exterior silhouette in both cameras, and
	# remote cars retain the complete safety-cell outline.
	var halo_guard_specs: Array = [
		[Vector3(0.72, 0.66, 0.0), Vector3(0.72, 1.38, 0.0), 0.013],
		[Vector3(0.72, 1.38, -0.020), Vector3(-0.54, 1.34, -0.36), 0.014],
		[Vector3(0.72, 1.38, 0.020), Vector3(-0.54, 1.34, 0.36), 0.014],
		[Vector3(-0.54, 1.34, -0.36), Vector3(-0.54, 1.34, 0.36), 0.015],
	]
	var cockpit_rail_specs: Array = [
		[Vector3(0.28, 0.74, -0.34), Vector3(-0.62, 0.73, -0.35), 0.034],
		[Vector3(0.28, 0.74, 0.34), Vector3(-0.62, 0.73, 0.35), 0.034],
	]
	if _is_player:
		_cockpit_halo_guard = _add_bar_multimesh(
			_body_root, "CockpitOnlyHaloGuard", halo_guard_specs, _carbon_material
		)
		_register_cockpit_detail(_cockpit_halo_guard)
		_add_bar_multimesh(
			_body_root, "ExteriorCockpitRails", cockpit_rail_specs, _carbon_material
		)
	else:
		# Remote halo and suspension share one carbon MultiMesh draw, assembled
		# after the wheel pivots have been authored.
		_remote_carbon_bar_specs = halo_guard_specs + cockpit_rail_specs
	if not _is_player:
		# Remote chase cameras only read the exterior survival-cell silhouette.
		# Premium interior panels, vents, trim and bolsters are player-only.
		return
	# The imported shell supplies the exterior silhouette. These authored layers
	# are deliberately concentrated inside the driver's sightline: a deep carbon
	# tub, padded rim, dash brow and restrained fictional accent stitching. They
	# remain dry/opaque so the daylight track view is never filtered or obscured.
	_register_cockpit_detail(_add_box(
		_body_root, "CockpitCarbonFloor", Vector3(1.42, 0.055, 0.55),
		Vector3(0.03, 0.51, 0.0), _carbon_material
	))
	_register_cockpit_detail(_add_box(
		_body_root, "CockpitDashBrow", Vector3(0.24, 0.035, 0.66),
		Vector3(0.58, 0.725, 0.0), _display_bezel_material,
		Vector3(0.0, 0.0, deg_to_rad(-5.0))
	))
	for side in [-1.0, 1.0]:
		_register_cockpit_detail(_add_box(
			_body_root, "CockpitInnerSide", Vector3(1.35, 0.18, 0.10),
			Vector3(-0.02, 0.65, side * 0.36), _carbon_material,
			Vector3(deg_to_rad(side * 2.0), 0.0, deg_to_rad(-3.0))
		))
		_register_cockpit_detail(_add_bar(
			_body_root, "CockpitMetallicRim",
			Vector3(0.47, 0.79, side * 0.37),
			Vector3(-0.55, 0.78, side * 0.39), 0.024, _rim_material
		))
		_register_cockpit_detail(_add_bar(
			_body_root, "CockpitAccentStitch",
			Vector3(0.45, 0.805, side * 0.395),
			Vector3(-0.50, 0.795, side * 0.415), 0.007, _accent_material
		))
		var bolster := _add_capsule(
			_body_root, "CockpitShoulderBolster", 0.075, 0.36,
			Vector3(-0.46, 0.83, side * 0.31), _secondary_material,
			Vector3(deg_to_rad(side * 7.0), 0.0, deg_to_rad(82.0))
		)
		_register_cockpit_detail(bolster)
	for vent_side in [-1.0, 1.0]:
		for vent_index in 3:
			_register_cockpit_detail(_add_box(
				_body_root, "CockpitVentFin", Vector3(0.12, 0.018, 0.036),
				Vector3(
					0.45 - float(vent_index) * 0.075,
					0.795,
					vent_side * (0.17 + float(vent_index) * 0.035)
				), _rim_material
			))


func _build_wheels_and_suspension() -> void:
	var specs := [
		["FrontLeft", Vector3(1.55, 0.43, -0.91), FRONT_WHEEL_RADIUS, true],
		["FrontRight", Vector3(1.55, 0.43, 0.91), FRONT_WHEEL_RADIUS, true],
		["RearLeft", Vector3(-1.45, 0.45, -0.93), REAR_WHEEL_RADIUS, false],
		["RearRight", Vector3(-1.45, 0.45, 0.93), REAR_WHEEL_RADIUS, false],
	]
	for spec in specs:
		var wheel_name: String = spec[0]
		var position: Vector3 = spec[1]
		var radius: float = spec[2]
		var is_front: bool = spec[3]
		var suspension := Node3D.new()
		suspension.name = "%sSuspension" % wheel_name
		suspension.position = position
		add_child(suspension)
		var steering := Node3D.new()
		steering.name = "%sSteering" % wheel_name
		suspension.add_child(steering)
		var spinner := Node3D.new()
		spinner.name = "%sSpin" % wheel_name
		steering.add_child(spinner)
		var side := signf(position.z)
		var width: float = 0.29 if is_front else 0.34
		if _is_player:
			_build_tyre(spinner, radius, width, side)
			_build_brake_hardware(steering, spinner, radius, width, side)
		else:
			_remote_wheel_scales.append(Vector3(radius, radius, width))
		_wheel_suspension_pivots.append(suspension)
		_wheel_steer_pivots.append(steering)
		_wheel_base_positions.append(position)
		_wheel_spin_pivots.append(spinner)
		if is_front:
			_front_steer_pivots.append(steering)
	if _is_player:
		_build_player_suspension()
	else:
		_build_remote_wheel_batch()
		_build_remote_suspension()


func _build_remote_wheel(parent: Node3D, radius: float, width: float) -> void:
	# The low-segment slick and compact forged centre are committed into one
	# surface. Steering/spin pivots remain identical to the player car, but each
	# remote wheel costs one draw instead of the player's detailed assembly.
	var tyre_mesh := TorusMesh.new()
	_configure_remote_tyre_mesh(tyre_mesh, radius)
	var rim_mesh := CylinderMesh.new()
	rim_mesh.top_radius = radius * 0.48
	rim_mesh.bottom_radius = radius * 0.48
	rim_mesh.height = width * 0.58
	rim_mesh.radial_segments = 16
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tyre_basis := Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
	tyre_basis = tyre_basis * Basis.from_scale(
		Vector3(1.0, width / maxf(radius * 0.42, 0.01), 1.0)
	)
	surface.append_from(tyre_mesh, 0, Transform3D(tyre_basis, Vector3.ZERO))
	var rim_basis := Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
	surface.append_from(rim_mesh, 0, Transform3D(rim_basis, Vector3.ZERO))
	var wheel := MeshInstance3D.new()
	wheel.name = "RemoteSlickAndForgedWheel"
	wheel.mesh = surface.commit()
	wheel.material_override = _remote_wheel_material
	parent.add_child(wheel)


func _configure_remote_tyre_mesh(mesh: TorusMesh, radius: float) -> void:
	mesh.inner_radius = radius * 0.58
	mesh.outer_radius = radius
	mesh.rings = 24
	mesh.ring_segments = 10


func _build_remote_wheel_batch() -> void:
	# Four independently transformed slicks share one MultiMesh draw. The steer,
	# spin and suspension pivot hierarchy remains separate for every tyre, so this
	# removes render submissions without changing any visible wheel motion.
	if _remote_wheel_mesh_cache == null:
		var tyre_mesh := TorusMesh.new()
		tyre_mesh.inner_radius = 0.58
		tyre_mesh.outer_radius = 1.0
		tyre_mesh.rings = 20
		tyre_mesh.ring_segments = 8
		var rim_mesh := CylinderMesh.new()
		rim_mesh.top_radius = 0.48
		rim_mesh.bottom_radius = 0.48
		rim_mesh.height = 0.58
		rim_mesh.radial_segments = 12
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		var tyre_basis := Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
		tyre_basis = tyre_basis * Basis.from_scale(Vector3(1.0, 1.0 / 0.42, 1.0))
		surface.append_from(tyre_mesh, 0, Transform3D(tyre_basis, Vector3.ZERO))
		var rim_basis := Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
		surface.append_from(rim_mesh, 0, Transform3D(rim_basis, Vector3.ZERO))
		var committed := surface.commit()
		if committed is ArrayMesh:
			_remote_wheel_mesh_cache = committed as ArrayMesh
	if _remote_wheel_mesh_cache == null:
		return
	_remote_wheel_multimesh = MultiMesh.new()
	_remote_wheel_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_remote_wheel_multimesh.mesh = _remote_wheel_mesh_cache
	_remote_wheel_multimesh.instance_count = _wheel_spin_pivots.size()
	_remote_wheel_instances = MultiMeshInstance3D.new()
	_remote_wheel_instances.name = "BatchedIndependentRemoteWheels"
	_remote_wheel_instances.multimesh = _remote_wheel_multimesh
	_remote_wheel_instances.material_override = _remote_wheel_material
	_remote_wheel_instances.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_remote_wheel_instances)
	_sync_remote_wheel_instances()


func _sync_remote_wheel_instances() -> void:
	if _remote_wheel_multimesh == null:
		return
	var count := mini(
		_remote_wheel_multimesh.instance_count,
		mini(
			_remote_wheel_scales.size(),
			mini(_wheel_suspension_pivots.size(), _wheel_steer_pivots.size())
		)
	)
	for index in count:
		var wheel_transform := _wheel_suspension_pivots[index].transform \
				* _wheel_steer_pivots[index].transform \
				* _wheel_spin_pivots[index].transform
		wheel_transform.basis = wheel_transform.basis * Basis.from_scale(
			_remote_wheel_scales[index]
		)
		_remote_wheel_multimesh.set_instance_transform(index, wheel_transform)


func _build_tyre(parent: Node3D, radius: float, width: float, side: float) -> void:
	var tyre_mesh := TorusMesh.new()
	tyre_mesh.inner_radius = radius * 0.58
	tyre_mesh.outer_radius = radius
	tyre_mesh.rings = 64
	tyre_mesh.ring_segments = 18
	var tyre := MeshInstance3D.new()
	tyre.name = "SlickTyre"
	tyre.mesh = tyre_mesh
	tyre.material_override = _rubber_material
	tyre.rotation.x = PI * 0.5
	tyre.scale.y = width / maxf(radius * 0.42, 0.01)
	parent.add_child(tyre)

	var outer_face := side * width * 0.49
	var rim_lip_mesh := TorusMesh.new()
	rim_lip_mesh.inner_radius = radius * 0.43
	rim_lip_mesh.outer_radius = radius * 0.54
	rim_lip_mesh.rings = 48
	rim_lip_mesh.ring_segments = 12
	var rim_lip := MeshInstance3D.new()
	rim_lip.name = "ForgedRimLip"
	rim_lip.mesh = rim_lip_mesh
	rim_lip.material_override = _rim_material
	rim_lip.rotation.x = PI * 0.5
	rim_lip.scale.y = 0.48
	rim_lip.position.z = outer_face
	parent.add_child(rim_lip)

	var stripe_mesh := TorusMesh.new()
	stripe_mesh.inner_radius = radius * 0.835
	stripe_mesh.outer_radius = radius * 0.895
	stripe_mesh.rings = 64
	stripe_mesh.ring_segments = 8
	var stripe := MeshInstance3D.new()
	stripe.name = "TyreCompoundStripe"
	stripe.mesh = stripe_mesh
	stripe.material_override = _tyre_stripe_material
	stripe.rotation.x = PI * 0.5
	stripe.scale.y = 0.34
	stripe.position.z = side * width * 0.515
	parent.add_child(stripe)

	var spoke_specs: Array = []
	for spoke_index in 10:
		var spoke_angle := TAU * float(spoke_index) / 10.0
		var inner := Vector3(
			cos(spoke_angle) * radius * 0.14,
			sin(spoke_angle) * radius * 0.14,
			outer_face
		)
		var outer := Vector3(
			cos(spoke_angle + 0.10) * radius * 0.45,
			sin(spoke_angle + 0.10) * radius * 0.45,
			outer_face
		)
		spoke_specs.append([inner, outer, 0.010])
	_add_bar_multimesh(parent, "ForgedSpokes", spoke_specs, _rim_material)

	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = radius * 0.115
	hub_mesh.bottom_radius = radius * 0.115
	hub_mesh.height = 0.055
	hub_mesh.radial_segments = 24
	var hub := MeshInstance3D.new()
	hub.name = "CenterLockHub"
	hub.mesh = hub_mesh
	hub.material_override = _accent_material
	hub.rotation.x = PI * 0.5
	hub.position.z = outer_face + side * 0.014
	parent.add_child(hub)


func _build_brake_hardware(
	steering: Node3D,
	spinner: Node3D,
	radius: float,
	width: float,
	side: float
	) -> void:
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = radius * 0.34
	disc_mesh.bottom_radius = radius * 0.34
	disc_mesh.height = 0.030
	disc_mesh.radial_segments = 36
	var disc := MeshInstance3D.new()
	disc.name = "CarbonBrakeDisc"
	disc.mesh = disc_mesh
	disc.material_override = _brake_material
	disc.rotation.x = PI * 0.5
	disc.position.z = side * width * 0.34
	spinner.add_child(disc)
	_add_box(
		steering,
		"BrakeCaliper",
		Vector3(radius * 0.13, radius * 0.34, 0.055),
		Vector3(-radius * 0.23, 0.0, side * width * 0.39),
		_body_material,
		Vector3(0.0, 0.0, deg_to_rad(12.0 * side))
	)


func _build_player_suspension() -> void:
	var carbon_specs: Array = []
	var metal_specs: Array = []
	var wheels := [
		[Vector3(1.55, 0.43, -0.91), true],
		[Vector3(1.55, 0.43, 0.91), true],
		[Vector3(-1.45, 0.45, -0.93), false],
		[Vector3(-1.45, 0.45, 0.93), false],
	]
	for wheel in wheels:
		var position: Vector3 = wheel[0]
		var is_front: bool = wheel[1]
		var side := signf(position.z)
		var chassis_x := 1.16 if is_front else -1.12
		var wheel_point := Vector3(position.x, position.y, position.z - side * 0.13)
		for longitudinal_offset in [-0.22, 0.22]:
			carbon_specs.append([
				Vector3(chassis_x + longitudinal_offset, 0.57, side * 0.31),
				wheel_point + Vector3(0.0, 0.08, 0.0), 0.014,
			])
			carbon_specs.append([
				Vector3(chassis_x + longitudinal_offset, 0.29, side * 0.35),
				wheel_point + Vector3(0.0, -0.08, 0.0), 0.014,
			])
		metal_specs.append([
			Vector3(chassis_x - 0.09, 0.66, side * 0.24), wheel_point, 0.012,
		])
		if is_front:
			metal_specs.append([
				Vector3(chassis_x + 0.12, 0.43, side * 0.29),
				wheel_point + Vector3(0.03, 0.0, 0.0), 0.011,
			])
	_add_bar_multimesh(_body_root, "CarbonWishbones", carbon_specs, _carbon_material)
	_add_bar_multimesh(_body_root, "PushAndTieRods", metal_specs, _rim_material)


func _build_remote_suspension() -> void:
	var bar_specs: Array = []
	var wheels := [
		[Vector3(1.55, 0.43, -0.91), true],
		[Vector3(1.55, 0.43, 0.91), true],
		[Vector3(-1.45, 0.45, -0.93), false],
		[Vector3(-1.45, 0.45, 0.93), false],
	]
	for wheel in wheels:
		var position: Vector3 = wheel[0]
		var is_front: bool = wheel[1]
		var side := signf(position.z)
		var chassis_x := 1.10 if is_front else -1.08
		bar_specs.append([
			Vector3(chassis_x, 0.42, side * 0.30),
			Vector3(position.x, position.y, position.z - side * 0.13), 0.018,
		])
	_remote_carbon_bar_specs.append_array(bar_specs)
	_add_bar_multimesh(
		_body_root, "BatchedRemoteHaloAndSuspension",
		_remote_carbon_bar_specs, _carbon_material
	)


func _build_steering_wheel_and_driver() -> void:
	if not _is_player:
		_build_remote_driver_and_yoke()
		return
	_build_driver_body()
	_steering_wheel_pivot = Node3D.new()
	_steering_wheel_pivot.name = "SteeringWheelPivot"
	_steering_wheel_pivot.position = Vector3(0.67, PLAYER_YOKE_HEIGHT_METERS, 0.0)
	_steering_wheel_pivot.scale = Vector3.ONE * 0.88
	_body_root.add_child(_steering_wheel_pivot)
	_register_cockpit_detail(_add_box(
		_steering_wheel_pivot, "YokeStructuralCore", Vector3(0.060, 0.185, 0.255),
		Vector3.ZERO, _display_bezel_material
	))
	_register_cockpit_detail(_add_capsule(
		_steering_wheel_pivot, "YokeTopRail", 0.031, 0.355,
		Vector3(0.0, 0.155, 0.0), _carbon_material,
		Vector3(PI * 0.5, 0.0, 0.0)
	))
	_register_cockpit_detail(_add_capsule(
		_steering_wheel_pivot, "YokeBottomRail", 0.028, 0.300,
		Vector3(0.0, -0.145, 0.0), _carbon_material,
		Vector3(PI * 0.5, 0.0, 0.0)
	))
	for side in [-1.0, 1.0]:
		_register_cockpit_detail(_add_bar(
			_steering_wheel_pivot, "YokeUpperShoulder",
			Vector3(0.0, 0.158, side * 0.12),
			Vector3(0.0, 0.095, side * 0.225), 0.033, _carbon_material
		))
		_register_cockpit_detail(_add_bar(
			_steering_wheel_pivot, "YokeLowerShoulder",
			Vector3(0.0, -0.145, side * 0.10),
			Vector3(0.0, -0.095, side * 0.225), 0.031, _carbon_material
		))
		_register_cockpit_detail(_add_capsule(
			_steering_wheel_pivot,
			"LeftGrip" if side < 0.0 else "RightGrip",
			0.054, 0.265, Vector3(-0.008, 0.0, side * 0.225),
			_rubber_material, Vector3(deg_to_rad(side * 7.0), 0.0, 0.0)
		))
	_register_cockpit_detail(_add_box(
		_steering_wheel_pivot, "DisplayBezel", Vector3(0.040, 0.115, 0.225),
		Vector3(-0.042, 0.010, 0.0), _display_bezel_material
	))
	_register_cockpit_detail(_add_box(
		_steering_wheel_pivot, "DashboardScreen", Vector3(0.022, 0.090, 0.202),
		Vector3(-0.066, 0.010, 0.0), _dashboard_screen_material
	))
	for paddle_side in [-1.0, 1.0]:
		_register_cockpit_detail(_add_box(
			_steering_wheel_pivot,
			"CarbonShiftPaddle",
			Vector3(0.028, 0.18, 0.042),
			Vector3(0.055, -0.005, paddle_side * 0.158),
			_brake_material,
			Vector3(deg_to_rad(7.0 * paddle_side), 0.0, 0.0)
		))
	for button_index in 10:
		var button_side := -1.0 if button_index % 2 == 0 else 1.0
		var button_row := float(button_index / 2)
		var control_material: Material = _control_red_material
		match button_index % 4:
			1:
				control_material = _control_blue_material
			2:
				control_material = _control_yellow_material
			3:
				control_material = _control_green_material
		_register_cockpit_detail(_add_box(
			_steering_wheel_pivot,
			"WheelControlButton",
			Vector3(0.017, 0.024, 0.024),
			Vector3(
				-0.076,
				-0.090 + button_row * 0.045,
				button_side * (0.085 + button_row * 0.017)
			),
			control_material
		), true)
	for dial_side in [-1.0, 1.0]:
		_register_cockpit_detail(_add_cylinder(
			_steering_wheel_pivot, "RotaryEncoder", 0.023, 0.022,
			Vector3(-0.074, -0.104, dial_side * 0.080),
			_control_yellow_material if dial_side < 0.0 else _control_blue_material,
			Vector3(0.0, 0.0, PI * 0.5)
		), true)
		for notch_index in 4:
			_register_cockpit_detail(_add_box(
				_steering_wheel_pivot, "EncoderNotch", Vector3(0.009, 0.010, 0.010),
				Vector3(
					-0.091,
					-0.104 + sin(float(notch_index) * PI * 0.5) * 0.017,
					dial_side * 0.080 + cos(float(notch_index) * PI * 0.5) * 0.017
				), _accent_material
			))
	_dashboard_label = Label3D.new()
	_dashboard_label.name = "GearRpmDisplay"
	_dashboard_label.font_size = 36
	_dashboard_label.pixel_size = 0.00082
	_dashboard_label.modulate = Color("70ffb0")
	_dashboard_label.outline_modulate = Color("08100d")
	_dashboard_label.outline_size = 3
	_dashboard_label.no_depth_test = true
	_dashboard_label.render_priority = 2
	_dashboard_label.position = Vector3(-0.080, 0.010, 0.0)
	_dashboard_label.rotation.y = -PI * 0.5
	_steering_wheel_pivot.add_child(_dashboard_label)
	_register_cockpit_detail(_dashboard_label)
	_build_shift_leds()
	_build_control_labels()
	_build_hand("LeftHand", -1.0)
	_build_hand("RightHand", 1.0)
	_build_driver_sleeves()


func _build_remote_driver_and_yoke() -> void:
	# Exterior-readable driver cues in two draws: helmet and visor. Remote cameras
	# never enter this cockpit, so a sub-pixel yoke, labels, hands, LEDs, encoders
	# and individual controls would be pure nearby-pack overdraw.
	var helmet_mesh := SphereMesh.new()
	helmet_mesh.radius = 0.17
	helmet_mesh.height = 0.33
	helmet_mesh.radial_segments = 16
	helmet_mesh.rings = 8
	var helmet := MeshInstance3D.new()
	helmet.name = "RemoteDriverHelmet"
	helmet.mesh = helmet_mesh
	helmet.material_override = _body_material
	helmet.position = Vector3(-0.48, 1.06, 0.0)
	_body_root.add_child(helmet)
	_add_box(
		_body_root, "RemoteHelmetVisor", Vector3(0.042, 0.090, 0.255),
		Vector3(-0.305, 1.075, 0.0), _glass_material,
		Vector3(0.0, 0.0, deg_to_rad(-5.0))
	)


func _build_driver_body() -> void:
	var helmet_mesh := SphereMesh.new()
	helmet_mesh.radius = 0.17
	helmet_mesh.height = 0.33
	helmet_mesh.radial_segments = 32
	helmet_mesh.rings = 16
	var helmet := MeshInstance3D.new()
	helmet.name = "DriverHelmet"
	helmet.mesh = helmet_mesh
	helmet.material_override = _body_material
	helmet.position = Vector3(-0.48, 1.06, 0.0)
	_body_root.add_child(helmet)
	_add_box(
		_body_root, "HelmetVisor", Vector3(0.042, 0.090, 0.255),
		Vector3(-0.305, 1.075, 0.0), _glass_material,
		Vector3(0.0, 0.0, deg_to_rad(-5.0))
	)
	_add_box(
		_body_root, "HelmetCenterStripe", Vector3(0.22, 0.025, 0.045),
		Vector3(-0.48, 1.218, 0.0), _accent_material
	)
	for side in [-1.0, 1.0]:
		var shoulder_mesh := CapsuleMesh.new()
		shoulder_mesh.radius = 0.12
		shoulder_mesh.height = 0.36
		shoulder_mesh.radial_segments = 18
		shoulder_mesh.rings = 8
		var shoulder := MeshInstance3D.new()
		shoulder.name = "DriverShoulder"
		shoulder.mesh = shoulder_mesh
		shoulder.material_override = _secondary_material
		shoulder.position = Vector3(-0.53, 0.82, side * 0.17)
		shoulder.rotation.x = deg_to_rad(12.0 * side)
		_body_root.add_child(shoulder)


func _build_shift_leds() -> void:
	for index in SHIFT_LED_COUNT:
		var color := Color("36dcff")
		if index >= 6:
			color = Color("ff365d")
		elif index >= 3:
			color = Color("ffe05d")
		var material := _emissive_material(color, 0.03)
		_shift_led_materials.append(material)
		var led_mesh := SphereMesh.new()
		led_mesh.radius = 0.013
		led_mesh.height = 0.026
		led_mesh.radial_segments = 12
		led_mesh.rings = 6
		var led := MeshInstance3D.new()
		led.name = "ShiftLed%02d" % index
		led.mesh = led_mesh
		led.material_override = material
		led.position = Vector3(-0.083, 0.112, lerpf(-0.142, 0.142, float(index) / 9.0))
		_steering_wheel_pivot.add_child(led)
		_register_cockpit_detail(led, true)


func _build_control_labels() -> void:
	var labels := [
		["MAP", Vector3(-0.085, 0.072, -0.125)],
		["BAL", Vector3(-0.085, 0.072, 0.125)],
		["SOC", Vector3(-0.085, -0.073, -0.120)],
		["DRS", Vector3(-0.085, -0.073, 0.120)],
	]
	for spec in labels:
		var label := Label3D.new()
		label.name = "FictionalControlLabel"
		label.text = str(spec[0])
		label.font_size = 18
		label.pixel_size = 0.00070
		label.modulate = Color("dceaf2")
		label.outline_modulate = Color("05080d")
		label.outline_size = 2
		label.position = spec[1]
		label.rotation.y = -PI * 0.5
		_steering_wheel_pivot.add_child(label)
		_register_cockpit_detail(label, true)


func _build_hand(hand_name: String, side: float) -> void:
	# Each hand is one semantic rig with several rounded glove pieces. Both rigs
	# are children of the yoke, so palms, fingers, cuffs and sleeves inherit the
	# exact same rotation rather than sliding over stationary grips.
	var hand_root := Node3D.new()
	hand_root.name = hand_name
	# Keep the gloves on the driver-facing side of the grip. The former shallow
	# offset placed the cuffs inside the imported shell in cockpit view.
	hand_root.position = Vector3(-0.090, 0.0, side * 0.225)
	hand_root.rotation.x = deg_to_rad(side * 7.0)
	hand_root.set_meta("visible_gloved_hand", true)
	_steering_wheel_pivot.add_child(hand_root)
	_hand_roots.append(hand_root)
	_register_cockpit_detail(hand_root)

	var palm := _add_capsule(
		hand_root, "GlovePalm", 0.058, 0.150, Vector3(-0.025, 0.0, 0.0),
		_glove_material, Vector3(deg_to_rad(side * 4.0), 0.0, 0.0)
	)
	palm.scale = Vector3(0.88, 1.0, 1.08)
	_register_cockpit_detail(palm)
	for finger_index in 4:
		var finger_y := -0.052 + float(finger_index) * 0.035
		var finger := _add_capsule(
			hand_root, "GloveFinger%02d" % finger_index, 0.016, 0.070,
			Vector3(-0.067, finger_y, -side * 0.026), _glove_material,
			Vector3(deg_to_rad(side * 18.0), 0.0, 0.0)
		)
		_register_cockpit_detail(finger)
	var thumb := _add_capsule(
		hand_root, "GloveThumb", 0.023, 0.090,
		Vector3(-0.068, 0.015, -side * 0.048), _glove_material,
		Vector3(deg_to_rad(side * 55.0), 0.0, deg_to_rad(side * 8.0))
	)
	_register_cockpit_detail(thumb)
	var cuff := _add_cylinder(
		hand_root, "GloveCuff", 0.063, 0.075,
		Vector3(-0.105, -0.004, side * 0.010), _glove_detail_material,
		Vector3(0.0, 0.0, PI * 0.5)
	)
	_register_cockpit_detail(cuff)
	var cuff_band := _add_cylinder(
		hand_root, "GloveCuffBand", 0.066, 0.018,
		Vector3(-0.146, -0.004, side * 0.010), _accent_material,
		Vector3(0.0, 0.0, PI * 0.5)
	)
	_register_cockpit_detail(cuff_band)
	for pad_index in 3:
		var pad := _add_box(
			hand_root, "GloveKnucklePad", Vector3(0.015, 0.020, 0.032),
			Vector3(-0.086, -0.032 + float(pad_index) * 0.034, -side * 0.048),
			_glove_detail_material
		)
		_register_cockpit_detail(pad)



func _build_driver_sleeves() -> void:
	# Sleeves originate at fixed shoulders and are re-aimed toward the rotating
	# cuffs. Parenting a complete straight arm to the yoke made it sweep through
	# the tub at high lock; these body-space sleeves stay above the survival cell.
	for side in [-1.0, 1.0]:
		var sleeve := _add_unit_bar(
			_body_root,
			"LeftDriverSleeve" if side < 0.0 else "RightDriverSleeve",
			_secondary_material
		)
		_driver_sleeves.append(sleeve)
		_register_cockpit_detail(sleeve)
	_update_driver_sleeves()


func _update_driver_sleeves() -> void:
	if _steering_wheel_pivot == null or _hand_roots.size() != 2 \
			or _driver_sleeves.size() != 2:
		return
	for index in 2:
		var side := -1.0 if index == 0 else 1.0
		var shoulder := Vector3(-0.50, 0.835, side * 0.205)
		var cuff_in_hand := Vector3(-0.155, -0.004, side * 0.008)
		var cuff_in_body := _steering_wheel_pivot.transform \
				* _hand_roots[index].transform * cuff_in_hand
		# A real sleeve flexes rather than cutting through the cockpit floor. The
		# clamp acts only on the cloth endpoint; the glove stays exactly on the grip.
		cuff_in_body.y = maxf(
			cuff_in_body.y, COCKPIT_HAND_CLEARANCE_FLOOR_METERS + 0.060
		)
		_pose_unit_bar(_driver_sleeves[index], shoulder, cuff_in_body, 0.052)


func _build_lights() -> void:
	var light_mesh := BoxMesh.new()
	light_mesh.size = Vector3(0.055, 0.12, 0.20)
	_rain_light = MeshInstance3D.new()
	_rain_light.name = "RearRainLight"
	_rain_light.mesh = light_mesh
	_rain_light.material_override = _rain_light_material
	_rain_light.position = Vector3(-2.16, 0.37, 0.0)
	_body_root.add_child(_rain_light)


func _build_surface_coating() -> void:
	# A single instanced draw gives mud/gravel/broken-asphalt races a visible car
	# response without cloning decals or particle nodes for every opponent.
	_surface_coating_material = _material(Color(0.12, 0.09, 0.065, 0.82), 0.0, 1.0)
	_surface_coating_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Mobile opponents express dirt through their already-required body/wheel
	# materials. Do not add an unused GeometryInstance to every remote graph.
	if not _is_player and _remote_mobile_budget:
		_surface_coating_count = 0
		return
	var speck := SphereMesh.new()
	speck.radius = 0.042
	speck.height = 0.070
	# The brown body tint carries the coating at racing distance. These low-poly
	# clumps add silhouette breakup without multiplying fine geometry across cars.
	speck.radial_segments = 8 if _is_player else 6
	speck.rings = 4 if _is_player else 3
	speck.material = _surface_coating_material
	var placements := [
		Transform3D(Basis.from_scale(Vector3(1.8, 0.45, 1.0)), Vector3(-0.40, 0.44, -0.62)),
		Transform3D(Basis.from_scale(Vector3(1.3, 0.34, 0.8)), Vector3(-0.82, 0.36, 0.66)),
		Transform3D(Basis.from_scale(Vector3(1.1, 0.28, 0.9)), Vector3(0.22, 0.40, 0.58)),
		Transform3D(Basis.from_scale(Vector3(1.5, 0.30, 0.7)), Vector3(0.55, 0.30, -0.44)),
		Transform3D(Basis.from_scale(Vector3(1.0, 0.32, 0.8)), Vector3(-1.30, 0.47, -0.55)),
		Transform3D(Basis.from_scale(Vector3(1.6, 0.30, 0.6)), Vector3(-1.58, 0.82, 0.46)),
		Transform3D(Basis.from_scale(Vector3(1.0, 0.25, 0.7)), Vector3(1.05, 0.31, 0.29)),
		Transform3D(Basis.from_scale(Vector3(1.3, 0.24, 0.6)), Vector3(1.42, 0.27, -0.24)),
		Transform3D(Basis.from_scale(Vector3(0.9, 0.23, 0.8)), Vector3(-0.12, 0.57, -0.47)),
		Transform3D(Basis.from_scale(Vector3(1.2, 0.22, 0.6)), Vector3(-1.74, 0.91, -0.30)),
	]
	var count := placements.size() if _is_player else 6
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = speck
	multimesh.instance_count = count
	for index in count:
		multimesh.set_instance_transform(index, placements[index])
	_surface_coating = MultiMeshInstance3D.new()
	_surface_coating.name = "SurfaceDirtCoating"
	_surface_coating.multimesh = multimesh
	_surface_coating.multimesh.visible_instance_count = 0
	_surface_coating.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_surface_coating.visible = false
	_body_root.add_child(_surface_coating)
	_surface_coating_count = count


func _apply_surface_appearance() -> void:
	if _body_material == null or _accent_material == null \
			or _surface_coating_material == null:
		return
	_surface_appearance_apply_count += 1
	if _surface_coating != null:
		_surface_coating.visible = false
		_surface_coating.multimesh.visible_instance_count = 0
	_body_material.albedo_color = team_color
	_accent_material.albedo_color = accent_color
	_rim_material.albedo_color = Color("2d333b")
	_remote_wheel_material.albedo_color = Color("15191e")
	_body_material.roughness = 0.16
	_body_material.clearcoat_roughness = 0.12
	_accent_material.roughness = 0.17
	_rubber_material.roughness = 0.82
	match _surface_style:
		RoadSurfaceCatalogType.WEATHERED_ASPHALT:
			# A tight clearcoat highlight reads as a rain-wet body at racing scale.
			_body_material.albedo_color = team_color.darkened(0.06)
			_body_material.roughness = 0.075
			_body_material.clearcoat_roughness = 0.035
			_accent_material.roughness = 0.09
		RoadSurfaceCatalogType.BUMPY_ASPHALT:
			if _surface_coating != null:
				_surface_coating.visible = true
				_surface_coating.multimesh.visible_instance_count = _surface_coating_count
			_surface_coating_material.albedo_color = Color(0.08, 0.085, 0.085, 0.48)
			_body_material.albedo_color = team_color.lerp(Color("3b3d3d"), 0.12)
			_body_material.roughness = 0.30
		RoadSurfaceCatalogType.COMPACT_GRAVEL:
			if _surface_coating != null:
				_surface_coating.visible = true
				_surface_coating.multimesh.visible_instance_count = _surface_coating_count
			_surface_coating_material.albedo_color = Color(0.43, 0.34, 0.22, 0.50)
			_body_material.albedo_color = team_color.lerp(Color("8a724d"), 0.24)
			_accent_material.albedo_color = accent_color.lerp(Color("a58b60"), 0.18)
			_body_material.roughness = 0.43
			_accent_material.roughness = 0.38
			_rubber_material.roughness = 0.96
		RoadSurfaceCatalogType.MUD:
			var dirt := clampf(_mud_accumulation, 0.0, 1.0)
			var visible_specks := clampi(
				ceili(dirt * float(_surface_coating_count)), 0, _surface_coating_count
			)
			# One alpha-zero player speck prewarms the transparent coating pipeline
			# during race setup, preventing a first-dirt shader hitch. Mobile remotes
			# receive the obvious brown tint but no repeated splatter draw.
			if _surface_coating != null:
				var prewarm_count := 1 \
						if _is_player and visible_specks == 0 else visible_specks
				_surface_coating.multimesh.visible_instance_count = prewarm_count
				_surface_coating.visible = _is_player or not _remote_mobile_budget
			_surface_coating_material.albedo_color = Color(
				0.12, 0.070, 0.032, 0.0 if dirt <= 0.001 else lerpf(0.42, 0.92, dirt)
			)
			_body_material.albedo_color = team_color.lerp(
				Color("4a2d18"), dirt * 0.74
			)
			_accent_material.albedo_color = accent_color.lerp(
				Color("5b3920"), dirt * 0.64
			)
			_rim_material.albedo_color = Color("2d333b").lerp(
				Color("3a2718"), dirt * 0.78
			)
			_remote_wheel_material.albedo_color = Color("15191e").lerp(
				Color("302116"), dirt * 0.72
			)
			_body_material.roughness = lerpf(0.16, 0.72, dirt)
			_accent_material.roughness = lerpf(0.17, 0.64, dirt)
			_rubber_material.roughness = lerpf(0.82, 1.0, dirt)


func _build_camera_sockets() -> void:
	# Camera mounts follow the authoritative vehicle transform, but not the
	# presentation-only suspension root. This lets the body pitch/heave under
	# load without dragging either camera down as road speed rises.
	cockpit_camera_socket = Marker3D.new()
	cockpit_camera_socket.name = "CockpitCameraSocket"
	cockpit_camera_socket.position = Vector3(-0.20, 1.10, 0.0)
	cockpit_camera_socket.basis = Basis.IDENTITY
	add_child(cockpit_camera_socket)
	chase_camera_socket = Marker3D.new()
	chase_camera_socket.name = "ChaseCameraSocket"
	chase_camera_socket.position = Vector3(-4.65, 2.10, 0.0)
	chase_camera_socket.basis = Basis.IDENTITY
	add_child(chase_camera_socket)


func _update_suspension(
		brake: float,
		throttle: float,
		wheel_slip: float,
		surface_bump: float = 0.0
	) -> void:
	for index in _wheel_suspension_pivots.size():
		var pivot := _wheel_suspension_pivots[index]
		var base := _wheel_base_positions[index]
		var front_factor := 1.0 if index < 2 else -0.55
		var side_factor := -1.0 if index % 2 == 0 else 1.0
		var compression := (
			-brake * 0.030 * front_factor
			+ throttle * 0.010 * front_factor
			+ _visual_roll * 0.30 * side_factor
			+ minf(wheel_slip, 1.0) * sin(_wheel_spin_angle + float(index)) * 0.008
			- surface_bump * 0.35
		)
		pivot.position.y = base.y + clampf(
			compression, -MAX_SUSPENSION_TRAVEL_METERS, MAX_SUSPENSION_TRAVEL_METERS
		)


func _update_dashboard(gear: int, rpm: float, shifting: bool) -> void:
	var gear_text := "R" if gear < 0 else ("N" if gear == 0 else str(gear))
	if _dashboard_label != null:
		_dashboard_label.text = "%s  %05d" % [gear_text, roundi(rpm)]
	var rpm_ratio := clampf(inverse_lerp(SHIFT_LED_RPM, REDLINE_RPM, rpm), 0.0, 1.0)
	var active_count := clampi(ceili(rpm_ratio * SHIFT_LED_COUNT), 0, SHIFT_LED_COUNT)
	var shift_flash := shifting and fmod(Time.get_ticks_msec() * 0.001, 0.12) < 0.06
	for index in _shift_led_materials.size():
		var active := index < active_count or shift_flash
		_shift_led_materials[index].emission_energy_multiplier = 4.2 if active else 0.03
		_shift_led_materials[index].albedo_color.a = 1.0 if active else 0.32


func _update_rain_light(brake: float, wheel_slip: float, delta: float) -> void:
	_rain_phase = fposmod(_rain_phase + delta, 0.50)
	# Do not synchronize cosmetic pulse writes across eleven mobile opponents.
	# Real braking/slip still illuminates them; the player's lamp keeps the pulse.
	var pulse := (_rain_phase < 0.115 or (_rain_phase > 0.20 and _rain_phase < 0.30)) \
			and (_is_player or not _remote_mobile_budget)
	var wet_surface := _surface_style in [
		RoadSurfaceCatalogType.WEATHERED_ASPHALT,
		RoadSurfaceCatalogType.MUD,
	]
	var active := brake > 0.18 or (wet_surface and (wheel_slip > 0.18 or pulse))
	if _rain_light_initialized and active == _rain_light_active:
		return
	_rain_light_initialized = true
	_rain_light_active = active
	_rain_light_material_update_count += 1
	_rain_light_material.emission_energy_multiplier = 7.5 if active else 0.04
	_rain_light_material.albedo_color = Color("ff2942") if active else Color("36070d")


func _speed_meters_per_second(state: Variant) -> float:
	var velocity: Variant = _value(state, &"velocity", Vector2.ZERO)
	if velocity is Vector2:
		return _finite_clamped(
			(velocity as Vector2).length() * AUTHORITY_UNIT_TO_METERS, 0.0, 140.0, 0.0
		)
	if velocity is Vector3:
		return _finite_clamped((velocity as Vector3).length(), 0.0, 140.0, 0.0)
	return _finite_clamped(
		_float_value(state, &"speed_mps", 0.0), 0.0, 140.0, 0.0
	)


func _value(source: Variant, property_name: StringName, fallback: Variant) -> Variant:
	if source == null:
		return fallback
	if source is Dictionary:
		var dictionary := source as Dictionary
		if dictionary.has(property_name):
			return dictionary[property_name]
		var string_key := str(property_name)
		return dictionary.get(string_key, fallback)
	if source is Object:
		var object := source as Object
		for property in object.get_property_list():
			if StringName(property.get("name", "")) == property_name:
				return object.get(property_name)
	return fallback


func _float_value(source: Variant, property_name: StringName, fallback: float) -> float:
	var value: Variant = _value(source, property_name, fallback)
	if value is float or value is int:
		return float(value)
	return fallback


func _int_value(source: Variant, property_name: StringName, fallback: int) -> int:
	var value: Variant = _value(source, property_name, fallback)
	if value is int or value is float:
		return int(value)
	return fallback


func _finite_clamped(
	value: float, minimum: float, maximum: float, fallback: float
	) -> float:
	if is_nan(value) or is_inf(value):
		return fallback
	return clampf(value, minimum, maximum)


func _opaque_color(color: Color, fallback: Color) -> Color:
	if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b):
		return fallback
	return Color(clampf(color.r, 0.0, 1.0), clampf(color.g, 0.0, 1.0), clampf(color.b, 0.0, 1.0), 1.0)


func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	return material


func _emissive_material(color: Color, energy: float) -> StandardMaterial3D:
	var material := _material(color, 0.0, 0.28)
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material


func _presentation_graph_stats() -> Dictionary:
	var stats := {
		"node_count": 0,
		"mesh_instance_count": 0,
		"label_3d_count": 0,
		"triangle_count": 0,
	}
	_accumulate_presentation_graph(self, stats)
	return stats


func _accumulate_presentation_graph(node: Node, stats: Dictionary) -> void:
	for child in node.get_children():
		stats["node_count"] = int(stats["node_count"]) + 1
		if child is MeshInstance3D:
			stats["mesh_instance_count"] = int(stats["mesh_instance_count"]) + 1
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.mesh != null:
				stats["triangle_count"] = int(stats["triangle_count"]) \
						+ int(mesh_instance.mesh.get_faces().size() / 3.0)
		elif child is MultiMeshInstance3D:
			stats["mesh_instance_count"] = int(stats["mesh_instance_count"]) + 1
			var multimesh_instance := child as MultiMeshInstance3D
			if multimesh_instance.multimesh != null \
					and multimesh_instance.multimesh.mesh != null:
				stats["triangle_count"] = int(stats["triangle_count"]) + int(
					multimesh_instance.multimesh.mesh.get_faces().size() / 3.0
				) * multimesh_instance.multimesh.instance_count
		elif child is Label3D:
			stats["label_3d_count"] = int(stats["label_3d_count"]) + 1
		_accumulate_presentation_graph(child, stats)


func _register_cockpit_detail(node: Node, is_control: bool = false) -> void:
	if node == null:
		return
	node.set_meta("cockpit_detail", true)
	_cockpit_detail_count += 1
	if node is Node3D:
		_cockpit_detail_nodes.append(node as Node3D)
	if is_control:
		node.set_meta("cockpit_control", true)
		_cockpit_control_count += 1


func _visible_cockpit_detail_count() -> int:
	var visible_count := 0
	for detail in _cockpit_detail_nodes:
		if detail != null and is_instance_valid(detail) and detail.visible:
			visible_count += 1
	return visible_count


func _hands_parented_to_yoke() -> bool:
	if _steering_wheel_pivot == null or _hand_roots.size() != 2:
		return false
	for hand_root in _hand_roots:
		if hand_root == null or hand_root.get_parent() != _steering_wheel_pivot:
			return false
	return true


func _minimum_hand_body_y() -> float:
	if _steering_wheel_pivot == null or _hand_roots.is_empty():
		return INF
	var minimum_y := INF
	for hand_root in _hand_roots:
		var hand_to_body := _steering_wheel_pivot.transform * hand_root.transform
		minimum_y = minf(
			minimum_y,
			_minimum_mesh_tree_y(hand_root, hand_to_body, true)
		)
	return minimum_y


func _minimum_mesh_tree_y(
		node: Node,
		transform_to_body: Transform3D,
		skip_node_transform: bool = false
	) -> float:
	var accumulated := transform_to_body
	if node is Node3D and not skip_node_transform:
		accumulated = transform_to_body * (node as Node3D).transform
	var minimum_y := INF
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		if instance.mesh != null:
			var bounds := instance.mesh.get_aabb()
			for corner_index in 8:
				var corner := Vector3(
					bounds.position.x + bounds.size.x * float(corner_index & 1),
					bounds.position.y + bounds.size.y * float((corner_index >> 1) & 1),
					bounds.position.z + bounds.size.z * float((corner_index >> 2) & 1)
				)
				minimum_y = minf(minimum_y, (accumulated * corner).y)
	for child in node.get_children():
		minimum_y = minf(
			minimum_y,
			_minimum_mesh_tree_y(child, accumulated)
		)
	return minimum_y


func _minimum_sleeve_body_y() -> float:
	var minimum_y := INF
	for sleeve in _driver_sleeves:
		if sleeve == null or sleeve.mesh == null:
			continue
		var bounds := sleeve.mesh.get_aabb()
		for corner_index in 8:
			var corner := Vector3(
				bounds.position.x + bounds.size.x * float(corner_index & 1),
				bounds.position.y + bounds.size.y * float((corner_index >> 1) & 1),
				bounds.position.z + bounds.size.z * float((corner_index >> 2) & 1)
			)
			minimum_y = minf(minimum_y, (sleeve.transform * corner).y)
	return minimum_y


func _remote_geometry_budget_snapshot() -> Dictionary:
	var stats := {
		"shadow_casters": 0,
		"bounded_details": 0,
		"unbounded_core": 0,
		"max_detail_range": 0.0,
	}
	_accumulate_remote_geometry_budget(self, stats)
	return stats


func _accumulate_remote_geometry_budget(node: Node, stats: Dictionary) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			var geometry := child as GeometryInstance3D
			if geometry.cast_shadow \
					!= GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				stats["shadow_casters"] = int(stats["shadow_casters"]) + 1
			if geometry.visibility_range_end > 0.0:
				stats["bounded_details"] = int(stats["bounded_details"]) + 1
				stats["max_detail_range"] = maxf(
					float(stats["max_detail_range"]),
					geometry.visibility_range_end
				)
			elif geometry == _remote_body_instance \
					or geometry == _remote_wheel_instances:
				stats["unbounded_core"] = int(stats["unbounded_core"]) + 1
		_accumulate_remote_geometry_budget(child, stats)


func _configure_remote_geometry(
		node: Node,
		detail_range: float,
		mobile_budget: bool
	) -> void:
	for child in node.get_children():
		if child is GeometryInstance3D:
			var geometry := child as GeometryInstance3D
			var is_core := geometry == _remote_body_instance \
					or geometry == _remote_wheel_instances
			geometry.cast_shadow = \
				GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if not is_core:
				geometry.visibility_range_end = detail_range
				geometry.visibility_range_end_margin = 8.0
				geometry.visibility_range_fade_mode = (
					GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				)
		_configure_remote_geometry(child, detail_range, mobile_budget)


func _add_capsule(
	parent: Node3D,
	mesh_name: String,
	radius: float,
	height: float,
	position: Vector3,
	material: Material,
	rotation: Vector3 = Vector3.ZERO
	) -> MeshInstance3D:
	var capsule := CapsuleMesh.new()
	capsule.radius = radius
	capsule.height = maxf(height, radius * 2.0)
	capsule.radial_segments = 18
	capsule.rings = 8
	var instance := MeshInstance3D.new()
	instance.name = mesh_name
	instance.mesh = capsule
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	parent.add_child(instance)
	return instance


func _add_cylinder(
	parent: Node3D,
	mesh_name: String,
	radius: float,
	height: float,
	position: Vector3,
	material: Material,
	rotation: Vector3 = Vector3.ZERO
	) -> MeshInstance3D:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 24
	var instance := MeshInstance3D.new()
	instance.name = mesh_name
	instance.mesh = cylinder
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	parent.add_child(instance)
	return instance


func _add_box(
	parent: Node3D,
	mesh_name: String,
	size: Vector3,
	position: Vector3,
	material: Material,
	rotation: Vector3 = Vector3.ZERO
	) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	var instance := MeshInstance3D.new()
	instance.name = mesh_name
	instance.mesh = box
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	parent.add_child(instance)
	return instance


func _add_unit_bar(
		parent: Node3D,
		mesh_name: String,
		material: Material
	) -> MeshInstance3D:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	cylinder.radial_segments = 10
	var instance := MeshInstance3D.new()
	instance.name = mesh_name
	instance.mesh = cylinder
	instance.material_override = material
	parent.add_child(instance)
	return instance


func _pose_unit_bar(
		instance: MeshInstance3D,
		start: Vector3,
		finish: Vector3,
		radius: float
	) -> void:
	var direction := finish - start
	var rotation_basis := Basis.IDENTITY
	if direction.length_squared() > 0.000001:
		rotation_basis = Basis(Quaternion(Vector3.UP, direction.normalized()))
	instance.transform = Transform3D(
		rotation_basis * Basis.from_scale(
			Vector3(radius, maxf(direction.length(), 0.0001), radius)
		),
		(start + finish) * 0.5
	)


func _add_bar(
	parent: Node3D,
	mesh_name: String,
	start: Vector3,
	finish: Vector3,
	radius: float,
	material: Material
	) -> MeshInstance3D:
	var direction := finish - start
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = direction.length()
	cylinder.radial_segments = 8
	var instance := MeshInstance3D.new()
	instance.name = mesh_name
	instance.mesh = cylinder
	instance.material_override = material
	instance.position = (start + finish) * 0.5
	if direction.length_squared() > 0.000001:
		instance.quaternion = Quaternion(Vector3.UP, direction.normalized())
	parent.add_child(instance)
	return instance


func _add_bar_multimesh(
	parent: Node3D,
	mesh_name: String,
	bar_specs: Array,
	material: Material
	) -> MultiMeshInstance3D:
	if bar_specs.is_empty():
		return null
	var unit_cylinder := CylinderMesh.new()
	unit_cylinder.top_radius = 1.0
	unit_cylinder.bottom_radius = 1.0
	unit_cylinder.height = 1.0
	unit_cylinder.radial_segments = 8
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = unit_cylinder
	multimesh.instance_count = bar_specs.size()
	for index in bar_specs.size():
		var spec: Array = bar_specs[index]
		var start: Vector3 = spec[0]
		var finish: Vector3 = spec[1]
		var radius: float = float(spec[2])
		var direction := finish - start
		var rotation_basis := Basis.IDENTITY
		if direction.length_squared() > 0.000001:
			rotation_basis = Basis(Quaternion(Vector3.UP, direction.normalized()))
		var scaled_basis := rotation_basis * Basis.from_scale(
			Vector3(radius, maxf(direction.length(), 0.0001), radius)
		)
		multimesh.set_instance_transform(
			index, Transform3D(scaled_basis, (start + finish) * 0.5)
		)
	var instance := MultiMeshInstance3D.new()
	instance.name = mesh_name
	instance.multimesh = multimesh
	instance.material_override = material
	parent.add_child(instance)
	return instance
