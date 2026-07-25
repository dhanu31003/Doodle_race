# Release Checklist

Status: **local candidate gates selectively complete; public/store release remains NO-GO**.

Every `[x]` below applies only to frozen gate `20260723T214917Z`, base commit `1034890142943b1f3bcf77a83c04ee0fa384d42b`, and the evidence indexed in [`TEST_REPORT.md`](TEST_REPORT.md). The gate passed from a dirty/untracked tree; checked local evidence does not imply physical qualification, signing, legal clearance, public deployment, or store approval. This checklist authorizes none of those actions.

## Scope and identity

- [ ] Final name has owner approval and trademark/store/domain clearance; provisional “RaceGlyph” is removed or explicitly cleared.
- [ ] Package/bundle IDs use an owner-approved reverse-DNS identity. Current `com.raceglyph.game` is development-only.
- [ ] Version/build numbers, supported OS floors, territories, age rating, and content claims are owner-frozen.
- [x] Implemented v1 contains no undisclosed required placeholder; player-facing prerelease markers are rejected by the frozen source gate, and exclusions are documented.
- [x] No Critical/High defect or warning/error/leak waiver remains in the tested local scope.
- [ ] Owner approves the remaining limitations and final known-issues statement.

## Product completion

- [x] Draw/closure/undo/redo/clear/validation/auto-fix/generate/tour/save/reload/edit/export/delete pass automated coverage.
- [x] Road/curbs/runoff/barriers/bridge/pit/grid/checkpoint/lane/minimap/seeded-scenery generation passes deterministic fixtures.
- [x] Conventional controls, assists, collisions/recovery, cockpit/chase cameras, effects/audio/HUD/results/pause pass unit/integration/playback coverage.
- [x] Configurable one-player + 1–11-AI racing passes representative 12-car × 20-lap and 20/20 frozen-corpus gates with zero DNF/invalid/non-finite/stuck outcomes.
- [x] Six predefined tracks, eight fictional colorways, and the forest-theme content foundation pass asset/catalog/rendering validation.
- [x] Thirteen routes plus accessibility, settings, credits, and license surfaces pass clean route/layout fixtures.

## Multiplayer/backend

- [x] Nakama `3.40.0`, Godot SDK `3.4.0`/exact commit, PostgreSQL `17.9-alpine3.23`, and immutable service digests are recorded.
- [x] Create/code-join/full/kick/lock/ready/start/results/share/rematch and 12-human admission/relay behavior pass local real/fake coverage; private-room AI fill remains a disclosed v1 exclusion.
- [x] Predefined/saved/same-room Studio track hash/generator/readiness and cancel/malformed/oversize behavior pass local coverage.
- [x] Prediction/interpolation/authority, impairment fixtures, real reconnect, phase preservation, host departure, compatibility UX, and outage behavior pass local coverage.
- [x] Offline mode remains usable independently of the backend.
- [x] Disposable local clean-room Compose, migration, health/readiness, strict redacted diagnostics, 12-client load, teardown, and isolated restore pass.
- [ ] Public staging smoke, TLS/WSS, DNS, provider secrets, monitoring, retention/deletion, capacity/budget, and incident review pass.
- [ ] Encrypted off-site backup, production restore/RPO/RTO, rollback, and upgrade drill pass.
- [ ] Owner authorizes provider/region and any public or paid infrastructure action.

## Quality evidence

- [ ] Clean immutable checkout/tag reproducibly builds the exact artifacts and reruns every gate.
- [x] Deterministic track/rendering fixtures, all 13 routes, and 15 accessibility layouts pass headless development-host coverage.
- [ ] Frozen candidate-wide pixel-diff/human visual review passes at required phone/tablet sizes.
- [x] Twelve-car AI, dense track-feature/forest, and bridge authority/rendering cases pass automated development-host gates.
- [ ] Thirty-minute physical thermal/battery and frozen mobile FPS/memory budgets pass.
- [ ] Every required physical-device matrix row passes with exact artifact, OS, logs, captures, and profiler evidence.
- [x] Frozen project/source/backend logs pass strict crash, parse/compile, warning, ObjectDB/resource leak, secret/token, malformed-input, and save-corruption contracts.
- [ ] Final dependency-vulnerability and complete SBOM release review passes.
- [x] `TEST_REPORT.md`, `PROJECT_STATUS.md`, performance/device/privacy/AI records, and this checklist match the frozen candidate and disclose their limits.

