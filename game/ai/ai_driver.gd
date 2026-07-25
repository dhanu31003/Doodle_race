class_name AiDriver
extends RefCounted
## Centerline/radius/section-aware deterministic racing controller.

const RaceInputType := preload("res://game/race/race_input.gd")
const AiPersonalityType := preload("res://game/ai/ai_personality.gd")
const VehicleConfigType := preload("res://game/race/vehicle_config.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")

var driver_id: StringName = &""
var personality: AiPersonality
var maximum_speed: float = 310.0
var _vehicle_config: VehicleConfig = VehicleConfigType.new().sanitized()

var _cached_command: RaceInput = null
var _next_decision_tick: int = 0

const CORNER_PROFILE_SAMPLES: int = 10


func _init(
		id: StringName = &"ai",
		race_seed: int = 1,
		difficulty: float = 0.75,
		vehicle_maximum_speed: float = 310.0
	) -> void:
	driver_id = id
	personality = AiPersonalityType.generate(race_seed, driver_id, difficulty)
	maximum_speed = clampf(vehicle_maximum_speed, 20.0, 1000.0)


func configure_vehicle_dynamics(source_config: VehicleConfig) -> void:
	_vehicle_config = (
		source_config if source_config != null else VehicleConfigType.new()
	).sanitized()
	maximum_speed = minf(maximum_speed, _vehicle_config.maximum_forward_speed)


func target_speed_for_radius(
		minimum_radius: float,
		in_corner: bool = false,
		offtrack: bool = false,
		surface_lateral_multiplier: float = 1.0,
		surface_speed_factor: float = 1.0
	) -> float:
	var safe_lateral_multiplier := clampf(surface_lateral_multiplier, 0.1, 1.0)
	var safe_speed_factor := clampf(surface_speed_factor, 0.1, 1.0)
	var target_speed := maximum_speed * personality.top_speed_factor * safe_speed_factor
	if not is_inf(minimum_radius):
		var tyre_safety := lerpf(0.94, 0.995, personality.risk)
		# Tight corners need additional line-tracking margin because a finite-width
		# lane and a rate-limited rack cannot follow the mathematical centerline at
		# the absolute tyre-circle solution. Wide sweepers retain near-peak usage.
		var tight_corner_amount := clampf((220.0 - minimum_radius) / 80.0, 0.0, 1.0)
		tyre_safety = maxf(0.74, tyre_safety - tight_corner_amount * 0.16)
		target_speed = minf(
			target_speed,
			_vehicle_config.corner_speed_limit_for_radius(minimum_radius, tyre_safety) \
					* sqrt(safe_lateral_multiplier)
		)
	if in_corner:
		target_speed *= lerpf(0.95, 1.0, personality.skill)
	if offtrack:
		target_speed = minf(target_speed, 105.0)
	return clampf(target_speed, 0.0, maximum_speed)


func approach_speed_for_corner(
		minimum_radius: float,
		distance_to_corner: float,
		in_corner: bool = true,
		surface_lateral_multiplier: float = 1.0,
		surface_braking_multiplier: float = 1.0,
		surface_speed_factor: float = 1.0
	) -> float:
	var corner_target := target_speed_for_radius(
		minimum_radius,
		in_corner,
		false,
		surface_lateral_multiplier,
		surface_speed_factor
	)
	var precision_amount := clampf(
		(personality.braking_precision - 0.76) / (1.10 - 0.76), 0.0, 1.0
	)
	var braking_safety := lerpf(0.72, 0.90, precision_amount) \
			* clampf(surface_braking_multiplier, 0.1, 1.0)
	return minf(
		maximum_speed * personality.top_speed_factor \
				* clampf(surface_speed_factor, 0.1, 1.0),
		_vehicle_config.braking_approach_speed_limit(
			corner_target, distance_to_corner, braking_safety
		)
	)


