class_name LocalNakamaLoadPeer
extends RefCounted
## Minimal official-SDK peer for backend operational load evidence.
## It intentionally does not preload gameplay/track scripts: this smoke proves
## Nakama room authority and relay fan-out, while track decoding is covered by
## the production transport and track-domain suites.

const NakamaFactoryScript := preload(
	"res://game/network/nakama/vendor/heroiclabs_nakama_godot/addons/com.heroiclabs.nakama/Nakama.gd"
)
const Limits := preload("res://game/network/network_limits.gd")

const RPC_CREATE := "raceglyph_create_room"
const RPC_JOIN := "raceglyph_join_room"
const PROTOCOL := Limits.PROTOCOL_VERSION
const SDK_LOG_ERROR := 1

var _host_node: Node
var _factory: Node
var _client: Variant
var _session: Variant
var _socket: Variant
var _events: Array[Dictionary] = []
var _sequence_by_opcode: Dictionary = {}
var _match_id := ""
var _room_code := ""
var _reconnect_token := ""
var _room_epoch := 0
var _last_server_tick := 0


func authenticate_device_async(
		host_node: Node,
		device_id: String,
		username: String,
		host: String,
		port: int,
		server_key: String
	) -> Dictionary:
	if host_node == null or host != "127.0.0.1" or port < 1024 or port > 65535:
		return _failure("local_configuration_invalid")
	_host_node = host_node
	_factory = NakamaFactoryScript.new()
	_factory.name = "LocalLoadSDK"
	_host_node.add_child(_factory)
	_client = _factory.create_client(server_key, host, port, "http", 5, SDK_LOG_ERROR)
	_session = await _client.authenticate_device_async(device_id, username, true, {
		"client": "raceglyph_local_load",
		"protocol": str(PROTOCOL),
	})
	if _session == null or _session.is_exception() or not _session.is_valid():
		return _failure("device_auth_failed")
	_socket = _factory.create_socket_from(_client)
	_socket.received_match_state.connect(_on_match_state)
	_socket.received_error.connect(_on_socket_error)
	_socket.closed.connect(_on_socket_closed)
	_socket.connection_error.connect(_on_connection_error)
	var connected: Variant = await _socket.connect_async(_session, true, 5)
	if connected == null or connected.is_exception():
		return _failure("socket_connect_failed")
	return _success({"user_id": str(_session.user_id)})


func create_private_room(display_name: String) -> Dictionary:
	var result := await _rpc(RPC_CREATE, {"display_name": display_name, "compatibility": _compatibility()})
	return result if not result["ok"] else await _join_from_rpc(result["value"])


func join_private_room(room_code: String, display_name: String) -> Dictionary:
	var result := await _rpc(RPC_JOIN, {
		"room_code": room_code.strip_edges().to_upper(),
		"display_name": display_name,
		"compatibility": _compatibility(),
	})
	return result if not result["ok"] else await _join_from_rpc(result["value"])


func submit_track_manifest(room_code: String, manifest: Dictionary) -> Dictionary:
	return await _send_opcode(room_code, 3, manifest)


func submit_generation_report(room_code: String, report: Dictionary) -> Dictionary:
	return await _send_opcode(room_code, 5, report)


func set_ready(room_code: String, ready: bool) -> Dictionary:
	return await _send_opcode(room_code, 6, {"ready": ready})


func set_room_lock(room_code: String, locked: bool) -> Dictionary:
	return await _send_opcode(room_code, 2, {"type": "room_lock", "locked": locked})


func start_countdown(room_code: String) -> Dictionary:
	return await _send_opcode(room_code, 7, {"request_start": true})


func _compatibility() -> Dictionary:
	return {
		"app_build": "0.2.0",
		"protocol_version": PROTOCOL,
		"track_schema_version": 1,
		"generator_version": 2,
		"platform": "linux",
	}


func send_envelope(room_code: String, envelope: Dictionary) -> Dictionary:
	if room_code.strip_edges().to_upper() != _room_code or _match_id.is_empty():
		return _failure("not_joined")
	var completion: Variant = await _socket.send_match_state_async(
		_match_id, int(envelope.get("opcode", -1)), JSON.stringify(envelope)
	)
	if completion != null and completion.has_method("is_exception") and completion.is_exception():
		return _failure("send_failed")
	return _success({"queued": true})


