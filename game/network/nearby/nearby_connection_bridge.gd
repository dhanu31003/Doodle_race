class_name NearbyConnectionBridge
extends RefCounted
## Thin, testable wrapper around the Android RaceGlyphNearby singleton.

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

const SINGLETON_NAME := "RaceGlyphNearby"

var _plugin: Object


func initialize() -> Dictionary:
	if not Engine.has_singleton(SINGLETON_NAME):
		return {
			"ok": false,
			"error": {
				"code": "nearby_android_required",
				"message": "Nearby multiplayer is available in the Android mobile build.",
			},
		}
	_plugin = Engine.get_singleton(SINGLETON_NAME)
	if _plugin == null or not bool(_plugin.call("isAvailable")):
		_plugin = null
		return {
			"ok": false,
			"error": {
				"code": "nearby_play_services_unavailable",
				"message": "Google Play services with Nearby Connections is unavailable on this device.",
			},
		}
	_bind("permission_result", _forward_permission_result)
	_bind("operation_failed", _forward_operation_failed)
	_bind("advertising_started", _forward_advertising_started)
	_bind("discovery_started", _forward_discovery_started)
	_bind("endpoint_found", _forward_endpoint_found)
	_bind("endpoint_lost", _forward_endpoint_lost)
	_bind("connection_initiated", _forward_connection_initiated)
	_bind("connection_result", _forward_connection_result)
	_bind("endpoint_disconnected", _forward_endpoint_disconnected)
	_bind("message_received", _forward_message_received)
	return {"ok": true}


func has_required_permissions() -> bool:
	return _plugin != null and bool(_plugin.call("hasRequiredPermissions"))


func request_required_permissions() -> void:
	if _plugin != null:
		_plugin.call("requestRequiredPermissions")


func start_advertising(endpoint_name: String) -> void:
	if _plugin != null:
		_plugin.call("startAdvertising", endpoint_name)


func stop_advertising() -> void:
	if _plugin != null:
		_plugin.call("stopAdvertising")


func start_discovery() -> void:
	if _plugin != null:
		_plugin.call("startDiscovery")


func stop_discovery() -> void:
	if _plugin != null:
		_plugin.call("stopDiscovery")


func request_connection(endpoint_id: String, local_name: String) -> void:
	if _plugin != null:
		_plugin.call("requestConnection", endpoint_id, local_name)


func send_message(endpoint_id: String, message: String) -> bool:
	return _plugin != null and bool(_plugin.call("sendMessage", endpoint_id, message))


func disconnect_endpoint(endpoint_id: String) -> void:
	if _plugin != null:
		_plugin.call("disconnectEndpoint", endpoint_id)


func stop_all() -> void:
	if _plugin != null:
		_plugin.call("stopAll")


func _bind(signal_name: StringName, callback: Callable) -> void:
	if _plugin != null and _plugin.has_signal(signal_name) and not _plugin.is_connected(signal_name, callback):
		_plugin.connect(signal_name, callback)


func _forward_permission_result(granted: bool, reason: String) -> void:
	permission_result.emit(granted, reason)


func _forward_operation_failed(operation: String, reason: String) -> void:
	operation_failed.emit(operation, reason)


func _forward_advertising_started() -> void:
	advertising_started.emit()


func _forward_discovery_started() -> void:
	discovery_started.emit()


func _forward_endpoint_found(endpoint_id: String, endpoint_name: String) -> void:
	endpoint_found.emit(endpoint_id, endpoint_name)


func _forward_endpoint_lost(endpoint_id: String) -> void:
	endpoint_lost.emit(endpoint_id)


func _forward_connection_initiated(endpoint_id: String, endpoint_name: String, digits: String) -> void:
	connection_initiated.emit(endpoint_id, endpoint_name, digits)


func _forward_connection_result(endpoint_id: String, connected: bool, reason: String) -> void:
	connection_result.emit(endpoint_id, connected, reason)


func _forward_endpoint_disconnected(endpoint_id: String) -> void:
	endpoint_disconnected.emit(endpoint_id)


func _forward_message_received(endpoint_id: String, message: String) -> void:
	message_received.emit(endpoint_id, message)
