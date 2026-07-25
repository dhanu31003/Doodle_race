class_name SnapshotInterpolator
extends RefCounted
## Tick-buffered remote-car interpolation over authoritative fixed-point states.

const Limits := preload("res://game/network/network_limits.gd")
const Result := preload("res://game/network/network_result.gd")
const Codec := preload("res://game/network/client/network_race_codec.gd")

var _snapshots: Array[Dictionary] = []


func push_snapshot(snapshot: Dictionary) -> Dictionary:
	if not snapshot.has("tick") or typeof(snapshot["tick"]) != TYPE_INT \
			or int(snapshot["tick"]) < 0 or not snapshot.has("cars") \
			or typeof(snapshot["cars"]) != TYPE_ARRAY:
		return Result.failure(&"interpolation_snapshot_invalid", "Interpolation snapshot is malformed.")
	if snapshot["cars"].size() > Limits.MAX_PLAYERS:
		return Result.failure(&"interpolation_snapshot_invalid", "Interpolation snapshot has too many cars.")
	if not _snapshots.is_empty() and int(snapshot["tick"]) <= int(_snapshots.back()["tick"]):
		return Result.failure(&"interpolation_snapshot_stale", "Interpolation snapshots must advance by tick.")
	var seen: Dictionary = {}
	for car_value in snapshot["cars"]:
		if typeof(car_value) != TYPE_DICTIONARY or not car_value.has("slot") \
				or typeof(car_value["slot"]) != TYPE_INT:
			return Result.failure(&"interpolation_car_invalid", "Interpolated car requires an integer slot.")
		var slot := int(car_value["slot"])
		if slot < 0 or slot >= Limits.MAX_PLAYERS or seen.has(slot):
			return Result.failure(&"interpolation_car_invalid", "Interpolated car slot is invalid or duplicated.")
		seen[slot] = true
		for field in ["x_q", "y_q", "rotation_q", "velocity_x_q", "velocity_y_q", "collision_layer", "collision_mask"]:
			if not car_value.has(field) or typeof(car_value[field]) != TYPE_INT:
				return Result.failure(&"interpolation_car_invalid", "Interpolated car has a malformed fixed field.", {"field": field})
		var dynamics_fields := [
			"gear", "engine_rpm_q", "shift_ticks", "steering_q", "slip_angle_q",
			"wheel_slip_q", "lateral_accel_q",
		]
		var dynamics_present := 0
		for field in dynamics_fields:
			if car_value.has(field):
				dynamics_present += 1
				if typeof(car_value[field]) != TYPE_INT:
					return Result.failure(
						&"interpolation_car_invalid",
						"Interpolated Formula telemetry must use fixed integers.",
						{"field": field}
					)
		if dynamics_present != 0 and dynamics_present != dynamics_fields.size():
			return Result.failure(
				&"interpolation_car_invalid", "Interpolated Formula telemetry is incomplete."
			)
		if not Codec.valid_airborne_bundle(car_value):
			return Result.failure(
				&"interpolation_car_invalid",
				"Interpolated vertical vehicle authority is incomplete or out of range."
			)
		if not Codec.valid_contact_bundle(car_value):
			return Result.failure(
				&"interpolation_car_invalid",
				"Interpolated vehicle contact telemetry is incomplete or out of range."
			)
	_snapshots.append(snapshot.duplicate(true))
	while _snapshots.size() > Limits.INTERPOLATION_BUFFER_SNAPSHOTS:
		_snapshots.pop_front()
	return Result.success({"buffered": _snapshots.size()})


func sample(render_tick: float) -> Dictionary:
	if _snapshots.is_empty():
		return {}
	if render_tick <= float(_snapshots[0]["tick"]):
		return _snapshots[0].duplicate(true)
	if render_tick >= float(_snapshots.back()["tick"]):
		return _snapshots.back().duplicate(true)
	for index in _snapshots.size() - 1:
		var first: Dictionary = _snapshots[index]
		var second: Dictionary = _snapshots[index + 1]
		if render_tick >= float(first["tick"]) and render_tick <= float(second["tick"]):
			var span := maxi(1, int(second["tick"]) - int(first["tick"]))
			var weight := clampf((render_tick - float(first["tick"])) / float(span), 0.0, 1.0)
			return _interpolate(first, second, render_tick, weight)
	return _snapshots.back().duplicate(true)


