# Art Direction

Status: **creative target and acceptance policy**. No asset is approved for release merely because it exists in the repository.

## Identity

RaceGlyph is a provisional internal name with no legal clearance. The visual language is “drawn line becomes engineered speed”: sweeping glyph-like curves, clean technical markings, warm natural scenery, and compact, readable racing instrumentation.

Do not imitate the reference product’s brand, exact composition, UI, logos, teams, liveries, textures, audio, or marketing. Do not use Formula 1 names, marks, trophy silhouettes, sponsor panels, real drivers, or recognizable team liveries.

## Visual principles

- **Track first:** asphalt and racing line remain the strongest readable shape at phone scale.
- **Crisp geometry:** antialiased curves, deliberate joins, stable texture density, and no gaps at supported zooms.
- **Fast readability:** car/team color is recognizable in peripheral vision and survives effects/shadows.
- **Selective richness:** dense detail around start, grandstands, and signature corners; quiet recovery/sightline zones.
- **One light world:** consistent top-left key light, lower-right soft shadows, and restrained highlights.
- **Original restraint:** fictional marks are abstract and non-letterform where possible; no accidental sponsor-like clutter.

## Initial forest theme

The first release-quality theme uses deep blue-green foliage, sun-warmed grass, charcoal asphalt, pale markings, and cyan/amber race accents. Snow, desert, coast, and city-night remain future content until forest meets visual and performance gates. Source-controlled tokens live in `assets/source/design_tokens.json`; that file is authoritative when this summary differs.

Provisional palette:

| Role | Color |
|---|---|
| Asphalt | `#2B3540` |
| Grass base | `#347A50` |
| Deep foliage | `#23523B` |
| UI ink | `#07111B` |
| UI paper | `#F4FBFF` |
| Primary glyph/action | `#38E4D7` |
| Warning | `#FFB14A` |
| Danger | `#FF5A5F` |

Color never carries state alone; pair it with icon, shape, label, or animation.

## Camera and scale

- Race presentation has two coherent perspective modes: an in-cockpit view framed by the fictional open-wheel car and steering wheel, and an elevated chase view positioned behind/above the car.
- Overhead geometry is reserved for Track Studio, circuit-selection/tour surfaces, and the minimap; it is never the active driving view.
- Track authority remains two-dimensional and is mapped into a real world-space 3D circuit. The car transform advances around a fixed track; terrain, barriers, buildings, trees, and grandstands never scroll as a screen-space illusion.
- Author at a canonical scale and verify at the smallest supported phone and tablet layouts.
- Shadows are separate, soft, and bounded; no baked shadow contradicts world light.
- Camera shake and speed zoom are subtle, capped, and independently reducible.

## Asset families

- Fictional formula-style cars with distinct silhouettes/color blocking, not protected real designs.
- Road, curbs, markings, runoff, barriers, fence, cones, gantries, pit/paddock.
- Trees, bushes, rocks, service vehicles, tents, grandstands, crowds, flags, signs, water, and ambient props.
- Menus, panels, controls, icons, minimap, countdown, HUD, results, app icon, splash, and store compositions.
- Effects: tire smoke, dust, sparks, fragments, brake glow, skid marks, crowd/flag motion, and restrained speed cues.

Prefer editable SVG/layered sources. Raster exports need clean premultiplied-alpha edges, atlasing where measured useful, consistent padding, and documented scale. Avoid tiny high-frequency details that shimmer under motion.

The current foundation includes source-controlled project-authored SVG identity, eight fictional car colorways, ten interface icons, five natural-circuit scenery pieces, and a true 3D presentation layer. The runtime Formula car is a clean-room project-original Blender model rebuilt by the retained generator in `assets/source/vehicles/`; it uses no third-party vehicle geometry, textures, logos, or livery. The circuit combines generated geometry and project-authored vehicle/cockpit animation with cleared CC0 trackside, asphalt, grass, vegetation, and daylight sources. Provenance is split between `assets/licenses/original-assets.json` and `assets/licenses/third-party-assets.json`. Presence and provenance metadata do not make an integrated visual release-approved; it still requires the acceptance checks below.

## UI motion and typography

- Motion communicates hierarchy: 120–220 ms for controls, 240–400 ms for panels, with reduced-motion behavior.
- Use one display face and one highly legible UI face only after license verification.
- Minimum touch target and text sizes are established through device testing, not desktop appearance.
- Numeric timing and position data use tabular figures if the licensed font supports them.

## Generation and external assets

Generated art is source material, not automatically ship-ready. Retain prompt/tool/version/date and applicable usage terms; inspect trademarks, anatomy/geometry, symmetry, transparency, artifacts, and visual consistency. External assets require source URL, author, exact license, proof, modifications, and attribution in `ASSET_LICENSES.md` before integration.

## Acceptance checklist per asset

- Original or license-cleared with ledger entry and source retained.
- No protected mark, copied layout, recognizable real livery, or placeholder label.
- Correct perspective, light direction, scale, padding, pivot, and transparent edge.
- Readable on the smallest supported screen and separated from road/background.
- No generation artifact, compression halo, seam, or atlas bleed.
- Meets memory/draw-call budget in its worst-case scene.
- Visually inspected in deterministic golden scenes and on applicable physical devices.

Until those checks have recorded evidence, an asset is **work in progress**, not final.