func target_speed_for_horizon(
		track: RaceTrackQuery,
		start_distance: float,
		horizon: float,
		offtrack: bool = false
	) -> float:
	if track == null or not track.is_valid():
		return 0.0
	var surface := RoadSurfaceCatalogType.profile(track.road_surface)
	var surface_lateral := float(surface["lateral_capacity_multiplier"])
	var surface_braking := float(surface["braking_multiplier"])
	var surface_speed := float(surface["ai_speed_factor"])
	var safe_horizon := clampf(horizon, 0.0, track.total_length * 0.5)
	var target_speed := target_speed_for_radius(
		INF, false, offtrack, surface_lateral, surface_speed
	)
	for sample_index in range(CORNER_PROFILE_SAMPLES + 1):
		var amount := float(sample_index) / float(CORNER_PROFILE_SAMPLES)
		var distance_ahead := safe_horizon * amount
		var sample_distance := start_distance + distance_ahead
		var radius := track.radius_at_distance(sample_distance)
		if is_inf(radius):
			continue
		var allowed_now := approach_speed_for_corner(
			radius,
			distance_ahead,
			track.is_corner_at_distance(sample_distance),
			surface_lateral,
			surface_braking,
			surface_speed
		)
		target_speed = minf(target_speed, allowed_now)
	if offtrack:
		target_speed = minf(target_speed, 105.0)
	return clampf(target_speed, 0.0, maximum_speed)


func command(
		state: VehicleState,
		track: RaceTrackQuery,
		nearby_states: Array,
		simulation_tick: int
	) -> RaceInput:
	if state == null or track == null or not track.is_valid() or not state.is_finite():
		return RaceInputType.new()
	if _cached_command != null and simulation_tick < _next_decision_tick:
		return _cached_command.duplicate_input()
	var projection := _authority_projection(state, track)
	if projection.is_empty():
		return RaceInputType.new()
	var speed := state.speed()
	var lookahead := clampf(26.0 + speed * lerpf(0.22, 0.42, personality.skill), 28.0, 145.0)
	var target_distance := float(projection["distance_along"]) + lookahead
	var target_sample := track.sample_at_distance(target_distance)
	var lane_limit := maxf(0.0, track.track_width * 0.5 - 7.0)
	var traffic_plan := _traffic_plan(
		state, track, projection, nearby_states, lane_limit
	)
	var target_in_corner := bool(target_sample.get("in_corner", false))
	var line_bias_scale := 0.08 if target_in_corner else 0.34
	var desired_lane := personality.line_bias * lane_limit * line_bias_scale
	var avoidance_lane := traffic_plan.x
	if not is_inf(avoidance_lane):
		desired_lane = lerpf(
			desired_lane, avoidance_lane, 0.65 if target_in_corner else 0.82
		)
	# Do not snap a physical rack across the road when traffic state changes.
	# Receding-horizon lane targets make each decision a bounded continuation of
	# the car's current line while still converging to the authored preference.
	desired_lane = lerpf(float(projection["signed_lateral"]), desired_lane, 0.44)
	desired_lane = clampf(desired_lane, -lane_limit, lane_limit)
	var target_position: Vector2 = target_sample["position"] + target_sample["normal"] * desired_lane
	var target_vector := target_position - state.position
	var target_chord := target_vector.length()
	var desired_direction := target_vector.normalized()
	if desired_direction.length_squared() <= 0.000001:
		desired_direction = target_sample["tangent"]
	var heading_error := wrapf(state.forward().angle_to(desired_direction), -PI, PI)
	# Pure pursuit requests an actual bicycle front-wheel angle. Normalizing that
	# angle by the shared speed-sensitive rack limit keeps AI and player steering
	# on the same authority curve instead of saturating an unrelated heading gain.
	var requested_wheel_angle := atan2(
		2.0 * _vehicle_config.wheelbase * sin(heading_error),
		maxf(target_chord, _vehicle_config.wheelbase)
	)
	requested_wheel_angle += heading_error * lerpf(0.025, 0.05, personality.skill)
	var lane_error := float(projection["signed_lateral"]) - desired_lane
	requested_wheel_angle += atan2(
		-lane_error * lerpf(1.6, 2.4, personality.skill),
		maxf(speed, 35.0)
	)
	var maximum_wheel_angle := _vehicle_config.maximum_steering_angle_for_speed(speed)
	var steer := clampf(
		requested_wheel_angle / maxf(maximum_wheel_angle, 0.001), -1.0, 1.0
	)

	var braking_horizon := maxf(lookahead * 2.20, speed * 1.25)
	var target_speed := target_speed_for_horizon(
		track,
		float(projection["distance_along"]),
		braking_horizon,
		state.is_offtrack
	)
	var traffic_speed_limit := traffic_plan.y
	if not is_inf(traffic_speed_limit):
		target_speed = minf(target_speed, traffic_speed_limit)
	var braking_margin := lerpf(4.0, 15.0, 1.0 - personality.braking_precision)
	var brake := clampf((speed - target_speed + braking_margin) / 55.0, 0.0, 1.0)
	var throttle := clampf((target_speed - speed + 35.0) / 65.0, 0.0, 1.0)
	if brake > 0.05:
		throttle *= maxf(0.0, 1.0 - brake * 1.25)
	# The race control contract is intentionally conventional: steer, throttle,
	# and brake/reverse only. RaceInput retains its legacy nitro bit solely for
	# deterministic replay compatibility, but default drivers never request it.
	_cached_command = RaceInputType.new(steer, throttle, brake)
	_next_decision_tick = simulation_tick + personality.reaction_ticks
	return _cached_command.duplicate_input()


