class_name RacePerspectiveView
extends Control
## Pseudo-3D race presentation projected from deterministic 2D track authority.
## Top-down geometry is never shown here; only the separate minimap uses it.

const CAMERA_COCKPIT: StringName = &"cockpit"
const CAMERA_CHASE: StringName = &"chase"

const AI_COLORS := [
	Color("ff6b72"), Color("51c8ff"), Color("ffc857"), Color("b99cff"),
	Color("4ee58b"), Color("43e6ea"), Color("ff91bb"), Color("ff9d4d"),
	Color("c5e35a"), Color("4e86ff"), Color("e8e8f2"),
]
const MAX_SKID_MARKS := 72
const SKID_MARK_LIFETIME_MS := 6500
const MIN_SKID_MARK_SPACING := 2.4

# The active race intentionally uses one bright, sunlit forest world in both
# cameras. Keeping these colors local to the race renderer prevents the darker
# navigation chrome from tinting the track presentation back toward night.
const DAY_SKY_TOP := Color("4b98d1")
const DAY_SKY_HORIZON := Color("d9eff5")
const DAY_GRASS_FAR := Color("6ba05d")
const DAY_GRASS_NEAR := Color("3f784a")
const DAY_FOLIAGE_FAR := Color("477d4c")
const DAY_FOLIAGE_DEEP := Color("1e5038")
const DAY_ASPHALT := Color("2b3540")
const DAY_GRAVEL := Color("a59b78")
const ROAD_CUT_FACTOR := 1.36
const ROAD_FOUNDATION_FACTOR := 1.31
const ROAD_GRAVEL_FACTOR := 1.22
const ROAD_CURB_FACTOR := 1.12

var camera_mode: StringName = CAMERA_CHASE
var _track: RaceTrackQuery
var _player: RaceEntry
var _entries: Array[RaceEntry] = []
var _entry_colors: Dictionary = {}
var _command: RaceInput
var _alpha: float = 1.0
var _player_color: Color = DesignSystem.MINT
var _low_graphics := false
var _reduced_motion := false
var _high_contrast := false
var _screen_shake_strength := 0.35
var _camera_distance: float = 0.0
var _camera_position: Vector2 = Vector2.ZERO
var _camera_forward: Vector2 = Vector2.RIGHT
var _camera_right: Vector2 = Vector2.DOWN
var _horizon_y: float = 0.0
var _road_bottom_y: float = 0.0
var _near_distance: float = 6.0
var _lookahead_distance: float = 480.0
var _focal_length: float = 640.0
var _skid_marks: Array[Dictionary] = []
var _last_skid_route_distance := INF


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func configure(
		track: RaceTrackQuery,
		mode: StringName = CAMERA_CHASE,
		player_color: Color = DesignSystem.MINT
	) -> void:
	_track = track
	_player_color = player_color
	_skid_marks.clear()
	_last_skid_route_distance = INF
	set_camera_mode(mode)
	queue_redraw()


func configure_accessibility(
		low_graphics: bool,
		reduced_motion: bool,
		high_contrast: bool,
		screen_shake_strength: float = 0.35
	) -> void:
	_low_graphics = low_graphics
	_reduced_motion = reduced_motion
	_high_contrast = high_contrast
	_screen_shake_strength = 0.0 if reduced_motion else clampf(screen_shake_strength, 0.0, 1.0)
	if low_graphics or reduced_motion:
		_skid_marks.clear()
		_last_skid_route_distance = INF
	queue_redraw()


func configure_entry_colors(colors_by_participant: Dictionary) -> void:
	_entry_colors = colors_by_participant.duplicate()
	queue_redraw()


static func chase_sway_offset(steering: float, screen_shake_strength: float, reduced_motion: bool) -> float:
	if reduced_motion or screen_shake_strength <= 0.0:
		return 0.0
	var response := minf(20.0, 12.0 * clampf(screen_shake_strength, 0.0, 1.0) / 0.35)
	return clampf(steering, -1.0, 1.0) * response


static func shift_settle_offset(shift_ticks_remaining: int, reduced_motion: bool) -> float:
	if reduced_motion or shift_ticks_remaining <= 0:
		return 0.0
	return minf(3.0, float(shift_ticks_remaining) * 0.6)


static func dashboard_rpm_ratio(engine_rpm: float, idle_rpm: float, redline_rpm: float) -> float:
	if is_nan(engine_rpm) or is_inf(engine_rpm) or redline_rpm <= idle_rpm:
		return 0.0
	return clampf((engine_rpm - idle_rpm) / (redline_rpm - idle_rpm), 0.0, 1.0)


static func dashboard_gear_segment_mask(gear: int) -> int:
	# Seven-segment bit order: top, upper-right, lower-right, bottom,
	# lower-left, upper-left, middle. Reverse is a restrained lower-case r.
	match clampi(gear, -1, 8):
		-1: return 80
		0: return 64
		1: return 6
		2: return 91
		3: return 79
		4: return 102
		5: return 109
		6: return 125
		7: return 7
		_: return 127


static func cosmetic_cue_state(
		state: VehicleState,
		previous_state: VehicleState,
		command: RaceInput,
		low_graphics: bool,
		reduced_motion: bool
	) -> Dictionary:
	if state == null:
		return {"brake_lights": false, "dust": false, "slip_smoke": false, "sparks": false, "debris": false, "skid_marks": false}
	var particles_allowed := not low_graphics and not reduced_motion
	var lateral_speed := absf(state.velocity.dot(Vector2(-sin(state.heading), cos(state.heading))))
	var fresh_contact := particles_allowed and previous_state != null and state.wall_contacts > previous_state.wall_contacts
	var sliding := particles_allowed and lateral_speed > 5.5 and state.speed() > 14.0
	return {
		"brake_lights": command != null and command.brake > 0.12,
		"dust": particles_allowed and state.is_offtrack and state.speed() > 3.0,
		"slip_smoke": sliding,
		"skid_marks": sliding and not state.is_offtrack,
		"sparks": fresh_contact,
		"debris": fresh_contact,
	}


func set_camera_mode(mode: StringName) -> void:
	camera_mode = CAMERA_COCKPIT if mode == CAMERA_COCKPIT else CAMERA_CHASE
	queue_redraw()


func update_race(
		player: RaceEntry,
		entries: Array[RaceEntry],
		command: RaceInput,
		interpolation_alpha: float
	) -> void:
	_player = player
	_entries = entries.duplicate()
	_command = command
	_alpha = clampf(interpolation_alpha, 0.0, 1.0)
	_update_surface_history()
	queue_redraw()


func has_race_authority() -> bool:
	return _track != null and _track.is_valid() and _player != null and _player.state != null


func clear_race_authority() -> void:
	_track = null
	_player = null
	_entries.clear()
	_skid_marks.clear()
	_last_skid_route_distance = INF
	_command = null
	queue_redraw()


func _draw() -> void:
	# The terrain and the road must share the exact same horizon. Preparing the
	# camera first is what makes the circuit read as embedded in the landscape
	# instead of a ribbon suspended in front of a separate background.
	if has_race_authority():
		_prepare_camera()
	_draw_environment()
	if not has_race_authority():
		_draw_empty_road()
		return
	var road := _build_projected_road()
	_draw_road(road)
	_draw_skid_marks()
	_draw_scenery(road)
	_draw_start_finish()
	_draw_rivals()
	if camera_mode == CAMERA_COCKPIT:
		_draw_cockpit()
	else:
		_draw_chase_car()


