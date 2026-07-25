class_name VehicleCatalog
extends RefCounted
## Release catalog for the eight fictional, performance-identical car identities.

const DEFAULT_CAR_ID := "car-prime"
const DEFAULT_TEAM_ID := "team-vector"


static func all() -> Array[Dictionary]:
	return [
		_entry("car-prime", "team-vector", "PRIME", "VECTOR WORKS", "5fffd0", "01", "res://assets/final/vehicles/car_prime.svg"),
		_entry("car-aurora", "team-aurora", "AURORA", "NORTHLIGHT GP", "51c8ff", "07", "res://assets/final/vehicles/car_aurora.svg"),
		_entry("car-cinder", "team-cinder", "CINDER", "EMBER RACING", "ff6b72", "13", "res://assets/final/vehicles/car_cinder.svg"),
		_entry("car-jade", "team-jade", "JADE", "VERDANT MOTOR", "4ee58b", "22", "res://assets/final/vehicles/car_jade.svg"),
		_entry("car-solar", "team-solar", "SOLAR", "HELIO DYNAMICS", "ffc857", "31", "res://assets/final/vehicles/car_solar.svg"),
		_entry("car-violet", "team-violet", "VIOLET", "PARALLAX SPORT", "b99cff", "44", "res://assets/final/vehicles/car_violet.svg"),
		_entry("car-tide", "team-tide", "TIDE", "PELAGIC RACING", "43e6ea", "56", "res://assets/final/vehicles/car_tide.svg"),
		_entry("car-rose", "team-rose", "ROSE", "APEX BLOOM", "ff91bb", "88", "res://assets/final/vehicles/car_rose.svg"),
	]


static func by_car_id(car_id: String) -> Dictionary:
	for entry in all():
		if entry["car_id"] == car_id:
			return entry
	return all()[0]


static func is_valid_pair(car_id: String, team_id: String) -> bool:
	for entry in all():
		if entry["car_id"] == car_id and entry["team_id"] == team_id:
			return true
	return false


static func _entry(
		car_id: String,
		team_id: String,
		name: String,
		team: String,
		accent_hex: String,
		number: String,
		asset: String
	) -> Dictionary:
	return {
		"car_id": car_id,
		"team_id": team_id,
		"name": name,
		"team": team,
		"accent": Color(accent_hex),
		"number": number,
		"asset": asset,
	}
