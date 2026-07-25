# TrackDefinition Format

Status: **implemented schema-v1 contract**. Strict decoding, canonical hashing, quantization checks, v0→v1 migration, malformed-input rejection, and deterministic compilation fixtures exist in the repository. Exact test outcomes belong in `TEST_REPORT.md`; desktop coverage is not cross-platform Android/iOS determinism proof.

## Purpose

`TrackDefinition` is the compact authoritative input for saving, sharing, hashing, and deterministic generation. It stores the player's cleaned authoring shape and choices—not road pixels, collision polygons, scenery instances, racing-line samples, or other derived output.

Implementation: `game/track/definition/track_definition.gd`, `bridge_crossing_definition.gd`, `track_definition_migrator.gd`, `game/core/canonical_json.gd`, and `game/config/game_limits.gd`.

## Schema 1 envelope

Canonical transport is UTF-8 JSON. This structural example is illustrative, not a passing fixture:

```json
{
  "schema_version": 1,
  "generator_version": 2,
  "track_id": "track-0123456789abcdef",
  "track_name": "Pine Loop",
  "author_id": "local-anonymous",
  "canvas_size": [1920, 1080],
  "control_points": [[0.125, 0.25], [0.5, 0.125], [0.875, 0.375], [0.4, 0.8]],
  "direction": "clockwise",
  "target_length": 1200,
  "track_width": 72,
  "theme": "classic",
  "pit_side": "none",
  "decoration_density": 0.5,
  "deterministic_seed": "12345",
  "bridge_crossings": [],
  "start_finish_distance": 0,
  "created_at_timestamp": 0,
  "updated_at_timestamp": 0,
  "content_hash": "0000000000000000000000000000000000000000000000000000000000000000"
}
```

## Current field rules

| Field | Implemented representation/rule |
|---|---|
| `schema_version` | Integer; current supported output is `1`. A deterministic v0→v1 migrator and golden legacy fixture exist. |
| `generator_version` | Positive integer; the release compiler emits `2`. Exact source/generator/compiled fingerprints are required by the multiplayer ready gate. |
| `track_id` | UTF-8 string up to 96 bytes. Empty IDs created through `create()` become `track-` plus the first 16 hex characters of a deterministic SHA-256. |
| `track_name` | Non-empty after trimming; up to 80 Godot string characters. Control/bidi policy still needs hardening. |
| `author_id` | Opaque UTF-8 string up to 128 bytes; no real name is required. |
| `canvas_size` | Two finite values; each `256..16384`, total area at most `67,108,864`. Created and decoded values must lie on the `0.001` coordinate grid. |
| `control_points` | Ordered normalized pairs in `[0,1]`, quantized to `0.000001`; implicit closure from last to first; 4–256 points. |
| `direction` | `clockwise` or `counter_clockwise`. |
| `target_length` | Finite project units, `500..100000`. Released physical unit mapping must remain stable. |
| `track_width` | Finite project units, `12..512`, and less than half the smaller canvas side. |
| `theme` | Non-empty UTF-8 identifier up to 64 bytes; current default is `classic`. Released theme allow-list is not yet enforced. |
| `pit_side` | `none`, `left`, or `right`. |
| `decoration_density` | Finite value in `[0,1]`. |
| `deterministic_seed` | GDScript signed 64-bit integer in memory, serialized canonically as signed decimal text. Legacy numeric input is accepted only inside JavaScript's safe-integer range. |
| `bridge_crossings` | Up to 16 explicit declarations; see below. |
| `start_finish_distance` | Finite arc distance in `[0,target_length)`. |
| timestamps | Non-negative JSON-safe integer values; update must not precede creation. Current persistence treats them as Unix seconds. |
| `content_hash` | SHA-256 of canonical JSON with only this field omitted; empty is accepted for an in-memory definition, stored/shared definitions should refresh and require it. |

These values describe the current code, not evidence that every boundary is tested or a promise that v1 is release-frozen.

## Coordinates and quantization

The implementation captures normalized points and rounds them to a `1e-6` grid. Canvas dimensions, width, and other ordinary coordinates use a `1e-3` quantum where passed through the shared quantizer. `denormalized_control_points()` multiplies normalized coordinates by `canvas_size`.

