extends RefCounted
## Deterministic, in-process stand-in for Google Nearby. It models discovery,
## star connections, reliable messages, and disconnects without radio hardware.

var bridges: Dictionary = {}
var advertisements: Dictionary = {}


func register(bridge: RefCounted, endpoint_id: String) -> void:
	bridges[endpoint_id] = bridge


func advertise(endpoint_id: String, endpoint_name: String) -> void:
	advertisements[endpoint_id] = endpoint_name


func discover(requester_id: String) -> void:
	var requester: RefCounted = bridges.get(requester_id)
	if requester == null:
		return
	for endpoint_id_value in advertisements.keys():
		var endpoint_id := str(endpoint_id_value)
		if endpoint_id != requester_id:
			requester.endpoint_found.emit(endpoint_id, str(advertisements[endpoint_id]))


func connect_pair(requester_id: String, target_id: String) -> void:
	var requester: RefCounted = bridges.get(requester_id)
	var target: RefCounted = bridges.get(target_id)
	if requester == null or target == null:
		if requester != null:
			requester.connection_result.emit(target_id, false, "endpoint_missing")
		return
	requester.connected[target_id] = true
	target.connected[requester_id] = true
	requester.connection_result.emit(target_id, true, "ok")
	target.connection_result.emit(requester_id, true, "ok")


func route(sender_id: String, target_id: String, message: String) -> bool:
	var sender: RefCounted = bridges.get(sender_id)
	var target: RefCounted = bridges.get(target_id)
	if sender == null or target == null or not bool(sender.connected.get(target_id, false)):
		return false
	target.message_received.emit(sender_id, message)
	return true


func disconnect_pair(sender_id: String, target_id: String) -> void:
	var sender: RefCounted = bridges.get(sender_id)
	var target: RefCounted = bridges.get(target_id)
	if sender != null:
		sender.connected.erase(target_id)
		sender.endpoint_disconnected.emit(target_id)
	if target != null:
		target.connected.erase(sender_id)
		target.endpoint_disconnected.emit(sender_id)
