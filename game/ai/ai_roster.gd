class_name AiRoster
extends RefCounted
## Stable 10-12 driver field factory used by solo races and multiplayer fill-ins.

const AiDriverType := preload("res://game/ai/ai_driver.gd")

const DRIVER_NAMES: PackedStringArray = [
	"Nova", "Apex", "Vela", "Kite", "Ember", "Pulse",
	"Orbit", "Rook", "Mako", "Flux", "Iris", "Drift",
]


static func create_drivers(
		race_seed: int,
		requested_count: int = 11,
		difficulty: float = 0.75,
		maximum_speed: float = 310.0
	) -> Array[AiDriver]:
	var count := clampi(requested_count, 10, 12)
	var drivers: Array[AiDriver] = []
	for index in count:
		var identifier := StringName("ai_%02d" % (index + 1))
		drivers.append(AiDriverType.new(identifier, race_seed, difficulty, maximum_speed))
	return drivers


static func display_name(index: int) -> String:
	if index < 0 or index >= DRIVER_NAMES.size():
		return "Driver %02d" % (index + 1)
	return DRIVER_NAMES[index]