func _draw_environment() -> void:
	var terrain_horizon := _horizon_y if _horizon_y > 0.0 \
		else size.y * environment_horizon_ratio(camera_mode)
	var sky_top := DAY_SKY_TOP.darkened(0.10) if _high_contrast else DAY_SKY_TOP
	var sky_bottom := DAY_SKY_HORIZON.lightened(0.05) if _high_contrast else DAY_SKY_HORIZON
	var band_count := 18 if _low_graphics else 64
	for band in band_count:
		var amount := float(band) / float(maxi(band_count - 1, 1))
		var band_y := (terrain_horizon + 2.0) * amount
		draw_rect(
			Rect2(0.0, band_y, size.x, (terrain_horizon + 2.0) / float(band_count) + 1.0),
			sky_top.lerp(sky_bottom, amount), true
		)

	# Mid-morning sun and restrained atmospheric shapes establish daylight even
	# when the upper sky is partly occupied by the race HUD.
	var sun_center := Vector2(size.x * 0.61, terrain_horizon * 0.57)
	if not _low_graphics:
		draw_circle(sun_center, 46.0, Color(1.0, 0.86, 0.48, 0.10))
		draw_circle(sun_center, 32.0, Color(1.0, 0.90, 0.58, 0.16))
	draw_circle(sun_center, 19.0, Color("ffe7a0"))
	_draw_cloud(Vector2(size.x * 0.16, terrain_horizon * 0.48), 0.92)
	if not _low_graphics:
		_draw_cloud(Vector2(size.x * 0.49, terrain_horizon * 0.28), 0.62)

	# Hazed hill layers lead directly into the ground plane. Their bases sit
	# below the shared horizon so no sky-colored seam can appear under the road.
	_draw_hill_layer(terrain_horizon + 1.0, 50.0, 91.0, Color("9bbc87"), 0.005)
	_draw_hill_layer(terrain_horizon + 7.0, 40.0, 79.0, Color("75a875"), 0.015)
	_draw_hill_layer(terrain_horizon + 13.0, 27.0, 56.0, DAY_FOLIAGE_FAR, 0.031)

	# Projected grass bands and radial mowing lanes make the ground read as a
	# continuous plane receding toward the road's vanishing point.
	draw_rect(
		Rect2(0.0, terrain_horizon, size.x, size.y - terrain_horizon),
		DAY_GRASS_NEAR, true
	)
	var ground_bands := 8 if _low_graphics else 14
	for band in ground_bands:
		var amount := float(band) / float(ground_bands)
		var next_amount := float(band + 1) / float(ground_bands)
		var top := terrain_horizon + pow(amount, 1.55) * (size.y - terrain_horizon)
		var bottom := terrain_horizon + pow(next_amount, 1.55) * (size.y - terrain_horizon)
		var shade := DAY_GRASS_FAR.lerp(DAY_GRASS_NEAR, pow(amount, 0.72))
		if band % 2 == 1:
			shade = shade.lightened(0.025)
		draw_rect(Rect2(0.0, top, size.x, bottom - top + 1.0), shade, true)
	_draw_mown_grass_lanes(terrain_horizon)
	_draw_grass_detail(terrain_horizon)

	# A continuous forest edge hides the mathematical horizon while maintaining
	# generous sight lines. All trunks terminate on the grass plane.
	for index in range(-20, int(size.x) + 42, 34):
		var x := float(index)
		var canopy_y := terrain_horizon - 4.0 - float((index * 13) % 11)
		var radius := 9.0 + float((index * 7) % 8)
		draw_rect(Rect2(x - 1.7, canopy_y, 3.4, terrain_horizon - canopy_y + 5.0), Color("6b4f32"), true)
		draw_circle(Vector2(x, canopy_y), radius, DAY_FOLIAGE_DEEP)
		draw_circle(Vector2(x - radius * 0.28, canopy_y - radius * 0.28), radius * 0.62, Color("4f8551"))

	# Thin horizon haze integrates distant scenery with the lit sky.
	draw_rect(Rect2(0.0, terrain_horizon - 2.0, size.x, 4.0), Color(0.84, 0.94, 0.88, 0.22), true)


static func environment_horizon_ratio(mode: StringName) -> float:
	return 0.305 if mode == CAMERA_COCKPIT else 0.33


static func daylight_palette() -> Dictionary:
	return {
		"sky_top": DAY_SKY_TOP,
		"sky_horizon": DAY_SKY_HORIZON,
		"grass_far": DAY_GRASS_FAR,
		"grass_near": DAY_GRASS_NEAR,
		"asphalt": DAY_ASPHALT,
		"gravel": DAY_GRAVEL,
	}


static func grounded_road_layer_factors() -> PackedFloat32Array:
	return PackedFloat32Array([
		ROAD_CUT_FACTOR,
		ROAD_FOUNDATION_FACTOR,
		ROAD_GRAVEL_FACTOR,
		ROAD_CURB_FACTOR,
		1.0,
	])


func _draw_cloud(center: Vector2, scale_factor: float) -> void:
	var shadow := Color(0.48, 0.67, 0.75, 0.18)
	var white := Color(0.98, 1.0, 1.0, 0.74)
	_draw_filled_ellipse(center + Vector2(4.0, 5.0) * scale_factor, Vector2(42.0, 9.0) * scale_factor, shadow)
	_draw_filled_ellipse(center, Vector2(45.0, 10.0) * scale_factor, white)
	draw_circle(center + Vector2(-18.0, -6.0) * scale_factor, 13.0 * scale_factor, white)
	draw_circle(center + Vector2(3.0, -10.0) * scale_factor, 17.0 * scale_factor, white)
	draw_circle(center + Vector2(23.0, -5.0) * scale_factor, 11.0 * scale_factor, white)


func _draw_hill_layer(
		base_y: float,
		minimum_height: float,
		maximum_height: float,
		color: Color,
		phase: float
	) -> void:
	var points := PackedVector2Array([Vector2(0.0, base_y + maximum_height)])
	var ridge := PackedVector2Array()
	var step := 52.0
	var sample_count := ceili(size.x / step) + 1
	for index in sample_count + 1:
		var x := minf(float(index) * step, size.x)
		var wave := (sin(float(index) * 1.73 + phase * size.x) + 1.0) * 0.5
		var height := lerpf(minimum_height, maximum_height, wave)
		var ridge_point := Vector2(x, base_y - height)
		points.append(ridge_point)
		ridge.append(ridge_point)
	points.append(Vector2(size.x, base_y + maximum_height))
	draw_colored_polygon(points, color)
	if ridge.size() >= 2:
		draw_polyline(ridge, Color(color.lightened(0.16), 0.54), 2.0, true)


func _draw_mown_grass_lanes(horizon: float) -> void:
	var vanishing_x := size.x * 0.5
	var bottom := size.y
	var lane_count := 12 if _low_graphics else 20
	var bottom_lane_width := size.x / float(lane_count)
	for index in lane_count:
		if index % 2 == 0:
			continue
		var left := float(index) * bottom_lane_width
		var right := left + bottom_lane_width
		var far_left := vanishing_x + (left - vanishing_x) * 0.025
		var far_right := vanishing_x + (right - vanishing_x) * 0.025
		draw_colored_polygon(PackedVector2Array([
			Vector2(far_left, horizon), Vector2(far_right, horizon),
			Vector2(right, bottom), Vector2(left, bottom),
		]), Color(0.72, 0.86, 0.55, 0.055 if not _high_contrast else 0.085))


