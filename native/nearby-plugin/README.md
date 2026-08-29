# RaceGlyph Nearby Android plugin

This Godot Android plugin wraps Google Nearby Connections `P2P_STAR` for the
offline private-room transport. It exposes discovery, connections, bounded
message transfer, fragmentation, and Android runtime-permission results to
GDScript. It does not contain game or race authority logic.

From the repository root, build and install both AAR variants with:

```sh
tools/mobile/build_nearby_plugin.sh
```

The helper installs Godot's Android template if required, invokes its pinned
Gradle wrapper, and copies `RaceGlyphNearby-{debug,release}.aar` into the
matching `addons/RaceGlyphNearby/bin/{debug,release}` directory before export.
