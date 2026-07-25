class_name RoadSurfaceEffects3D
extends Node3D
## Bounded, presentation-only weather and loose-surface effects.
##
## One rain field, one static MultiMesh, and a four-emitter spray pool cover the
## complete race. No effect node is allocated when cars approach one another,
## which keeps the two-car and twelve-car paths identical on mobile hardware.

const Mapper := preload("res://game/presentation3d/world_coordinate_mapper.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")

const SPRAY_POOL_SIZE := 4
const MOBILE_ACTIVE_SPRAY_LIMIT := 2
const DESKTOP_ACTIVE_SPRAY_LIMIT := 4
const SPRAY_PARTICLES_PER_EMITTER := 24
const MUD_MOBILE_PARTICLES_PER_EMITTER := 12
const MOBILE_STATIC_DETAIL_LIMIT := 72
const DESKTOP_STATIC_DETAIL_LIMIT := 160
const MUD_MOBILE_STATIC_DETAIL_LIMIT := 20
const MUD_DESKTOP_STATIC_DETAIL_LIMIT := 96
const MIN_SPRAY_SPEED_AUTHORITY := 12.0

var _surface_style: StringName = RoadSurfaceCatalogType.SMOOTH_ASPHALT
var _mobile_budget := false
var _reduced_motion := false
var _rain: GPUParticles3D
var _spray_emitters: Array[GPUParticles3D] = []
var _static_detail: MultiMeshInstance3D
var _configured := false
var _active_spray_count := 0
var _static_detail_count := 0
var _mobile_update_phase := 0


func _ready() -> void:
	_ensure_nodes()


func configure(track: RaceTrackQuery, mobile_budget: bool, reduced_motion: bool) -> void:
	_ensure_nodes()
	_mobile_budget = mobile_budget
	_reduced_motion = reduced_motion
	_surface_style = track.road_surface if track != null and track.is_valid() \
			else RoadSurfaceCatalogType.SMOOTH_ASPHALT
	_configure_rain()
	_configure_spray_pool()
	_rebuild_static_detail(track)
	_configured = track != null and track.is_valid()
	_mobile_update_phase = 0


func update_vehicles(entries: Array[RaceEntry], vehicles: Dictionary, player_id: String) -> void:
	_ensure_nodes()
	var player_visual := vehicles.get(player_id) as Node3D
	if _rain != null:
		_rain.emitting = _configured \
				and _surface_style == RoadSurfaceCatalogType.WEATHERED_ASPHALT
		if _rain.emitting and player_visual != null and is_instance_valid(player_visual):
			_rain.global_position = player_visual.global_position + Vector3.UP * 7.5

	var supports_spray := _surface_style in [
		RoadSurfaceCatalogType.WEATHERED_ASPHALT,
		RoadSurfaceCatalogType.BUMPY_ASPHALT,
		RoadSurfaceCatalogType.COMPACT_GRAVEL,
		RoadSurfaceCatalogType.MUD,
	]
	var active_limit := MOBILE_ACTIVE_SPRAY_LIMIT if _mobile_budget \
			else DESKTOP_ACTIVE_SPRAY_LIMIT
	if _surface_style == RoadSurfaceCatalogType.MUD:
		# Mud is the fill-rate-heavy surface. Mobile follows only the player with
		# one compact rear wake instead of layering the closest opponents too.
		active_limit = 1 if _mobile_budget else 2
	if _reduced_motion:
		active_limit = mini(active_limit, 1)
	if _mobile_budget:
		_mobile_update_phase = (_mobile_update_phase + 1) % 2
		if _mobile_update_phase == 0:
			return
	_active_spray_count = 0
	for emitter in _spray_emitters:
		emitter.emitting = false
	if not _configured or not supports_spray:
		return

	# Entries are race-order stable and the player is normally first. Prefer the
	# player explicitly, then fill the fixed pool with the nearest eligible cars.
	var candidates: Array[Dictionary] = []
	for entry in entries:
		if entry == null or entry.state == null or not entry.state.is_grounded:
			continue
		var id := str(entry.participant_id)
		if id.is_empty():
			id = str(entry.state.vehicle_id)
		var visual := vehicles.get(id) as Node3D
		if visual == null or not is_instance_valid(visual) \
				or entry.state.velocity.length() < MIN_SPRAY_SPEED_AUTHORITY:
			continue
		var priority := 0.0 if id == player_id else 1.0
		if player_visual != null and is_instance_valid(player_visual) and id != player_id:
			priority += visual.global_position.distance_squared_to(player_visual.global_position)
		candidates.append({"visual": visual, "state": entry.state, "priority": priority})
	candidates.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return float(first["priority"]) < float(second["priority"])
	)
	for index in mini(active_limit, candidates.size()):
		var candidate: Dictionary = candidates[index]
		var vehicle := candidate["visual"] as Node3D
		var state := candidate["state"] as VehicleState
		var emitter := _spray_emitters[index]
		var speed_ratio := clampf(
			(state.velocity.length() - MIN_SPRAY_SPEED_AUTHORITY) / 175.0,
			0.18, 1.0
		)
		emitter.amount_ratio = speed_ratio * (0.58 if _reduced_motion else 1.0)
		emitter.global_transform = vehicle.global_transform.translated_local(
			Vector3(-1.78, 0.14, 0.0)
		)
		emitter.emitting = true
		_active_spray_count += 1


