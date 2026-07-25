class_name FormulaCameraRig3D
extends Node3D
## Presentation-only Formula camera. The world remains fixed; this rig follows
## interpolated vehicle transforms supplied by RaceWorld3D.

const CAMERA_COCKPIT: StringName = &"cockpit"
const CAMERA_CHASE: StringName = &"chase"

const CHASE_BASE_FOV := 66.0
const COCKPIT_BASE_FOV := 70.0
const COCKPIT_LOOK_DISTANCE := 27.0
const COCKPIT_LOOK_DOWN_SLOPE := 0.118
## Chase translation remains locked to the current interpolated car origin, but
## road-grade pitch is eased separately. This removes the hard camera nod at a
## bridge ramp/deck seam without bringing back speed-dependent world lag.
const CHASE_GRADE_RESPONSE := 4.2
const CHASE_MAX_GRADE_RATE_RADIANS := deg_to_rad(42.0)

var camera_mode: StringName = CAMERA_CHASE
var camera: Camera3D

var _target_transform := Transform3D.IDENTITY
var _target_speed_mps := 0.0
var _target_steering := 0.0
var _has_target := false
var _reduced_motion := false
var _smoothed_look_at := Vector3.ZERO
var _cockpit_socket_transform := Transform3D.IDENTITY
var _chase_socket_transform := Transform3D.IDENTITY
var _has_cockpit_socket := false
var _has_chase_socket := false
var _smoothed_chase_pitch := 0.0
var _has_smoothed_chase_pitch := false


func _ready() -> void:
	_ensure_camera()
	set_process(true)


func configure_accessibility(
		reduced_motion: bool,
		_screen_shake_strength: float = 0.35
	) -> void:
	_reduced_motion = reduced_motion


func set_camera_mode(mode: StringName) -> void:
	camera_mode = CAMERA_COCKPIT if mode == CAMERA_COCKPIT else CAMERA_CHASE
	_ensure_camera()
	camera.near = 0.08 if camera_mode == CAMERA_COCKPIT else 0.18
	if _has_target:
		snap_to_target()


func update_target(
		vehicle_transform: Transform3D,
		speed_mps: float,
		steering: float,
		_shift_ticks_remaining: int
	) -> void:
	_target_transform = vehicle_transform
	_target_speed_mps = maxf(speed_mps, 0.0)
	_target_steering = clampf(steering, -1.0, 1.0)
	if not _has_target:
		_has_target = true
		snap_to_target()


func clear_target() -> void:
	_has_target = false


func update_socket_targets(cockpit_transform: Variant, chase_transform: Variant) -> void:
	_has_cockpit_socket = cockpit_transform is Transform3D
	_has_chase_socket = chase_transform is Transform3D
	if _has_cockpit_socket:
		_cockpit_socket_transform = cockpit_transform as Transform3D
	if _has_chase_socket:
		_chase_socket_transform = chase_transform as Transform3D


func clear_socket_targets() -> void:
	_has_cockpit_socket = false
	_has_chase_socket = false


func presentation_snapshot() -> Dictionary:
	var pose: Dictionary = _desired_pose() if _has_target else {}
	var desired_position: Vector3 = pose.get("position", Vector3.ZERO)
	var camera_position := camera.global_position \
			if camera != null and is_instance_valid(camera) else Vector3.ZERO
	return {
		"camera_mode": camera_mode,
		"has_target": _has_target,
		"has_cockpit_socket": _has_cockpit_socket,
		"has_chase_socket": _has_chase_socket,
		"target_speed_mps": _target_speed_mps,
		"target_steering": _target_steering,
		"target_origin": _target_transform.origin,
		"camera_position": camera_position,
		"desired_position": desired_position,
		"relative_position": camera_position - _target_transform.origin,
		"desired_relative_position": desired_position - _target_transform.origin,
		"vehicle_distance": camera_position.distance_to(_target_transform.origin),
		"desired_vehicle_distance": desired_position.distance_to(_target_transform.origin),
		"fov": camera.fov if camera != null and is_instance_valid(camera) else 0.0,
		"desired_fov": _desired_fov() if _has_target else 0.0,
		"target_grade_pitch_radians": _target_grade_pitch(),
		"smoothed_chase_pitch_radians": _smoothed_chase_pitch,
	}


