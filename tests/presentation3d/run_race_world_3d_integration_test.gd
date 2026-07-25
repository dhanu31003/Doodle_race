extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const RaceWorldType := preload("res://game/presentation3d/race_world_3d.gd")
const Mapper := preload("res://game/presentation3d/world_coordinate_mapper.gd")
const Catalog := preload("res://game/content/predefined_track_catalog.gd")
const Compiler := preload("res://game/track/generation/track_compiler.gd")
const TrackQuery := preload("res://game/race/track_query.gd")
const RaceEntryType := preload("res://game/race/race_entry.gd")
const VehicleStateType := preload("res://game/race/vehicle_state.gd")
const RaceInputType := preload("res://game/race/race_input.gd")

const CAR_COUNT := 12
const PLAYER_ID: StringName = &"car_00"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	var fixture := _compiled_query("builtin-evergreen-oval")
	test.assert_true(bool(fixture.get("valid", false)), "true-world fixture compiles a built-in circuit")
	if bool(fixture.get("valid", false)):
		await _test_true_world_contract(test, fixture["query"] as RaceTrackQuery)
	await process_frame
	var result: Dictionary = test.result("race_world_3d_integration")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _test_true_world_contract(test: RefCounted, query: RaceTrackQuery) -> void:
	root.size = Vector2i(960, 540)
	var centerline_before := query.centerline.duplicate()
	var total_length_before := query.total_length
	var world := RaceWorldType.new()
	world.name = "RaceWorld3DIntegrationFixture"
	world.size = Vector2(960.0, 540.0)
	root.add_child(world)
	await process_frame
	var capable_desktop_default := world.debug_snapshot()
	if not bool(capable_desktop_default.get("mobile_device_profile", true)):
		test.assert_true(
			not bool(capable_desktop_default.get("mobile_render_budget", true))
					and int(capable_desktop_default.get("viewport_stretch_shrink", 0)) == 1
					and int(capable_desktop_default.get("viewport_msaa_3d", -1))
							== Viewport.MSAA_2X,
			"capable desktop default retains native 3D resolution and 2x MSAA"
		)
	world.configure(query, RaceWorldType.CAMERA_CHASE, Color("18d8a0"))
	await process_frame
	var pre_low_graphics := world.debug_snapshot()
	world.configure_accessibility(true, true, false, 0.0)
	await process_frame

	var configured := world.debug_snapshot()
	if not bool(pre_low_graphics.get("mobile_device_profile", true)):
		test.assert_true(
			float(pre_low_graphics.get("track_stats", {}).get(
				"sample_step_authority", 99.0
			)) < float(configured.get("track_stats", {}).get(
				"sample_step_authority", 0.0
			)),
			"switching Low Graphics rebuilds an existing track at mobile tessellation"
		)
	var viewport := world.debug_viewport()
	var camera := world.debug_camera()
	var environment := world.debug_environment()
	test.assert_true(
		bool(configured.get("viewport_present", false)) and viewport is SubViewport,
		"RaceWorld3D owns a real SubViewport"
	)
	test.assert_true(
		viewport != null and viewport.own_world_3d,
		"race viewport requests an isolated three-dimensional World3D"
	)
	test.assert_true(
		bool(configured.get("camera_present", false)) and camera is Camera3D,
		"RaceWorld3D owns a real Camera3D"
	)
	test.assert_true(camera != null and camera.current, "race Camera3D is current inside its viewport")
	test.assert_true(
		bool(configured.get("environment_present", false)) and environment is Environment,
		"RaceWorld3D owns a daylight Environment"
	)
	test.assert_true(
		environment != null and environment.sky != null,
		"daylight environment has an HDRI or procedural sky fallback"
	)
	test.assert_true(
		bool(configured.get("directional_sun_present", false)),
		"daylight world includes a directional sun"
	)
	test.assert_true(
		float(configured.get("ambient_light_energy", 0.0)) >= 0.42
				and float(configured.get("ambient_light_energy", 1.0)) <= 0.60
				and float(configured.get("background_energy_multiplier", 0.0)) >= 0.62
				and float(configured.get("background_energy_multiplier", 1.0)) <= 0.82
				and float(configured.get("tonemap_exposure", 0.0)) >= 0.78
				and float(configured.get("tonemap_exposure", 1.0)) <= 0.92
				and float(configured.get("adjustment_brightness", 0.0)) >= 0.94
				and float(configured.get("adjustment_brightness", 2.0)) <= 1.01
				and float(configured.get("sun_light_energy", 0.0)) >= 0.95
				and float(configured.get("sun_light_energy", 2.0)) <= 1.15
				and bool(configured.get("adjustment_enabled", false)),
		"daylight grade stays visibly daytime without the previous stacked washout"
	)
	test.assert_true(
		bool(configured.get("mobile_render_budget", false)),
		"Low Graphics activates the same bounded remote-car budget used on mobile"
	)
	test.assert_equal(
		int(configured.get("viewport_stretch_shrink", 0)), 2,
		"mobile low tier halves only the 3D viewport render dimensions"
	)
	test.assert_equal(
		int(configured.get("viewport_msaa_3d", -1)), Viewport.MSAA_DISABLED,
		"mobile low tier removes costly multisample antialiasing"
	)
	test.assert_equal(
		int(configured.get("viewport_screen_space_aa", -1)),
		Viewport.SCREEN_SPACE_AA_DISABLED,
		"mobile low tier avoids stacking a second antialiasing pass"
	)
	test.assert_true(
		float(configured.get("sun_shadow_max_distance", 999.0)) <= 145.01
				and not bool(configured.get("fog_enabled", true)),
		"mobile low tier bounds directional shadows and disables full-screen fog"
	)

	var initial_track_transform: Transform3D = world.debug_track_root().transform
	var initial_scenery_transform: Transform3D = world.debug_scenery_root().transform
	test.assert_equal(
		initial_track_transform, Transform3D.IDENTITY,
		"track root starts at fixed world identity"
	)
	test.assert_equal(
		initial_scenery_transform, Transform3D.IDENTITY,
		"scenery root starts at fixed world identity"
	)
	test.assert_true(
		bool(configured.get("fixed_world_invariant", false)),
		"configured world reports the fixed-world invariant"
	)
	var scenery_clearance: Dictionary = configured.get("scenery_clearance", {})
	var scenery_violations: Array = scenery_clearance.get("violations", [])
	var first_scenery_violation: Dictionary = scenery_violations[0] \
			if not scenery_violations.is_empty() else {}
	test.assert_true(
		bool(scenery_clearance.get("valid", false))
				and int(scenery_clearance.get("prop_count", 0)) > 0
				and float(scenery_clearance.get("minimum_clearance_meters", -1.0)) >= 0.5,
		"every fixed trackside prop clears the complete runoff envelope by at least 0.5m (valid=%s props=%d minimum=%.3f first=%s:%s:%.3f violations=%d)" % [
			str(scenery_clearance.get("valid", false)),
			int(scenery_clearance.get("prop_count", 0)),
			float(scenery_clearance.get("minimum_clearance_meters", -1.0)),
			str(first_scenery_violation.get("kind", "none")),
			str(first_scenery_violation.get("name", "none")),
			float(first_scenery_violation.get("clearance_meters", 0.0)),
			scenery_violations.size(),
		]
	)
	var scenery_counts: Dictionary = scenery_clearance.get("counts_by_kind", {})
	var scenery_stats: Dictionary = scenery_clearance.get("presentation_stats", {})
	test.assert_true(
		int(scenery_counts.get("safety_barrier", 0)) >= 96
				and int(scenery_counts.get("catch_fence", 0)) >= 72,
		"mobile scenery tier keeps continuous two-sided barrier and catch-fence bands"
	)
	test.assert_true(
		int(scenery_counts.get("tree", 0)) >= 34
				and int(scenery_counts.get("bush", 0)) >= 18
				and int(scenery_counts.get("fictional_billboard", 0)) >= 18,
		"mobile scenery tier keeps vegetation and large original billboard layers"
	)
	test.assert_true(
		int(scenery_counts.get("grandstand", 0)) >= 4
				and int(scenery_counts.get("spectator_terrace", 0)) >= 3
				and int(scenery_counts.get("trackside_spectator", 0)) >= 48
				and int(scenery_counts.get("grandstand_spectator", 0)) >= 96
				and int(scenery_stats.get("crowd_instances", 0)) >= 160
				and float(scenery_stats.get(
					"minimum_spectator_top_meters", 0.0
				)) >= 2.85,
		"mobile scenery grounds a fence-visible audience on stands and viewing terraces"
	)
	test.assert_true(
		int(scenery_stats.get("billboard_batches", 99)) <= 4
				and int(scenery_stats.get("grandstand_batches", 99)) <= 6
				and int(scenery_stats.get("crowd_batches", 99)) <= 4
				and int(scenery_stats.get("terrace_batches", 99)) <= 4
				and int(scenery_stats.get("crowd_triangles", 99_999)) <= 12_000
				and int(scenery_stats.get("terrace_triangles", 99_999)) <= 1_000
				and int(scenery_stats.get("crowd_shadow_casters", 1)) == 0
				and int(scenery_stats.get("billboard_shadow_casters", 1)) == 0
				and int(scenery_stats.get("terrace_shadow_casters", 1)) == 0,
		"mobile venue uses bounded shadow-free billboard and crowd batches"
	)
	test.assert_true(
		int(scenery_stats.get("tree_instances", 0)) == 34
				and int(scenery_stats.get("bush_instances", 0)) == 18
				and int(scenery_stats.get("tree_batches", 99)) <= 8
				and int(scenery_stats.get("bush_batches", 99)) <= 4
				and int(scenery_stats.get("vegetation_render_nodes", 99)) <= 12,
		"mobile vegetation preserves density in no more than twelve spatial batches"
	)
	test.assert_true(
		int(scenery_clearance.get("collision_object_count", 1)) == 0
				and int(scenery_clearance.get("animation_player_count", 1)) == 0
				and int(scenery_clearance.get("skeleton_count", 1)) == 0,
		"trackside life adds no colliders, skeletons, or per-object animation graphs"
	)
	var first_layout_hash := str(scenery_clearance.get("layout_hash", ""))
	world.configure(query, RaceWorldType.CAMERA_CHASE, Color("18d8a0"))
	await process_frame
	configured = world.debug_snapshot()
	test.assert_true(
		not first_layout_hash.is_empty()
				and str(configured.get("scenery_clearance", {}).get(
					"layout_hash", ""
				)) == first_layout_hash,
		"rebuilding the same verified track produces an identical venue layout"
	)
	test.assert_true(
		int(configured.get("track_stats", {}).get("surface_count", 0)) == 4,
		"true world contains the complete four-surface circuit mesh"
	)
	var mobile_track_stats: Dictionary = configured.get("track_stats", {})
	test.assert_true(
		float(mobile_track_stats.get("sample_step_authority", 0.0)) >= 9.99
				and int(mobile_track_stats.get("segment_count", 9999)) <= 500
				and int(mobile_track_stats.get("triangles", 999_999)) <= 6_000,
		"long mobile circuit uses the coarser bounded mesh tier without dropping surfaces"
	)

	var entries := _make_grid(query)
	var player: RaceEntry = entries[0]
	var command := RaceInputType.new(0.24, 0.86, 0.0)
	command.source_mask = RaceInputType.SOURCE_KEYBOARD
	var authority_before := _authority_snapshot(entries, command)
	world.update_race(player, entries, command, 1.0)
	var authority_after := _authority_snapshot(entries, command)
	var populated := world.debug_snapshot()
	test.assert_equal(
		authority_after, authority_before,
		"presentation does not mutate vehicle states, previous states, or player input"
	)
	test.assert_equal(
		int(populated.get("vehicle_count", 0)), CAR_COUNT,
		"RaceWorld3D presents the full twelve-car race capacity"
	)
	var lod_counts: Dictionary = populated.get("cockpit_lod_counts", {})
	test.assert_equal(
		int(lod_counts.get("player_cockpit", 0)), 1,
		"twelve-car world assigns the rich cockpit to exactly one player car"
	)
	test.assert_equal(
		int(lod_counts.get("remote_exterior", 0)), CAR_COUNT - 1,
		"every non-player car uses the bounded remote exterior tier"
	)
	test.assert_true(
		not bool(populated.get("player_cockpit_detail_visible", true))
				and int(populated.get("player_visible_cockpit_details", -1)) == 0,
		"chase camera culls player-only cockpit micro-detail from the mobile render set"
	)
	var chase_visibility_apply_count := int(
		populated.get("player_cockpit_visibility_apply_count", -1)
	)
	test.assert_true(
		int(populated.get("maximum_remote_meshes", 999)) <= 10
				and int(populated.get("maximum_remote_nodes", 999)) <= 32,
		"all eleven remote Formula graphs remain under their mesh/node ceilings"
	)
	test.assert_true(
		int(populated.get("maximum_remote_triangles", 999_999)) <= 10_000,
		"each remote car remains inside the mobile primitive budget"
	)
	test.assert_equal(
		int(populated.get("maximum_remote_shadow_casters", -1)), 0,
		"eleven-car mobile field adds no repeated remote shadow casters"
	)
	test.assert_true(
		int(populated.get("minimum_remote_bounded_details", 0)) >= 4,
		"every opponent keeps near-readable details with distance culling"
	)
	test.assert_equal(
		int(populated.get("remote_wheel_batch_instances", 0)),
		(CAR_COUNT - 1) * 4,
		"remote field batches all forty-four independently animated wheel instances"
	)
	var render_budget_apply_count := int(
		populated.get("vehicle_render_budget_apply_count", -1)
	)
	var static_world_rebuild_count := int(
		populated.get("static_world_rebuild_count", -1)
	)
	test.assert_equal(
		render_budget_apply_count, CAR_COUNT - 1,
		"each remote receives one render-budget configuration when it is created"
	)
	for _frame in 120:
		world.update_race(player, entries, command, 1.0)
	test.assert_equal(
		int(world.debug_snapshot().get("vehicle_render_budget_apply_count", -1)),
		render_budget_apply_count,
		"steady-state race updates never rebuild or reallocate opponent LODs"
	)
	test.assert_equal(
		int(world.debug_snapshot().get("static_world_rebuild_count", -1)),
		static_world_rebuild_count,
		"steady-state race updates never rebuild track, terrain, or scenery"
	)
	test.assert_equal(
		int(populated.get("vehicle_world_transforms", {}).size()), CAR_COUNT,
		"debug contract exposes all twelve independent car transforms"
	)
	test.assert_true(
		bool(populated.get("has_race_authority", false)),
		"world recognizes the supplied player authority"
	)
	var initial_sparks: Dictionary = populated.get("collision_sparks", {})
	test.assert_equal(
		int(initial_sparks.get("pool_size", 0)), 6,
		"true world owns the fixed-capacity contact-spark pool"
	)
	test.assert_equal(
		int(initial_sparks.get("accepted_bursts", -1)), 0,
		"ordinary race population cannot infer phantom collision sparks from proximity"
	)
	var expected_initial := _state_world_transform(player.state)
	var initial_player_transform: Transform3D = populated["player_world_transform"]
	test.assert_near(
		initial_player_transform.origin.distance_to(expected_initial.origin),
		0.0, 0.0001,
		"player visual begins exactly at the mapped authoritative transform"
	)
	var camera_before_motion: Transform3D = populated["camera_world_transform"]

	player.previous_state = player.state.duplicate_state()
	player.state = _vehicle_state_at(query, 90.0, PLAYER_ID)
	var moved_authority_before := _authority_snapshot(entries, command)
	world.update_race(player, entries, command, 1.0)
	var moved := world.debug_snapshot()
	test.assert_equal(
		_authority_snapshot(entries, command), moved_authority_before,
		"normal presentation update leaves advanced authority untouched"
	)
	var moved_player_transform: Transform3D = moved["player_world_transform"]
	test.assert_true(
		moved_player_transform.origin.distance_to(initial_player_transform.origin) > 5.0,
		"player visual advances when authoritative VehicleState advances"
	)
	test.assert_near(
		moved_player_transform.origin.distance_to(_state_world_transform(player.state).origin),
		0.0, 0.0001,
		"advanced player visual remains on the authoritative world coordinate"
	)
	test.assert_equal(
		world.debug_vehicle_transform(PLAYER_ID), moved_player_transform,
		"per-vehicle debug accessor agrees with the player world snapshot"
	)
	var grounded_state := player.state.duplicate_state()
	player.previous_state = grounded_state.duplicate_state()
	player.state = grounded_state.duplicate_state()
	player.state.vertical_offset_meters = 0.6
	player.state.vertical_velocity_mps = -1.0
	player.state.is_grounded = false
	world.update_race(player, entries, command, 0.5)
	var airborne_transform := world.debug_vehicle_transform(PLAYER_ID)
	test.assert_near(
		airborne_transform.origin.y,
		moved_player_transform.origin.y + 0.3,
		0.0001,
		"true-world interpolation applies half of the authoritative airborne offset"
	)
	player.state = grounded_state
	player.previous_state = grounded_state.duplicate_state()
	world.update_race(player, entries, command, 1.0)
	for _frame in 10:
		await process_frame
	var camera_after_motion: Transform3D = world.debug_snapshot()["camera_world_transform"]
	test.assert_true(
		camera_after_motion.origin.distance_to(camera_before_motion.origin) > 0.25,
		"camera advances after its authoritative player target advances"
	)
	test.assert_true(
		camera_after_motion.origin.distance_to(moved_player_transform.origin) < 24.0,
		"camera follows within a bounded Formula chase distance"
	)

	# The chase mount and look target must advance in one vehicle-relative frame.
	# A world-space look lerp trails farther behind at higher translation speeds
	# and pitches the camera down even though the authored mount itself is fixed.
	world.set_camera_mode(RaceWorldType.CAMERA_CHASE)
	var chase_saved_state := player.state.duplicate_state()
	var chase_saved_previous := player.previous_state.duplicate_state()
	var chase_reference_player: Transform3D = world.debug_snapshot()[
		"player_world_transform"
	]
	var chase_reference_camera := camera.global_transform
	var chase_reference_forward_local := chase_reference_player.basis.inverse() \
			* (-chase_reference_camera.basis.z)
	var chase_reference_origin_screen := camera.unproject_position(
		chase_reference_player.origin
	)
	var authority_forward := Vector2(
		cos(player.state.heading), sin(player.state.heading)
	)
	player.state = chase_saved_state.duplicate_state()
	player.state.position += authority_forward * 100.0
	player.state.velocity = authority_forward * 320.0
	player.previous_state = player.state.duplicate_state()
	world.update_race(player, entries, RaceInputType.new(0.0, 1.0, 0.0), 1.0)
	await process_frame
	var chase_advanced := world.debug_snapshot()
	var chase_advanced_player: Transform3D = chase_advanced["player_world_transform"]
	var chase_advanced_camera: Transform3D = chase_advanced["camera_world_transform"]
	var chase_advanced_forward_local := chase_advanced_player.basis.inverse() \
			* (-chase_advanced_camera.basis.z)
	var chase_advanced_origin_screen := camera.unproject_position(
		chase_advanced_player.origin
	)
	test.assert_true(
		chase_advanced_forward_local.dot(chase_reference_forward_local) > 0.999999,
		"integrated chase pitch stays invariant during a high-speed forward step"
	)
	test.assert_near(
		chase_advanced_origin_screen.distance_to(chase_reference_origin_screen),
		0.0, 0.01,
		"integrated chase framing stays fixed while speed and world position increase"
	)
	test.assert_near(
		(chase_advanced_player.affine_inverse() * chase_advanced_camera.origin).distance_to(
			chase_reference_player.affine_inverse() * chase_reference_camera.origin
		),
		0.0, 0.0001,
		"integrated chase mount keeps one vehicle-relative offset at every speed"
	)
	player.state = chase_saved_state
	player.previous_state = chase_saved_previous
	world.update_race(player, entries, command, 1.0)
	world.set_camera_mode(RaceWorldType.CAMERA_CHASE)
	await process_frame

	var chase_camera_transform := camera.global_transform
	world.set_camera_mode(RaceWorldType.CAMERA_COCKPIT)
	var cockpit := world.debug_snapshot()
	for grade_key in [
		"ambient_light_energy", "background_energy_multiplier",
		"tonemap_exposure", "adjustment_brightness",
		"adjustment_contrast", "sun_light_energy",
	]:
		test.assert_near(
			float(cockpit.get(grade_key, -1.0)),
			float(configured.get(grade_key, -2.0)), 0.000001,
			"cockpit and chase share the same daylight grade: %s" % grade_key
		)
	test.assert_equal(
		cockpit.get("camera_mode"), RaceWorldType.CAMERA_COCKPIT,
		"camera mode toggles from chase to cockpit"
	)
	test.assert_true(
		(cockpit["camera_world_transform"] as Transform3D).origin.distance_to(
			chase_camera_transform.origin
		) > 1.0,
		"cockpit toggle changes the physical Camera3D pose"
	)
	test.assert_true(
		bool(cockpit.get("player_cockpit_detail_visible", false))
				and int(cockpit.get("player_visible_cockpit_details", 0)) >= 80,
		"cockpit toggle restores the complete premium interior synchronously"
	)
	test.assert_equal(
		int(cockpit.get("player_cockpit_visibility_apply_count", -1)),
		chase_visibility_apply_count + 1,
		"cockpit transition performs one visibility pass without rebuilding the car"
	)

	# Exercise the complete VehicleState -> animated Formula visual -> authored
	# socket -> camera path at both ends of the speed range. This catches camera
	# drift that an isolated rig with a synthetic static socket cannot reproduce.
	var saved_player_state := player.state.duplicate_state()
	var saved_previous_state := player.previous_state.duplicate_state()
	player.state = saved_player_state.duplicate_state()
	player.state.velocity = Vector2.ZERO
	player.state.shift_ticks_remaining = 0
	player.previous_state = player.state.duplicate_state()
	var neutral_command := RaceInputType.new(0.0, 0.0, 0.0)
	for _frame in 24:
		world.update_race(player, entries, neutral_command, 1.0)
		await process_frame
	var cockpit_rest_transform := camera.global_transform
	var cockpit_rest_fov := camera.fov
	var player_forward := Vector3(cos(player.state.heading), 0.0, sin(player.state.heading))
	var horizon_probe := cockpit_rest_transform.origin + player_forward * 180.0
	var cockpit_rest_horizon_screen := camera.unproject_position(horizon_probe)

	player.state = saved_player_state.duplicate_state()
	player.state.velocity = Vector2(
		cos(player.state.heading), sin(player.state.heading)
	) * 320.0
	player.state.shift_ticks_remaining = 12
	player.previous_state = player.state.duplicate_state()
	var full_throttle_command := RaceInputType.new(0.0, 1.0, 0.0)
	for _frame in 24:
		world.update_race(player, entries, full_throttle_command, 1.0)
		await process_frame
	var cockpit_top_speed_transform := camera.global_transform
	var cockpit_top_speed_horizon_screen := camera.unproject_position(horizon_probe)
	test.assert_near(
		cockpit_top_speed_transform.origin.distance_to(cockpit_rest_transform.origin),
		0.0, 0.0001,
		"integrated cockpit camera cannot sink under full-speed chassis heave or an upshift"
	)
	test.assert_true(
		(-cockpit_top_speed_transform.basis.z).dot(
			-cockpit_rest_transform.basis.z
		) > 0.999999,
		"integrated cockpit pitch remains invariant from rest through top speed"
	)
	test.assert_near(
		camera.fov, cockpit_rest_fov, 0.0001,
		"integrated cockpit FOV remains invariant from rest through top speed"
	)
	test.assert_near(
		cockpit_top_speed_horizon_screen.y,
		cockpit_rest_horizon_screen.y,
		0.01,
		"integrated cockpit horizon stays on the same screen row at top speed"
	)
	player.state = saved_player_state
	player.previous_state = saved_previous_state
	world.update_race(player, entries, command, 1.0)
	await process_frame

	world.set_camera_mode(RaceWorldType.CAMERA_CHASE)
	var restored_chase := world.debug_snapshot()
	test.assert_equal(
		restored_chase.get("camera_mode"), RaceWorldType.CAMERA_CHASE,
		"camera mode toggles back to chase"
	)
	test.assert_true(
		not bool(restored_chase.get("player_cockpit_detail_visible", true))
				and int(restored_chase.get("player_visible_cockpit_details", -1)) == 0,
		"returning to chase immediately removes only the interior micro-detail"
	)

	# Presentation consumes the explicit authority event, not visual proximity.
	var impact_position := player.state.position + Vector2(0.0, 2.0)
	player.previous_state = player.state.duplicate_state()
	player.state = player.state.duplicate_state()
	player.state.vehicle_contact_serial = 1
	player.state.vehicle_contact_tick = 42
	player.state.vehicle_contact_speed = 96.0
	player.state.vehicle_contact_position = impact_position
	player.state.vehicle_contact_normal = Vector2.UP
	player.state.vehicle_contact_other_id = entries[1].participant_id
	world.update_race(player, entries, command, 1.0)
	var first_contact := world.debug_snapshot()
	var first_sparks: Dictionary = first_contact.get("collision_sparks", {})
	test.assert_equal(
		int(first_contact.get("vehicle_contact_serials", {}).get(str(PLAYER_ID), -1)),
		1,
		"presentation consumes the player's monotonic vehicle-contact serial"
	)
	test.assert_equal(
		int(first_sparks.get("accepted_bursts", 0)), 1,
		"one new above-threshold contact serial emits exactly one yellow burst"
	)
	var expected_impact_world := Mapper.authority_position_to_world(
		impact_position, player.state.track_elevation,
		RaceWorldType.VEHICLE_RIDE_HEIGHT_METERS + 0.22
	)
	test.assert_near(
		(first_sparks["last_world_position"] as Vector3).distance_to(expected_impact_world),
		0.0, 0.000001,
		"collision burst is placed at the mapped authoritative contact point"
	)

	world.update_race(player, entries, command, 1.0)
	test.assert_equal(
		int(world.debug_snapshot().get("collision_sparks", {}).get("accepted_bursts", 0)),
		1,
		"re-presenting the same serial cannot repeat its spark burst"
	)
	var opponent: RaceEntry = entries[1]
	opponent.previous_state = opponent.state.duplicate_state()
	opponent.state = opponent.state.duplicate_state()
	opponent.state.vehicle_contact_serial = 1
	opponent.state.vehicle_contact_tick = 42
	opponent.state.vehicle_contact_speed = 96.0
	opponent.state.vehicle_contact_position = impact_position
	opponent.state.vehicle_contact_normal = Vector2.DOWN
	opponent.state.vehicle_contact_other_id = PLAYER_ID
	world.update_race(player, entries, command, 1.0)
	test.assert_equal(
		int(world.debug_snapshot().get("collision_sparks", {}).get("accepted_bursts", 0)),
		1,
		"mirrored telemetry from the other participant deduplicates to the same physical burst"
	)

	player.previous_state = player.state.duplicate_state()
	player.state = player.state.duplicate_state()
	player.state.vehicle_contact_serial = 2
	player.state.vehicle_contact_tick = 43
	player.state.vehicle_contact_speed = 4.0
	world.update_race(player, entries, command, 1.0)
	var soft_contact_sparks: Dictionary = world.debug_snapshot().get("collision_sparks", {})
	test.assert_equal(
		int(soft_contact_sparks.get("accepted_bursts", 0)), 1,
		"sub-threshold car contact remains silent"
	)
	test.assert_true(
		int(soft_contact_sparks.get("rejected_bursts", 0)) >= 1,
		"spark presentation records the deliberate nonzero impact threshold"
	)

	player.previous_state = player.state.duplicate_state()
	player.state = player.state.duplicate_state()
	player.state.vehicle_contact_serial = 3
	player.state.vehicle_contact_tick = 44
	player.state.vehicle_contact_speed = 128.0
	world.update_race(player, entries, command, 1.0)
	var second_sparks: Dictionary = world.debug_snapshot().get("collision_sparks", {})
	test.assert_equal(
		int(second_sparks.get("accepted_bursts", 0)), 2,
		"next strong contact serial reuses the bounded pool for one new burst"
	)
	test.assert_true(
		int(second_sparks.get("emitting_count", 99)) <= 6,
		"integrated collision effects cannot exceed the six-emitter cap"
	)

	# Guest snapshots intentionally omit the other-id field. Tick plus quantized
	# shared position must still collapse the two mirrored reports.
	var network_style_position := impact_position + Vector2(1.25, -0.75)
	player.previous_state = player.state.duplicate_state()
	player.state = player.state.duplicate_state()
	player.state.vehicle_contact_serial = 4
	player.state.vehicle_contact_tick = 45
	player.state.vehicle_contact_speed = 84.0
	player.state.vehicle_contact_position = network_style_position
	player.state.vehicle_contact_normal = Vector2.RIGHT
	player.state.vehicle_contact_other_id = &""
	opponent.previous_state = opponent.state.duplicate_state()
	opponent.state = opponent.state.duplicate_state()
	opponent.state.vehicle_contact_serial = 2
	opponent.state.vehicle_contact_tick = 45
	opponent.state.vehicle_contact_speed = 84.0
	opponent.state.vehicle_contact_position = network_style_position
	opponent.state.vehicle_contact_normal = Vector2.LEFT
	opponent.state.vehicle_contact_other_id = &""
	world.update_race(player, entries, command, 1.0)
	test.assert_equal(
		int(world.debug_snapshot().get("collision_sparks", {}).get("accepted_bursts", 0)),
		3,
		"tick-plus-contact-position fallback deduplicates mirrored network telemetry without other-id"
	)

	var pre_recovery_player := moved_player_transform
	var pre_recovery_camera: Transform3D = world.debug_snapshot()["camera_world_transform"]
	player.previous_state = player.state.duplicate_state()
	player.state = _vehicle_state_at(query, 460.0, PLAYER_ID)
	player.state.recovery_hard_snap_serial = 1
	var recovery_authority_before := _authority_snapshot(entries, command)
	world.update_race(player, entries, command, 0.0)
	var recovered := world.debug_snapshot()
	var recovered_player: Transform3D = recovered["player_world_transform"]
	var recovered_camera: Transform3D = recovered["camera_world_transform"]
	test.assert_equal(
		_authority_snapshot(entries, command), recovery_authority_before,
		"hard-snap presentation does not modify recovery authority"
	)
	test.assert_near(
		recovered_player.origin.distance_to(_state_world_transform(player.state).origin),
		0.0, 0.0001,
		"recovery serial bypasses alpha-zero interpolation and snaps to current state"
	)
	test.assert_true(
		recovered_player.origin.distance_to(pre_recovery_player.origin) > 25.0,
		"recovery presentation makes the intended discontinuous world-space snap"
	)
	test.assert_equal(
		int(recovered.get("player_recovery_serial", -1)), 1,
		"snapshot exposes the authoritative player recovery serial"
	)
	test.assert_equal(
		int(recovered.get("presentation_snap_serial", -1)), 1,
		"presentation records the consumed recovery hard-snap serial"
	)
	test.assert_equal(
		int(recovered.get("presentation_snap_count", 0)), 1,
		"one recovery serial change causes exactly one presentation snap"
	)
	test.assert_equal(
		str(recovered.get("last_recovery_snap_id", "")), str(PLAYER_ID),
		"recovery snap is attributed to the correct player visual"
	)
	test.assert_true(
		recovered_camera.origin.distance_to(pre_recovery_camera.origin) > 25.0,
		"recovery serial hard-snaps the camera with the vehicle"
	)
	test.assert_true(
		recovered_camera.origin.distance_to(recovered_player.origin) < 24.0,
		"hard-snapped camera remains attached to the recovered car"
	)

	var final_snapshot := world.debug_snapshot()
	test.assert_equal(
		world.debug_track_root().transform, initial_track_transform,
		"track root transform never moves across race updates"
	)
	test.assert_equal(
		world.debug_scenery_root().transform, initial_scenery_transform,
		"scenery root transform never moves across race updates"
	)
	test.assert_true(
		bool(final_snapshot.get("fixed_world_invariant", false)),
		"fixed-world invariant survives movement, camera toggles, and recovery"
	)
	test.assert_equal(
		query.centerline, centerline_before,
		"true-world configuration and updates do not mutate track authority"
	)
	test.assert_near(
		query.total_length, total_length_before, 0.000001,
		"true-world configuration preserves authoritative lap length"
	)
	var normal_contrast := float(final_snapshot.get("adjustment_contrast", 0.0))
	var normal_sun_energy := float(final_snapshot.get("sun_light_energy", 0.0))
	world.configure_accessibility(true, true, true, 0.0)
	await process_frame
	var high_contrast_grade := world.debug_snapshot()
	test.assert_true(
		float(high_contrast_grade.get("adjustment_contrast", 0.0)) > normal_contrast
				and float(high_contrast_grade.get("ambient_light_energy", 0.0)) <= 0.60,
		"High Contrast raises post contrast while retaining the bounded daylight range"
	)
	test.assert_near(
		float(high_contrast_grade.get("sun_light_energy", -1.0)),
		normal_sun_energy, 0.000001,
		"High Contrast no longer brightens the physical sun or clips venue whites"
	)

	root.remove_child(world)
	world.free()
	entries.clear()
	await process_frame