func reset_effects() -> void:
	_configured = false
	_active_spray_count = 0
	if _rain != null:
		_rain.emitting = false
	for emitter in _spray_emitters:
		emitter.emitting = false
	if _static_detail != null:
		_static_detail.multimesh = null
	_static_detail_count = 0


func presentation_snapshot() -> Dictionary:
	_ensure_nodes()
	var particle_capacity := 0
	for emitter in _spray_emitters:
		particle_capacity += emitter.amount
	return {
		"surface_style": str(_surface_style),
		"rain_enabled": _rain != null and _rain.emitting,
		"rain_particle_capacity": _rain.amount if _rain != null else 0,
		"spray_pool_size": _spray_emitters.size(),
		"active_spray_count": _active_spray_count,
		"spray_particle_capacity": particle_capacity,
		"spray_draw_passes": (
			_spray_emitters[0].draw_passes if not _spray_emitters.is_empty() else 0
		),
		"minimum_spray_speed": MIN_SPRAY_SPEED_AUTHORITY,
		"static_detail_count": _static_detail_count,
		"mobile_budget": _mobile_budget,
		"mobile_update_stride": 2 if _mobile_budget else 1,
		"rear_axle_only": true,
		"emitter_local_x": -1.78,
		"presentation_only": true,
	}


func _ensure_nodes() -> void:
	if _rain != null:
		return
	_rain = GPUParticles3D.new()
	_rain.name = "WeatheredRainField"
	_rain.local_coords = false
	_rain.lifetime = 1.0
	_rain.fixed_fps = 30
	_rain.interpolate = true
	_rain.fract_delta = true
	_rain.visibility_aabb = AABB(Vector3(-18.0, -12.0, -24.0), Vector3(36.0, 26.0, 48.0))
	_rain.draw_pass_1 = _particle_quad(Color(0.68, 0.82, 0.90, 0.50), Vector2(0.018, 0.52))
	add_child(_rain)
	for index in SPRAY_POOL_SIZE:
		var emitter := GPUParticles3D.new()
		emitter.name = "RoadSurfaceSpray%02d" % index
		emitter.amount = SPRAY_PARTICLES_PER_EMITTER
		emitter.lifetime = 0.88
		emitter.fixed_fps = 24
		emitter.interpolate = true
		emitter.fract_delta = true
		emitter.local_coords = false
		emitter.visibility_aabb = AABB(Vector3(-6.0, -2.0, -5.0), Vector3(12.0, 7.0, 10.0))
		emitter.emitting = false
		add_child(emitter)
		_spray_emitters.append(emitter)
	_static_detail = MultiMeshInstance3D.new()
	_static_detail.name = "RoadSurfaceLooseDetail"
	_static_detail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_static_detail)


