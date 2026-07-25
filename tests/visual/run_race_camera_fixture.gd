extends SceneTree
## Visual QA fixture. Example:
## godot --path . --write-movie evidence/cockpit.png --quit-after 240 \
##   --fixed-fps 60 --script res://tests/visual/run_race_camera_fixture.gd -- --camera=cockpit

const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const AiRosterType := preload("res://game/ai/ai_roster.gd")
const TrackCatalogType := preload("res://game/content/predefined_track_catalog.gd")

const AUTODRIVE_SECONDS := 14.0
const PROOF_INTERVAL_FRAMES := 120
const PERFORMANCE_WARMUP_FRAMES := 180
const PERFORMANCE_TARGET_FPS := 55.0
const PERFORMANCE_MAX_P95_FRAME_MS := 20.5
const PERFORMANCE_MAX_P99_FRAME_MS := 33.3
const PERFORMANCE_MAX_FRAME_MS := 50.0
const STANDARD_MAX_DRAW_CALLS := 650
# Enlarged 1.2-1.38 km worlds keep the full desktop barrier/fence cadence. The
# measured post-upgrade field is 953 objects; 1,000 is a tight structural ceiling
# while the mobile tier below remains independently capped at 600.
const STANDARD_MAX_RENDER_OBJECTS := 1_000
const STANDARD_MAX_PRIMITIVES := 850_000
const MOBILE_MAX_DRAW_CALLS := 300
const MOBILE_MAX_RENDER_OBJECTS := 600
const MOBILE_MAX_PRIMITIVES := 300_000
const NEARBY_STRESS_RADIUS_AUTHORITY := 100.0 # 30 m presentation radius.


func _initialize() -> void:
	call_deferred("_build_fixture")


func _build_fixture() -> void:
	var requested: StringName = &"chase"
	var autodrive := false
	var performance_proof := false
	var camera_stability_proof := false
	var mobile_tier := false
	var track_id := ""
	for argument in OS.get_cmdline_user_args():
		if argument == "--camera=cockpit":
			requested = &"cockpit"
		elif argument == "--autodrive":
			autodrive = true
		elif argument == "--performance-proof":
			autodrive = true
			performance_proof = true
		elif argument == "--camera-stability-proof":
			autodrive = true
			camera_stability_proof = true
		elif argument == "--mobile-tier":
			mobile_tier = true
		elif argument.begins_with("--track="):
			track_id = argument.trim_prefix("--track=")
	var screen := RaceScreenType.new()
	var race_payload := {"visual_fixture": true}
	if not track_id.is_empty():
		var record := TrackCatalogType.by_id(track_id)
		var definition: TrackDefinition = record.get("definition")
		if definition != null:
			race_payload["track_definition_json"] = definition.canonical_json(true)
			race_payload["display_name"] = str(record.get("name", track_id))
	screen.set_payload(race_payload)
	root.add_child(screen)
	screen.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	if mobile_tier and screen.perspective_view != null:
		screen.perspective_view.configure_accessibility(true, false, false, 0.0)
		await process_frame
		var tier_snapshot: Dictionary = screen.perspective_view.debug_snapshot()
		print("MOBILE_RENDER_TIER shrink=%d msaa=%d ssaa=%d shadow_m=%.1f fog=%s track_segments=%d track_triangles=%d" % [
			int(tier_snapshot.get("viewport_stretch_shrink", 0)),
			int(tier_snapshot.get("viewport_msaa_3d", -1)),
			int(tier_snapshot.get("viewport_screen_space_aa", -1)),
			float(tier_snapshot.get("sun_shadow_max_distance", 0.0)),
			str(bool(tier_snapshot.get("fog_enabled", true))),
			int(tier_snapshot.get("track_stats", {}).get("segment_count", -1)),
			int(tier_snapshot.get("track_stats", {}).get("triangles", -1)),
		])
	if screen.perspective_view != null and screen.perspective_view.camera_mode != requested:
		screen._toggle_camera(false)
	if autodrive:
		_run_autodrive(
			screen, performance_proof, mobile_tier, camera_stability_proof
		)