func _draw_grass_detail(horizon: float) -> void:
	if _low_graphics:
		return
	var ground_height := maxf(size.y - horizon, 1.0)
	for index in 58:
		var x := fposmod(float(index * 197 + 71), maxf(size.x, 1.0))
		var depth := fposmod(float(index * 83 + 19), 100.0) / 100.0
		var y := horizon + (0.18 + pow(depth, 1.34) * 0.82) * ground_height
		var blade_height := 1.0 + depth * 4.5
		var blade_color := Color("d4dc83") if index % 3 == 0 else Color("235e3b")
		blade_color.a = 0.16 + depth * 0.14
		draw_line(
			Vector2(x, y), Vector2(x + 1.2 + depth * 1.8, y - blade_height),
			blade_color, 1.0, true
		)


func _draw_empty_road() -> void:
	var horizon := size.y * environment_horizon_ratio(camera_mode)
	var half_width_far := size.x * 0.03
	var half_width_near := size.x * 0.40
	# Even the loading/blocked state keeps the road bed visibly attached to the
	# same daylight ground plane.
	draw_colored_polygon(PackedVector2Array([
		Vector2(size.x * 0.5 - half_width_far * 1.22, horizon),
		Vector2(size.x * 0.5 + half_width_far * 1.22, horizon),
		Vector2(size.x * 0.5 + half_width_near * 1.22, size.y),
		Vector2(size.x * 0.5 - half_width_near * 1.22, size.y),
	]), DAY_GRAVEL)
	draw_colored_polygon(PackedVector2Array([
		Vector2(size.x * 0.5 - half_width_far, horizon),
		Vector2(size.x * 0.5 + half_width_far, horizon),
		Vector2(size.x * 0.5 + half_width_near, size.y),
		Vector2(size.x * 0.5 - half_width_near, size.y),
	]), DAY_ASPHALT)


func _prepare_camera() -> void:
	var current := _player.state
	var previous := _player.previous_state if _player.previous_state != null else current
	var distance_delta := _track.forward_delta(previous.track_distance, current.track_distance)
	_camera_distance = _track.wrap_distance(previous.track_distance + distance_delta * _alpha)
	var lateral := lerpf(previous.lateral_offset, current.lateral_offset, _alpha)
	var center_sample := _track.sample_at_distance(_camera_distance)
	_camera_position = center_sample["position"] + center_sample["normal"] * lateral
	var heading := lerp_angle(previous.heading, current.heading, _alpha)
	_camera_forward = Vector2(cos(heading), sin(heading))
	_camera_right = Vector2(-_camera_forward.y, _camera_forward.x)
	if camera_mode == CAMERA_COCKPIT:
		_horizon_y = size.y * environment_horizon_ratio(CAMERA_COCKPIT)
		_road_bottom_y = size.y * 0.84
		_near_distance = 5.0
		_focal_length = size.x * 0.58
	else:
		_horizon_y = size.y * environment_horizon_ratio(CAMERA_CHASE)
		_road_bottom_y = size.y * 0.98
		_near_distance = 10.0
		_focal_length = size.x * 0.54
	_lookahead_distance = minf(520.0, _track.total_length * 0.42)


func _build_projected_road() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var sample_count := 34 if _low_graphics else 52
	for index in sample_count:
		var amount := float(index) / float(sample_count - 1)
		var distance_ahead := _near_distance + pow(amount, 1.68) * (_lookahead_distance - _near_distance)
		output.append(_project(distance_ahead, 0.0))
	return output


func _project(distance_ahead: float, lateral_offset: float) -> Dictionary:
	var sample := _track.sample_at_distance(_camera_distance + distance_ahead)
	var world_position: Vector2 = sample["position"] + sample["normal"] * lateral_offset
	var relative := world_position - _camera_position
	var lateral_world := relative.dot(_camera_right)
	var scale_factor := _focal_length / maxf(distance_ahead + 18.0, 1.0)
	var depth_ratio := _near_distance / maxf(distance_ahead, _near_distance)
	var screen_y := _horizon_y + (_road_bottom_y - _horizon_y) * pow(depth_ratio, 0.58)
	var center_x := size.x * 0.5 + lateral_world * scale_factor
	center_x = clampf(center_x, -size.x * 0.8, size.x * 1.8)
	return {
		"distance": distance_ahead,
		"center": Vector2(center_x, screen_y),
		"half_width": _track.track_width * 0.5 * scale_factor,
		"scale": scale_factor,
		"sample": sample,
	}


func _draw_road(road: Array[Dictionary]) -> void:
	for index in range(road.size() - 2, -1, -1):
		var near: Dictionary = road[index]
		var far: Dictionary = road[index + 1]
		var near_center: Vector2 = near["center"]
		var far_center: Vector2 = far["center"]
		var near_half := float(near["half_width"])
		var far_half := float(far["half_width"])

		# A compacted gravel roadbed extends beyond the kerbs and is followed by a
		# tight soil/contact seam. Unlike a drop shadow, both bands share every
		# projected road sample, so the asphalt reads as cut into the terrain.
		var cut_factor := ROAD_CUT_FACTOR
		draw_colored_polygon(PackedVector2Array([
			near_center + Vector2(-near_half * cut_factor, 0.0),
			near_center + Vector2(near_half * cut_factor, 0.0),
			far_center + Vector2(far_half * cut_factor, 0.0),
			far_center + Vector2(-far_half * cut_factor, 0.0),
		]), Color(0.055, 0.16, 0.09, 0.58))
		var foundation_factor := ROAD_FOUNDATION_FACTOR
		draw_colored_polygon(PackedVector2Array([
			near_center + Vector2(-near_half * foundation_factor, 0.0),
			near_center + Vector2(near_half * foundation_factor, 0.0),
			far_center + Vector2(far_half * foundation_factor, 0.0),
			far_center + Vector2(-far_half * foundation_factor, 0.0),
		]), Color("315b3b"))
		var gravel_factor := ROAD_GRAVEL_FACTOR
		var gravel := DAY_GRAVEL.lerp(Color("c0b68f"), float(index % 3) * 0.025)
		draw_colored_polygon(PackedVector2Array([
			near_center + Vector2(-near_half * gravel_factor, 0.0),
			near_center + Vector2(near_half * gravel_factor, 0.0),
			far_center + Vector2(far_half * gravel_factor, 0.0),
			far_center + Vector2(-far_half * gravel_factor, 0.0),
		]), gravel)

		var curb_factor := ROAD_CURB_FACTOR
		var curb_color := DesignSystem.CORAL if (index / 2) % 2 == 0 else DesignSystem.WHITE
		draw_colored_polygon(PackedVector2Array([
			near_center + Vector2(-near_half * curb_factor, 0.0),
			near_center + Vector2(near_half * curb_factor, 0.0),
			far_center + Vector2(far_half * curb_factor, 0.0),
			far_center + Vector2(-far_half * curb_factor, 0.0),
		]), curb_color)
		var asphalt := DAY_ASPHALT.lerp(Color("35414c"), float(index % 2) * 0.06)
		draw_colored_polygon(PackedVector2Array([
			near_center + Vector2(-near_half, 0.0),
			near_center + Vector2(near_half, 0.0),
			far_center + Vector2(far_half, 0.0),
			far_center + Vector2(-far_half, 0.0),
		]), asphalt)
		# A faint sunward tone and occasional sealed joints prevent the wide
		# asphalt plane from reading as a single flat vector fill.
		draw_colored_polygon(PackedVector2Array([
			near_center + Vector2(-near_half * 0.88, 0.0),
			near_center + Vector2(-near_half * 0.08, 0.0),
			far_center + Vector2(-far_half * 0.08, 0.0),
			far_center + Vector2(-far_half * 0.88, 0.0),
		]), Color(0.86, 0.91, 0.91, 0.020))
		if not _low_graphics and index % 9 == 4:
			draw_line(
				near_center + Vector2(-near_half * 0.93, 0.0),
				near_center + Vector2(near_half * 0.93, 0.0),
				Color(0.04, 0.055, 0.07, 0.14),
				maxf(1.0, float(near["scale"]) * 0.06), true
			)
		if not _low_graphics and index % 3 == 1:
			var wear_center := near_center.lerp(far_center, 0.46)
			var wear_half := lerpf(near_half, far_half, 0.46)
			for speck in 2:
				var signed_noise := fposmod(float(index * 31 + speck * 47), 101.0) / 100.0 - 0.5
				var speck_color := Color(0.82, 0.86, 0.86, 0.075) if speck == 0 \
					else Color(0.02, 0.03, 0.04, 0.075)
				draw_circle(
					wear_center + Vector2(signed_noise * wear_half * 1.55, float(speck) * 1.5),
					clampf(float(near["scale"]) * (0.055 + float(speck) * 0.018), 0.45, 2.2),
					speck_color
				)
		var edge_color := Color(0.97, 0.98, 0.96, 0.88)
		draw_line(near_center + Vector2(-near_half, 0.0), far_center + Vector2(-far_half, 0.0), edge_color, maxf(1.0, near["scale"] * 0.12), true)
		draw_line(near_center + Vector2(near_half, 0.0), far_center + Vector2(far_half, 0.0), edge_color, maxf(1.0, near["scale"] * 0.12), true)
		# Subtle tire-darkened lane bands and a broken center reference add surface
		# scale without competing with the HUD or the racing line.
		var groove_offset := near_half * 0.28
		var far_groove_offset := far_half * 0.28
		var groove_color := Color(0.04, 0.055, 0.07, 0.10)
		draw_line(near_center + Vector2(-groove_offset, 0.0), far_center + Vector2(-far_groove_offset, 0.0), groove_color, maxf(1.0, near["scale"] * 0.11), true)
		draw_line(near_center + Vector2(groove_offset, 0.0), far_center + Vector2(far_groove_offset, 0.0), groove_color, maxf(1.0, near["scale"] * 0.11), true)
		if index % 4 < 2:
			draw_line(near_center, far_center, Color(0.94, 0.97, 0.98, 0.42), maxf(1.0, near["scale"] * 0.08), true)