func _configure_rain() -> void:
	_rain.amount = 150 if _mobile_budget else 280
	_rain.emitting = false
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(14.0, 5.0, 20.0)
	process.direction = Vector3(-0.08, -1.0, 0.03).normalized()
	process.spread = 4.0
	process.initial_velocity_min = 18.0
	process.initial_velocity_max = 23.0
	process.gravity = Vector3(0.0, -4.0, 0.0)
	process.scale_min = 0.75
	process.scale_max = 1.15
	process.color = Color(0.72, 0.86, 0.94, 0.48)
	_rain.process_material = process


func _configure_spray_pool() -> void:
	var color := Color(0.34, 0.31, 0.28, 0.66)
	var size := Vector2(0.055, 0.055)
	var particle_shape := &"droplet"
	var gravity := -11.0
	var velocity_min := 2.4
	var velocity_max := 5.2
	var secondary_mesh: Mesh = null
	match _surface_style:
		RoadSurfaceCatalogType.MUD:
			color = Color(0.055, 0.045, 0.038, 0.86)
			size = Vector2(0.064, 0.064)
			gravity = -13.0
			velocity_min = 3.8
			velocity_max = 7.6
		RoadSurfaceCatalogType.COMPACT_GRAVEL:
			color = Color(0.50, 0.43, 0.31, 0.70)
			size = Vector2(0.038, 0.038)
			gravity = -10.0
			velocity_min = 3.2
			velocity_max = 6.5
			secondary_mesh = _particle_blob(
				Color(0.58, 0.49, 0.34, 0.16), 0.125
			)
		RoadSurfaceCatalogType.BUMPY_ASPHALT:
			color = Color(0.10, 0.11, 0.11, 0.78)
			size = Vector2(0.040, 0.025)
			particle_shape = &"chip"
			gravity = -14.0
			velocity_min = 2.0
			velocity_max = 4.4
		RoadSurfaceCatalogType.WEATHERED_ASPHALT:
			color = Color(0.62, 0.72, 0.76, 0.25)
			size = Vector2(0.012, 0.060)
			particle_shape = &"mist"
			gravity = -8.0
			velocity_min = 2.5
			velocity_max = 5.0
	var mesh: Mesh
	if particle_shape == &"chip":
		mesh = _particle_chip(color, size)
	elif particle_shape == &"mist":
		mesh = _particle_quad(color, size)
	else:
		mesh = _particle_blob(color, size.x)
	for emitter in _spray_emitters:
		emitter.amount = MUD_MOBILE_PARTICLES_PER_EMITTER \
				if _mobile_budget and _surface_style == RoadSurfaceCatalogType.MUD \
				else SPRAY_PARTICLES_PER_EMITTER
		emitter.fixed_fps = 18 if _mobile_budget else 24
		var process := ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		process.emission_box_extents = Vector3(0.16, 0.05, 0.72)
		process.direction = Vector3(-0.82, 0.56, 0.0).normalized()
		process.spread = 24.0
		process.initial_velocity_min = velocity_min
		process.initial_velocity_max = velocity_max
		process.gravity = Vector3(0.0, gravity, 0.0)
		process.damping_min = 0.6
		process.damping_max = 1.8
		process.scale_min = 0.55
		process.scale_max = 1.25
		process.color = color
		emitter.process_material = process
		emitter.draw_pass_1 = mesh
		if secondary_mesh != null:
			emitter.draw_passes = 2
			emitter.draw_pass_2 = secondary_mesh
		else:
			if emitter.draw_passes > 1:
				emitter.draw_pass_2 = null
			emitter.draw_passes = 1
		emitter.emitting = false