func _make_grid(query: RaceTrackQuery) -> Array[RaceEntry]:
	var entries: Array[RaceEntry] = []
	for index in CAR_COUNT:
		var participant_id := StringName("car_%02d" % index)
		var entry := RaceEntryType.new()
		entry.participant_id = participant_id
		entry.display_name = "CAR %02d" % index
		entry.is_human = index == 0
		entry.grid_position = index + 1
		entry.state = _vehicle_state_at(
			query, query.total_length * float(index) / float(CAR_COUNT), participant_id
		)
		entry.previous_state = entry.state.duplicate_state()
		entries.append(entry)
	return entries


func _vehicle_state_at(
		query: RaceTrackQuery,
		distance: float,
		vehicle_id: StringName
	) -> VehicleState:
	var sample := query.sample_at_distance(distance)
	var tangent := Vector2(sample.get("tangent", Vector2.RIGHT)).normalized()
	var state := VehicleStateType.new()
	state.vehicle_id = vehicle_id
	state.position = sample.get("position", Vector2.ZERO)
	state.velocity = tangent * 180.0
	state.heading = tangent.angle()
	state.track_distance = fposmod(distance, query.total_length)
	state.track_elevation = float(sample.get("elevation_level", 0.0))
	state.gear = 5
	state.engine_rpm = 11_200.0
	state.steering_input = 0.18
	state.simulation_tick = roundi(distance)
	return state


func _state_world_transform(state: VehicleState) -> Transform3D:
	return Mapper.authority_transform(
		state.position, state.heading, state.track_elevation,
		RaceWorldType.VEHICLE_RIDE_HEIGHT_METERS + state.vertical_offset_meters
	)


func _authority_snapshot(entries: Array[RaceEntry], command: RaceInput) -> Dictionary:
	var entry_snapshots: Dictionary = {}
	for entry in entries:
		entry_snapshots[str(entry.participant_id)] = {
			"state": entry.state.authority_snapshot(),
			"previous_state": entry.previous_state.authority_snapshot(),
		}
	return {
		"entries": entry_snapshots,
		"command": command.to_dictionary(),
	}


func _compiled_query(track_id: String) -> Dictionary:
	var record := Catalog.by_id(track_id)
	var definition: TrackDefinition = record.get("definition")
	var compiled: TrackCompileResult = Compiler.compile(definition)
	if not compiled.succeeded() or compiled.track == null:
		return {"valid": false}
	var query: RaceTrackQuery = TrackQuery.from_compiled(compiled.track)
	return {
		"valid": query.is_valid(),
		"definition": definition,
		"compiled": compiled.track,
		"query": query,
	}