func _update_surface_history() -> void:
	var now := Time.get_ticks_msec()
	while not _skid_marks.is_empty() and int(_skid_marks[0].get("expires_at", 0)) <= now:
		_skid_marks.pop_front()
	if _player == null or _player.state == null or _low_graphics or _reduced_motion:
		return
	var previous := _player.previous_state if _player.previous_state != null else _player.state
	var cues := cosmetic_cue_state(_player.state, previous, _command, false, false)
	if not bool(cues.get("skid_marks", false)):
		return
	var route_distance := _player.state.track_distance
	if not is_inf(_last_skid_route_distance) and _track != null \
			and _track.circular_distance(route_distance, _last_skid_route_distance) < MIN_SKID_MARK_SPACING:
		return
	_last_skid_route_distance = route_distance
	_skid_marks.append({
		"distance": route_distance,
		"lateral": _player.state.lateral_offset,
		"expires_at": now + SKID_MARK_LIFETIME_MS,
	})
	while _skid_marks.size() > MAX_SKID_MARKS:
		_skid_marks.pop_front()


func _draw_skid_marks() -> void:
	if _track == null or _low_graphics or _reduced_motion:
		return
	var now := Time.get_ticks_msec()
	for mark in _skid_marks:
		var ahead := _track.wrap_distance(float(mark.get("distance", 0.0)) - _camera_distance)
		if ahead <= _near_distance or ahead >= _lookahead_distance - 5.0:
			continue
		var lateral := float(mark.get("lateral", 0.0))
		var near_projection := _project(ahead, lateral)
		var far_projection := _project(ahead + 4.0, lateral)
		var near_center: Vector2 = near_projection["center"]
		var far_center: Vector2 = far_projection["center"]
		var tire_offset := clampf(float(near_projection["scale"]) * 1.35, 1.2, 18.0)
		var life := clampf(float(int(mark.get("expires_at", now)) - now) / float(SKID_MARK_LIFETIME_MS), 0.0, 1.0)
		var color := Color(0.015, 0.022, 0.03, 0.18 + life * 0.34)
		draw_line(near_center + Vector2(-tire_offset, 0.0), far_center + Vector2(-tire_offset * 0.72, 0.0), color, maxf(1.0, tire_offset * 0.23), true)
		draw_line(near_center + Vector2(tire_offset, 0.0), far_center + Vector2(tire_offset * 0.72, 0.0), color, maxf(1.0, tire_offset * 0.23), true)


func skid_mark_count() -> int:
	return _skid_marks.size()


func _draw_scenery(road: Array[Dictionary]) -> void:
	var stride := 8 if _low_graphics else 5
	for index in range(road.size() - 2, 1, -stride):
		var projection: Dictionary = road[index]
		var distance := float(projection["distance"])
		var side := -1.0 if (index / stride) % 2 == 0 else 1.0
		var roadside := _project(distance, side * (_track.track_width * 0.5 + 13.0 + float((index * 7) % 12)))
		var anchor: Vector2 = roadside["center"]
		var scale_factor := clampf(float(roadside["scale"]), 0.35, 11.0)
		var trunk_height := 4.7 * scale_factor
		_draw_filled_ellipse(
			anchor + Vector2(scale_factor * 0.72, scale_factor * 0.20),
			Vector2(scale_factor * 3.25, scale_factor * 0.72),
			Color(0.05, 0.16, 0.09, 0.22)
		)
		draw_rect(Rect2(anchor.x - scale_factor * 0.55, anchor.y - trunk_height, scale_factor * 1.1, trunk_height), Color("5a4027"), true)
		draw_rect(Rect2(anchor.x - scale_factor * 0.38, anchor.y - trunk_height, scale_factor * 0.25, trunk_height), Color(0.79, 0.60, 0.34, 0.34), true)
		var canopy_center := anchor - Vector2(0.0, trunk_height + scale_factor * 1.8)
		draw_circle(canopy_center, scale_factor * 2.75, DAY_FOLIAGE_DEEP)
		draw_circle(canopy_center - Vector2(scale_factor * 0.82, scale_factor * 0.72), scale_factor * 1.64, Color("438354"))
		draw_circle(canopy_center + Vector2(scale_factor * 0.78, scale_factor * 0.18), scale_factor * 1.46, Color("2f6c45"))
		draw_circle(canopy_center - Vector2(scale_factor * 0.58, scale_factor * 1.06), scale_factor * 0.78, Color(0.52, 0.75, 0.38, 0.58))

		# White-and-charcoal distance bollards and a restrained guard rail give
		# drivers repeatable speed/depth cues, particularly through long bends.
		var marker_side := -side
		var marker := _project(distance + 4.0, marker_side * (_track.track_width * 0.5 + 6.5))
		var marker_anchor: Vector2 = marker["center"]
		var marker_scale := clampf(float(marker["scale"]), 0.32, 10.0)
		var marker_height := clampf(marker_scale * 3.6, 2.5, 36.0)
		_draw_filled_ellipse(
			marker_anchor + Vector2(marker_scale * 0.35, 0.5),
			Vector2(maxf(1.5, marker_scale * 0.9), maxf(0.7, marker_scale * 0.24)),
			Color(0.03, 0.09, 0.05, 0.24)
		)
		draw_rect(
			Rect2(marker_anchor.x - marker_scale * 0.34, marker_anchor.y - marker_height, marker_scale * 0.68, marker_height),
			Color("f4f3e8"), true
		)
		draw_rect(
			Rect2(marker_anchor.x - marker_scale * 0.34, marker_anchor.y - marker_height, marker_scale * 0.68, marker_height * 0.30),
			Color("29323a"), true
		)

		if not _low_graphics and index % (stride * 2) == 1:
			var opposite := _project(distance + 8.0, marker_side * (_track.track_width * 0.5 + 9.0))
			var pole: Vector2 = opposite["center"]
			var pole_height := clampf(float(opposite["scale"]) * 9.0, 5.0, 72.0)
			draw_line(pole + Vector2(1.5, 1.0), pole - Vector2(-1.5, pole_height - 1.0), Color(0.0, 0.0, 0.0, 0.18), maxf(1.0, opposite["scale"] * 0.35))
			draw_line(pole, pole - Vector2(0.0, pole_height), Color("68737a"), maxf(1.0, opposite["scale"] * 0.25))
			draw_circle(pole - Vector2(0.0, pole_height), maxf(1.5, opposite["scale"] * 0.62), Color("e7eef0"))