func _rebuild_static_detail(track: RaceTrackQuery) -> void:
	_static_detail.multimesh = null
	_static_detail_count = 0
	if track == null or not track.is_valid() or not _surface_style in [
		RoadSurfaceCatalogType.BUMPY_ASPHALT,
		RoadSurfaceCatalogType.COMPACT_GRAVEL,
		RoadSurfaceCatalogType.MUD,
	]:
		return
	var limit := MOBILE_STATIC_DETAIL_LIMIT if _mobile_budget else DESKTOP_STATIC_DETAIL_LIMIT
	if _surface_style == RoadSurfaceCatalogType.MUD:
		limit = MUD_MOBILE_STATIC_DETAIL_LIMIT if _mobile_budget \
				else MUD_DESKTOP_STATIC_DETAIL_LIMIT
	var minimum_count := 12 if _mobile_budget \
			and _surface_style == RoadSurfaceCatalogType.MUD else 24
	var count := clampi(roundi(track.total_length / 28.0), minimum_count, limit)
	var mesh := BoxMesh.new()
	var material := StandardMaterial3D.new()
	material.roughness = 1.0
	match _surface_style:
		RoadSurfaceCatalogType.MUD:
			mesh.size = Vector3(0.16, 0.035, 0.10)
			material.albedo_color = Color("211912")
		RoadSurfaceCatalogType.COMPACT_GRAVEL:
			mesh.size = Vector3(0.11, 0.045, 0.08)
			material.albedo_color = Color("5f523c")
		_:
			mesh.size = Vector3(0.34, 0.026, 0.14)
			material.albedo_color = Color("171a1b")
	mesh.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = count
	for index in count:
		var seed := track.deterministic_seed + index * 7919
		var along_jitter := (_unit_hash(seed + 17) - 0.5) * track.total_length / float(count)
		var distance := track.total_length * (float(index) + 0.5) / float(count) + along_jitter
		var sample := track.sample_at_distance(distance)
		var lateral_authority := (_unit_hash(seed + 31) - 0.5) * track.track_width * 0.72
		var center := Mapper.authority_position_to_world(
			sample.get("position", Vector2.ZERO),
			float(sample.get("elevation_level", 0.0)),
			Mapper.ROAD_SURFACE_Y_METERS + 0.018
		)
		var normal := Mapper.authority_direction_to_world(sample.get("normal", Vector2.UP))
		var position := center + normal * Mapper.authority_scalar_to_meters(lateral_authority)
		var yaw := -Vector2(sample.get("tangent", Vector2.RIGHT)).angle() \
				+ (_unit_hash(seed + 47) - 0.5) * 1.4
		var scale := 0.65 + _unit_hash(seed + 63) * 0.85
		multimesh.set_instance_transform(
			index,
			Transform3D(
				Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(scale, 1.0, scale)),
				position
			)
		)
	_static_detail.multimesh = multimesh
	_static_detail_count = count


static func _particle_quad(color: Color, size: Vector2) -> QuadMesh:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	var mesh := QuadMesh.new()
	mesh.size = size
	mesh.material = material
	return mesh


static func _particle_blob(color: Color, radius: float) -> SphereMesh:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.roughness = 1.0
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 1.65
	mesh.radial_segments = 6
	mesh.rings = 3
	mesh.material = material
	return mesh


static func _particle_chip(color: Color, size: Vector2) -> BoxMesh:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size.x, size.y, size.x * 0.72)
	mesh.material = material
	return mesh


static func _unit_hash(value: int) -> float:
	var hashed := int(value)
	hashed = ((hashed >> 16) ^ hashed) * 0x45d9f3b
	hashed = ((hashed >> 16) ^ hashed) * 0x45d9f3b
	hashed = (hashed >> 16) ^ hashed
	return float(hashed & 0x7fffffff) / float(0x7fffffff)
