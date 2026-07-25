class_name WorldCoordinateMapper
extends RefCounted
## Pure, deterministic adapter from the existing two-dimensional race authority
## into the three-dimensional presentation world. Nothing in this class mutates
## authority state or depends on the scene tree.

const WORLD_UNIT_TO_METERS: float = 0.30
const BRIDGE_HEIGHT_UNITS_TO_METERS: float = 0.001
const BRIDGE_HEIGHT_UNITS: int = 6000
const BRIDGE_HEIGHT_METERS: float = float(BRIDGE_HEIGHT_UNITS) \
		* BRIDGE_HEIGHT_UNITS_TO_METERS
const ROAD_SURFACE_Y_METERS: float = 0.04


static func authority_scalar_to_meters(value: float) -> float:
	if not _finite(value):
		return 0.0
	return value * WORLD_UNIT_TO_METERS


static func bridge_height_units_to_meters(value: float) -> float:
	if not _finite(value):
		return 0.0
	return value * BRIDGE_HEIGHT_UNITS_TO_METERS


static func elevation_level_to_meters(elevation_level: float) -> float:
	if not _finite(elevation_level):
		return 0.0
	return clampf(elevation_level, 0.0, 1.0) * BRIDGE_HEIGHT_METERS


static func authority_position_to_world(
		authority_position: Vector2,
		elevation_level: float = 0.0,
		vertical_offset_meters: float = 0.0
	) -> Vector3:
	if not _finite_vector2(authority_position):
		return Vector3.ZERO
	var safe_vertical_offset := vertical_offset_meters \
			if _finite(vertical_offset_meters) else 0.0
	return Vector3(
		authority_position.x * WORLD_UNIT_TO_METERS,
		elevation_level_to_meters(elevation_level) + safe_vertical_offset,
		authority_position.y * WORLD_UNIT_TO_METERS
	)


static func authority_direction_to_world(authority_direction: Vector2) -> Vector3:
	if not _finite_vector2(authority_direction) \
			or authority_direction.length_squared() <= 0.0000000001:
		return Vector3.RIGHT
	var direction := authority_direction.normalized()
	return Vector3(direction.x, 0.0, direction.y)


static func authority_heading_to_world_yaw(authority_heading: float) -> float:
	if not _finite(authority_heading):
		return 0.0
	# Presentation roots use local +X as their forward contract. Godot's
	# positive Y rotation turns +X toward -Z, while authority-positive heading
	# turns +X toward +Y (mapped to world +Z), hence the sign inversion.
	return -wrapf(authority_heading, -PI, PI)


static func authority_transform(
		authority_position: Vector2,
		authority_heading: float,
		elevation_level: float = 0.0,
		vertical_offset_meters: float = 0.0
	) -> Transform3D:
	var basis := Basis(Vector3.UP, authority_heading_to_world_yaw(authority_heading))
	return Transform3D(
		basis,
		authority_position_to_world(
			authority_position, elevation_level, vertical_offset_meters
		)
	)


static func static_root_transforms() -> Dictionary:
	# The generated track and scenery are fixed in world space. Cars and cameras
	# move through them; neither root is scrolled relative to the player.
	return {
		"track_root": Transform3D.IDENTITY,
		"scenery_root": Transform3D.IDENTITY,
	}


static func _finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


static func _finite_vector2(value: Vector2) -> bool:
	return _finite(value.x) and _finite(value.y)
