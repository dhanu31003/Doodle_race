extends RefCounted

signal permission_result(granted: bool, reason: String)
signal operation_failed(operation: String, reason: String)
signal advertising_started
signal discovery_started
signal endpoint_found(endpoint_id: String, endpoint_name: String)
signal endpoint_lost(endpoint_id: String)
signal connection_initiated(endpoint_id: String, endpoint_name: String, authentication_digits: String)
signal connection_result(endpoint_id: String, connected: bool, reason: String)
signal endpoint_disconnected(endpoint_id: String)
signal message_received(endpoint_id: String, message: String)

var hub: RefCounted
var endpoint_id := ""
var connected: Dictionary = {}


func _init(value: RefCounted, id: String) -> void:
	hub = value
	endpoint_id = id
	hub.register(self, endpoint_id)


func initialize() -> Dictionary:
	return {"ok": true}


func has_required_permissions() -> bool:
	return true


func request_required_permissions() -> void:
	permission_result.emit(true, "test")


func start_advertising(endpoint_name: String) -> void:
	hub.advertise(endpoint_id, endpoint_name)
	advertising_started.emit()


func stop_advertising() -> void:
	hub.advertisements.erase(endpoint_id)


func start_discovery() -> void:
	discovery_started.emit()
	hub.discover(endpoint_id)


func stop_discovery() -> void:
	pass


func request_connection(target_id: String, _local_name: String) -> void:
	hub.connect_pair(endpoint_id, target_id)


func send_message(target_id: String, message: String) -> bool:
	return hub.route(endpoint_id, target_id, message)


func disconnect_endpoint(target_id: String) -> void:
	hub.disconnect_pair(endpoint_id, target_id)


func stop_all() -> void:
	for target_id_value in connected.keys().duplicate():
		hub.disconnect_pair(endpoint_id, str(target_id_value))
	stop_advertising()