func snap_to_target() -> void:
	if not _has_target:
		return
	_ensure_camera()
	if camera_mode == CAMERA_CHASE:
		_smoothed_chase_pitch = _target_grade_pitch()
		_has_smoothed_chase_pitch = true
	var pose := _desired_pose()
	camera.global_position = pose["position"]
	_smoothed_look_at = pose["look_at"]
	_safe_look_at(_smoothed_look_at)
	camera.fov = _desired_fov()


func _process(delta: float) -> void:
	if not _has_target:
		return
	_ensure_camera()
	if camera_mode == CAMERA_CHASE:
		_advance_chase_grade(delta)
	var pose := _desired_pose()
	# A real cockpit camera is bolted to the survival cell.  Smoothing its world
	# position independently from the rendered chassis makes the wheel, halo and
	# tyres swim underneath the driver's eyes—the same visual failure as moving
	# scenery around a fixed screen-space car.  Keep the cockpit pose rigid to the
	# authored socket; suspension/chassis animation already supplies the bounded
	# physical motion. Chase position and aim are likewise rigid to the authored
	# external mount. Interpolating a world-space look point while moving the mount
	# immediately makes that point trail farther behind at higher speed, producing
	# an artificial downward pitch. Vehicle transforms are already interpolated by
	# RaceWorld3D, so a second translation-dependent camera filter is incorrect.
	if camera_mode == CAMERA_COCKPIT:
		camera.global_position = pose["position"]
		_smoothed_look_at = pose["look_at"]
		_safe_look_at(_smoothed_look_at)
		var cockpit_fov_response := 16.0 if _reduced_motion else 8.5
		camera.fov = lerpf(
			camera.fov,
			_desired_fov(),
			_exponential_weight(cockpit_fov_response, delta)
		)
		return
	# Keep the complete chase pose in the same interpolated vehicle frame. Neither
	# camera position, aim offset nor FOV may acquire world-space translation lag.
	camera.global_position = pose["position"]
	_smoothed_look_at = pose["look_at"]
	_safe_look_at(_smoothed_look_at)
	var fov_response := 16.0 if _reduced_motion else 5.5
	camera.fov = lerpf(
		camera.fov, _desired_fov(), _exponential_weight(fov_response, delta)
	)


func _ensure_camera() -> void:
	if camera != null and is_instance_valid(camera):
		return
	camera = Camera3D.new()
	camera.name = "RaceCamera"
	camera.current = true
	camera.near = 0.18
	camera.far = 2400.0
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	add_child(camera)