func sample_delayed(latest_authoritative_tick: int) -> Dictionary:
	return sample(float(latest_authoritative_tick - Limits.INTERPOLATION_DELAY_TICKS))


func buffered_count() -> int:
	return _snapshots.size()


func clear() -> void:
	_snapshots.clear()


func _interpolate(first: Dictionary, second: Dictionary, render_tick: float, weight: float) -> Dictionary:
	var first_by_slot := _cars_by_slot(first["cars"])
	var second_by_slot := _cars_by_slot(second["cars"])
	var slots: Array = first_by_slot.keys()
	for slot in second_by_slot.keys():
		if not first_by_slot.has(slot):
			slots.append(slot)
	slots.sort()
	var cars: Array[Dictionary] = []
	for slot in slots:
		if not first_by_slot.has(slot):
			cars.append(second_by_slot[slot].duplicate(true))
			continue
		if not second_by_slot.has(slot):
			cars.append(first_by_slot[slot].duplicate(true))
			continue
		var a: Dictionary = first_by_slot[slot]
		var b: Dictionary = second_by_slot[slot]
		var car := a.duplicate(true)
		for field in ["x_q", "y_q", "velocity_x_q", "velocity_y_q"]:
			car[field] = roundi(lerpf(float(a[field]), float(b[field]), weight))
		for field in [
			"engine_rpm_q", "steering_q", "slip_angle_q", "wheel_slip_q", "lateral_accel_q",
		]:
			if a.has(field) and b.has(field):
				car[field] = roundi(lerpf(float(a[field]), float(b[field]), weight))
			elif b.has(field) and weight >= 0.5:
				car[field] = b[field]
		car["rotation_q"] = _lerp_rotation_q(int(a["rotation_q"]), int(b["rotation_q"]), weight)
		for field in [
			"lap", "checkpoint", "collision_layer", "collision_mask", "flags",
			"gear", "shift_ticks",
		]:
			if b.has(field):
				car[field] = b[field] if weight >= 0.5 else a.get(field, b[field])
		# Height and vertical velocity interpolate as one authority bundle. Grounded
		# remains discrete, and its exact-zero invariant wins as soon as the selected
		# endpoint has landed.
		var a_has_airborne := a.has(Codec.AIRBORNE_FIELDS[0])
		var b_has_airborne := b.has(Codec.AIRBORNE_FIELDS[0])
		for field in Codec.AIRBORNE_FIELDS:
			car.erase(field)
		if a_has_airborne and b_has_airborne:
			car["grounded"] = b["grounded"] \
					if weight >= 0.5 else a["grounded"]
			if int(car["grounded"]) == 1:
				car["vertical_offset_q"] = 0
				car["vertical_velocity_q"] = 0
			else:
				car["vertical_offset_q"] = roundi(lerpf(
					float(a["vertical_offset_q"]),
					float(b["vertical_offset_q"]),
					weight
				))
				car["vertical_velocity_q"] = roundi(lerpf(
					float(a["vertical_velocity_q"]),
					float(b["vertical_velocity_q"]),
					weight
				))
		else:
			var airborne_source: Dictionary = b if weight >= 0.5 else a
			for field in Codec.AIRBORNE_FIELDS:
				if airborne_source.has(field):
					car[field] = airborne_source[field]
		# Contact data is one monotonic discrete event bundle. Never interpolate
		# its normal/position or mix fields from different authoritative impacts.
		var contact_source: Dictionary = b if weight >= 0.5 else a
		for field in Codec.CONTACT_FIELDS:
			car.erase(field)
			if contact_source.has(field):
				car[field] = contact_source[field]
		cars.append(car)
	return {"tick": render_tick, "cars": cars}


func _cars_by_slot(cars: Array) -> Dictionary:
	var output: Dictionary = {}
	for car in cars:
		output[int(car["slot"])] = car
	return output


func _lerp_rotation_q(first: int, second: int, weight: float) -> int:
	var full_turn := Limits.ROTATION_Q_LIMIT
	var half_turn := full_turn / 2
	var delta := second - first
	while delta > half_turn:
		delta -= full_turn
	while delta < -half_turn:
		delta += full_turn
	return roundi(float(first) + float(delta) * weight)