func _run_autodrive(
		screen: Control,
		performance_proof: bool = false,
		mobile_tier: bool = false,
		camera_stability_proof: bool = false
	) -> void:
	while screen.director == null or screen.input_adapter == null:
		await process_frame
	var drivers: Array = AiRosterType.create_drivers(0xF1C0, 1, 0.90)
	if drivers.is_empty():
		push_error("DRIVEN_WORLD_PROOF could not create the deterministic fixture driver")
		return
	var driver: Variant = drivers[0]
	var player: RaceEntry = screen.director.entry(screen.PLAYER_ID)
	if player == null:
		push_error("DRIVEN_WORLD_PROOF could not resolve the player entry")
		return
	if driver.has_method("configure_vehicle_dynamics"):
		driver.configure_vehicle_dynamics(player.vehicle_model.config)

	while screen.director.phase != screen.director.PHASE_RACING:
		await process_frame
	var initial: Dictionary = screen.perspective_view.debug_snapshot()
	var initial_player: Transform3D = initial.get(
		"player_world_transform", Transform3D.IDENTITY
	)
	var initial_camera: Transform3D = initial.get(
		"camera_world_transform", Transform3D.IDENTITY
	)
	var race_camera: Camera3D = screen.perspective_view.debug_camera()
	var stability_reference_forward_local := initial_player.basis.inverse() \
			* (-initial_camera.basis.z)
	var stability_reference_relative_position := initial_player.affine_inverse() \
			* initial_camera.origin
	var stability_reference_screen_row := 0.0
	if race_camera != null:
		stability_reference_screen_row = race_camera.unproject_position(
			initial_player.origin
		).y
	var stability_samples := 0
	var maximum_stability_pitch_drift_degrees := 0.0
	var maximum_stability_screen_row_drift := 0.0
	var maximum_stability_mount_drift := 0.0
	var frame_times_ms: Array[float] = []
	var process_times_ms: Array[float] = []
	var physics_times_ms: Array[float] = []
	var reported_fps: Array[float] = []
	var maximum_draw_calls := 0
	var maximum_objects := 0
	var maximum_primitives := 0
	var maximum_nearby_cars := 0
	var nearby_car_total := 0
	var nearby_car_samples := 0
	var initial_shift_serial := player.state.shift_serial
	var maximum_gear := player.state.gear
	var maximum_rpm := player.state.engine_rpm
	var maximum_speed := player.state.speed()
	var maximum_absolute_steering := absf(player.state.steering_input)
	var frame_limit := roundi(AUTODRIVE_SECONDS * 60.0)
	for frame in frame_limit:
		player = screen.director.entry(screen.PLAYER_ID)
		if player == null or player.state == null:
			break
		var frame_started_usec := Time.get_ticks_usec()
		if performance_proof and frame >= PERFORMANCE_WARMUP_FRAMES:
			# Exercise every quantized coating transition during the first three
			# measured seconds, then retain the fully muddy field for the remainder.
			_set_surface_stress_progress(
				screen,
				clampf(
					float(frame - PERFORMANCE_WARMUP_FRAMES) / 180.0,
					0.0,
					1.0
				)
			)
			_anchor_dense_non_overlapping_pack(screen, player)
		var decision_states: Array = []
		for entry in screen.director.entries:
			decision_states.append(entry.state.duplicate_state())
		var command: RaceInput = driver.command(
			player.state,
			screen.race_query,
			decision_states,
			player.state.simulation_tick
		)
		screen.input_adapter.touch_steer = command.steer
		screen.input_adapter.touch_throttle = command.throttle
		screen.input_adapter.touch_brake = command.brake
		maximum_gear = maxi(maximum_gear, player.state.gear)
		maximum_rpm = maxf(maximum_rpm, player.state.engine_rpm)
		maximum_speed = maxf(maximum_speed, player.state.speed())
		maximum_absolute_steering = maxf(
			maximum_absolute_steering, absf(player.state.steering_input)
		)
		if frame % PROOF_INTERVAL_FRAMES == 0:
			var sample: Dictionary = screen.perspective_view.debug_snapshot()
			var pose: Transform3D = sample.get(
				"player_world_transform", Transform3D.IDENTITY
			)
			print((
				"DRIVEN_FRAME frame=%d speed=%.2f gear=%d rpm=%.0f steer=%.3f " \
				+ "shift_ticks=%d world=(%.2f,%.2f,%.2f) " \
				+ "fixed_world=%s"
			) % [
					frame, player.state.speed(), player.state.gear,
					player.state.engine_rpm, player.state.steering_input,
					player.state.shift_ticks_remaining,
					pose.origin.x, pose.origin.y, pose.origin.z,
					str(bool(sample.get("fixed_world_invariant", false))),
				]
			)
		await process_frame
		if camera_stability_proof:
			var stability_snapshot: Dictionary = screen.perspective_view.debug_snapshot()
			var stability_player: Transform3D = stability_snapshot.get(
				"player_world_transform", Transform3D.IDENTITY
			)
			var stability_camera: Transform3D = stability_snapshot.get(
				"camera_world_transform", Transform3D.IDENTITY
			)
			var stability_forward_local := stability_player.basis.inverse() \
					* (-stability_camera.basis.z)
			var forward_dot := clampf(
				stability_forward_local.normalized().dot(
					stability_reference_forward_local.normalized()
				), -1.0, 1.0
			)
			maximum_stability_pitch_drift_degrees = maxf(
				maximum_stability_pitch_drift_degrees,
				rad_to_deg(acos(forward_dot))
			)
			maximum_stability_mount_drift = maxf(
				maximum_stability_mount_drift,
				(stability_player.affine_inverse() * stability_camera.origin).distance_to(
					stability_reference_relative_position
				)
			)
			if race_camera != null:
				maximum_stability_screen_row_drift = maxf(
					maximum_stability_screen_row_drift,
					absf(race_camera.unproject_position(stability_player.origin).y
							- stability_reference_screen_row)
				)
			stability_samples += 1
		if performance_proof and frame >= PERFORMANCE_WARMUP_FRAMES:
			var nearby_cars := 0
			for other_entry in screen.director.entries:
				if other_entry != player and other_entry.state != null \
						and other_entry.state.position.distance_squared_to(
							player.state.position
						) <= NEARBY_STRESS_RADIUS_AUTHORITY \
								* NEARBY_STRESS_RADIUS_AUTHORITY:
					nearby_cars += 1
			maximum_nearby_cars = maxi(maximum_nearby_cars, nearby_cars)
			nearby_car_total += nearby_cars
			nearby_car_samples += 1
			frame_times_ms.append(
				float(Time.get_ticks_usec() - frame_started_usec) / 1000.0
			)
			process_times_ms.append(
				float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
			)
			physics_times_ms.append(
				float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
			)
			reported_fps.append(float(Engine.get_frames_per_second()))
			maximum_draw_calls = maxi(
				maximum_draw_calls,
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
			)
			maximum_objects = maxi(
				maximum_objects,
				int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
			)
			maximum_primitives = maxi(
				maximum_primitives,
				int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
			)

	screen.input_adapter.reset_touch()
	var final: Dictionary = screen.perspective_view.debug_snapshot()
	var final_player: Transform3D = final.get(
		"player_world_transform", Transform3D.IDENTITY
	)
	var final_camera: Transform3D = final.get(
		"camera_world_transform", Transform3D.IDENTITY
	)
	var player_travel := final_player.origin.distance_to(initial_player.origin)
	var camera_travel := final_camera.origin.distance_to(initial_camera.origin)
	var fixed_world := bool(final.get("fixed_world_invariant", false))
	print((
		"DRIVEN_WORLD_PROOF player_travel_m=%.2f camera_travel_m=%.2f " \
		+ "track_origin=%s scenery_origin=%s fixed_world=%s"
	) % [
			player_travel,
			camera_travel,
			str(final.get("track_root_origin", Vector3.INF)),
			str(final.get("scenery_root_origin", Vector3.INF)),
			str(fixed_world),
		]
	)
	var shift_events := maxi(player.state.shift_serial - initial_shift_serial, 0)
	print((
		"DRIVETRAIN_VISUAL_PROOF max_speed=%.2f max_gear=%d shifts=%d " \
		+ "max_rpm=%.0f max_abs_steering=%.3f"
	) % [
		maximum_speed,
		maximum_gear,
		shift_events,
		maximum_rpm,
		maximum_absolute_steering,
	])
	if player_travel < 20.0 or camera_travel < 20.0 or not fixed_world:
		push_error("DRIVEN_WORLD_PROOF failed its world-space motion invariant")
	if maximum_gear < 3 or shift_events < 2 or maximum_absolute_steering < 0.05:
		push_error("DRIVETRAIN_VISUAL_PROOF failed its moving gear/steering invariant")
	var camera_stability_passed := true
	if camera_stability_proof:
		camera_stability_passed = stability_samples == frame_limit \
				and maximum_speed >= 150.0 \
				and maximum_stability_pitch_drift_degrees <= 0.01 \
				and maximum_stability_screen_row_drift <= 0.10 \
				and maximum_stability_mount_drift <= 0.001
		print((
			"CHASE_CAMERA_STABILITY_PROOF samples=%d max_speed=%.2f " \
			+ "pitch_drift_deg=%.6f screen_row_drift_px=%.4f " \
			+ "mount_drift_m=%.6f"
		) % [
			stability_samples,
			maximum_speed,
			maximum_stability_pitch_drift_degrees,
			maximum_stability_screen_row_drift,
			maximum_stability_mount_drift,
		])
		if not camera_stability_passed:
			push_error("CHASE_CAMERA_STABILITY_PROOF detected speed-dependent framing drift")
	var performance_passed := true
	if performance_proof:
		performance_passed = _emit_performance_proof(
			frame_times_ms,
			process_times_ms,
			physics_times_ms,
			reported_fps,
			maximum_draw_calls,
			maximum_objects,
			maximum_primitives,
			maximum_nearby_cars,
			float(nearby_car_total) / float(maxi(nearby_car_samples, 1)),
			mobile_tier
		)
	if performance_proof or camera_stability_proof:
		quit(0 if performance_passed and camera_stability_passed else 1)


