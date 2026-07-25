class_name NetworkEndpoint
extends RefCounted
## Local/private Nakama endpoint configuration. Defaults deliberately target
## loopback on desktop and Android emulator host forwarding; no public service
## is implied or contacted without an explicit override.

const DEFAULT_PORT := 7350
const DEFAULT_SERVER_KEY := "defaultkey"


static func defaults() -> Dictionary:
	return {
		"host": "10.0.2.2" if OS.get_name() == "Android" else "127.0.0.1",
		"port": DEFAULT_PORT,
		"server_key": DEFAULT_SERVER_KEY,
		"scheme": "http",
	}


static func from_runtime_overrides(base: Dictionary = {}) -> Dictionary:
	var value := defaults()
	value.merge(base, true)
	var environment_host := OS.get_environment("RACEGLYPH_NAKAMA_HOST").strip_edges()
	var environment_port := OS.get_environment("RACEGLYPH_NAKAMA_PORT").strip_edges()
	var environment_scheme := OS.get_environment("RACEGLYPH_NAKAMA_SCHEME").strip_edges().to_lower()
	var environment_key := OS.get_environment("RACEGLYPH_NAKAMA_SERVER_KEY").strip_edges()
	if not environment_host.is_empty():
		value["host"] = environment_host
	if environment_port.is_valid_int():
		value["port"] = int(environment_port)
	if environment_scheme in ["http", "https"]:
		value["scheme"] = environment_scheme
	if not environment_key.is_empty():
		value["server_key"] = environment_key
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--nakama-host="):
			value["host"] = argument.trim_prefix("--nakama-host=")
		elif argument.begins_with("--nakama-port=") and argument.trim_prefix("--nakama-port=").is_valid_int():
			value["port"] = int(argument.trim_prefix("--nakama-port="))
		elif argument.begins_with("--nakama-scheme="):
			value["scheme"] = argument.trim_prefix("--nakama-scheme=").to_lower()
		elif argument.begins_with("--nakama-key="):
			value["server_key"] = argument.trim_prefix("--nakama-key=")
	return sanitize(value)


static func sanitize(value: Dictionary) -> Dictionary:
	var host := str(value.get("host", "")).strip_edges()
	if not _valid_host(host):
		host = str(defaults()["host"])
	var local_development := _is_local_development_host(host)
	var port := int(value.get("port", DEFAULT_PORT))
	if port < 1 or port > 65_535:
		port = DEFAULT_PORT
	var scheme := str(value.get("scheme", "http")).strip_edges().to_lower()
	if scheme != "http" and scheme != "https":
		scheme = "http" if local_development else "https"
	# Nakama's SDK derives ws/wss from this same scheme. Cleartext transport is
	# limited to exact loopback/emulator addresses; runtime flags and environment
	# overrides cannot downgrade an arbitrary remote host.
	if scheme == "http" and not local_development:
		scheme = "https"
	var server_key := str(value.get("server_key", DEFAULT_SERVER_KEY)).strip_edges()
	if server_key.is_empty() or server_key.length() > 128:
		server_key = DEFAULT_SERVER_KEY
	return {"host": host, "port": port, "scheme": scheme, "server_key": server_key}


static func _is_local_development_host(value: String) -> bool:
	return value.to_lower() in ["127.0.0.1", "localhost", "::1", "10.0.2.2"]


static func _valid_host(value: String) -> bool:
	if value.is_empty() or value.length() > 253:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) or value[index] in [".", "-", ":"]):
			return false
	return true
