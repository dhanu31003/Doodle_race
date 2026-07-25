extends SceneTree
## Deterministic presentation-only collision frame used by visual QA.

const FormulaCarVisualType := preload(
	"res://game/presentation3d/formula_car_visual_3d.gd"
)
const SparkPoolType := preload(
	"res://game/presentation3d/collision_spark_pool_3d.gd"
)
const VehicleStateType := preload("res://game/race/vehicle_state.gd")
const RaceInputType := preload("res://game/race/race_input.gd")


func _initialize() -> void:
	_build_fixture.call_deferred()


func _build_fixture() -> void:
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
	sun.light_energy = 2.2
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	root.add_child(sun)

	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(36.0, 28.0)
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("303940")
	ground_material.roughness = 0.88
	ground_mesh.material = ground_material
	var ground := MeshInstance3D.new()
	ground.mesh = ground_mesh
	ground.position.y = 0.02
	root.add_child(ground)

	var first := FormulaCarVisualType.new()
	first.name = "ContactCarA"
	root.add_child(first)
	first.configure(Color("18d8a0"), true)
	first.position = Vector3(0.0, 0.0, -0.78)
	first.rotation.y = deg_to_rad(-2.5)
	var second := FormulaCarVisualType.new()
	second.name = "ContactCarB"
	root.add_child(second)
	second.configure(Color("f06a37"), false)
	second.position = Vector3(0.18, 0.0, 0.92)
	second.rotation.y = deg_to_rad(3.5)
	var state := VehicleStateType.new()
	state.velocity = Vector2(170.0, 0.0)
	state.engine_rpm = 11_800.0
	state.gear = 5
	state.steering_input = 0.10
	first.apply_vehicle_state(state, RaceInputType.new(0.10, 0.70, 0.0), 1.0 / 60.0)
	state = state.duplicate_state()
	state.steering_input = -0.08
	second.apply_vehicle_state(state, RaceInputType.new(-0.08, 0.65, 0.0), 1.0 / 60.0)

	var spark_pool := SparkPoolType.new()
	spark_pool.name = "CollisionSparkPool"
	root.add_child(spark_pool)
	var camera := Camera3D.new()
	camera.name = "CollisionReviewCamera"
	camera.fov = 48.0
	camera.near = 0.05
	root.add_child(camera)
	camera.look_at_from_position(
		Vector3(-5.5, 2.25, 4.6), Vector3(0.25, 0.52, 0.08), Vector3.UP
	)
	camera.current = true

	for _warmup in 4:
		await process_frame
	var accepted := spark_pool.emit_contact(
		Vector3(0.42, 0.48, 0.09), Vector3(0.0, 0.0, 1.0),
		132.0, "visual-contact-a-b:42"
	)
	print("COLLISION_SPARK_VISUAL accepted=%s snapshot=%s" % [
		str(accepted), str(spark_pool.presentation_snapshot())
	])
	for _capture_frame in 28:
		await process_frame
	quit(0)