func _draw_start_finish() -> void:
	var ahead := _track.wrap_distance(-_camera_distance)
	if ahead < _near_distance or ahead > _lookahead_distance:
		return
	var projection := _project(ahead, 0.0)
	var center: Vector2 = projection["center"]
	var half_width := float(projection["half_width"])
	var stripe_height := clampf(float(projection["scale"]) * 0.9, 1.5, 18.0)
	var cells := 10
	for cell in cells:
		var left := lerpf(center.x - half_width, center.x + half_width, float(cell) / float(cells))
		var right := lerpf(center.x - half_width, center.x + half_width, float(cell + 1) / float(cells))
		draw_rect(Rect2(left, center.y - stripe_height * 0.5, right - left + 1.0, stripe_height), DesignSystem.WHITE if cell % 2 == 0 else Color("111722"), true)


func _draw_rivals() -> void:
	var visible_entries: Array[Dictionary] = []
	for entry in _entries:
		if entry == null or entry == _player or entry.state == null or entry.status == RaceEntry.STATUS_DNF:
			continue
		var state := entry.state
		var previous := entry.previous_state if entry.previous_state != null else state
		var delta := _track.forward_delta(previous.track_distance, state.track_distance)
		var distance_along := _track.wrap_distance(previous.track_distance + delta * _alpha)
		var ahead := _track.wrap_distance(distance_along - _camera_distance)
		if ahead <= _near_distance * 0.65 or ahead > _lookahead_distance:
			continue
		var lateral := lerpf(previous.lateral_offset, state.lateral_offset, _alpha)
		visible_entries.append({"entry": entry, "ahead": ahead, "lateral": lateral})
	visible_entries.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return float(first["ahead"]) > float(second["ahead"])
	)
	for visible in visible_entries:
		var entry: RaceEntry = visible["entry"]
		var projection := _project(float(visible["ahead"]), float(visible["lateral"]))
		var current_speed := entry.state.forward_speed()
		var previous_speed := entry.previous_state.forward_speed() if entry.previous_state != null else current_speed
		_draw_rear_car(
			projection["center"], float(projection["scale"]),
			_entry_colors.get(
				str(entry.participant_id),
				AI_COLORS[posmod(entry.grid_position - 2, AI_COLORS.size())]
			), false,
			previous_speed - current_speed > 0.8
		)


func _draw_rear_car(
		anchor: Vector2,
		perspective_scale: float,
		color: Color,
		player_car: bool,
		braking: bool = false
	) -> void:
	var scale_factor := clampf(perspective_scale, 0.42, 15.0)
	if player_car:
		scale_factor = 17.7
	var car_width := scale_factor * 7.15
	var car_height := scale_factor * 4.55
	var center := anchor - Vector2(0.0, car_height * 0.39)
	var carbon := Color("10161d")
	var carbon_edge := Color("39444e")
	var tire := Color("070a0e")
	var body_light := Color("eef3f4").lerp(color, 0.10)
	var coral := Color("ff6b72")
	var detailed := scale_factor >= 2.1 and not _low_graphics
	var line_width := maxf(1.0, scale_factor * 0.18)

	# Contact shadow and exposed rear tires establish the low, wide stance before
	# any bodywork is layered over them.
	_draw_filled_ellipse(
		center + Vector2(0.0, car_height * 0.42),
		Vector2(car_width * 0.60, car_height * 0.27),
		Color(0.0, 0.0, 0.0, 0.38)
	)
	for side in [-1.0, 1.0]:
		var wheel_center := center + Vector2(side * car_width * 0.43, car_height * 0.12)
		var tire_radii := Vector2(car_width * 0.13, car_height * 0.35)
		_draw_filled_ellipse(wheel_center, tire_radii, tire)
		if detailed:
			_draw_filled_ellipse(wheel_center, tire_radii * Vector2(0.72, 0.82), color.darkened(0.30))
			_draw_filled_ellipse(wheel_center, tire_radii * Vector2(0.50, 0.66), Color("151b22"))
			draw_circle(wheel_center, maxf(1.0, scale_factor * 0.20), Color("7a858e"))
			draw_line(
				wheel_center - Vector2(0.0, tire_radii.y * 0.66),
				wheel_center + Vector2(0.0, tire_radii.y * 0.66),
				coral, maxf(1.0, scale_factor * 0.09), true
			)

	# Wishbones remain visibly separate from the floor, preserving open-wheel
	# readability even when rival cars are only a few pixels tall.
	for side in [-1.0, 1.0]:
		var hub := center + Vector2(side * car_width * 0.40, car_height * 0.10)
		draw_line(hub, center + Vector2(side * car_width * 0.18, -car_height * 0.08), carbon_edge, line_width, true)
		draw_line(hub, center + Vector2(side * car_width * 0.23, car_height * 0.27), carbon_edge, line_width, true)

	# Venturi floor and diffuser first, then the sculpted white shoulders and
	# graphite engine cover from the shared original concept identity.
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-car_width * 0.40, car_height * 0.34),
		center + Vector2(-car_width * 0.34, -car_height * 0.12),
		center + Vector2(0.0, -car_height * 0.30),
		center + Vector2(car_width * 0.34, -car_height * 0.12),
		center + Vector2(car_width * 0.40, car_height * 0.34),
	]), carbon)
	for side in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			center + Vector2(side * car_width * 0.36, car_height * 0.28),
			center + Vector2(side * car_width * 0.31, -car_height * 0.08),
			center + Vector2(side * car_width * 0.18, -car_height * 0.25),
			center + Vector2(side * car_width * 0.08, car_height * 0.22),
		]), body_light)
		draw_colored_polygon(PackedVector2Array([
			center + Vector2(side * car_width * 0.34, car_height * 0.24),
			center + Vector2(side * car_width * 0.28, car_height * 0.03),
			center + Vector2(side * car_width * 0.15, -car_height * 0.15),
			center + Vector2(side * car_width * 0.21, car_height * 0.24),
		]), color)
		if detailed:
			draw_line(
				center + Vector2(side * car_width * 0.30, car_height * 0.01),
				center + Vector2(side * car_width * 0.19, -car_height * 0.15),
				coral, maxf(1.0, scale_factor * 0.13), true
			)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-car_width * 0.13, car_height * 0.24),
		center + Vector2(-car_width * 0.16, -car_height * 0.20),
		center + Vector2(0.0, -car_height * 0.44),
		center + Vector2(car_width * 0.16, -car_height * 0.20),
		center + Vector2(car_width * 0.13, car_height * 0.24),
	]), Color("202832"))
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-car_width * 0.035, car_height * 0.21),
		center + Vector2(-car_width * 0.055, -car_height * 0.34),
		center + Vector2(0.0, -car_height * 0.43),
		center + Vector2(car_width * 0.055, -car_height * 0.34),
		center + Vector2(car_width * 0.035, car_height * 0.21),
	]), color)

	# Broad two-element rear wing, carbon endplates, and central rain light make
	# the silhouette unmistakably formula/open-wheel without copying a real car.
	draw_line(
		center + Vector2(-car_width * 0.18, -car_height * 0.16),
		center + Vector2(-car_width * 0.18, -car_height * 0.42),
		carbon_edge, line_width, true
	)
	draw_line(
		center + Vector2(car_width * 0.18, -car_height * 0.16),
		center + Vector2(car_width * 0.18, -car_height * 0.42),
		carbon_edge, line_width, true
	)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-car_width * 0.58, -car_height * 0.49),
		center + Vector2(car_width * 0.58, -car_height * 0.49),
		center + Vector2(car_width * 0.54, -car_height * 0.34),
		center + Vector2(-car_width * 0.54, -car_height * 0.34),
	]), carbon)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-car_width * 0.50, -car_height * 0.45),
		center + Vector2(car_width * 0.50, -car_height * 0.45),
		center + Vector2(car_width * 0.47, -car_height * 0.39),
		center + Vector2(-car_width * 0.47, -car_height * 0.39),
	]), body_light)
	draw_line(
		center + Vector2(-car_width * 0.46, -car_height * 0.36),
		center + Vector2(car_width * 0.46, -car_height * 0.36),
		color, maxf(1.0, scale_factor * 0.15), true
	)
	for side in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			center + Vector2(side * car_width * 0.60, -car_height * 0.53),
			center + Vector2(side * car_width * 0.51, -car_height * 0.52),
			center + Vector2(side * car_width * 0.50, -car_height * 0.29),
			center + Vector2(side * car_width * 0.60, -car_height * 0.27),
		]), coral)

	# Halo and cockpit opening sit above the engine spine instead of reading as a
	# generic roof or sedan cabin.
	var cockpit_center := center - Vector2(0.0, car_height * 0.20)
	_draw_filled_ellipse(cockpit_center, Vector2(car_width * 0.10, car_height * 0.12), Color("05090d"))
	if detailed:
		draw_arc(cockpit_center, car_height * 0.15, PI * 1.08, PI * 1.92, 18, carbon_edge, maxf(1.0, scale_factor * 0.16), true)
		draw_line(cockpit_center - Vector2(0.0, car_height * 0.15), cockpit_center + Vector2(0.0, car_height * 0.06), carbon_edge, maxf(1.0, scale_factor * 0.14), true)

	var lamp_color := Color("ff3344") if braking else Color("8a202b")
	var lamp_size := Vector2(maxf(2.0, scale_factor * 0.32), maxf(2.0, scale_factor * 0.42))
	draw_rect(Rect2(center + Vector2(-lamp_size.x * 0.5, car_height * 0.27), lamp_size), lamp_color, true)
	if detailed:
		for fin in [-0.22, -0.11, 0.0, 0.11, 0.22]:
			draw_line(
				center + Vector2(car_width * fin, car_height * 0.25),
				center + Vector2(car_width * fin * 1.16, car_height * 0.40),
				carbon_edge, maxf(1.0, scale_factor * 0.09), true
			)