func reset() -> void:
	_cached_command = null
	_next_decision_tick = 0


func _authority_projection(state: VehicleState, track: RaceTrackQuery) -> Dictionary:
	# VehicleModel refreshes these values from the route projection every fixed
	# tick. Consuming that authority avoids projecting the same car again at each
	# AI decision while keeping a bounded fallback for malformed/external state.
	var distance_valid := not is_nan(state.track_distance) and not is_inf(state.track_distance) \
		and state.track_distance >= -0.001 \
		and state.track_distance < track.total_length + 0.001
	var lateral_limit := maxf(track.track_width * 2.0, 64.0)
	var lateral_valid := not is_nan(state.lateral_offset) and not is_inf(state.lateral_offset) \
		and absf(state.lateral_offset) <= lateral_limit
	if distance_valid and lateral_valid:
		return {
			"distance_along": track.wrap_distance(state.track_distance),
			"signed_lateral": state.lateral_offset,
		}
	if distance_valid:
		return track.nearest_continuous(
			state.position,
			state.track_distance,
			state.track_collision_layer,
			maxf(track.track_width * 2.5, state.speed() * 0.5 + 24.0)
		)
	return track.nearest(state.position)


func _traffic_plan(
		state: VehicleState,
		track: RaceTrackQuery,
		projection: Dictionary,
		nearby_states: Array,
		lane_limit: float
	) -> Vector2:
	var strongest_offset := INF
	var speed_limit := INF
	var closest_ahead := INF
	for other_variant in nearby_states:
		if not other_variant is VehicleState:
			continue
		var other: VehicleState = other_variant
		if other == state or not other.is_finite():
			continue
		# Route distance cannot be shorter than the straight-line chord. Rejecting
		# distant cars here avoids an expensive full-track projection for opponents
		# that cannot enter the 58-unit avoidance window.
		if state.position.distance_squared_to(other.position) > 72.0 * 72.0:
			continue
		if not track.collision_layers_compatible(
			state.track_collision_layer,
			state.track_collision_mask,
			other.track_collision_layer,
			other.track_collision_mask
		):
			continue
		var ahead := track.forward_delta(
			float(projection["distance_along"]), other.track_distance
		)
		if ahead <= 0.0 or ahead > 72.0:
			continue
		var lateral_gap := other.lateral_offset - float(projection["signed_lateral"])
		if absf(lateral_gap) <= 12.0 and ahead < closest_ahead:
			closest_ahead = ahead
			var pass_side := personality.preferred_pass_side
			if absf(other.lateral_offset) > lane_limit * 0.72:
				pass_side = -1 if other.lateral_offset > 0.0 else 1
			strongest_offset = float(pass_side) * lane_limit * lerpf(
				0.40, 0.70, personality.overtake_commitment
			)
		if absf(lateral_gap) > _vehicle_config.vehicle_radius * 2.35:
			continue
		var hard_gap := _vehicle_config.vehicle_radius * 2.15
		var desired_headway := hard_gap + state.speed() * 0.035
		var available_gap := maxf(0.0, ahead - hard_gap)
		var other_speed := maxf(0.0, other.forward_speed())
		var allowed_speed := other_speed + available_gap * 1.80
		if ahead < hard_gap:
			allowed_speed = minf(
				allowed_speed,
				other_speed * clampf(ahead / maxf(hard_gap, 0.001), 0.65, 1.0)
			)
		elif ahead > desired_headway:
			allowed_speed += (ahead - desired_headway) * 0.65
		speed_limit = minf(speed_limit, allowed_speed)
	return Vector2(strongest_offset, speed_limit)
