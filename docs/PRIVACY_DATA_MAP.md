# Privacy Data Map

Status: **current implementation map plus frozen development-artifact audit**, not a store disclosure. Local storage, deletion/export, and private-room flows are implemented. Android debug and unsigned iOS project metadata were audited on 2026-07-24; signed final binaries, public hosting, provider logs, retention, owner notice, and store answers remain unresolved.

## Principles

- Offline play requires no account or network.
- Collect the minimum needed for private multiplayer; no ads, cross-app tracking, contacts, precise location, photos, microphone, or real-name requirement.
- Prefer a random per-install identifier over hardware identifiers.
- Clearly separate required service data from optional diagnostics/telemetry.
- Export and deletion must cover local and backend data where applicable.
- Never log tokens, credentials, private room codes, or raw personal text.

## Current data flows

| Data | Source | Purpose | Location/recipient | Retention | Status |
|---|---|---|---|---|---|
| Track definition/name/thumbnail | Player | Create/save/share track | Local app sandbox; canonical definition relayed in transient Nakama match state for a private room | Local until delete; room copy until room close | Local persistence and transient room transfer implemented; no backend track library |
| Settings, selected car/team | Player/device | Preferences/accessibility | Local app sandbox | Until reset/delete | Implemented |
| Best laps/results | Gameplay | Local progression/results | Local app sandbox | Until delete/migration | Implemented |
| Random install ID | App | Anonymous Nakama auth | Separate app-private `network/install_identity.v1`; Nakama/PostgreSQL when private rooms are used | Local copy until Delete All Local Data; backend lifetime/deletion policy TBD | Local generation/deletion implemented; backend deletion unavailable |
| Nakama user/session IDs and tokens | Backend | Authenticate socket/RPC | Runtime memory; Nakama | Cleared on leave/reset/local deletion; backend token expiry policy TBD | Runtime handling implemented; platform secure-store persistence is not used |
| Room code, membership, ready/presence | Players | Private room lifecycle | Nakama match state/storage directory and relay peers | Removed when the room closes; provider/log retention remains TBD | Implemented in the local candidate |
| Input/state packets | Players/host | Live race | Nakama relay and room peers | In-memory; no routine project persistence | Implemented |
| Connection metadata (IP, time, errors) | Network/server | Security and operations | Nakama/container logs; future hosting provider | Local runners retain only redacted summaries; production retention TBD | Inherent Nakama behavior; local diagnostic scans implemented, hosting not audited |
| Diagnostic/performance metrics | App/server | Reliability/performance | Local evidence or approved telemetry service | Disabled by default until policy/consent/retention defined | Not selected |
| Crash reports | App/platform | Diagnose crashes | None selected | N/A | Not implemented |

User-entered track names are untrusted text. Limit, sanitize for display/logging, and avoid persisting them in operational logs.

## Platform permissions/capabilities

### Android

Landscape/touch/controller need no sensitive runtime permission. Both Android presets request only `INTERNET` for multiplayer and `VIBRATE` for haptic cues; user-data backup and retain-on-uninstall are disabled. Camera, microphone, contacts, location, storage/media, advertising ID, and notification permissions are not product requirements. Static audit of debug APK `../builds/android/RaceGlyph-final.apk` confirmed exactly `INTERNET` and `VIBRATE` in the packaged manifest; see `../evidence/logs/android-apk-final-20260723T213702Z.log`. This does not replace the audit of the future release-signed AAB or Play SDK/data-safety reports.

### iOS

Network access, controller, haptics, and landscape/safe-area handling are expected. Microphone input is disabled in `project.godot`, the iOS camera module is disabled in the export preset, and no camera/microphone/photo feature is required. `tools/mobile/sanitize_ios_export.sh` removes only empty template-generated usage-description keys and validates the resulting plist. Static audit of unsigned project `../builds/ios/final` confirmed that sensitive usage-description keys are absent and its one `PrivacyInfo.xcprivacy` declares tracking false; see `../evidence/logs/ios-xcode-export-final-20260723T214053Z.log`. This does not waive signed archive, embedded-SDK privacy report, network-capture, or App Privacy review. Apple signing/team access remains external.

## Storage and security

- Local saves use app-private storage, atomic writes, backups, validation, and migration.
- Nakama session/refresh/reconnect material is held in runtime memory only and is never written to ordinary track/settings JSON. Platform Keychain/Android Keystore persistence is not implemented or claimed.
- TLS/WSS is mandatory outside localhost. Database and backup encryption/access controls are required in staging/production.
- Access to backend records is authenticated and scoped. Short room codes are discoverability tokens, not authorization.
- Backups, logs, and evidence inherit retention/deletion rules and must exclude secrets.

## Player controls

Settings exposes export and deletion for local tracks/preferences/results. The portable export recursively excludes install/device identifiers and authentication/reconnect tokens. **Delete All Local Data** closes the live multiplayer transport, clears in-memory room/reconnect state, deletes the separate anonymous install identity and its transient copies, then deletes profile/save copies; partial filesystem failure is reported instead of claimed successful.

This is local-device deletion only. It does **not** delete a Nakama/PostgreSQL account or hosting-provider logs/backups. No public backend is deployed, and no external/backend self-service deletion flow has been implemented. That external deletion/export, retention, and backup-expiry work remains a release blocker if multiplayer is publicly deployed.

## Children, consent, and telemetry

Target age rating and child-directed status are undecided. Do not add analytics, ads, chat, profiling, social graph, or marketing SDKs without a new privacy/security review and owner approval. Optional telemetry stays off until purpose, fields, processor, region, legal basis/consent, retention, opt-out, deletion, and store disclosures are finalized.

## Release audit

Frozen local evidence: the `20260723T214917Z` source contract passed privacy/redaction/credential-shape checks; the real local 12-client and restore drills retained zero secret/token hits or raw session responses/dumps. Exact checksums and scope limits are in `TEST_REPORT.md`. No public backend, provider, or store binary was audited.

1. Diff this map against source, dependency lockfiles/SBOM, Android manifest, iOS entitlements/privacy report, runtime network capture, server schema/config/logs, and store SDK reports.
2. Verify no undocumented endpoint, identifier, permission, tracking domain, or sensitive log field.
3. Complete Google Play Data safety and Apple App Privacy answers from observed behavior, not intention.
4. Publish an owner-approved privacy notice and in-app link if multiplayer/backend is enabled.
5. Test local/backend export, deletion, token expiry/logout, room TTL, log redaction, and backup expiry.

Any unresolved data flow, retention value, SDK behavior, or disclosure blocks store release.

## References

- Apple privacy manifests: <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>
- Android manifest and permissions: <https://developer.android.com/guide/topics/manifest/manifest-intro>