func _draw_chase_car() -> void:
	var steer := _command.steer if _command != null else 0.0
	if _player != null and _player.state != null:
		steer = _player.state.steering_input
	var sway := chase_sway_offset(steer, _screen_shake_strength, _reduced_motion)
	var shift_settle := shift_settle_offset(_player.state.shift_ticks_remaining, _reduced_motion)
	var anchor := Vector2(size.x * 0.5 + sway, size.y * 0.885 + shift_settle)
	var previous := _player.previous_state if _player.previous_state != null else _player.state
	var cues := cosmetic_cue_state(_player.state, previous, _command, _low_graphics, _reduced_motion)
	_draw_recent_skid_trail(anchor)
	_draw_player_surface_effects(anchor, cues)
	_draw_rear_car(anchor, 17.7, _player_color, true, bool(cues["brake_lights"]))


func _draw_recent_skid_trail(anchor: Vector2) -> void:
	if _low_graphics or _reduced_motion or _skid_marks.is_empty():
		return
	var visible_count := mini(_skid_marks.size(), 14)
	for index in visible_count:
		var source_index := _skid_marks.size() - visible_count + index
		var mark: Dictionary = _skid_marks[source_index]
		var remaining := clampf(
			float(int(mark.get("expires_at", 0)) - Time.get_ticks_msec()) / float(SKID_MARK_LIFETIME_MS),
			0.0, 1.0
		)
		var y := anchor.y + 19.0 + float(visible_count - 1 - index) * 3.2
		var width := 1.4 + remaining * 1.4
		var color := Color(0.01, 0.016, 0.023, 0.14 + remaining * 0.40)
		draw_line(Vector2(anchor.x - 45.0, y), Vector2(anchor.x - 47.0, y + 5.0), color, width, true)
		draw_line(Vector2(anchor.x + 45.0, y), Vector2(anchor.x + 47.0, y + 5.0), color, width, true)


func _draw_player_surface_effects(anchor: Vector2, cues: Dictionary) -> void:
	if bool(cues.get("dust", false)):
		for offset in [Vector2(-52.0, 24.0), Vector2(48.0, 30.0), Vector2(-27.0, 42.0)]:
			draw_circle(anchor + offset, 8.0, Color(0.72, 0.61, 0.42, 0.32))
	if bool(cues.get("slip_smoke", false)):
		draw_line(anchor + Vector2(-47.0, 13.0), anchor + Vector2(-70.0, 49.0), Color(0.82, 0.87, 0.91, 0.36), 5.0, true)
		draw_line(anchor + Vector2(47.0, 13.0), anchor + Vector2(70.0, 49.0), Color(0.82, 0.87, 0.91, 0.36), 5.0, true)
	if bool(cues.get("sparks", false)):
		var side := -1.0 if _player.state.lateral_offset < 0.0 else 1.0
		var origin := anchor + Vector2(side * 53.0, 2.0)
		for offset in [Vector2(side * 32.0, -16.0), Vector2(side * 42.0, 4.0), Vector2(side * 27.0, 22.0)]:
			draw_line(origin, origin + offset, DesignSystem.GOLD, 3.0, true)
	if bool(cues.get("debris", false)):
		var debris_side := -1.0 if _player.state.lateral_offset < 0.0 else 1.0
		var debris_origin := anchor + Vector2(debris_side * 58.0, 4.0)
		for index in 3:
			var piece := debris_origin + Vector2(debris_side * (15.0 + index * 11.0), -11.0 + index * 10.0)
			draw_rect(Rect2(piece - Vector2(2.5, 1.5), Vector2(5.0, 3.0)), Color("7f8994"), true)