func _set_surface_stress_progress(screen: Control, progress: float) -> void:
	if screen == null or screen.perspective_view == null \
			or screen.race_query == null \
			or str(screen.race_query.road_surface) != "mud":
		return
	for visual in screen.perspective_view._vehicles.values():
		if visual != null and is_instance_valid(visual) \
				and visual.has_method("set_surface_lap_progress"):
			visual.call("set_surface_lap_progress", progress)


func _anchor_dense_non_overlapping_pack(
		screen: Control,
		player: RaceEntry
	) -> void:
	# Rendering stress must keep the opponents in view after shader warmup. Place
	# them in the production 9-unit stagger (18 units per same lane, above the
	# 16-unit capsule length), behind the moving player on the live circuit. This
	# changes only the QA fixture's remote states; the player remains autodriven.
	if screen.race_query == null or player == null or player.state == null:
		return
	var slot := 0
	for entry in screen.director.entries:
		if entry == player or entry.state == null:
			continue
		slot += 1
		var sample: Dictionary = screen.race_query.sample_at_distance(
			player.state.track_distance - float(slot) * 9.0
		)
		var tangent := Vector2(
			sample.get("tangent", Vector2.RIGHT)
		).normalized()
		var normal := Vector2(sample.get("normal", Vector2.UP)).normalized()
		var lateral := (-1.0 if slot % 2 == 1 else 1.0) * minf(
			screen.race_query.track_width * 0.22, 7.0
		)
		_pose_dense_pack_state(
			entry.state, player.state, sample, tangent, normal, lateral
		)
		if entry.previous_state != null:
			_pose_dense_pack_state(
				entry.previous_state, player.state, sample, tangent, normal, lateral
			)


