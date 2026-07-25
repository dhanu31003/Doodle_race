extends SceneTree
## Release-quality deterministic offline race soak.
##
## This is intentionally separate from the fast race unit suite. It runs full
## fixed-step authority with the production vehicle, AI, lap, and contact code.

const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackQueryType := preload("res://game/race/track_query.gd")
const DirectorType := preload("res://game/race/race_director.gd")
const AiRosterType := preload("res://game/ai/ai_roster.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const TrackCatalogType := preload("res://tests/race/ai_soak_track_catalog.gd")
const PredefinedCatalogType := preload("res://game/content/predefined_track_catalog.gd")

const DEFAULT_OUTPUT_PATH := "res://evidence/runtime/ai_soak_report.json"
const FIELD_SIZE := 12
const REPRESENTATIVE_LAPS := 20
const CORPUS_LAPS := 1
const CHECKPOINTS := 12
const STUCK_WINDOW_TICKS := 60 * 12
const PROGRESS_EPSILON := 1.0
const MIN_CORPUS_PASS_RATE := 0.95
const MAX_TICKS_HARD_CAP := 60 * 900
## Generation 2 keeps the frozen 20-lap coverage after the two catalog
## representatives became 2.5x longer.  The 2.7M aggregate ceiling preserves
## the previous clean-baseline timing margin without cutting race coverage.
const HOST_WALL_TIME_CEILING_MS := 2_700_000
const HOST_MIN_AUTHORITY_VEHICLE_STEPS_PER_SECOND := 1_100.0
const SAME_SEED_DIRECTOR_MULTIPLIER := 2
const DETERMINISM_SAMPLE_INTERVAL_TICKS := 600
const MAX_REPRESENTATIVE_RECOVERIES_PER_CAR := 4
const MAX_CORPUS_RECOVERIES_PER_CAR := 2

var _failures: Array[String] = []


func _initialize() -> void:
	var soak_target := OS.get_environment("RACE_SOAK_TARGET")
	if soak_target == "bridge_probe":
		_run_bridge_recovery_probe()
		return
	if soak_target == "representative_probe":
		_run_representative_pace_probe()
		return
	if soak_target == "predefined_catalog_smoke":
		_run_predefined_catalog_smoke()
		return
	var started_usec := Time.get_ticks_usec()
	var report := {
		"schema_version": 2,
		"suite": "offline_ai_release_soak",
		"fixed_hz": 60,
		"field_size": FIELD_SIZE,
		"representative_laps": REPRESENTATIVE_LAPS,
		"corpus_laps": CORPUS_LAPS,
		"stuck_window_ticks": STUCK_WINDOW_TICKS,
		"physics_changes_for_soak": false,
		"host_timing_scope": "Development-host regression evidence only; not mobile FPS or thermal proof.",
		"host": {
			"os": OS.get_name(),
			"processor": OS.get_processor_name(),
			"logical_cpu_count": OS.get_processor_count(),
			"godot": Engine.get_version_info(),
		},
		"gates": {
			"representative_track_count": 4,
			"representative_laps_each": REPRESENTATIVE_LAPS,
			"representative_required_finish_rate": 1.0,
			"representative_max_dnfs": 0,
			"representative_max_invalid_motion": 0,
			"representative_max_non_finite_states": 0,
			"representative_max_stuck_episodes": 0,
			"representative_max_recoveries_per_car": MAX_REPRESENTATIVE_RECOVERIES_PER_CAR,
			"corpus_track_count": 20,
			"corpus_laps_each": CORPUS_LAPS,
			"corpus_required_track_pass_rate": MIN_CORPUS_PASS_RATE,
			"corpus_track_requires_all_cars_finished": true,
			"corpus_max_recoveries_per_car": MAX_CORPUS_RECOVERIES_PER_CAR,
			"same_seed_twin_authority_required": true,
			"same_seed_director_multiplier": SAME_SEED_DIRECTOR_MULTIPLIER,
			"determinism_sample_interval_ticks": DETERMINISM_SAMPLE_INTERVAL_TICKS,
			"host_wall_time_ceiling_ms": HOST_WALL_TIME_CEILING_MS,
			"host_min_authority_vehicle_steps_per_second": HOST_MIN_AUTHORITY_VEHICLE_STEPS_PER_SECOND,
		},
		"representative_runs": [],
		"corpus": {},
		"failures": [],
	}

	var representative_specs := TrackCatalogType.representative_specs()
	for spec in representative_specs:
		var run_result := _run_spec(spec, REPRESENTATIVE_LAPS, true)
		report["representative_runs"].append(run_result)
		_gate_representative(run_result)
		_print_run("REPRESENTATIVE", run_result)

	var corpus_result := _run_corpus()
	report["corpus"] = corpus_result
	_gate_corpus(corpus_result)

	report["wall_time_ms"] = int((Time.get_ticks_usec() - started_usec) / 1000)
	var primary_fixed_ticks := _total_primary_fixed_ticks(report)
	var authority_vehicle_steps := primary_fixed_ticks * FIELD_SIZE * SAME_SEED_DIRECTOR_MULTIPLIER
	var wall_time_seconds := maxf(float(report["wall_time_ms"]) / 1000.0, 0.001)
	var authority_vehicle_steps_per_second := float(authority_vehicle_steps) / wall_time_seconds
	var host_microseconds_per_authority_vehicle_step := \
		float(report["wall_time_ms"]) * 1000.0 / float(authority_vehicle_steps) \
		if authority_vehicle_steps > 0 else INF
	report["host_performance"] = {
		"primary_fixed_ticks": primary_fixed_ticks,
		"authority_vehicle_steps": authority_vehicle_steps,
		"authority_vehicle_steps_per_second": snappedf(
			authority_vehicle_steps_per_second, 0.001
		),
		"host_microseconds_per_authority_vehicle_step": snappedf(
			host_microseconds_per_authority_vehicle_step, 0.001
		),
	}
	if int(report["wall_time_ms"]) > HOST_WALL_TIME_CEILING_MS:
		_failures.append("development-host wall time %d ms exceeded frozen %d ms ceiling" % [
			int(report["wall_time_ms"]), HOST_WALL_TIME_CEILING_MS
		])
	if authority_vehicle_steps_per_second < HOST_MIN_AUTHORITY_VEHICLE_STEPS_PER_SECOND:
		_failures.append(
			"development-host authority throughput %.1f vehicle-steps/s fell below frozen %.1f minimum" % [
				authority_vehicle_steps_per_second,
				HOST_MIN_AUTHORITY_VEHICLE_STEPS_PER_SECOND,
			]
		)
	report["failures"] = _failures
	report["passed"] = _failures.is_empty()
	report["report_digest"] = _digest(_report_digest_payload(report))
	var output_path := OS.get_environment("RACE_SOAK_OUTPUT")
	if output_path.is_empty():
		output_path = DEFAULT_OUTPUT_PATH
	var write_ok := _write_report(output_path, report)
	if not write_ok:
		_failures.append("could not write soak report to %s" % output_path)
		report["passed"] = false

	print("AI soak: %d representative, %d corpus, %.1f%% corpus pass, %d ms" % [
		report["representative_runs"].size(),
		int(corpus_result.get("track_count", 0)),
		float(corpus_result.get("pass_rate", 0.0)) * 100.0,
		int(report["wall_time_ms"]),
	])
	print("AI soak host: %d primary ticks, %d authority vehicle-steps, %.1f steps/s, %.1f us/step" % [
		primary_fixed_ticks,
		authority_vehicle_steps,
		authority_vehicle_steps_per_second,
		host_microseconds_per_authority_vehicle_step,
	])
	print("AI soak report: %s" % ProjectSettings.globalize_path(output_path))
	if _failures.is_empty() and write_ok:
		print("PASS offline AI release soak")
		quit(0)
	else:
		for failure in _failures:
			print("FAIL %s" % failure)
		quit(1)


func _run_representative_pace_probe() -> void:
	var requested_id := OS.get_environment("RACE_SOAK_PROBE_TRACK")
	var requested_laps := int(OS.get_environment("RACE_SOAK_PROBE_LAPS")) \
		if not OS.get_environment("RACE_SOAK_PROBE_LAPS").is_empty() else 2
	var probe_laps := clampi(requested_laps, 1, REPRESENTATIVE_LAPS)
	var selected: Dictionary = {}
	for spec in TrackCatalogType.representative_specs():
		if requested_id.is_empty() or str(spec.get("id", "")) == requested_id:
			selected = spec
			break
	if selected.is_empty():
		print("FAIL representative pace probe: unknown track %s" % requested_id)
		quit(1)
		return
	var probe_collisions := OS.get_environment("RACE_SOAK_PROBE_COLLISIONS") != "0"
	var result := _run_spec(selected, probe_laps, false, probe_collisions)
	var passed := bool(result.get("compiled", false)) \
		and int(result.get("finishes", 0)) == FIELD_SIZE \
		and int(result.get("dnfs", FIELD_SIZE)) == 0 \
		and int(result.get("invalid_motion", 1)) == 0 \
		and int(result.get("non_finite_states", 1)) == 0 \
		and int(result.get("stuck_episodes", FIELD_SIZE)) == 0 \
		and _within_recovery_budget(result, MAX_REPRESENTATIVE_RECOVERIES_PER_CAR)
	_print_run("PACE_PROBE", result)
	var diagnostic_compile := TrackCompilerType.compile(selected.get("definition"))
	var diagnostic_query := TrackQueryType.from_compiled(diagnostic_compile.track) \
		if diagnostic_compile.track != null else null
	for state_variant in result.get("final_states", []):
		if state_variant is Dictionary \
				and int(state_variant.get("automatic_recoveries", 0)) > 0:
			print("PACE_RECOVERY %s %s" % [
				str(state_variant.get("participant_id", "unknown")),
				str(state_variant.get("recovery_events", [])),
			])
			if diagnostic_query != null and diagnostic_query.is_valid():
				for event_variant in state_variant.get("recovery_events", []):
					if event_variant is Dictionary:
						var event_sample := diagnostic_query.sample_at_distance(
							float(event_variant.get("track_distance", 0.0))
						)
						print("PACE_RECOVERY_GEOMETRY radius=%.2f in_corner=%s" % [
							float(event_sample.get("radius", INF)),
							str(event_sample.get("in_corner", false)),
						])
	print("PASS representative pace probe" if passed else "FAIL representative pace probe")
	quit(0 if passed else 1)


func _run_predefined_catalog_smoke() -> void:
	var started_usec := Time.get_ticks_usec()
	var passed_tracks := 0
	var items := PredefinedCatalogType.all()
	for item in items:
		var definition: TrackDefinition = item.get("definition")
		var run_result := _run_spec({
			"id": str(item.get("track_id", "")),
			"archetype": str(item.get("archetype", "")),
			"seed": int(item.get("seed", 1)),
			"definition": definition,
		}, 1, false, false)
		var passed := bool(run_result.get("compiled", false)) \
			and int(run_result.get("finishes", 0)) == FIELD_SIZE \
			and int(run_result.get("dnfs", FIELD_SIZE)) == 0 \
			and int(run_result.get("invalid_motion", 1)) == 0 \
			and int(run_result.get("non_finite_states", 1)) == 0 \
			and int(run_result.get("stuck_episodes", FIELD_SIZE)) == 0 \
			and _within_recovery_budget(
				run_result, MAX_REPRESENTATIVE_RECOVERIES_PER_CAR
			)
		run_result["passed"] = passed
		_print_run("CATALOG_SMOKE", run_result)
		if passed:
			passed_tracks += 1
		else:
			print("CATALOG_SMOKE_FAILURE id=%s result=%s" % [
				str(item.get("track_id", "")),
				str(run_result),
			])
	var wall_time_ms := int((Time.get_ticks_usec() - started_usec) / 1000)
	var passed := items.size() == 6 and passed_tracks == items.size()
	print("PREDEFINED_AI_SMOKE tracks=%d passed=%d laps=1 field=%d collisions=false wall_ms=%d" % [
		items.size(), passed_tracks, FIELD_SIZE, wall_time_ms,
	])
	print("PASS predefined 12-car AI finish smoke" if passed \
		else "FAIL predefined 12-car AI finish smoke")
	quit(0 if passed else 1)


func _run_bridge_recovery_probe() -> void:
	var specs := TrackCatalogType.representative_specs()
	var bridge_spec: Dictionary = specs[3]
	var requested_laps := int(OS.get_environment("RACE_SOAK_PROBE_LAPS")) \
		if not OS.get_environment("RACE_SOAK_PROBE_LAPS").is_empty() else 3
	var probe_laps := clampi(requested_laps, 1, REPRESENTATIVE_LAPS)
	var result := _run_spec(bridge_spec, probe_laps, true)
	var passed := bool(result.get("compiled", false)) \
		and int(result.get("finishes", 0)) == FIELD_SIZE \
		and int(result.get("dnfs", FIELD_SIZE)) == 0 \
		and int(result.get("invalid_motion", 1)) == 0 \
		and int(result.get("non_finite_states", 1)) == 0 \
		and int(result.get("stuck_episodes", FIELD_SIZE)) == 0 \
		and _within_recovery_budget(result, MAX_REPRESENTATIVE_RECOVERIES_PER_CAR) \
		and bool(result.get("deterministic", false))
	var report := {
		"schema_version": 1,
		"suite": "bridge_recovery_targeted_probe",
		"laps": probe_laps,
		"field_size": FIELD_SIZE,
		"max_recoveries_per_car": MAX_REPRESENTATIVE_RECOVERIES_PER_CAR,
		"passed": passed,
		"run": result,
	}
	var output_path := "res://evidence/runtime/ai_bridge_recovery_probe.json"
	var write_ok := _write_report(output_path, report)
	_print_run("BRIDGE_PROBE", result)
	print("Bridge recovery probe: %s" % ProjectSettings.globalize_path(output_path))
	print("PASS bridge recovery probe" if passed and write_ok else "FAIL bridge recovery probe")
	quit(0 if passed and write_ok else 1)


func _run_corpus() -> Dictionary:
	var parsed := TrackCatalogType.corpus_fixture()
	if parsed.is_empty():
		return {"track_count": 0, "passed_tracks": 0, "pass_rate": 0.0, "runs": [], "error": "fixture_parse_failed"}
	var records: Array = parsed.get("tracks", [])
	var runs: Array[Dictionary] = []
	var passed_tracks := 0
	var source_hashes: Array[String] = []
	var compile_hashes: Array[String] = []
	for record_variant in records:
		if not record_variant is Dictionary:
			continue
		var record: Dictionary = record_variant
		var definition := TrackCatalogType.corpus_definition(record)
		var run_result := _run_spec({
			"id": str(record.get("id", "corpus-invalid")),
			"archetype": "generated_corpus",
			"seed": int(record.get("seed", 1)),
			"definition": definition,
		}, CORPUS_LAPS, true)
		runs.append(run_result)
		source_hashes.append(str(run_result.get("source_hash", "")))
		compile_hashes.append(str(run_result.get("compiled_hash", "")))
		var passed := bool(run_result.get("compiled", false)) \
			and int(run_result.get("finishes", 0)) == FIELD_SIZE \
			and int(run_result.get("dnfs", FIELD_SIZE)) == 0 \
			and int(run_result.get("invalid_motion", 1)) == 0 \
			and int(run_result.get("non_finite_states", 1)) == 0 \
			and int(run_result.get("stuck_episodes", FIELD_SIZE)) == 0 \
			and _within_recovery_budget(run_result, MAX_CORPUS_RECOVERIES_PER_CAR) \
			and bool(run_result.get("deterministic", false))
		run_result["passed"] = passed
		if passed:
			passed_tracks += 1
		_print_run("CORPUS", run_result)
	var track_count := runs.size()
	var pass_rate := float(passed_tracks) / float(track_count) if track_count > 0 else 0.0
	return {
		"corpus_id": str(parsed.get("corpus_id", "")),
		"generator": str(parsed.get("generator", "")),
		"fixture_path": TrackCatalogType.CORPUS_PATH,
		"fixture_digest": FileAccess.get_file_as_string(TrackCatalogType.CORPUS_PATH).sha256_text(),
		"track_count": track_count,
		"passed_tracks": passed_tracks,
		"failed_tracks": track_count - passed_tracks,
		"pass_rate": snappedf(pass_rate, 0.000001),
		"required_pass_rate": MIN_CORPUS_PASS_RATE,
		"source_hash_set_digest": _digest(source_hashes),
		"compile_hash_set_digest": _digest(compile_hashes),
		"runs": runs,
	}


func _run_spec(
		spec: Dictionary,
		laps: int,
		verify_determinism: bool,
		enable_vehicle_collisions: bool = true
	) -> Dictionary:
	var run_started := Time.get_ticks_usec()
	var definition: TrackDefinition = spec.get("definition")
	var compile_result := TrackCompilerType.compile(definition)
	var compile_codes: Array[String] = []
	for issue in compile_result.report.issues:
		if issue.severity_name() == "error":
			compile_codes.append(str(issue.code))
	if compile_result.track == null or not compile_result.report.is_valid():
		return {
			"track_id": str(spec.get("id", "")),
			"archetype": str(spec.get("archetype", "")),
			"compiled": false,
			"compile_errors": compile_codes,
			"wall_time_ms": int((Time.get_ticks_usec() - run_started) / 1000),
		}
	var query := TrackQueryType.from_compiled(compile_result.track)
	if not query.is_valid():
		return {
			"track_id": str(spec.get("id", "")),
			"archetype": str(spec.get("archetype", "")),
			"compiled": false,
			"compile_errors": ["race_query:%s" % str(query.error)],
			"wall_time_ms": int((Time.get_ticks_usec() - run_started) / 1000),
		}
	var timeout_seconds := minf(880.0, maxf(90.0, float(laps) * query.total_length / 52.0 + 90.0))
	var primary := _build_director(
		query, laps, int(spec.get("seed", 1)), timeout_seconds, enable_vehicle_collisions
	)
	var replay := _build_director(
		query, laps, int(spec.get("seed", 1)), timeout_seconds, enable_vehicle_collisions
	) if verify_determinism else null
	var progress_state: Dictionary = {}
	var contact_pairs: Dictionary = {}
	var vehicle_contact_events := 0
	var offtrack_recoveries := 0
	var stuck_recoveries := 0
	var non_finite_states := 0
	var determinism_samples := 0
	var speed_samples: Array[float] = []
	for entry in primary.entries:
		progress_state[entry.participant_id] = {
			"last_progress": entry.classification_progress(),
			"last_change_tick": 0,
			"last_recovery_count": entry.automatic_recovery_count,
			"max_stagnant_ticks": 0,
			"in_stuck_episode": false,
			"stuck_episodes": 0,
			"was_offtrack": entry.state.is_offtrack,
		}
	var determinism_matches := true
	var tick_limit := mini(MAX_TICKS_HARD_CAP, ceili(timeout_seconds * 60.0) + 5)
	while primary.phase != DirectorType.PHASE_RESULTS and primary.fixed_tick < tick_limit:
		primary.tick_fixed()
		if replay != null:
			replay.tick_fixed()
		if primary.phase != DirectorType.PHASE_RACING:
			continue
		for entry in primary.entries:
			var monitor: Dictionary = progress_state[entry.participant_id]
			if not entry.state.is_finite():
				non_finite_states += 1
			if entry.status != RaceEntry.STATUS_RACING:
				monitor["in_stuck_episode"] = false
				progress_state[entry.participant_id] = monitor
				continue
			var progress := entry.classification_progress()
			# An authority recovery can intentionally move a car backwards to a safe
			# road sample. Start a fresh progress window there instead of counting the
			# time spent re-covering that distance as a second stuck episode.
			if entry.automatic_recovery_count > int(monitor["last_recovery_count"]):
				monitor["last_recovery_count"] = entry.automatic_recovery_count
				monitor["last_progress"] = progress
				monitor["last_change_tick"] = primary.fixed_tick
				monitor["in_stuck_episode"] = false
			if progress >= float(monitor["last_progress"]) + PROGRESS_EPSILON:
				if bool(monitor["in_stuck_episode"]):
					stuck_recoveries += 1
				monitor["in_stuck_episode"] = false
				monitor["last_progress"] = progress
				monitor["last_change_tick"] = primary.fixed_tick
			var stagnant_ticks := primary.fixed_tick - int(monitor["last_change_tick"])
			monitor["max_stagnant_ticks"] = maxi(int(monitor["max_stagnant_ticks"]), stagnant_ticks)
			if stagnant_ticks >= STUCK_WINDOW_TICKS and not bool(monitor["in_stuck_episode"]):
				monitor["in_stuck_episode"] = true
				monitor["stuck_episodes"] = int(monitor["stuck_episodes"]) + 1
			if bool(monitor["was_offtrack"]) and not entry.state.is_offtrack:
				offtrack_recoveries += 1
			monitor["was_offtrack"] = entry.state.is_offtrack
			progress_state[entry.participant_id] = monitor
			if primary.fixed_tick % 60 == 0:
				speed_samples.append(entry.state.speed())
		vehicle_contact_events += _sample_vehicle_contacts(primary, contact_pairs)
		if replay != null and primary.fixed_tick % DETERMINISM_SAMPLE_INTERVAL_TICKS == 0:
			determinism_samples += 1
			determinism_matches = determinism_matches and _authority_digest(primary) == _authority_digest(replay)

	var invalid_motion := 0
	var wall_contacts := 0
	var automatic_recoveries := 0
	var offtrack_authority_recoveries := 0
	var contact_authority_recoveries := 0
	var stuck_cars := 0
	var stuck_episodes := 0
	var maximum_stagnant_ticks := 0
	var final_states: Array[Dictionary] = []
	for entry in primary.entries:
		invalid_motion += entry.lap_tracker.invalid_motion_count
		wall_contacts += entry.state.wall_contacts
		automatic_recoveries += entry.automatic_recovery_count
		offtrack_authority_recoveries += entry.recovery_offtrack_count
		contact_authority_recoveries += entry.recovery_contact_count
		var monitor: Dictionary = progress_state[entry.participant_id]
		maximum_stagnant_ticks = maxi(maximum_stagnant_ticks, int(monitor["max_stagnant_ticks"]))
		stuck_episodes += int(monitor["stuck_episodes"])
		if bool(monitor["in_stuck_episode"]):
			stuck_cars += 1
		final_states.append({
			"participant_id": str(entry.participant_id),
			"status": str(entry.status),
			"laps_completed": entry.lap_tracker.laps_completed,
			"invalid_motion": entry.lap_tracker.invalid_motion_count,
			"wall_contacts": entry.state.wall_contacts,
			"automatic_recoveries": entry.automatic_recovery_count,
			"offtrack_recoveries": entry.recovery_offtrack_count,
			"contact_recoveries": entry.recovery_contact_count,
			"last_recovery_tick": entry.recovery_last_tick,
			"last_recovery_reason": str(entry.recovery_last_reason),
			"recovery_events": entry.recovery_events.duplicate(true),
			"stuck_episodes": int(monitor["stuck_episodes"]),
			"max_stagnant_ticks": int(monitor["max_stagnant_ticks"]),
			"authority_digest": _digest(entry.state.authority_snapshot()),
		})
	if replay != null:
		determinism_matches = determinism_matches \
			and primary.fixed_tick == replay.fixed_tick \
			and _authority_digest(primary) == _authority_digest(replay) \
			and _digest(primary.results()) == _digest(replay.results())
	var results := primary.results()
	var finishes := 0
	var dnfs := 0
	var first_finish_time := INF
	var last_finish_time := 0.0
	for result in results:
		if str(result.get("status", "")) == "finished":
			finishes += 1
			first_finish_time = minf(first_finish_time, float(result.get("finish_time", INF)))
			last_finish_time = maxf(last_finish_time, float(result.get("finish_time", 0.0)))
		elif str(result.get("status", "")) == "dnf":
			dnfs += 1
	speed_samples.sort()
	var sampled_speed_mean := 0.0
	for sampled_speed in speed_samples:
		sampled_speed_mean += sampled_speed
	if not speed_samples.is_empty():
		sampled_speed_mean /= float(speed_samples.size())
	var sampled_speed_median := speed_samples[speed_samples.size() / 2] \
		if not speed_samples.is_empty() else 0.0
	var sampled_speed_p90 := speed_samples[mini(
		speed_samples.size() - 1, floori(float(speed_samples.size()) * 0.90)
	)] if not speed_samples.is_empty() else 0.0
	return {
		"track_id": str(spec.get("id", "")),
		"archetype": str(spec.get("archetype", "")),
		"compiled": true,
		"source_hash": compile_result.track.source_hash,
		"compiled_hash": compile_result.track.compile_hash,
		"lap_length": compile_result.track.total_length,
		"sample_count": compile_result.track.centerline.size(),
		"bridge_crossings": compile_result.track.bridge_crossings.size(),
		"laps": laps,
		"ticks": primary.fixed_tick,
		"simulated_seconds": snappedf(primary.race_time, 0.001),
		"first_finish_time": snappedf(first_finish_time, 0.001) if finishes > 0 else -1.0,
		"last_finish_time": snappedf(last_finish_time, 0.001) if finishes > 0 else -1.0,
		"sampled_speed_mean": snappedf(sampled_speed_mean, 0.01),
		"sampled_speed_median": snappedf(sampled_speed_median, 0.01),
		"sampled_speed_p90": snappedf(sampled_speed_p90, 0.01),
		"timeout_seconds": snappedf(timeout_seconds, 0.001),
		"finishes": finishes,
		"dnfs": dnfs,
		"invalid_motion": invalid_motion,
		"non_finite_states": non_finite_states,
		"stuck_cars": stuck_cars,
		"stuck_episodes": stuck_episodes,
		"maximum_stagnant_ticks": maximum_stagnant_ticks,
		"stuck_recoveries": stuck_recoveries,
		"offtrack_recoveries": offtrack_recoveries,
		"wall_contacts": wall_contacts,
		"automatic_recoveries": automatic_recoveries,
		"authority_recovery_reasons": {
			"blocked_offtrack": offtrack_authority_recoveries,
			"blocked_contact": contact_authority_recoveries,
		},
		"vehicle_contact_events": vehicle_contact_events,
		"deterministic": determinism_matches,
		"determinism_samples": determinism_samples + (1 if replay != null else 0),
		"authority_digest": _authority_digest(primary),
		"twin_authority_digest": _authority_digest(replay) if replay != null else "",
		"results_digest": _digest(results),
		"final_states": final_states,
		"wall_time_ms": int((Time.get_ticks_usec() - run_started) / 1000),
	}


func _build_director(
		track: RaceTrackQuery,
		laps: int,
		seed_value: int,
		timeout_seconds: float,
		enable_vehicle_collisions: bool = true
	) -> RaceDirector:
	var director := DirectorType.new()
	director.configure(track, laps, seed_value, CHECKPOINTS, enable_vehicle_collisions)
	director.countdown_duration = 0.0
	director.race_time_limit = timeout_seconds
	var drivers := AiRosterType.create_drivers(seed_value, FIELD_SIZE, 0.82)
	for index in drivers.size():
		var driver = drivers[index]
		director.add_entry(driver.driver_id, AiRosterType.display_name(index), false, driver)
	director.start()
	return director


func _sample_vehicle_contacts(director: RaceDirector, active_pairs: Dictionary) -> int:
	var currently_touching: Dictionary = {}
	var events := 0
	# Fast impacts can already be separated by the end-of-tick solver. Seed the
	# episode set from authoritative contact telemetry before checking persistent
	# capsule proximity, so neither nose/tail hits nor same-tick bounces are lost.
	for entry in director.entries:
		if entry.state.vehicle_contact_tick != entry.state.simulation_tick \
				or entry.state.vehicle_contact_other_id == &"":
			continue
		var telemetry_key := _vehicle_pair_key(
			str(entry.participant_id), str(entry.state.vehicle_contact_other_id)
		)
		currently_touching[telemetry_key] = true
	for first_index in director.entries.size():
		var first = director.entries[first_index]
		for second_index in range(first_index + 1, director.entries.size()):
			var second = director.entries[second_index]
			if first.vehicle_model.vehicle_contact_gap(
				first.state, second.state, second.vehicle_model.config
			) > 0.02:
				continue
			var pair_key := _vehicle_pair_key(
				str(first.participant_id), str(second.participant_id)
			)
			currently_touching[pair_key] = true
	for pair_key in currently_touching:
		if not active_pairs.has(pair_key):
			events += 1
	active_pairs.clear()
	for pair_key in currently_touching:
		active_pairs[pair_key] = true
	return events


func _vehicle_pair_key(first_id: String, second_id: String) -> String:
	return "%s|%s" % [first_id, second_id] \
		if first_id < second_id else "%s|%s" % [second_id, first_id]


func _gate_representative(run_result: Dictionary) -> void:
	var label := str(run_result.get("track_id", "unknown"))
	if not bool(run_result.get("compiled", false)):
		_failures.append("%s did not compile: %s" % [label, str(run_result.get("compile_errors", []))])
		return
	if int(run_result.get("finishes", 0)) != FIELD_SIZE:
		_failures.append("%s finished %d/%d cars over %d laps" % [label, int(run_result.get("finishes", 0)), FIELD_SIZE, REPRESENTATIVE_LAPS])
	if int(run_result.get("dnfs", 0)) != 0:
		_failures.append("%s recorded %d DNF results" % [label, int(run_result.get("dnfs", 0))])
	if int(run_result.get("invalid_motion", 0)) != 0:
		_failures.append("%s recorded invalid lap-authority motion" % label)
	if int(run_result.get("non_finite_states", 0)) != 0:
		_failures.append("%s produced non-finite vehicle state" % label)
	if int(run_result.get("stuck_episodes", 0)) != 0:
		_failures.append("%s recorded %d no-progress episodes" % [label, int(run_result.get("stuck_episodes", 0))])
	if not _within_recovery_budget(run_result, MAX_REPRESENTATIVE_RECOVERIES_PER_CAR):
		_failures.append("%s exceeded the frozen %d automatic recoveries-per-car budget" % [label, MAX_REPRESENTATIVE_RECOVERIES_PER_CAR])
	if not bool(run_result.get("deterministic", false)):
		_failures.append("%s diverged from its same-seed replay" % label)


func _gate_corpus(corpus_result: Dictionary) -> void:
	var count := int(corpus_result.get("track_count", 0))
	if count != 20:
		_failures.append("frozen corpus must contain exactly 20 runnable tracks, got %d" % count)
	var pass_rate := float(corpus_result.get("pass_rate", 0.0))
	if pass_rate + 0.0000001 < MIN_CORPUS_PASS_RATE:
		_failures.append("generated corpus no-stuck pass rate %.1f%% is below %.1f%%" % [pass_rate * 100.0, MIN_CORPUS_PASS_RATE * 100.0])


func _within_recovery_budget(run_result: Dictionary, budget: int) -> bool:
	for state_variant in run_result.get("final_states", []):
		if not state_variant is Dictionary:
			return false
		if int(state_variant.get("automatic_recoveries", budget + 1)) > budget:
			return false
	return true


func _total_primary_fixed_ticks(report: Dictionary) -> int:
	var total := 0
	for run_variant in report.get("representative_runs", []):
		if run_variant is Dictionary:
			total += int(run_variant.get("ticks", 0))
	var corpus: Dictionary = report.get("corpus", {})
	for run_variant in corpus.get("runs", []):
		if run_variant is Dictionary:
			total += int(run_variant.get("ticks", 0))
	return total


func _authority_digest(director: RaceDirector) -> String:
	var states: Array[Dictionary] = []
	for entry in director.entries:
		states.append({
			"participant_id": str(entry.participant_id),
			"state": entry.state.authority_snapshot(),
			"laps": entry.lap_tracker.laps_completed,
			"next_checkpoint": entry.lap_tracker.next_checkpoint,
			"status": str(entry.status),
			"automatic_recovery_count": entry.automatic_recovery_count,
			"recovery_stagnant_ticks": entry.recovery_stagnant_ticks,
			"recovery_cooldown_until_tick": entry.recovery_cooldown_until_tick,
			"recovery_last_tick": entry.recovery_last_tick,
			"recovery_last_reason": str(entry.recovery_last_reason),
			"recovery_offtrack_count": entry.recovery_offtrack_count,
			"recovery_contact_count": entry.recovery_contact_count,
			"recovery_events": entry.recovery_events.duplicate(true),
		})
	return _digest({"tick": director.fixed_tick, "phase": str(director.phase), "states": states})


func _report_digest_payload(report: Dictionary) -> Dictionary:
	return {
		"schema_version": report["schema_version"],
		"representative_runs": report["representative_runs"],
		"corpus": report["corpus"],
		"host_performance": report["host_performance"],
		"passed": report["passed"],
	}


func _digest(value: Variant) -> String:
	return CanonicalJsonType.stringify(value).sha256_text()


func _write_report(path: String, report: Dictionary) -> bool:
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK and not DirAccess.dir_exists_absolute(directory):
		return false
	var temporary := absolute_path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(report, "  ", false) + "\n")
	file.flush()
	file.close()
	if FileAccess.file_exists(absolute_path):
		DirAccess.remove_absolute(absolute_path)
	return DirAccess.rename_absolute(temporary, absolute_path) == OK