func wait_for_opcode_async(opcode: int, timeout_ms: int = 3000) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		for index in range(_events.size()):
			if int(_events[index].get("opcode", -1)) == opcode:
				var event := _events[index]
				_events.remove_at(index)
				return _success(event)
		await Engine.get_main_loop().process_frame
	return _failure("event_timeout")


func drain_events() -> Array[Dictionary]:
	var output := _events.duplicate(true)
	_events.clear()
	return output


func session_user_id() -> String:
	return "" if _session == null else str(_session.user_id)


func room_epoch() -> int:
	return _room_epoch


func close() -> void:
	if _socket != null:
		_socket.close()
	if is_instance_valid(_factory):
		_factory.queue_free()
	_socket = null
	_client = null
	_session = null
	_factory = null
	_host_node = null
	_events.clear()
	_sequence_by_opcode.clear()
	_match_id = ""
	_room_code = ""
	_reconnect_token = ""
	_room_epoch = 0


func _rpc(rpc_id: String, payload: Dictionary) -> Dictionary:
	if _client == null or _session == null:
		return _failure("not_authenticated")
	var response: Variant = await _client.rpc_async(_session, rpc_id, JSON.stringify(payload))
	if response == null or response.is_exception():
		return _failure("rpc_failed")
	var parser := JSON.new()
	if parser.parse(str(response.payload)) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return _failure("rpc_malformed")
	var value: Dictionary = parser.data
	if not bool(value.get("ok", false)):
		var error: Dictionary = value.get("error", {})
		return _failure(str(error.get("code", "rpc_refused")))
	return _success(value)


func _join_from_rpc(value: Dictionary) -> Dictionary:
	_match_id = str(value.get("match_id", ""))
	_room_code = str(value.get("room_code", "")).to_upper()
	_reconnect_token = str(value.get("reconnect_token", ""))
	_room_epoch = int(value.get("room_epoch", 0))
	if _match_id.is_empty() or _reconnect_token.is_empty() or _room_epoch <= 0:
		return _failure("rpc_malformed")
	var joined: Variant = await _socket.join_match_async(
		_match_id, {"reconnect_token": _reconnect_token}
	)
	if joined == null or joined.is_exception():
		_match_id = ""
		_room_code = ""
		_reconnect_token = ""
		_room_epoch = 0
		return _failure("match_join_failed")
	return _success({"room_code": _room_code, "room_epoch": _room_epoch})


func _send_opcode(room_code: String, opcode: int, payload: Dictionary) -> Dictionary:
	var sequence := int(_sequence_by_opcode.get(opcode, 0)) + 1
	_sequence_by_opcode[opcode] = sequence
	return await send_envelope(room_code, {
		"protocol": PROTOCOL,
		"opcode": opcode,
		"room_epoch": _room_epoch,
		"sender_id": session_user_id(),
		"seq": sequence,
		"tick": _last_server_tick,
		"payload": payload,
	})


func _on_match_state(match_state: Variant) -> void:
	var parser := JSON.new()
	if parser.parse(str(match_state.data)) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		_append_error("event_malformed")
		return
	var event: Dictionary = parser.data
	if int(event.get("opcode", -1)) != int(match_state.op_code):
		_append_error("opcode_mismatch")
		return
	_last_server_tick = maxi(_last_server_tick, int(event.get("tick", 0)))
	_events.append(event)


func _on_socket_error(_error: Variant) -> void:
	_append_error("socket_error")


func _on_socket_closed() -> void:
	# A deliberate close during test teardown is not an authority error.
	pass


func _on_connection_error(_error: Variant) -> void:
	_append_error("connection_error")


func _append_error(code: String) -> void:
	_events.append({
		"protocol": PROTOCOL,
		"opcode": 15,
		"room_epoch": _room_epoch,
		"sender_id": "nakama",
		"seq": 0,
		"payload": {"code": code},
	})


func _success(value: Dictionary) -> Dictionary:
	return {"ok": true, "value": value}


func _failure(code: String) -> Dictionary:
	return {"ok": false, "error": {"code": code}}