func _pose_dense_pack_state(
		state: VehicleState,
		player_state: VehicleState,
		sample: Dictionary,
		tangent: Vector2,
		normal: Vector2,
		lateral: float
	) -> void:
	state.position = Vector2(sample.get("position", Vector2.ZERO)) + normal * lateral
	state.velocity = tangent * player_state.speed()
	state.heading = tangent.angle()
	state.track_distance = float(sample.get("distance_along", 0.0))
	state.lateral_offset = lateral
	state.track_elevation = float(sample.get("elevation_level", 0.0))
	state.track_collision_layer = int(sample.get(
		"collision_layer", state.track_collision_layer
	))
	state.track_collision_mask = int(sample.get(
		"collision_mask", state.track_collision_mask
	))
	state.gear = player_state.gear
	state.engine_rpm = player_state.engine_rpm
	state.is_offtrack = false


func _emit_performance_proof(
		frame_times_ms: Array[float],
		process_times_ms: Array[float],
		physics_times_ms: Array[float],
		reported_fps: Array[float],
	maximum_draw_calls: int,
	maximum_objects: int,
	maximum_primitives: int,
	maximum_nearby_cars: int,
	average_nearby_cars: float,
	mobile_tier: bool
	) -> bool:
	if frame_times_ms.is_empty():
		push_error("RENDER_PERFORMANCE_PROOF collected no post-warmup samples")
		return false
	var average_frame_ms := _average(frame_times_ms)
	var p95_frame_ms := _percentile(frame_times_ms, 0.95)
	var p99_frame_ms := _percentile(frame_times_ms, 0.99)
	var maximum_frame_ms := _maximum(frame_times_ms)
	var average_fps := _average(reported_fps)
	var average_process_ms := _average(process_times_ms)
	var average_physics_ms := _average(physics_times_ms)
	print((
		"RENDER_PERFORMANCE_PROOF tier=%s samples=%d avg_fps=%.1f avg_frame_ms=%.2f " \
		+ "p95_frame_ms=%.2f p99_frame_ms=%.2f max_frame_ms=%.2f " \
		+ "avg_process_ms=%.2f avg_physics_ms=%.2f " \
		+ "max_draw_calls=%d max_objects=%d max_primitives=%d " \
		+ "nearby_30m_max=%d nearby_30m_avg=%.2f"
	) % [
		"mobile_low" if mobile_tier else "standard",
		frame_times_ms.size(),
		average_fps,
		average_frame_ms,
		p95_frame_ms,
		p99_frame_ms,
		maximum_frame_ms,
		average_process_ms,
		average_physics_ms,
		maximum_draw_calls,
		maximum_objects,
		maximum_primitives,
		maximum_nearby_cars,
		average_nearby_cars,
	])
	var passed := true
	if maximum_nearby_cars < 11 or average_nearby_cars < 10.5:
		push_error(
			"RENDER_PERFORMANCE_PROOF did not exercise a dense nearby-car pack"
		)
		passed = false
	var draw_cap := MOBILE_MAX_DRAW_CALLS if mobile_tier else STANDARD_MAX_DRAW_CALLS
	var object_cap := MOBILE_MAX_RENDER_OBJECTS \
			if mobile_tier else STANDARD_MAX_RENDER_OBJECTS
	var primitive_cap := MOBILE_MAX_PRIMITIVES \
			if mobile_tier else STANDARD_MAX_PRIMITIVES
	if maximum_draw_calls > draw_cap or maximum_objects > object_cap \
			or maximum_primitives > primitive_cap:
		push_error((
			"RENDER_PERFORMANCE_PROOF exceeded %s scene cap: " \
			+ "draws=%d/%d objects=%d/%d primitives=%d/%d"
		) % [
			"mobile" if mobile_tier else "standard",
			maximum_draw_calls, draw_cap,
			maximum_objects, object_cap,
			maximum_primitives, primitive_cap,
		])
		passed = false
	if average_fps < PERFORMANCE_TARGET_FPS \
			or p95_frame_ms > PERFORMANCE_MAX_P95_FRAME_MS \
			or p99_frame_ms > PERFORMANCE_MAX_P99_FRAME_MS \
			or maximum_frame_ms > PERFORMANCE_MAX_FRAME_MS:
		push_error((
			"RENDER_PERFORMANCE_PROOF missed target: avg_fps=%.1f " \
			+ "p95_frame_ms=%.2f p99_frame_ms=%.2f max_frame_ms=%.2f"
		) % [average_fps, p95_frame_ms, p99_frame_ms, maximum_frame_ms])
		passed = false
	return passed


static func _average(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


static func _percentile(values: Array[float], percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var ordered := values.duplicate()
	ordered.sort()
	var index := clampi(
		ceili(clampf(percentile, 0.0, 1.0) * float(ordered.size())) - 1,
		0,
		ordered.size() - 1
	)
	return ordered[index]


static func _maximum(values: Array[float]) -> float:
	var maximum := 0.0
	for value in values:
		maximum = maxf(maximum, value)
	return maximum
