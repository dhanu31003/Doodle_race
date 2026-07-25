extends SceneTree
## Builds both venue tiers for every first-party circuit. This catches close
## switchbacks and lobes that are valid road geometry but place a barrier,
## fence, stand, or other fixed prop inside a neighbouring runoff area.

const TestCaseType := preload("res://tests/support/test_case.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const QueryType := preload("res://game/race/track_query.gd")
const SceneryType := preload("res://game/presentation3d/trackside_scenery_3d.gd")
const MOBILE_SCENERY_CONFIGURE_CEILING_MS := 5000.0
const STANDARD_SCENERY_CONFIGURE_CEILING_MS := 7500.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	var items := CatalogType.all()
	var maximum_configure_ms := 0.0
	var maximum_configure_label := "none"
	var maximum_skip_ratio := 0.0
	var maximum_skip_label := "none"
	test.assert_equal(items.size(), 6, "clearance gate covers every reviewed default circuit")
	for item in items:
		var definition: TrackDefinition = item["definition"]
		var compiled: TrackCompileResult = CompilerType.compile(definition)
		test.assert_true(compiled.succeeded(), "%s compiles for venue clearance" % definition.track_id)
		if not compiled.succeeded():
			continue
		var query: RaceTrackQuery = QueryType.from_compiled(compiled.track)
		test.assert_true(query.is_valid(), "%s produces a race query for venue clearance" % definition.track_id)
		if not query.is_valid():
			continue
		for low_graphics in [true, false]:
			var metrics := _audit_tier(
				test, query, definition.track_id, low_graphics
			)
			var tier_name := "mobile" if low_graphics else "standard"
			if float(metrics["configure_ms"]) > maximum_configure_ms:
				maximum_configure_ms = float(metrics["configure_ms"])
				maximum_configure_label = "%s:%s" % [definition.track_id, tier_name]
			if float(metrics["skip_ratio"]) > maximum_skip_ratio:
				maximum_skip_ratio = float(metrics["skip_ratio"])
				maximum_skip_label = "%s:%s" % [definition.track_id, tier_name]
			await process_frame
	print("CATALOG_SCENERY_BUDGET tracks=%d tiers=2 max_configure_ms=%.3f max_configure=%s worst_skip_percent=%.2f worst_skip=%s" % [
		items.size(), maximum_configure_ms, maximum_configure_label,
		maximum_skip_ratio * 100.0, maximum_skip_label,
	])
	var result: Dictionary = test.result("predefined_scenery_clearance")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _audit_tier(
	test: RefCounted,
	query: RaceTrackQuery,
	track_id: String,
	low_graphics: bool
	) -> Dictionary:
	var tier_name := "mobile" if low_graphics else "standard"
	var ceiling_ms := MOBILE_SCENERY_CONFIGURE_CEILING_MS \
			if low_graphics else STANDARD_SCENERY_CONFIGURE_CEILING_MS
	var scenery := SceneryType.new()
	root.add_child(scenery)
	var configure_started := Time.get_ticks_usec()
	scenery.configure(query, low_graphics, false)
	var configure_ms := float(
		Time.get_ticks_usec() - configure_started
	) / 1000.0
	test.assert_true(
		configure_ms <= ceiling_ms,
		"%s:%s builds its complete venue inside the %.0fms host load ceiling (%.3fms)" % [
			track_id, tier_name, ceiling_ms, configure_ms,
		]
	)
	var snapshot: Dictionary = scenery.debug_clearance_snapshot()
	var stats: Dictionary = snapshot.get("presentation_stats", {})
	var barrier_candidates := int(stats.get("safety_barrier_candidates", 0))
	var barrier_instances := int(stats.get("safety_barrier_instances", 0))
	var barrier_skipped := int(stats.get("safety_barrier_skipped", 0))
	var fence_candidates := int(stats.get("catch_fence_candidates", 0))
	var fence_instances := int(stats.get("catch_fence_instances", 0))
	var fence_skipped := int(stats.get("catch_fence_skipped", 0))
	var barrier_retention := float(barrier_instances) / maxf(
		float(barrier_candidates), 1.0
	)
	var fence_retention := float(fence_instances) / maxf(
		float(fence_candidates), 1.0
	)
	var skip_ratio := maxf(1.0 - barrier_retention, 1.0 - fence_retention)
	var violations: Array = snapshot.get("violations", [])
	var first: Dictionary = violations[0] if not violations.is_empty() else {}
	test.assert_true(
		bool(snapshot.get("valid", false))
				and int(snapshot.get("prop_count", 0)) > 0
				and float(snapshot.get("minimum_clearance_meters", -INF)) >= 0.5,
		(
			"%s:%s keeps every fixed venue prop at least 0.5m beyond all runoff " \
					+ "(props=%d minimum=%.3f first=%s:%s:%.3f violations=%d)"
		) % [
			track_id,
			tier_name,
			int(snapshot.get("prop_count", 0)),
			float(snapshot.get("minimum_clearance_meters", -INF)),
			str(first.get("kind", "none")),
			str(first.get("name", "none")),
			float(first.get("clearance_meters", 0.0)),
			violations.size(),
		]
	)
	test.assert_false(
		str(snapshot.get("layout_hash", "")).is_empty(),
		"%s:%s publishes a deterministic venue layout hash" % [track_id, tier_name]
	)
	test.assert_true(
		barrier_candidates >= 96
				and barrier_instances >= 96
				and barrier_skipped == barrier_candidates - barrier_instances
				and barrier_retention >= 0.80,
		"%s:%s retains a strong batched two-sided safety-barrier majority (%d/%d, %.1f%%)" % [
			track_id, tier_name, barrier_instances, barrier_candidates,
			barrier_retention * 100.0,
		]
	)
	test.assert_true(
		fence_candidates >= 72
				and fence_instances >= 72
				and fence_skipped == fence_candidates - fence_instances
				and fence_retention >= 0.80,
		"%s:%s retains a strong batched two-sided catch-fence majority (%d/%d, %.1f%%)" % [
			track_id, tier_name, fence_instances, fence_candidates,
			fence_retention * 100.0,
		]
	)
	print("CATALOG_SCENERY_CLEARANCE id=%s tier=%s valid=%s props=%d minimum=%.3f violations=%d barriers=%d/%d fences=%d/%d configure_ms=%.3f" % [
		track_id,
		tier_name,
		str(snapshot.get("valid", false)),
		int(snapshot.get("prop_count", 0)),
		float(snapshot.get("minimum_clearance_meters", -INF)),
		violations.size(),
		barrier_instances,
		barrier_candidates,
		fence_instances,
		fence_candidates,
		configure_ms,
	])
	scenery.clear_scenery()
	scenery.free()
	return {
		"configure_ms": configure_ms,
		"skip_ratio": skip_ratio,
	}