func _print_run(prefix: String, result: Dictionary) -> void:
	if not bool(result.get("compiled", false)):
		print("%s %s compile=FAIL errors=%s" % [prefix, result.get("track_id", "unknown"), result.get("compile_errors", [])])
		return
	var recovery_reasons: Dictionary = result.get("authority_recovery_reasons", {})
	print("%s %s laps=%d length=%.1f finishes=%d/%d dnf=%d invalid=%d stuck=%d recoveries=%d(%d off/%d contact) contacts=%d/%d deterministic=%s ticks=%d finish_s=%.1f..%.1f speed=%.1f/%.1f/%.1f wall_ms=%d" % [
		prefix,
		result.get("track_id", "unknown"),
		int(result.get("laps", 0)),
		float(result.get("lap_length", 0.0)),
		int(result.get("finishes", 0)),
		FIELD_SIZE,
		int(result.get("dnfs", 0)),
		int(result.get("invalid_motion", 0)),
		int(result.get("stuck_episodes", 0)),
		int(result.get("automatic_recoveries", 0)),
		int(recovery_reasons.get("blocked_offtrack", 0)),
		int(recovery_reasons.get("blocked_contact", 0)),
		int(result.get("vehicle_contact_events", 0)),
		int(result.get("wall_contacts", 0)),
		str(result.get("deterministic", false)),
		int(result.get("ticks", 0)),
		float(result.get("first_finish_time", -1.0)),
		float(result.get("last_finish_time", -1.0)),
		float(result.get("sampled_speed_mean", 0.0)),
		float(result.get("sampled_speed_median", 0.0)),
		float(result.get("sampled_speed_p90", 0.0)),
		int(result.get("wall_time_ms", 0)),
	])
