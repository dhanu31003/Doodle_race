# Asset and Dependency License Inventory

Status: **validated development inventory; final legal clearance open**. The frozen `20260723T214917Z` gate validated 30 SVGs, 8 car colorways, and all 51 inventoried source/final/generated paths, and the Credits route passed. This proves inventory structure and source integrity, not owner rights/trademark approval or packaged store clearance. Update this ledger in the same change that adds or replaces any art, audio, font, generated media, code add-on, or other third-party content.

## Legal boundary

RaceGlyph is a provisional working name without trademark, store-name, domain, or other legal clearance. Do not publish under it until the owner approves a cleared identity.

Never copy or extract the reference product’s branding, screens, logos, sponsors, teams, drivers, cars, liveries, textures, sound, music, code, models, or marketing. Do not ship Formula 1 marks, real teams/drivers/sponsors, protected trophies, or a confusingly similar car/livery identity.

Allowed sources are project-created original work, generated work whose service terms permit the intended commercial distribution, CC0/public domain, or an explicit license compatible with commercial Android/iOS distribution and modification. “Free,” a search result, or missing license text is not permission.

## Inventory

`assets/licenses/original-assets.json` is the machine-readable source inventory for the original visual, 3D vehicle, and audio foundation. `assets/licenses/third-party-assets.json` separately records retained CC0 archives and direct PBR/HDRI downloads, license proofs, checksums, runtime derivatives, and modification notes. The original manifest covers authored SVG/JSON/Python sources, the deterministic Blender vehicle export, generated splash/key art, and procedural audio. The `WIP` status here means final owner/legal release review is still required; it does not contradict the origin declaration.

| ID | Shipped path(s) | Title/type | Creator/source URL | Exact license + proof | Modifications/tool prompt metadata | Attribution location | Trademark review | Status |
|---|---|---|---|---|---|---|---|---|
| RG-ART-001 | `assets/source/design_tokens.json`, `assets/source/brand/*`, `assets/final/brand/*` | Identity/tokens | RaceGlyph project; no external URL | `LicenseRef-RaceGlyph-Original`; `assets/licenses/original-assets.json` | Hand-authored JSON/SVG geometry | Credits & Licenses screen | Pending final-name/mark review | WIP |
| RG-ART-002 | `assets/source/vehicles/*`, `assets/final/vehicles/*` | Master car + 8 fictional colorways | RaceGlyph project; no external URL | Same manifest | Hand-authored SVG geometry/colorways | Credits & Licenses screen | Pending silhouette/livery review | WIP |
| RG-ART-006 | `assets/generated/concepts/formula_car_design_reference_v1.*` | Original Formula-car design reference | RaceGlyph project; generated with OpenAI built-in image generation | Same manifest plus adjacent prompt/checksum metadata | User-supplied photograph used only for generic proportion/aero-complexity inspiration; prompt explicitly excludes all branding, livery, text, team identity, and exact protected design | Internal production reference; not rendered as a flat in-game sprite | Pending protected-design/similarity review | WIP |
| RG-ART-003 | `assets/final/ui/*` | 9 player-facing interface icons plus 1 dormant internal boost glyph | RaceGlyph project; no external URL | Same manifest | Hand-authored SVG on 64-unit grid | Credits & Licenses screen | Pending icon similarity review | WIP |
| RG-ART-004 | `assets/final/scenery/*` | 5 forest/circuit scenery pieces | RaceGlyph project; no external URL | Same manifest | Hand-authored SVG with project palette/light | Credits & Licenses screen | Pending sign/mark review | WIP |
| RG-ART-005 | `assets/generated/key_art/*`, `assets/final/brand/raceglyph_splash.webp`, `assets/final/brand/raceglyph_boot_splash.png` | Splash/key art | OpenAI built-in image generation for this RaceGlyph project | Same manifest; project prompt retained in final handoff | Project-specific generation prompt, visual inspection, runtime crop/compression | In-game credits describe generated/project-created media | Pending protected-mark and identity review | WIP |
| RG-AUDIO-001 | `assets/final/audio/*` | 13 player-facing original music/engine/ambience/UI/race cues plus 1 dormant internal boost cue and checksum manifest | RaceGlyph project; no external URL | `LicenseRef-RaceGlyph-Original`; `assets/final/audio/original-audio-manifest.json` | Deterministic synthesis from oscillators and fixed-seed noise; no samples/recordings/external melodies | In-game credits | Not applicable | WIP |
| RG-3D-001 | `assets/source/vehicles/generate_premium_formula_car.py`, `assets/source/vehicles/formula_car_premium_original_PROVENANCE.md`, `assets/final/3d/vehicles/formula_car_premium_original.glb` | Premium modern Formula-car body | RaceGlyph project; no external URL | `LicenseRef-RaceGlyph-Original`; exact source/runtime checksums in `assets/licenses/original-assets.json` and adjacent provenance record | Clean-room Blender primitives and project-authored loft profiles; Godot adds original slicks, brakes, suspension, halo, driver, wheel, dashboard, materials, and animation | Credits describe project-created vehicle | No real logo, sponsor, team, driver, livery, or copied texture; final protected-design similarity review remains open | WIP |
| RG-3D-002 | `assets/final/3d/trackside/kenney_racing/*` | Racing Kit 1.2 trackside props | Kenney; `https://opengameart.org/content/racing-kit` | CC0-1.0; retained source license and archive checksum in `assets/licenses/third-party-assets.json` | Selected unbranded GLTF props placed, scaled, recolored, and lit in a deterministic world-space scenery system; Tankco-named props are not referenced | Credits & Licenses screen (voluntary) | Runtime selection excludes named promotional props | CLEARED |
| RG-3D-003 | `assets/final/3d/materials/clean_asphalt_*_1k.jpg` | Clean Asphalt 1K PBR maps | Dimitrios Savva / Poly Haven; `https://polyhaven.com/a/clean_asphalt` | CC0-1.0; retained legalcode and exact direct-file checksums in `assets/licenses/third-party-assets.json` | Diffuse and OpenGL normal maps tile across generated asphalt; ARM retained for verified future tuning | Credits & Licenses screen (voluntary) | Not applicable | CLEARED |
| RG-3D-004 | `assets/final/3d/environment/kloofendal_43d_clear_puresky_1k.hdr` | Kloofendal 43d Clear Pure Sky HDRI | Greg Zaal / Poly Haven; `https://polyhaven.com/a/kloofendal_43d_clear_puresky` | CC0-1.0; retained legalcode and exact direct-file checksum in `assets/licenses/third-party-assets.json` | Original 1K HDR used for daylight sky and reflections; authored directional sun drives shadows | Credits & Licenses screen (voluntary) | Not applicable | CLEARED |
| RG-3D-005 | `assets/final/3d/materials/sparse_grass_*_1k.jpg` | Sparse Grass 1K PBR maps | Amal Kumar / Poly Haven; `https://polyhaven.com/a/sparse_grass` | CC0-1.0; retained legalcode and exact direct-file checksums in `assets/licenses/third-party-assets.json` | Diffuse and OpenGL normal maps tile across the fixed ground plane with a project daylight tint | Credits & Licenses screen (voluntary) | Not applicable | CLEARED |
| RG-3D-006 | `assets/final/3d/trackside/quaternius_nature/*` | Selected textured trees and shrubs from Ultimate Stylized Nature | Quaternius; `https://quaternius.com/packs/ultimatestylizednature.html` | CC0-1.0; retained official source-page snapshot, bundled CC0 text, and exact runtime checksums in `assets/licenses/third-party-assets.json` | Four glTF tree variants and one shrub selected; textures resized to 512 px and seasonal leaves retinted natural green for mobile; deterministic density, scale, shadows, and clearance authored in-project | Credits & Licenses screen (voluntary) | No names, logos, or protected marks in the selected vegetation | CLEARED |
| RG-CODE-001 | `game/network/nakama/vendor/heroiclabs_nakama_godot/*` | Official Nakama Godot client SDK 3.4.0 | Heroic Labs; `https://github.com/heroiclabs/nakama-godot` | Apache-2.0; bundled `LICENSE` and `UPSTREAM.json`, exact commit `14b7f7078a9822c15b0424624e4c883c87730cee` | Upstream `.gd` source unmodified; Godot-generated `.gd.uid` files added | Full license/upstream record bundled; Credits & Licenses screen | Not applicable | CLEARED |

