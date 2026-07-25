class_name CollisionSparkPool3D
extends Node3D
## Presentation-only, fixed-capacity car-contact spark pool.
##
## Authoritative collision telemetry decides whether an event exists. This node
## only turns an event into a short yellow burst; it never queries proximity,
## mutates a vehicle, or feeds anything back into simulation.

const POOL_SIZE: int = 6
const PARTICLES_PER_BURST: int = 14
const BURST_LIFETIME_SECONDS: float = 0.36
const SPARK_WIDTH_METERS: float = 0.028
const SPARK_LENGTH_METERS: float = 0.095
const MIN_IMPACT_SPEED_AUTHORITY: float = 12.0
const MAX_REMEMBERED_EVENT_KEYS: int = 32

var _emitters: Array[GPUParticles3D] = []
var _cursor: int = 0
var _accepted_bursts: int = 0
var _rejected_bursts: int = 0
var _last_world_position := Vector3.ZERO
var _last_world_normal := Vector3.RIGHT
var _last_impact_speed_authority: float = 0.0
var _event_keys: Dictionary = {}
var _event_key_order: Array[String] = []
var _built: bool = false


func _ready() -> void:
	_ensure_pool()


func emit_contact(
		world_position: Vector3,
		world_normal: Vector3,
		impact_speed_authority: float,
		event_key: String = ""
	) -> bool:
	_ensure_pool()
	if not _finite_vector3(world_position) \
			or not _finite_vector3(world_normal) \
			or world_normal.length_squared() <= 0.000001 \
			or not is_finite(impact_speed_authority) \
			or impact_speed_authority < MIN_IMPACT_SPEED_AUTHORITY:
		_rejected_bursts += 1
		return false
	if not event_key.is_empty() and _event_keys.has(event_key):
		_rejected_bursts += 1
		return false
	_remember_event_key(event_key)

	var emitter := _emitters[_cursor]
	_cursor = (_cursor + 1) % POOL_SIZE
	var normal := world_normal.normalized()
	var process := emitter.process_material as ParticleProcessMaterial
	if process != null:
		process.direction = (normal * 0.72 + Vector3.UP * 0.78).normalized()
		var severity := clampf(
			inverse_lerp(MIN_IMPACT_SPEED_AUTHORITY, 240.0, impact_speed_authority),
			0.0, 1.0
		)
		process.initial_velocity_min = lerpf(3.8, 7.2, severity)
		process.initial_velocity_max = lerpf(6.4, 11.5, severity)
	emitter.global_position = world_position + Vector3.UP * 0.06
	emitter.emitting = false
	emitter.restart()
	emitter.emitting = true
	_accepted_bursts += 1
	_last_world_position = world_position
	_last_world_normal = normal
	_last_impact_speed_authority = impact_speed_authority
	return true


func reset_pool() -> void:
	_ensure_pool()
	for emitter in _emitters:
		emitter.emitting = false
	_cursor = 0
	_accepted_bursts = 0
	_rejected_bursts = 0
	_last_world_position = Vector3.ZERO
	_last_world_normal = Vector3.RIGHT
	_last_impact_speed_authority = 0.0
	_event_keys.clear()
	_event_key_order.clear()


func presentation_snapshot() -> Dictionary:
	_ensure_pool()
	var emitting_count := 0
	var total_particle_capacity := 0
	var maximum_lifetime := 0.0
	for emitter in _emitters:
		if emitter.emitting:
			emitting_count += 1
		total_particle_capacity += emitter.amount
		maximum_lifetime = maxf(maximum_lifetime, emitter.lifetime)
	return {
		"pool_size": _emitters.size(),
		"particles_per_burst": PARTICLES_PER_BURST,
		"total_particle_capacity": total_particle_capacity,
		"emitting_count": emitting_count,
		"accepted_bursts": _accepted_bursts,
		"rejected_bursts": _rejected_bursts,
		"cursor": _cursor,
		"minimum_impact_speed_authority": MIN_IMPACT_SPEED_AUTHORITY,
		"maximum_lifetime_seconds": maximum_lifetime,
		"spark_width_meters": SPARK_WIDTH_METERS,
		"spark_length_meters": SPARK_LENGTH_METERS,
		"remembered_event_keys": _event_keys.size(),
		"last_world_position": _last_world_position,
		"last_world_normal": _last_world_normal,
		"last_impact_speed_authority": _last_impact_speed_authority,
		"yellow_emissive": true,
		"presentation_only": true,
	}


func _ensure_pool() -> void:
	if _built:
		return
	_built = true
	for index in POOL_SIZE:
		var emitter := GPUParticles3D.new()
		emitter.name = "CollisionSparkEmitter%02d" % index
		emitter.amount = PARTICLES_PER_BURST
		emitter.lifetime = BURST_LIFETIME_SECONDS
		emitter.one_shot = true
		emitter.explosiveness = 0.96
		emitter.randomness = 0.36
		emitter.fixed_fps = 30
		emitter.interpolate = true
		emitter.fract_delta = true
		emitter.visibility_aabb = AABB(Vector3(-4.0, -2.0, -4.0), Vector3(8.0, 6.0, 8.0))
		emitter.process_material = _particle_process_material()
		emitter.draw_pass_1 = _spark_mesh()
		emitter.emitting = false
		add_child(emitter)
		_emitters.append(emitter)


func _particle_process_material() -> ParticleProcessMaterial:
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.075
	process.direction = Vector3(0.25, 0.85, 0.0).normalized()
	process.spread = 58.0
	process.initial_velocity_min = 4.0
	process.initial_velocity_max = 8.5
	process.gravity = Vector3(0.0, -18.0, 0.0)
	process.damping_min = 1.2
	process.damping_max = 2.8
	process.scale_min = 0.55
	process.scale_max = 1.10
	process.color = Color("ffd23f")
	return process


func _spark_mesh() -> QuadMesh:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("ffd43b")
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.emission_enabled = true
	material.emission = Color("ffb51f")
	material.emission_energy_multiplier = 5.5
	var mesh := QuadMesh.new()
	mesh.size = Vector2(SPARK_WIDTH_METERS, SPARK_LENGTH_METERS)
	mesh.material = material
	return mesh


func _remember_event_key(event_key: String) -> void:
	if event_key.is_empty():
		return
	_event_keys[event_key] = true
	_event_key_order.append(event_key)
	while _event_key_order.size() > MAX_REMEMBERED_EVENT_KEYS:
		var forgotten: String = _event_key_order.pop_front()
		_event_keys.erase(forgotten)


static func _finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
