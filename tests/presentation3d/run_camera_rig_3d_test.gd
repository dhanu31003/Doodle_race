extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const CameraRigType := preload("res://game/presentation3d/camera_rig_3d.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	root.size = Vector2i(1280, 720)
	var rig := CameraRigType.new()
	root.add_child(rig)
	await process_frame
	rig.configure_accessibility(false, 0.35)
	rig.set_camera_mode(CameraRigType.CAMERA_CHASE)

	var vehicle := Transform3D(Basis.IDENTITY, Vector3(14.0, 0.075, -8.0))
	var authored_socket := vehicle * Transform3D(
		Basis.IDENTITY, Vector3(-4.65, 2.10, 0.0)
	)
	rig.update_target(vehicle, 0.0, 0.0, 0)
	rig.update_socket_targets(null, authored_socket)
	rig.snap_to_target()
	var stopped: Dictionary = rig.presentation_snapshot()
	var stopped_origin_screen := rig.camera.unproject_position(vehicle.origin)
	var stopped_top_screen := rig.camera.unproject_position(
		vehicle.origin + Vector3.UP
	)
	var stopped_projected_height := stopped_origin_screen.distance_to(
		stopped_top_screen
	)

	rig.update_target(vehicle, 140.0, 1.0, 0)
	rig.snap_to_target()
	var top_speed_right: Dictionary = rig.presentation_snapshot()
	var top_speed_origin_screen := rig.camera.unproject_position(vehicle.origin)
	var top_speed_top_screen := rig.camera.unproject_position(
		vehicle.origin + Vector3.UP
	)
	var top_speed_projected_height := top_speed_origin_screen.distance_to(
		top_speed_top_screen
	)
	test.assert_near(
		(top_speed_right["camera_position"] as Vector3).distance_to(
			stopped["camera_position"] as Vector3
		),
		0.0, 0.000001,
		"stopped and top-speed chase positions are epsilon-identical at the same authored socket"
	)
	test.assert_near(
		float(top_speed_right.get("vehicle_distance", -1.0)),
		float(stopped.get("vehicle_distance", -2.0)),
		0.000001,
		"stopped and top-speed car-to-camera distances remain numerically identical"
	)
	test.assert_near(
		float(top_speed_right.get("fov", 0.0)),
		float(stopped.get("fov", 0.0)),
		0.000001,
		"stopped and top-speed chase FOV remain identical"
	)
	test.assert_near(
		top_speed_origin_screen.distance_to(stopped_origin_screen),
		0.0, 0.01,
		"vehicle screen position is invariant from stopped to top speed"
	)
	test.assert_true(
		absf(top_speed_projected_height - stopped_projected_height)
				/ maxf(stopped_projected_height, 0.0001) <= 0.01,
		"projected vehicle scale changes by no more than one percent at top speed"
	)
	var chase_reference_forward_local := vehicle.basis.inverse() \
			* (-rig.camera.global_basis.z)
	var translated_vehicle := Transform3D(
		Basis.IDENTITY, vehicle.origin + Vector3(32.0, 0.0, 0.0)
	)
	var translated_socket := translated_vehicle * Transform3D(
		Basis.IDENTITY, Vector3(-4.65, 2.10, 0.0)
	)
	rig.update_target(translated_vehicle, 140.0, 0.0, 0)
	rig.update_socket_targets(null, translated_socket)
	await process_frame
	var translated_forward_local := translated_vehicle.basis.inverse() \
			* (-rig.camera.global_basis.z)
	var translated_origin_screen := rig.camera.unproject_position(
		translated_vehicle.origin
	)
	test.assert_true(
		translated_forward_local.dot(chase_reference_forward_local) > 0.999999,
		"high-speed forward travel cannot create chase-camera pitch from look-target lag"
	)
	test.assert_near(
		translated_origin_screen.distance_to(top_speed_origin_screen),
		0.0, 0.01,
		"chase vehicle framing remains invariant while its world position advances"
	)

	# A bridge ramp may change the vehicle root from level to a steep grade in one
	# authority sample. The car must align immediately, but the external camera
	# should ease that nod through both the climb and the descent.
	rig.set_process(false)
	var level_bridge_vehicle := Transform3D(
		Basis.IDENTITY, Vector3(60.0, 3.0, -18.0)
	)
	rig.update_target(level_bridge_vehicle, 55.0, 0.0, 0)
	rig.update_socket_targets(null, level_bridge_vehicle * Transform3D(
		Basis.IDENTITY, Vector3(-4.65, 2.10, 0.0)
	))
	rig.snap_to_target()
	var uphill_vehicle := Transform3D(
		Basis(Vector3.BACK, deg_to_rad(24.0)),
		Vector3(61.0, 3.4, -18.0)
	)
	rig.update_target(uphill_vehicle, 55.0, 0.0, 0)
	rig.update_socket_targets(null, uphill_vehicle * Transform3D(
		Basis.IDENTITY, Vector3(-4.65, 2.10, 0.0)
	))
	rig._process(1.0 / 60.0)
	var climb_first: Dictionary = rig.presentation_snapshot()
	test.assert_near(
		float(climb_first["target_grade_pitch_radians"]),
		deg_to_rad(24.0), 0.0001,
		"bridge climb exposes the complete current road grade to the rig"
	)
	test.assert_true(
		float(climb_first["smoothed_chase_pitch_radians"]) > 0.0
				and float(climb_first["smoothed_chase_pitch_radians"])
						<= CameraRigType.CHASE_MAX_GRADE_RATE_RADIANS / 60.0 + 0.0001,
		"first uphill frame is rate-limited instead of snapping to the ramp angle"
	)
	test.assert_near(
		(climb_first["camera_position"] as Vector3).distance_to(
			climb_first["desired_position"] as Vector3
		),
		0.0, 0.000001,
		"grade easing never introduces world-translation lag"
	)
	for _frame in 120:
		rig._process(1.0 / 60.0)
	var climb_settled: Dictionary = rig.presentation_snapshot()
	test.assert_near(
		float(climb_settled["smoothed_chase_pitch_radians"]),
		deg_to_rad(24.0), deg_to_rad(0.15),
		"chase grade converges smoothly to a sustained bridge climb"
	)
	var before_descent := float(climb_settled["smoothed_chase_pitch_radians"])
	var downhill_vehicle := Transform3D(
		Basis(Vector3.BACK, deg_to_rad(-18.0)),
		Vector3(82.0, 4.2, -18.0)
	)
	rig.update_target(downhill_vehicle, 55.0, 0.0, 0)
	rig.update_socket_targets(null, downhill_vehicle * Transform3D(
		Basis.IDENTITY, Vector3(-4.65, 2.10, 0.0)
	))
	rig._process(1.0 / 60.0)
	var descent_first: Dictionary = rig.presentation_snapshot()
	test.assert_true(
		before_descent - float(descent_first["smoothed_chase_pitch_radians"])
				<= CameraRigType.CHASE_MAX_GRADE_RATE_RADIANS / 60.0 + 0.0001,
		"first downhill frame is rate-limited instead of abruptly pitching down"
	)
	for _frame in 150:
		rig._process(1.0 / 60.0)
	var descent_settled: Dictionary = rig.presentation_snapshot()
	test.assert_near(
		float(descent_settled["smoothed_chase_pitch_radians"]),
		deg_to_rad(-18.0), deg_to_rad(0.15),
		"chase grade converges smoothly to a sustained bridge descent"
	)
	rig.set_process(true)

	rig.update_target(vehicle, 70.0, -1.0, 0)
	rig.snap_to_target()
	var left_lock: Dictionary = rig.presentation_snapshot()
	rig.update_target(vehicle, 70.0, 1.0, 0)
	rig.snap_to_target()
	var right_lock: Dictionary = rig.presentation_snapshot()
	test.assert_near(
		(left_lock["camera_position"] as Vector3).distance_to(
			right_lock["camera_position"] as Vector3
		),
		0.0, 0.000001,
		"full-left and full-right steering cannot move the authored chase mount"
	)

	var moved_vehicle := Transform3D(
		Basis(Vector3.UP, -0.73), Vector3(91.0, 0.075, 46.0)
	)
	var moved_socket := moved_vehicle * Transform3D(
		Basis.IDENTITY, Vector3(-4.65, 2.10, 0.0)
	)
	rig.update_target(moved_vehicle, 120.0, 0.55, 0)
	rig.update_socket_targets(null, moved_socket)
	await process_frame
	var followed: Dictionary = rig.presentation_snapshot()
	test.assert_near(
		(followed["camera_position"] as Vector3).distance_to(
			followed["desired_position"] as Vector3
		),
		0.0, 0.000001,
		"moving vehicle receives the exact authored chase position without speed-dependent damping lag"
	)
	test.assert_near(
		float(followed.get("vehicle_distance", -1.0)),
		float(top_speed_right.get("vehicle_distance", -2.0)),
		0.00001,
		"authored chase distance survives translated and rotated vehicle transforms"
	)

	rig.set_camera_mode(CameraRigType.CAMERA_COCKPIT)
	rig.update_socket_targets(
		moved_vehicle * Transform3D(Basis.IDENTITY, Vector3(-0.20, 1.10, 0.0)),
		moved_socket
	)
	rig.update_target(moved_vehicle, 0.0, 0.0, 0)
	rig.snap_to_target()
	var cockpit_stopped: Dictionary = rig.presentation_snapshot()
	var cockpit_stopped_forward := -rig.camera.global_basis.z
	var horizon_probe := moved_vehicle.origin \
			+ (moved_vehicle.basis * Vector3.RIGHT).normalized() * 120.0
	var cockpit_stopped_horizon_screen := rig.camera.unproject_position(horizon_probe)

	rig.update_target(moved_vehicle, 140.0, 1.0, 12)
	rig.snap_to_target()
	var cockpit_top_speed: Dictionary = rig.presentation_snapshot()
	var cockpit_top_speed_forward := -rig.camera.global_basis.z
	var cockpit_top_speed_horizon_screen := rig.camera.unproject_position(horizon_probe)
	test.assert_true(
		float(cockpit_top_speed.get("vehicle_distance", 99.0)) < 2.0,
		"cockpit socket remains rigidly mounted inside the survival-cell envelope"
	)
	test.assert_near(
		(cockpit_top_speed["camera_position"] as Vector3).distance_to(
			cockpit_stopped["camera_position"] as Vector3
		),
		0.0, 0.000001,
		"top speed and an active upshift cannot lower the cockpit camera mount"
	)
	test.assert_near(
		float(cockpit_top_speed.get("fov", 0.0)),
		float(cockpit_stopped.get("fov", 0.0)),
		0.000001,
		"cockpit FOV is speed-invariant so the horizon cannot slide down"
	)
	test.assert_true(
		cockpit_top_speed_forward.dot(cockpit_stopped_forward) > 0.999999,
		"cockpit view direction remains invariant from rest through top speed"
	)
	test.assert_near(
		cockpit_top_speed_horizon_screen.y,
		cockpit_stopped_horizon_screen.y,
		0.001,
		"a distant horizon probe remains on the same screen row at top speed"
	)
	test.assert_near(
		float(cockpit_top_speed.get("desired_fov", 0.0)),
		CameraRigType.COCKPIT_BASE_FOV,
		0.000001,
		"cockpit uses its authored fixed field of view"
	)

	root.remove_child(rig)
	rig.free()
	await process_frame
	var result: Dictionary = test.result("camera_rig_3d")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)
