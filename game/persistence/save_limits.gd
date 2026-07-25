class_name SaveLimits
extends RefCounted
## Resource limits keep malformed local files from turning into unbounded work.

const SAVE_SCHEMA_VERSION: int = 1
const ENVELOPE_SCHEMA_VERSION: int = 1
const MAX_SAVE_BYTES: int = 4 * 1024 * 1024
const MAX_SAVED_TRACKS: int = 64
const MAX_TRACK_METADATA_BYTES: int = 4096
const MAX_TRACK_TAGS: int = 8
const MAX_TAG_LENGTH: int = 24
const MAX_THUMBNAIL_PATH_BYTES: int = 256
const MAX_BEST_LAPS: int = 256
const MAX_RACE_RESULTS: int = 200
const MAX_UNLOCKS: int = 128
const MAX_CONTENT_ID_BYTES: int = 96
const MAX_VEHICLE_ID_BYTES: int = 96
const MAX_RACE_TIME_MS: int = 86_400_000
const MAX_SAFE_JSON_INTEGER: int = 9_007_199_254_740_991