## Art, legal, and privacy

- [ ] Every packaged asset/store image and dependency maps to a final `CLEARED` ledger/SBOM record and checksum; first-party/generated media are still `WIP`.
- [ ] Final UI, logo, liveries, signs, sounds, screenshots, metadata, icon/splash, and name pass protected-mark/confusing-similarity review.
- [x] In-game Credits & Licenses exposes project-created media and bundled Nakama notice/license obligations.
- [x] Frozen source plus Android/iOS development-candidate metadata pass the recorded permission/usage-key/privacy-manifest audits.
- [x] Portable local export/deletion and runtime token/session clearing pass automated persistence coverage.
- [ ] Public network capture/server/provider schema/log/retention audit, backend account export/deletion, TLS, and backup expiry pass.
- [ ] Apple App Privacy/privacy report and Google Play Data safety answers match a signed final candidate and observed public behavior.
- [ ] Owner approves the final privacy notice, age/child-directed decision, rights ledger, store text, and legal uncertainties.

## Android artifact

- [x] Godot 4.7.1 templates and Java 17/API 36/Build-Tools 36.0.0/NDK configuration are recorded.
- [x] Debug APK `590b75e…3c42` passes package/version, landscape project settings, ARM64, icon, min/target SDK, exact `INTERNET` + `VIBRATE`, and signature audit.
- [x] That APK installs, warm-launches, and renders the menu on the API 36 emulator without a critical app-runtime pattern.
- [ ] Touch/controller/vibration/background-resume and performance/thermal pass required physical Android devices.
- [ ] Release AAB uses a protected owner-controlled keystore, non-debug signing/configuration, and final owner-approved identity; the retained debug AAB is not a store artifact.
- [ ] Play internal/pre-launch results and current target-API/store policy are reviewed at submission time.

## iOS artifact

- [x] Godot 4.7.1 generates the final unsigned Xcode project; bundle/version/deployment target, both phone/tablet landscapes, privacy manifest, sensitive usage-key absence, and 16/16 opaque icons pass static audit.
- [ ] Xcode completes the no-sign host build. Current exact blocker: `iOS 26.0 Platform Not Installed` at storyboard compilation.
- [ ] Owner team/certificate/provisioning, signed archive validation, and TestFlight configuration pass.
- [ ] Touch/controller/haptics/lifecycle plus performance/thermal pass physical iPhone and iPad.

## Store package

- [ ] Final icon/splash and required device-size screenshots contain no debug/placeholder/private data and pass owner/legal review.
- [ ] Store title/subtitle/description/keywords/support/privacy URLs and release notes are owner-approved.
- [ ] Age-rating, content rights, export compliance, privacy/data, accessibility, and account-deletion answers are complete.
- [ ] Support, incident, backend capacity, migration, rollback, and save-compatibility plans are staffed for release.

## External approval gates

- [ ] Owner authorizes developer-account fees, paid hosting/assets/services, device purchase/rental, and any other cost.
- [ ] Owner provides/authorizes signing identities, provisioning, keystore custody, store accounts, and required physical devices.
- [ ] Owner explicitly approves public backend exposure, TestFlight/external testing, store upload, and publication.

## Final go/no-go

- [ ] Candidate is clean, immutable, tagged, reproducibly built, signed, checksummed, backed up, and linked to complete evidence.
- [ ] Cross-functional review records GO with approver/date.
- [ ] Production rollback target and player communication are prepared.

Current decision: **NO-GO for public/store release**. Remaining unchecked items are explicit blockers; no unchecked item is silently waived.