func _draw_cockpit() -> void:
	var steering := _command.steer if _command != null else 0.0
	if _player != null and _player.state != null:
		steering = _player.state.steering_input
	var bottom := size.y
	var cockpit_top := size.y * 0.755
	var carbon := Color("0b1118")
	var carbon_edge := Color("35434d")
	var body_light := Color("eef3f4").lerp(_player_color, 0.10)
	var coral := Color("ff6b72")
	var nose_tip_y := size.y * 0.565

	# The front axle remains visible in first person: exposed tires, wishbones,
	# and the low tapered nose retain the same V2 silhouette as the garage car.
	for side in [-1.0, 1.0]:
		var front_wheel := Vector2(size.x * (0.105 if side < 0.0 else 0.895), size.y * 0.705)
		var tire_radii := Vector2(clampf(size.x * 0.048, 42.0, 62.0), clampf(size.y * 0.035, 20.0, 29.0))
		_draw_filled_ellipse(front_wheel + Vector2(4.0 * side, 5.0), tire_radii * Vector2(1.05, 1.08), Color(0.0, 0.0, 0.0, 0.34))
		_draw_filled_ellipse(front_wheel, tire_radii, Color("070a0e"))
		_draw_filled_ellipse(front_wheel, tire_radii * Vector2(0.78, 0.58), Color("222b33"))
		if not _low_graphics:
			draw_line(front_wheel - Vector2(tire_radii.x * 0.62, 0.0), front_wheel + Vector2(tire_radii.x * 0.62, 0.0), _player_color, 3.0, true)
			draw_line(front_wheel - Vector2(tire_radii.x * 0.38, -4.0), front_wheel + Vector2(tire_radii.x * 0.38, 4.0), coral, 2.0, true)
		var suspension_root := Vector2(size.x * (0.455 if side < 0.0 else 0.545), size.y * 0.69)
		draw_line(front_wheel, suspension_root, carbon_edge, 5.0, true)
		draw_line(front_wheel + Vector2(0.0, 9.0), suspension_root + Vector2(side * 20.0, 28.0), Color("64717a"), 3.0, true)

	draw_colored_polygon(PackedVector2Array([
		Vector2(size.x * 0.487, nose_tip_y),
		Vector2(size.x * 0.513, nose_tip_y),
		Vector2(size.x * 0.585, size.y * 0.94),
		Vector2(size.x * 0.415, size.y * 0.94),
	]), body_light)
	draw_colored_polygon(PackedVector2Array([
		Vector2(size.x * 0.496, nose_tip_y + 4.0),
		Vector2(size.x * 0.504, nose_tip_y + 4.0),
		Vector2(size.x * 0.528, size.y * 0.94),
		Vector2(size.x * 0.472, size.y * 0.94),
	]), _player_color)
	draw_line(Vector2(size.x * 0.505, nose_tip_y + 12.0), Vector2(size.x * 0.535, size.y * 0.90), coral, 3.0, true)

	# Sculpted cockpit shoulders use pale composite over a graphite tub, with an
	# accent pinstripe rather than any real-team livery or sponsor treatment.
	draw_colored_polygon(PackedVector2Array([
		Vector2(0.0, bottom), Vector2(0.0, cockpit_top + 12.0),
		Vector2(size.x * 0.20, cockpit_top - 32.0), Vector2(size.x * 0.35, cockpit_top + 12.0),
		Vector2(size.x * 0.43, bottom),
	]), carbon)
	draw_colored_polygon(PackedVector2Array([
		Vector2(size.x, bottom), Vector2(size.x, cockpit_top + 12.0),
		Vector2(size.x * 0.80, cockpit_top - 32.0), Vector2(size.x * 0.65, cockpit_top + 12.0),
		Vector2(size.x * 0.57, bottom),
	]), carbon)
	for side in [-1.0, 1.0]:
		draw_colored_polygon(PackedVector2Array([
			Vector2(size.x * (0.02 if side < 0.0 else 0.98), bottom),
			Vector2(size.x * (0.08 if side < 0.0 else 0.92), cockpit_top + 11.0),
			Vector2(size.x * (0.215 if side < 0.0 else 0.785), cockpit_top - 20.0),
			Vector2(size.x * (0.34 if side < 0.0 else 0.66), cockpit_top + 20.0),
			Vector2(size.x * (0.40 if side < 0.0 else 0.60), bottom),
		]), body_light)
		draw_line(
			Vector2(size.x * (0.10 if side < 0.0 else 0.90), cockpit_top + 13.0),
			Vector2(size.x * (0.36 if side < 0.0 else 0.64), bottom),
			_player_color, 7.0, true
		)
		draw_line(
			Vector2(size.x * (0.18 if side < 0.0 else 0.82), cockpit_top - 13.0),
			Vector2(size.x * (0.34 if side < 0.0 else 0.66), cockpit_top + 28.0),
			coral, 3.0, true
		)
	draw_rect(Rect2(0.0, size.y * 0.91, size.x, size.y * 0.09), Color("050a12"), true)

	# Layered elliptical halo: broad carbon shadow, graphite structure, and a
	# restrained specular edge. The center stay meets the nose instead of floating.
	var halo_center := Vector2(size.x * 0.5, size.y * 0.605)
	var halo_radii := Vector2(size.x * 0.235, size.y * 0.102)
	_draw_ellipse_arc(halo_center + Vector2(0.0, 3.0), halo_radii, PI * 1.05, PI * 1.95, 32, Color(0.0, 0.0, 0.0, 0.42), 21.0)
	_draw_ellipse_arc(halo_center, halo_radii, PI * 1.05, PI * 1.95, 32, carbon, 15.0)
	_draw_ellipse_arc(halo_center - Vector2(0.0, 2.0), halo_radii, PI * 1.07, PI * 1.93, 28, Color("53616b"), 2.5)
	var halo_left := halo_center + Vector2(cos(PI * 1.05) * halo_radii.x, sin(PI * 1.05) * halo_radii.y)
	var halo_right := halo_center + Vector2(cos(PI * 1.95) * halo_radii.x, sin(PI * 1.95) * halo_radii.y)
	draw_line(Vector2(size.x * 0.19, cockpit_top), halo_left, carbon, 15.0, true)
	draw_line(Vector2(size.x * 0.81, cockpit_top), halo_right, carbon, 15.0, true)
	draw_line(Vector2(size.x * 0.5, halo_center.y - halo_radii.y), Vector2(size.x * 0.5, cockpit_top - 2.0), Color(0.0, 0.0, 0.0, 0.46), 20.0, true)
	draw_line(Vector2(size.x * 0.5, halo_center.y - halo_radii.y), Vector2(size.x * 0.5, cockpit_top - 2.0), carbon, 14.0, true)
	draw_line(Vector2(size.x * 0.5 - 2.0, halo_center.y - halo_radii.y + 2.0), Vector2(size.x * 0.5 - 2.0, cockpit_top - 5.0), carbon_edge, 2.2, true)
	var wheel_settle := shift_settle_offset(_player.state.shift_ticks_remaining, _reduced_motion)
	var wheel_center := Vector2(size.x * 0.5, size.y * 0.84 + wheel_settle)
	var radius := clampf(size.x * 0.082, 78.0, 112.0)
	var wheel_angle := steering * 0.34
	_draw_rotated_wheel(wheel_center, radius, wheel_angle)
	var previous := _player.previous_state if _player.previous_state != null else _player.state
	var cues := cosmetic_cue_state(_player.state, previous, _command, _low_graphics, _reduced_motion)
	if bool(cues.get("dust", false)):
		draw_circle(Vector2(size.x * 0.08, size.y * 0.86), 18.0, Color(0.72, 0.61, 0.42, 0.24))
		draw_circle(Vector2(size.x * 0.92, size.y * 0.88), 21.0, Color(0.72, 0.61, 0.42, 0.24))
	if bool(cues.get("sparks", false)):
		var spark_side := 0.05 if _player.state.lateral_offset < 0.0 else 0.95
		var spark_origin := Vector2(size.x * spark_side, size.y * 0.77)
		for offset in [Vector2(34.0 if spark_side < 0.5 else -34.0, -22.0), Vector2(42.0 if spark_side < 0.5 else -42.0, 4.0)]:
			draw_line(spark_origin, spark_origin + offset, DesignSystem.GOLD, 3.0, true)
	if bool(cues.get("debris", false)):
		var side_direction := 1.0 if _player.state.lateral_offset < 0.0 else -1.0
		for index in 3:
			var debris := Vector2(size.x * (0.06 if side_direction > 0.0 else 0.94), size.y * 0.80) + Vector2(side_direction * index * 11.0, index * 9.0)
			draw_rect(Rect2(debris - Vector2(2.0, 1.5), Vector2(4.0, 3.0)), Color("7f8994"), true)