Raw touch samples are not canonical network data. Preserve them locally only when needed for editable history. Canonical generation must begin from the quantized `control_points` and explicit version/seed, not platform-specific raw input or rendered pixels.

## Bridge crossings

Each schema-1 bridge declaration is:

```json
{
  "crossing_id": "bridge-0",
  "distance_a": 240.5,
  "distance_b": 880.25,
  "overpass": "a"
}
```

Distances are finite arc distances on the target lap and must be less than `target_length`; `overpass` is `a` or `b`; IDs are non-empty and unique. Arc distances deliberately avoid coupling the persisted crossing to a spline sample count. Geometry validation still must reject adjacent/ambiguous segments, insufficient approaches/clearance, impossible topology, and conflicting layer graphs. One continuous checkpoint/progress order is preserved.

## Canonical serialization and hash

`CanonicalJson.stringify()` currently:

1. Sorts dictionary string keys lexicographically.
2. Preserves array order.
3. Emits no insignificant whitespace.
4. Uses JSON string escaping.
5. Emits quantized floats in fixed decimal form with up to nine fractional digits, removes trailing zeroes, and normalizes negative zero.
6. Computes lowercase hexadecimal SHA-256 through Godot's `sha256_text()`.

`TrackDefinition.calculated_content_hash()` hashes every serialized field except `content_hash`, including identity, metadata, and timestamps. A hash proves canonical byte identity, not authorship or payload safety; validate the full document after receipt.

`CanonicalJson` has deterministic textual sentinels for non-finite floats, but `TrackDefinition.validate_schema()` rejects non-finite authority values. Trust-boundary callers validate a decoded definition before accepting its hash or compiling it; malformed nested values, NaN/infinity, oversize input, unsafe numeric seeds, and stale hashes are covered by the schema runner.

## Limits and trust boundary

- Maximum canonical serialized definition: 32,768 bytes.
- Maximum control points: 256; maximum input stroke samples elsewhere: 16,384.
- Maximum bridge declarations: 16.
- Unknown/future schema versions must be rejected or explicitly migrated, never guessed.
- Network/server layers may enforce a smaller measured payload cap.
- Do not deserialize network bytes into executable Godot objects.
- Reject invalid type, enum, range, quantization, size, hash, or geometry with a stable stage/field code; do not silently clamp malicious payloads.

`from_json()` rejects an oversize payload before parsing, records JSON/root-type errors, and `from_dictionary()` records missing, wrong-type, nested-shape, and unknown-field errors before conversion. The returned value object may therefore carry decode diagnostics; callers must still require `validate_schema().is_valid()` before storing, sharing, hashing as trusted content, or compiling it.

## Generation contract

Given the same canonical definition, schema/generator code, versioned configuration, and supported architecture, generation must yield equivalent authoritative samples, checkpoint order, bridge layers, and decoration placements. Render-only variation is allowed only when it cannot affect collision, visibility fairness, navigation, progress, or multiplayer readiness.

Use named random streams derived from `deterministic_seed` so adding one decoration/AI category does not perturb unrelated categories.

## Migration policy

- Current code migrates legacy schema `0` dictionaries to schema `1` with deterministic defaults/ID. `tests/fixtures/tracks/legacy_v0.json` and the track-domain runner exercise the golden migration and idempotent reparse contract.
- Decode the declared version, validate its permitted shape, migrate one version at a time, validate again, refresh hash, and write beside a backup.
- Migrations must be deterministic and idempotent; never mutate the only saved copy in place.
- Retain golden input, canonical bytes, hash, and generated metrics for every released schema/generator pair.
- Any authority-changing generator/config change increments `generator_version` even if schema fields do not change.
- Multiplayer never migrates implicitly during ready-up: the host supplies a supported canonical version or start is blocked.

## Required fixtures

The repository runners cover round-trip/canonical key order, quantization, max point/size/crossing bounds, malformed and nested types, NaN/infinity, unknown fields/enums/versions, hash mismatch, 64-bit seed preservation, closure/radius, bridge topology/order/layers, and v0→v1 idempotence. Unicode control/bidi policy and identical authoritative generation/hash on exported Android and iOS builds remain release-review items. Results and candidate evidence are reported in `TEST_REPORT.md`, not inferred from this inventory.