func _desired_pose() -> Dictionary:
	var vehicle_forward := (_target_transform.basis * Vector3.RIGHT).normalized()
	if vehicle_forward.length_squared() < 0.5:
		vehicle_forward = Vector3.RIGHT
	var origin := _target_transform.origin
	if camera_mode == CAMERA_COCKPIT:
		var forward := vehicle_forward
		var cockpit_anchor := _cockpit_socket_transform \
				if _has_cockpit_socket else _target_transform
		# Gear changes animate the drivetrain and chassis, not the driver's eye
		# point. A vertical camera settle made each upshift look like the camera was
		# sinking as speed increased, so the authored mount is now authoritative.
		var cockpit_position := cockpit_anchor.origin
		if _has_cockpit_socket:
			# The authored halo ring sits above the helmet/eye plane. Keep this offset
			# low enough to retain the yoke and hands while clearing the raised rails.
			cockpit_position += forward * 0.12 + Vector3.UP * 0.14
		else:
			cockpit_position += forward * 0.18 + Vector3.UP * 0.88
		var cockpit_look := cockpit_position \
				+ forward * COCKPIT_LOOK_DISTANCE \
				- Vector3.UP * COCKPIT_LOOK_DISTANCE * COCKPIT_LOOK_DOWN_SLOPE
		return {"position": cockpit_position, "look_at": cockpit_look}
	var forward := _smoothed_chase_forward()
	var chase_position := origin - forward * 7.5 + Vector3.UP * 2.85
	if _has_chase_socket:
		# The vehicle authors an exterior socket that already sits behind and above
		# the rear wing. Treating it as merely another target and subtracting a
		# second full chase distance pushed the car below frame as speed increased.
		# Keep the socket authoritative with one constant mounting offset.
		# Recover the authored offset in car-local coordinates, then apply it in
		# the eased grade frame. Yaw and car-origin translation remain immediate.
		var socket_local := _target_transform.affine_inverse() \
				* _chase_socket_transform.origin
		chase_position = origin + _chase_basis(forward) * socket_local \
				- forward * 0.10 + Vector3.UP * 0.16
	# A fixed look offset preserves the same composition at every speed.
	var chase_look := origin + forward * 1.65 \
			+ Vector3.UP * 0.58
	return {"position": chase_position, "look_at": chase_look}


func _target_grade_pitch() -> float:
	if not _has_target:
		return 0.0
	var forward := (_target_transform.basis * Vector3.RIGHT).normalized()
	if forward.length_squared() < 0.5:
		return 0.0
	return asin(clampf(forward.y, -0.999, 0.999))


func _advance_chase_grade(delta: float) -> void:
	var target := _target_grade_pitch()
	if not _has_smoothed_chase_pitch:
		_smoothed_chase_pitch = target
		_has_smoothed_chase_pitch = true
		return
	var safe_delta := clampf(delta, 0.0, 0.1)
	var desired_step := angle_difference(_smoothed_chase_pitch, target) \
			* _exponential_weight(CHASE_GRADE_RESPONSE, safe_delta)
	var maximum_step := CHASE_MAX_GRADE_RATE_RADIANS * safe_delta
	_smoothed_chase_pitch += clampf(desired_step, -maximum_step, maximum_step)


func _smoothed_chase_forward() -> Vector3:
	var target_forward := (_target_transform.basis * Vector3.RIGHT).normalized()
	var horizontal := Vector3(target_forward.x, 0.0, target_forward.z)
	if horizontal.length_squared() < 0.0001:
		horizontal = Vector3.RIGHT
	else:
		horizontal = horizontal.normalized()
	var pitch := _smoothed_chase_pitch if _has_smoothed_chase_pitch \
			else _target_grade_pitch()
	return (horizontal * cos(pitch) + Vector3.UP * sin(pitch)).normalized()


static func _chase_basis(forward: Vector3) -> Basis:
	var safe_forward := forward.normalized()
	var lateral := safe_forward.cross(Vector3.UP)
	if lateral.length_squared() < 0.0001:
		lateral = Vector3.BACK
	else:
		lateral = lateral.normalized()
	var local_up := lateral.cross(safe_forward).normalized()
	return Basis(safe_forward, local_up, lateral).orthonormalized()


func _desired_fov() -> float:
	if camera_mode == CAMERA_COCKPIT:
		# Widening a pitched camera's vertical FOV pulls the horizon toward screen
		# centre, which reads as a downward camera tilt during acceleration. Fixed
		# FOV keeps the horizon and cockpit framing invariant at every speed.
		return COCKPIT_BASE_FOV
	return CHASE_BASE_FOV


func _safe_look_at(target: Vector3) -> void:
	if camera.global_position.distance_squared_to(target) <= 0.0001:
		return
	camera.look_at(target, Vector3.UP)


static func _exponential_weight(sharpness: float, delta: float) -> float:
	return 1.0 - exp(-maxf(sharpness, 0.0) * clampf(delta, 0.0, 0.25))