func _draw_rotated_wheel(center: Vector2, radius: float, angle: float) -> void:
	var carbon := Color("0c1219")
	var graphite := Color("3a4650")
	var coral := Color("ff6b72")
	var outer_local := PackedVector2Array([
		Vector2(-radius * 0.82, -radius * 0.31),
		Vector2(-radius * 0.60, -radius * 0.53),
		Vector2(radius * 0.60, -radius * 0.53),
		Vector2(radius * 0.82, -radius * 0.31),
		Vector2(radius * 0.79, radius * 0.30),
		Vector2(radius * 0.55, radius * 0.49),
		Vector2(-radius * 0.55, radius * 0.49),
		Vector2(-radius * 0.79, radius * 0.30),
	])
	var outer := _rotated_points(center, outer_local, angle)
	draw_colored_polygon(outer, carbon)
	var outline := outer.duplicate()
	outline.append(outer[0])
	draw_polyline(outline, graphite, 4.0, true)

	# Rear-mounted paddles and hand grips remain mechanically readable when the
	# yoke rotates; all local points share the same steering transform.
	for side in [-1.0, 1.0]:
		var paddle_a := center + Vector2(side * radius * 0.49, -radius * 0.47).rotated(angle)
		var paddle_b := center + Vector2(side * radius * 0.58, radius * 0.35).rotated(angle)
		draw_line(paddle_a, paddle_b, Color("697680"), 7.0, true)
		var grip_local := Vector2(side * radius * 0.76, radius * 0.02)
		var glove_center := center + grip_local.rotated(angle)
		draw_circle(glove_center, radius * 0.19, Color("111820"))
		draw_circle(glove_center, radius * 0.145, Color("d9e1e3"))
		draw_line(
			glove_center - Vector2(radius * 0.09, 0.0).rotated(angle),
			glove_center + Vector2(radius * 0.09, 0.0).rotated(angle),
			_player_color, 3.0, true
		)

	var screen_local := PackedVector2Array([
		Vector2(-radius * 0.40, -radius * 0.20), Vector2(radius * 0.40, -radius * 0.20),
		Vector2(radius * 0.35, radius * 0.18), Vector2(-radius * 0.35, radius * 0.18),
	])
	draw_colored_polygon(_rotated_points(center, screen_local, angle), Color("07141c"))
	var display_local := PackedVector2Array([
		Vector2(-radius * 0.29, -radius * 0.10), Vector2(radius * 0.29, -radius * 0.10),
		Vector2(radius * 0.26, radius * 0.08), Vector2(-radius * 0.26, radius * 0.08),
	])
	draw_colored_polygon(_rotated_points(center, display_local, angle), _player_color.darkened(0.68))
	var idle_rpm := 4500.0
	var redline_rpm := 12500.0
	var engine_rpm := idle_rpm
	var gear := 0
	var shift_ticks := 0
	if _player != null and _player.state != null:
		engine_rpm = _player.state.engine_rpm
		gear = _player.state.gear
		shift_ticks = _player.state.shift_ticks_remaining
		if _player.vehicle_model != null and _player.vehicle_model.config != null:
			idle_rpm = _player.vehicle_model.config.idle_rpm
			redline_rpm = _player.vehicle_model.config.redline_rpm
	var rpm_ratio := dashboard_rpm_ratio(engine_rpm, idle_rpm, redline_rpm)
	var active_lights := clampi(ceili(rpm_ratio * 5.0), 0, 5)
	if shift_ticks > 0:
		active_lights = 5
	for index in 5:
		var light_color := Color("1b2a2f")
		if index < active_lights:
			light_color = coral if shift_ticks > 0 else (_player_color if index < 3 else (DesignSystem.GOLD if index == 3 else coral))
		var light_local := Vector2((float(index) - 2.0) * radius * 0.12, -radius * 0.31)
		draw_circle(center + light_local.rotated(angle), radius * 0.035, light_color)
	_draw_dashboard_gear(center, radius, angle, gear)
	if _command != null and _command.brake > 0.12:
		var brake_a := center + Vector2(-radius * 0.12, radius * 0.01).rotated(angle)
		var brake_b := center + Vector2(radius * 0.12, radius * 0.01).rotated(angle)
		draw_line(brake_a, brake_b, Color("ff3344"), 5.0, true)


func _draw_dashboard_gear(center: Vector2, radius: float, angle: float, gear: int) -> void:
	var half_width := radius * 0.065
	var half_height := radius * 0.095
	var digit_center := Vector2(0.0, -radius * 0.005)
	var segments := [
		[Vector2(-half_width, -half_height), Vector2(half_width, -half_height)],
		[Vector2(half_width, -half_height), Vector2(half_width, 0.0)],
		[Vector2(half_width, 0.0), Vector2(half_width, half_height)],
		[Vector2(-half_width, half_height), Vector2(half_width, half_height)],
		[Vector2(-half_width, 0.0), Vector2(-half_width, half_height)],
		[Vector2(-half_width, -half_height), Vector2(-half_width, 0.0)],
		[Vector2(-half_width, 0.0), Vector2(half_width, 0.0)],
	]
	var mask := dashboard_gear_segment_mask(gear)
	for segment_index in segments.size():
		if (mask & (1 << segment_index)) == 0:
			continue
		var segment: Array = segments[segment_index]
		var segment_start: Vector2 = segment[0]
		var segment_finish: Vector2 = segment[1]
		var start: Vector2 = center + (digit_center + segment_start).rotated(angle)
		var finish: Vector2 = center + (digit_center + segment_finish).rotated(angle)
		draw_line(start, finish, Color("b8fff3"), maxf(2.0, radius * 0.026), true)


func _rotated_points(center: Vector2, local_points: PackedVector2Array, angle: float) -> PackedVector2Array:
	var output := PackedVector2Array()
	for point in local_points:
		output.append(center + point.rotated(angle))
	return output


func _draw_ellipse_arc(
		center: Vector2,
		radii: Vector2,
		start_angle: float,
		end_angle: float,
		point_count: int,
		color: Color,
		width: float
	) -> void:
	var points := PackedVector2Array()
	for index in point_count:
		var amount := float(index) / float(maxi(point_count - 1, 1))
		var arc_angle := lerpf(start_angle, end_angle, amount)
		points.append(center + Vector2(cos(arc_angle) * radii.x, sin(arc_angle) * radii.y))
	draw_polyline(points, color, width, true)


func _draw_filled_ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	var polygon := PackedVector2Array()
	for index in 24:
		var angle := TAU * float(index) / 24.0
		polygon.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	draw_colored_polygon(polygon, color)