Status is one of `WIP`, `CLEARED`, `REJECTED`, or `REPLACEMENT REQUIRED`. Only `CLEARED` content may enter a release artifact.

`LicenseRef-RaceGlyph-Original` is a project provenance label, not a public source-code/content license grant. Ownership and distribution terms for the final product still require owner confirmation.

`assets/final/ui/icon_boost.svg` and `assets/final/audio/boost.wav` are dormant legacy/internal compatibility resources. RaceGlyph exposes only steering, accelerator, and brake/reverse; race authority forces the legacy nitro bit false, AI never requests it, multiplayer rejects `boost=true`, and no shipped screen invokes these resources. Their presence in the source inventory must not be described as a player feature. Final package enumeration decides whether they are excluded from distribution or remain documented internal baggage.

## Required record fields

- Stable inventory ID and every source/final/atlas path derived from it.
- Human creator or generation tool/provider, model/version, creation date, prompt/project record, and governing terms snapshot.
- Original source URL and a retained copy/screenshot of exact license/terms with retrieval date.
- SPDX identifier where one accurately exists; otherwise full license name and obligations.
- Modifications, crop/color/cleanup/format conversion, and relationship between source and final exports.
- Required attribution text and where it appears in-game/store/source distribution.
- Reviewer/date for provenance, visual artifacts, protected marks, and confusing similarity.
- File checksum for final release asset or deterministic manifest containing checksums.

## First-party and generated work

First-party programmatic/SVG/audio assets still receive an entry so the release can prove origin. Record the authoring file and tool. For generative systems, retain prompt and output provenance outside the shipped app where appropriate; manually inspect and clean every output. Generated does not mean rights-cleared.

## Fonts and audio

Font licenses must explicitly cover embedding/subsetting in mobile apps and any store imagery. Record exact font files and version. Audio needs composition, performance, recording, and sample rights; a music track with only one of those cleared is rejected. No unverified sample packs or platform-ripped sounds.

## Code and services

Track Godot add-ons, Nakama Godot SDK, native plugins, backend modules, build tools bundled into output, and their transitive notices in a dependency/SBOM appendix or generated manifest linked here. Service terms and privacy behavior are reviewed separately even when client code is open source.

## Release audit

The frozen automated asset validator and source contract passed, but no signed final Android/iOS package enumeration, store-media audit, protected-mark review, or owner sign-off has occurred. All first-party/generated `WIP` rows therefore remain release blockers; only the official Nakama SDK row is `CLEARED`.

1. Enumerate every file packaged in Android/iOS artifacts and every store image/video.
2. Match each non-project/tool-generated file to one cleared record and checksum.
3. Verify source/license proof, attribution, modification permission, trademark review, and compatible obligations.
4. Scan UI, tracks, liveries, signs, audio, metadata, app icon, splash, and screenshots for protected/placeholder content.
5. Generate Credits/Licenses UI and required bundled notices from the frozen ledger.
6. Have the owner approve the final identity and any legally material uncertainty.

An empty, incomplete, or `WIP` ledger blocks release.
