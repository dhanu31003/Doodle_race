class_name NetworkLimits
extends RefCounted
## Versioned multiplayer limits shared by transports, clients, and tests.

const PROTOCOL_VERSION: int = 3
const APP_BUILD_ID: String = "0.3.0"
const TRACK_SCHEMA_VERSION: int = 2
const TRACK_GENERATOR_VERSION: int = 3
const SUPPORTED_PLATFORMS: Array[String] = ["android", "ios", "linux", "macos", "web", "windows"]
const MAX_PLAYERS: int = 12
const ROOM_CODE_LENGTH: int = 6
const ROOM_CODE_ALPHABET: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const ALLOWED_MULTIPLAYER_LAPS: Array[int] = [1, 3, 5]
const DEFAULT_MULTIPLAYER_LAPS: int = 3
const DEFAULT_MULTIPLAYER_COLLISIONS: bool = true

const MAX_PLAYER_ID_BYTES: int = 96
const MAX_DISPLAY_NAME_LENGTH: int = 24
const MAX_REQUEST_ID_BYTES: int = 96
const MAX_MESSAGE_BYTES: int = 65_536
const MAX_TRACK_DEFINITION_BYTES: int = 32_768
const MAX_ERROR_DETAIL_BYTES: int = 2_048
const MAX_SAFE_SEQUENCE: int = 9_007_199_254_740_991

const SIMULATION_HZ: int = 60
const INPUT_SUBMISSION_MIN_HZ: int = 10
const INPUT_SUBMISSION_MAX_HZ: int = 20
const AUTHORITATIVE_SNAPSHOT_MIN_HZ: int = 10
const AUTHORITATIVE_SNAPSHOT_MAX_HZ: int = 15
const INPUT_INTERVAL_MS: int = 1000 / INPUT_SUBMISSION_MAX_HZ
const SNAPSHOT_INTERVAL_MS: int = 1000 / 12
const MAX_INPUT_FRAMES_PER_SECOND: int = INPUT_SUBMISSION_MAX_HZ
const MAX_SNAPSHOTS_PER_SECOND: int = AUTHORITATIVE_SNAPSHOT_MAX_HZ
const MAX_CONTROL_MESSAGES_PER_SECOND: int = 12

const COUNTDOWN_SECONDS: int = 3
const COUNTDOWN_TICKS: int = SIMULATION_HZ * COUNTDOWN_SECONDS
const RECONNECT_WINDOW_MS: int = 20_000
const MAX_STALE_INPUT_TICKS: int = SIMULATION_HZ * 2
const MAX_FUTURE_INPUT_TICKS: int = 6
const PREDICTION_HISTORY_TICKS: int = SIMULATION_HZ * 3
const INTERPOLATION_BUFFER_SNAPSHOTS: int = 32
const INTERPOLATION_DELAY_TICKS: int = 6
const HARD_RECONCILE_DISTANCE_Q: int = 2_000

const STEERING_MIN: int = -1000
const STEERING_MAX: int = 1000
const PEDAL_MIN: int = 0
const PEDAL_MAX: int = 1000
const WORLD_COORDINATE_Q_LIMIT: int = 1_000_000_000
const VELOCITY_Q_LIMIT: int = 10_000_000
const ROTATION_Q_LIMIT: int = 6_283_185
const ENGINE_RPM_Q_LIMIT: int = 200_000
const SHIFT_TICKS_LIMIT: int = 120
const STEERING_STATE_Q_LIMIT: int = 10_000
const SLIP_ANGLE_Q_LIMIT: int = 15_708
const WHEEL_SLIP_Q_LIMIT: int = 40_000
const LATERAL_ACCELERATION_Q_LIMIT: int = 2_000_000
const VERTICAL_OFFSET_Q_LIMIT: int = 120_000
const VERTICAL_VELOCITY_Q_LIMIT: int = 300_000
const CONTACT_SERIAL_LIMIT: int = MAX_SAFE_SEQUENCE
const CONTACT_TICK_LIMIT: int = MAX_SAFE_SEQUENCE
const CONTACT_SPEED_Q_LIMIT: int = 2_000_000
const CONTACT_NORMAL_Q_LIMIT: int = 10_000
const CONTACT_NORMAL_LENGTH_Q_MIN: int = 9_900
const CONTACT_NORMAL_LENGTH_Q_MAX: int = 10_100

const ROOM_CREATE_ATTEMPTS_PER_MINUTE: int = 5
const ROOM_JOIN_ATTEMPTS_PER_MINUTE: int = 10
const MALFORMED_MESSAGES_BEFORE_QUARANTINE: int = 8

const ROOM_CREATING: StringName = &"CREATING"
const ROOM_LOBBY: StringName = &"LOBBY"
const ROOM_TRACK_SYNC: StringName = &"TRACK_SYNC"
const ROOM_READY: StringName = &"READY"
const ROOM_COUNTDOWN: StringName = &"COUNTDOWN"
const ROOM_RACING: StringName = &"RACING"
const ROOM_RESULTS: StringName = &"RESULTS"
const ROOM_CLOSED: StringName = &"CLOSED"

const HOST_DEPARTURE_LOBBY_POLICY: StringName = &"transfer_oldest_connected"
const HOST_DEPARTURE_RACE_POLICY: StringName = &"end_race"


static func is_valid_multiplayer_lap_count(value: Variant) -> bool:
	return typeof(value) == TYPE_INT and ALLOWED_MULTIPLAYER_LAPS.has(int(value))


static func default_race_config() -> Dictionary:
	return {
		"laps": DEFAULT_MULTIPLAYER_LAPS,
		"collisions": DEFAULT_MULTIPLAYER_COLLISIONS,
	}


static func compatibility_payload(platform_name: String = "") -> Dictionary:
	var platform := platform_name.strip_edges().to_lower()
	if platform.is_empty():
		platform = OS.get_name().strip_edges().to_lower()
	return {
		"app_build": APP_BUILD_ID,
		"protocol_version": PROTOCOL_VERSION,
		"track_schema_version": TRACK_SCHEMA_VERSION,
		"generator_version": TRACK_GENERATOR_VERSION,
		"platform": platform,
	}
