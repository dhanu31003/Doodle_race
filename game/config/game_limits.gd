class_name GameLimits
extends RefCounted
## Central, versioned limits for user-authored tracks.
##
## Keep these values deterministic and platform-neutral. Changing a value that
## affects compilation requires incrementing TrackCompiler.COMPILER_VERSION.

const TRACK_SCHEMA_VERSION: int = 2
const TRACK_COMPILER_VERSION: int = 3

const COORDINATE_SCALE: int = 1000
const COORDINATE_QUANTUM: float = 1.0 / float(COORDINATE_SCALE)
const NORMALIZED_SCALE: int = 1_000_000
const NORMALIZED_QUANTUM: float = 1.0 / float(NORMALIZED_SCALE)

const MIN_CANVAS_SIDE: float = 256.0
const MAX_CANVAS_SIDE: float = 16384.0
const MAX_CANVAS_AREA: float = 67_108_864.0

const MIN_TRACK_WIDTH: float = 12.0
const MAX_TRACK_WIDTH: float = 512.0
const MIN_CONTROL_POINTS: int = 4
const MAX_CONTROL_POINTS: int = 256
const MAX_INPUT_STROKE_POINTS: int = 16384
const MIN_RESAMPLED_POINTS: int = 32
const MAX_RESAMPLED_POINTS: int = 8192
const MAX_TRACK_DEFINITION_BYTES: int = 32_768
const MAX_SAFE_JSON_INTEGER: int = 9_007_199_254_740_991

const MAX_TRACK_ID_BYTES: int = 96
const MAX_AUTHOR_ID_BYTES: int = 128
const MAX_DISPLAY_NAME_LENGTH: int = 80
const MAX_THEME_BYTES: int = 64
const MAX_ROAD_SURFACE_BYTES: int = 32
const MAX_BRIDGE_CROSSINGS: int = 16

const MAX_TARGET_LENGTH: float = 100_000.0
const MIN_DECORATION_DENSITY: float = 0.0
const MAX_DECORATION_DENSITY: float = 1.0

const DEFAULT_STROKE_MIN_SPACING: float = 2.0
const DEFAULT_STROKE_SIMPLIFY_TOLERANCE: float = 0.75
const DEFAULT_CLOSE_SNAP_DISTANCE: float = 18.0
const DEFAULT_SPLINE_SUBDIVISIONS: int = 24
const DEFAULT_SAMPLE_SPACING: float = 6.0
const MIN_SAMPLE_SPACING: float = 1.0
const MAX_SAMPLE_SPACING: float = 64.0

const MIN_TRACK_LENGTH: float = 500.0
const MIN_TURN_RADIUS: float = 18.0
const MIN_RADIUS_TO_WIDTH_RATIO: float = 0.50
const START_STRAIGHT_LENGTH: float = 96.0
const START_STRAIGHT_MAX_ANGLE_DEGREES: float = 10.0
const PIT_STRAIGHT_LENGTH: float = 180.0
const GEOMETRY_EPSILON: float = 0.000001
const STRAIGHT_CURVATURE_EPSILON: float = 0.00001
