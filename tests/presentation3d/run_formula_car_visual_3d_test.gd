extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const FormulaCarVisualType := preload("res://game/presentation3d/formula_car_visual_3d.gd")
const VehicleStateType := preload("res://game/race/vehicle_state.gd")
const RaceInputType := preload("res://game/race/race_input.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	var off_tree_visual := FormulaCarVisualType.new()
	off_tree_visual.configure(Color("42d7aa"), false)
	test.assert_true(
		off_tree_visual.cockpit_socket() != null,
		"configure builds the cockpit contract before the visual enters a live tree"
	)
	test.assert_true(
		off_tree_visual.chase_target_socket() != null,
		"configure builds the chase contract before the visual enters a live tree"
	)
	var remote_lod: Dictionary = off_tree_visual.presentation_snapshot()
	print("REMOTE_FORMULA_LOD nodes=%d meshes=%d labels=%d triangles=%d imported=%d wheels=%d details=%d" % [
		int(remote_lod.get("presentation_node_count", -1)),
		int(remote_lod.get("mesh_instance_count", -1)),
		int(remote_lod.get("label_3d_count", -1)),
		int(remote_lod.get("triangle_count", -1)),
		int(remote_lod.get("imported_body_meshes", -1)),
		int(remote_lod.get("wheel_count", -1)),
		int(remote_lod.get("cockpit_detail_count", -1)),
	])
	test.assert_equal(
		str(remote_lod.get("lod_tier", "")), "remote_exterior",
		"non-player configure selects the explicit remote exterior tier before build"
	)
	test.assert_equal(
		int(remote_lod.get("visible_gloved_hand_count", -1)), 0,
		"remote exterior tier does not duplicate player-only hand rigs"
	)
	test.assert_equal(
		int(remote_lod.get("cockpit_control_count", -1)), 0,
		"remote exterior tier does not duplicate dashboard controls or LEDs"
	)
	test.assert_equal(
		int(remote_lod.get("cockpit_detail_count", -1)), 0,
		"remote exterior tier omits all registered premium cockpit detail"
	)
	test.assert_equal(
		int(remote_lod.get("label_3d_count", -1)), 0,
		"remote exterior tier contains no per-car Label3D draw"
	)
	test.assert_equal(
		int(remote_lod.get("wheel_count", 0)), 4,
		"remote exterior retains four independent steer/spin wheel pivots"
	)
	test.assert_true(
		int(remote_lod.get("imported_body_meshes", 0)) >= 1,
		"remote exterior retains the premium imported Formula shell"
	)
	test.assert_true(
		int(remote_lod.get("mesh_instance_count", 999)) <= 10,
		"remote Formula batching stays inside the ten-draw mesh ceiling"
	)
	test.assert_true(
		int(remote_lod.get("presentation_node_count", 999)) <= 32,
		"remote Formula graph stays inside the bounded thirty-two-node ceiling"
	)
	test.assert_true(
		int(remote_lod.get("triangle_count", 999_999)) <= 10_000,
		"remote premium silhouette stays inside the ten-thousand-triangle mobile cap"
	)
	test.assert_equal(
		int(remote_lod.get("remote_batched_body_draws", 0)), 1,
		"all authored remote body surfaces are submitted as one batched draw"
	)
	test.assert_equal(
		int(remote_lod.get("remote_batched_wheel_draws", 0)), 1,
		"four remote slicks share one batched draw"
	)
	test.assert_equal(
		int(remote_lod.get("remote_wheel_batch_instances", 0)), 4,
		"wheel batch retains one independently transformed instance per wheel"
	)
	var desktop_budget_apply_count := int(
		remote_lod.get("remote_render_budget_apply_count", -1)
	)
	off_tree_visual.configure_remote_render_budget(true)
	var mobile_lod: Dictionary = off_tree_visual.presentation_snapshot()
	test.assert_true(
		bool(mobile_lod.get("remote_mobile_budget", false)),
		"mobile render profile is explicit on remote cars"
	)
	test.assert_equal(
		int(mobile_lod.get("remote_shadow_caster_count", -1)), 0,
		"mobile remote tier multiplies no directional-shadow casters across the pack"
	)
	test.assert_true(
		int(mobile_lod.get("remote_bounded_detail_count", 0)) >= 4
				and float(mobile_lod.get("remote_max_detail_range", 999.0))
						<= 42.01,
		"small remote details remain near-visible and are camera-culled beyond 42 m"
	)
	test.assert_equal(
		int(mobile_lod.get("remote_unbounded_core_count", 0)), 2,
		"batched body and independently animated wheel silhouettes remain unbounded"
	)
	var mobile_budget_apply_count := int(
		mobile_lod.get("remote_render_budget_apply_count", -1)
	)
	test.assert_equal(
		mobile_budget_apply_count, desktop_budget_apply_count + 1,
		"changing render tier performs exactly one bounded configuration pass"
	)
	for _frame in 120:
		off_tree_visual.apply_vehicle_state(
			{"velocity": Vector2(80.0, 0.0), "steering_input": 0.35},
			null,
			1.0 / 60.0
		)
	test.assert_equal(
		int(off_tree_visual.presentation_snapshot().get(
			"remote_render_budget_apply_count", -1
		)),
		mobile_budget_apply_count,
		"per-frame vehicle animation performs no LOD rebuild or budget allocation"
	)
	off_tree_visual.free()
	var visual := FormulaCarVisualType.new()
	root.add_child(visual)
	await process_frame
	var configured_color := Color("ff335d")
	visual.configure(configured_color, true)
	var initial: Dictionary = visual.presentation_snapshot()
	print("PLAYER_FORMULA_LOD nodes=%d meshes=%d labels=%d details=%d controls=%d hands=%d" % [
		int(initial.get("presentation_node_count", -1)),
		int(initial.get("mesh_instance_count", -1)),
		int(initial.get("label_3d_count", -1)),
		int(initial.get("cockpit_detail_count", -1)),
		int(initial.get("cockpit_control_count", -1)),
		int(initial.get("visible_gloved_hand_count", -1)),
	])
	test.assert_equal(
		str(initial.get("lod_tier", "")), "player_cockpit",
		"direct/player build retains the complete premium cockpit tier"
	)
	test.assert_true(bool(initial.get("built", false)), "Formula visual builds after entering the scene tree")
	test.assert_equal(
		str(initial.get("base_model_path", "")),
		"res://assets/final/3d/vehicles/formula_car_premium_original.glb",
		"Formula visual uses the project-original premium body contract"
	)
	test.assert_true(
		int(initial.get("imported_body_meshes", 0)) >= 1,
		"generated premium body is part of the rendered Formula assembly"
	)
	test.assert_equal(int(initial.get("wheel_count", 0)), 4, "four independent slick wheel pivots are built")
	test.assert_true(bool(initial.get("cockpit_socket", false)), "cockpit camera socket is available")
	test.assert_true(bool(initial.get("chase_socket", false)), "chase camera socket is available")
	test.assert_true(bool(initial.get("is_player", false)), "configure records the player presentation role")
	test.assert_equal(initial.get("team_color"), configured_color, "team material accepts an opaque livery color")
	test.assert_equal(
		int(initial.get("visible_gloved_hand_count", 0)), 2,
		"cockpit contains exactly two semantic visible gloved-hand rigs"
	)
	test.assert_true(
		bool(initial.get("hands_parented_to_yoke", false)),
		"both hands are rigid children of the steering yoke"
	)
	test.assert_true(
		bool(initial.get("hands_clear_cockpit_floor", false))
				and bool(initial.get("sleeves_clear_cockpit_floor", false)),
		"centered gloves, cuffs and sleeves remain above the monocoque clearance plane"
	)
	test.assert_true(
		int(initial.get("cockpit_control_count", 0)) >= 24,
		"styled yoke carries a dense bank of fictional controls, encoders, labels and LEDs"
	)
	test.assert_true(
		int(initial.get("cockpit_detail_count", 0)) >= 80,
		"cockpit surround, yoke and driver rigs replace the former plain presentation"
	)
	test.assert_equal(
		int(initial.get("visible_cockpit_detail_count", -1)),
		int(initial.get("cockpit_detail_count", -2)),
		"the complete registered cockpit graph starts visible in direct review mode"
	)
	var structural_node_count := int(initial.get("presentation_node_count", -1))
	visual.set_cockpit_detail_visible(false)
	var chase_lod: Dictionary = visual.presentation_snapshot()
	test.assert_true(
		not bool(chase_lod.get("cockpit_detail_visible", true))
				and int(chase_lod.get("visible_cockpit_detail_count", -1)) == 0,
		"chase mode can synchronously cull every player-only cockpit detail"
	)
	test.assert_equal(
		int(chase_lod.get("presentation_node_count", -2)), structural_node_count,
		"chase culling changes visibility without rebuilding the Formula graph"
	)
	test.assert_equal(
		int(chase_lod.get("visible_gloved_hand_count", 0)), 2,
		"chase culling preserves both semantic hand rigs for instant restoration"
	)
	visual.set_cockpit_detail_visible(true)
	var restored_cockpit: Dictionary = visual.presentation_snapshot()
	test.assert_equal(
		int(restored_cockpit.get("visible_cockpit_detail_count", -1)),
		int(restored_cockpit.get("cockpit_detail_count", -2)),
		"cockpit toggle restores the complete detail set synchronously"
	)
	test.assert_equal(
		int(restored_cockpit.get("cockpit_visibility_apply_count", -1)), 2,
		"one chase and one cockpit transition each apply visibility exactly once"
	)
	test.assert_equal(
		int(initial.get("cockpit_wet_fx_count", -1)), 0,
		"dry cockpit view contains no raindrop or wet-screen effect"
	)
	test.assert_true(
		visual.cockpit_socket().basis.x.dot(Vector3.RIGHT) > 0.999,
		"cockpit socket preserves the shared local +X forward basis"
	)
	test.assert_true(
		visual.chase_target_socket().basis.x.dot(Vector3.RIGHT) > 0.999,
		"chase socket preserves the shared local +X forward basis"
	)
	var resting_cockpit_socket := visual.cockpit_socket().global_transform
	var resting_chase_socket := visual.chase_target_socket().global_transform

	var state := VehicleStateType.new()
	state.velocity = Vector2(200.0, 0.0)
	state.steering_input = 0.82
	state.lateral_acceleration = 95.0
	state.wheel_slip = 0.55
	state.engine_rpm = 14_400.0
	state.gear = 7
	var command := RaceInputType.new(0.82, 0.35, 0.62)
	for _frame in 12:
		visual.apply_vehicle_state(state, command, 1.0 / 60.0)
	var animated: Dictionary = visual.presentation_snapshot()
	test.assert_near(
		visual.cockpit_socket().global_position.distance_to(
			resting_cockpit_socket.origin
		),
		0.0, 0.000001,
		"cockpit camera mount ignores speed, braking and suspension heave"
	)
	test.assert_near(
		visual.chase_target_socket().global_position.distance_to(
			resting_chase_socket.origin
		),
		0.0, 0.000001,
		"chase camera mount ignores speed, braking and suspension heave"
	)
	test.assert_true(
		visual.cockpit_socket().global_basis.x.dot(resting_cockpit_socket.basis.x)
				> 0.999999,
		"cockpit camera mount ignores presentation-only body pitch"
	)
	test.assert_true(
		visual.chase_target_socket().global_basis.x.dot(resting_chase_socket.basis.x)
				> 0.999999,
		"chase camera mount ignores presentation-only body pitch"
	)
	test.assert_true(
		absf(float(animated.get("front_steer_radians", 0.0))) > deg_to_rad(10.0),
		"front axle visibly follows authoritative steering"
	)
	test.assert_true(
		float(animated.get("front_steer_radians", 0.0)) < 0.0
				and float(animated.get("steering_wheel_radians", 0.0)) > 0.0,
		"positive/right authority turns front tyres toward local +Z and rolls the yoke clockwise"
	)
	test.assert_true(
		bool(animated.get("front_turns_toward_local_positive_z", false))
				and bool(animated.get("yoke_turns_clockwise_for_positive_input", false)),
		"positive/right tyre and yoke bases agree with the mapped vehicle turn"
	)
	test.assert_true(
		absf(float(animated.get("front_steer_radians", 0.0))) <= deg_to_rad(22.01),
		"front steering stays inside the authored Formula rack limit"
	)
	test.assert_true(
		absf(float(animated.get("steering_wheel_radians", 0.0))) > deg_to_rad(60.0),
		"cockpit wheel and hands visibly rotate with steering"
	)
	test.assert_true(
		absf(float(animated.get("steering_wheel_radians", 0.0))) <= deg_to_rad(170.01),
		"cockpit steering stays within a bounded physical range"
	)
	test.assert_true(
		absf(float(animated.get("wheel_spin_radians", 0.0))) > 0.01,
		"vehicle speed drives visible slick rotation"
	)
	test.assert_true(
		absf(float(animated.get("body_roll_radians", 0.0))) <= deg_to_rad(3.21),
		"lateral-load body roll remains bounded"
	)
	test.assert_true(
		absf(float(animated.get("body_pitch_radians", 0.0))) <= deg_to_rad(1.81),
		"braking pitch remains bounded"
	)
	test.assert_true(
		absf(float(animated.get("body_heave_meters", 0.0))) <= 0.046,
		"aero and pedal heave remain within suspension travel"
	)
	test.assert_true(int(animated.get("active_shift_leds", 0)) >= 8, "high RPM illuminates the shift-light bank")
	test.assert_true(
		str(animated.get("dashboard_text", "")).begins_with("7"),
		"cockpit dashboard displays authoritative gear and RPM"
	)
	test.assert_true(
		float(animated.get("rain_light_energy", 0.0)) > 1.0,
		"braking or slip makes the rear rain light conspicuous"
	)

	state.steering_input = -0.82
	visual.apply_vehicle_state(state, RaceInputType.new(-0.82, 0.35, 0.0), 0.0)
	var left_turn: Dictionary = visual.presentation_snapshot()
	test.assert_true(
		float(left_turn.get("front_steer_radians", 0.0)) > 0.0
				and float(left_turn.get("steering_wheel_radians", 0.0)) < 0.0,
		"negative/left authority reverses both tyre and yoke signs together"
	)
	test.assert_true(
		not bool(left_turn.get("front_turns_toward_local_positive_z", true))
				and not bool(left_turn.get("yoke_turns_clockwise_for_positive_input", true)),
		"left tyre and yoke bases both reverse from the right-turn semantic"
	)
	state.steering_input = 0.82
	visual.apply_vehicle_state(state, command, 0.0)
	for steering_lock in [-1.0, 1.0]:
		state.steering_input = steering_lock
		visual.apply_vehicle_state(
			state, RaceInputType.new(steering_lock, 0.2, 0.0), 0.0
		)
		var lock_snapshot: Dictionary = visual.presentation_snapshot()
		print("COCKPIT_HAND_CLEARANCE steer=%+.1f hand_y=%.4f sleeve_y=%.4f floor=%.4f" % [
			steering_lock,
			float(lock_snapshot.get("minimum_hand_body_y", -99.0)),
			float(lock_snapshot.get("minimum_sleeve_body_y", -99.0)),
			float(lock_snapshot.get("cockpit_hand_clearance_floor_y", 99.0)),
		])
		test.assert_true(
			bool(lock_snapshot.get("hands_clear_cockpit_floor", false))
					and bool(lock_snapshot.get("sleeves_clear_cockpit_floor", false)),
			"both hand rigs and flexible sleeves clear the chassis at steering lock %+.1f" \
					% steering_lock
		)
	state.steering_input = 0.82
	visual.apply_vehicle_state(state, command, 0.0)

	visual.apply_vehicle_state(
		{
			"velocity": Vector2(INF, NAN),
			"steering_input": INF,
			"lateral_acceleration": NAN,
			"engine_rpm": INF,
			"gear": 99,
		},
		{"steer": NAN, "throttle": INF, "brake": NAN},
		INF
	)
	var malformed: Dictionary = visual.presentation_snapshot()
	test.assert_true(
		absf(float(malformed.get("front_steer_radians", 0.0))) <= deg_to_rad(22.01),
		"malformed presentation telemetry cannot exceed steering bounds"
	)
	test.assert_true(
		absf(float(malformed.get("body_roll_radians", 0.0))) <= deg_to_rad(3.21),
		"malformed telemetry cannot make the chassis transform non-physical"
	)
	var review_mode := _review_mode()
	if not review_mode.is_empty():
		var review_state := state.duplicate_state()
		review_state.steering_input = 0.03
		if review_mode == &"front-right":
			review_state.steering_input = 0.72
		elif review_mode == &"front-left":
			review_state.steering_input = -0.72
		elif review_mode == &"cockpit-right":
			review_state.steering_input = 1.0
		elif review_mode == &"cockpit-left":
			review_state.steering_input = -1.0
		review_state.lateral_acceleration = 24.0
		review_state.wheel_slip = 0.08
		review_state.engine_rpm = 12_800.0
		review_state.gear = 5
		var review_command := RaceInputType.new(
			review_state.steering_input, 0.78, 0.0
		)
		for _review_frame in 8:
			visual.apply_vehicle_state(review_state, review_command, 1.0 / 60.0)
		_build_capture_stage(visual, review_mode)
		for _frame in 24:
			await process_frame

	root.remove_child(visual)
	visual.free()
	await process_frame
	var result: Dictionary = test.result("formula_car_visual_3d")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _review_mode() -> StringName:
	for argument in OS.get_cmdline_user_args():
		if argument == "--review":
			return &"chase"
		if argument == "--review=cockpit":
			return &"cockpit"
		if argument == "--review=cockpit-right":
			return &"cockpit-right"
		if argument == "--review=cockpit-left":
			return &"cockpit-left"
		if argument == "--review=cockpit-procedural":
			return &"cockpit-procedural"
		if argument == "--review=front":
			return &"front"
		if argument == "--review=front-right":
			return &"front-right"
		if argument == "--review=front-left":
			return &"front-left"
	return &""


func _build_capture_stage(visual: Node3D, review_mode: StringName) -> void:
	root.size = Vector2i(1280, 720)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("78bff2")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d8edff")
	environment.ambient_light_energy = 0.72
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	root.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color("fff4dc")
	sun.light_energy = 2.1
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	root.add_child(sun)
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(30.0, 30.0)
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("273139")
	ground_material.roughness = 0.86
	ground_mesh.material = ground_material
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	ground.position.y = 0.02
	root.add_child(ground)
	var camera := Camera3D.new()
	camera.name = "ReviewCamera"
	camera.fov = 58.0
	camera.near = 0.04
	if str(review_mode).begins_with("front"):
		camera.fov = 46.0
		root.add_child(camera)
		camera.look_at_from_position(Vector3(3.85, 1.55, 2.85), Vector3(0.05, 0.55, 0.0))
	elif review_mode in [
		&"cockpit", &"cockpit-procedural", &"cockpit-right", &"cockpit-left"
	]:
		if review_mode == &"cockpit-procedural":
			var imported := visual.get_node_or_null("BodyMotionRoot/PremiumOriginalFormulaBody")
			if imported != null:
				imported.visible = false
		visual.cockpit_socket().add_child(camera)
		camera.position = Vector3(0.12, 0.14, 0.0)
		camera.basis = Basis.looking_at(Vector3(1.0, -0.118, 0.0).normalized(), Vector3.UP)
	else:
		visual.chase_target_socket().add_child(camera)
		camera.basis = Basis.looking_at(Vector3(1.0, -0.16, 0.0).normalized(), Vector3.UP)
	camera.current = true
