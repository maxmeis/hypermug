# HyperMug brand assets

- `HyperMug-Logo.png`: original transparent deep-navy moka-pot mark, 1254 × 1254 RGBA. Use as the reusable source for web and other placements.
- `HyperMug.iconset/`: the ten standard macOS icon sizes, derived from the PNG with `sips`.
- `HyperMug.icns`: native macOS app icon compiled from the iconset with `iconutil`.

For the app bundle, copy `HyperMug.icns` to `Contents/Resources` and set `CFBundleIconFile` to `HyperMug` in Info.plist. For the website, derive suitable favicon and touch-icon sizes from `HyperMug-Logo.png`; retain its alpha.

The menu bar uses a separate 18-point vector moka-pot template in [`MokaPotStatusImage.swift`](../HyperMug/Sources/App/MokaPotStatusImage.swift), with a filled pot for Caffeine on and an outline for off. Black and transparent artwork lets macOS tint it for light and dark menu bars. Secure Input retains its lock symbol and takes precedence over the Caffeine state.

## Provenance

- Generation tool: built-in `image_gen.imagegen`, with `transparent_background: true`.
- Source image: edited 2026-11-19 with the user's supplied three-symbol moka-pot reference; the leftmost filled silhouette was selected. No API-key CLI was used.
- Final prompt:

> Edit the attached reference image. Keep ONLY the leftmost solid black moka-pot symbol. Remove the middle outline symbol, the right sketch symbol, and the entire white background. Rebuild the leftmost symbol with perfectly smooth, crisp, flat geometric edges while closely preserving its exact compact proportions, narrow facet cutouts, tiny lid knob, short triangular left spout, small hooked right handle, and short lower boiler. Make it a SINGLE-COLOR deep navy #172e50 filled silhouette (no gold, no yellow, no red, no gradients or other colors). All facet cutouts and outside background are truly transparent. No steam. Center the complete single moka pot on a transparent square with roughly 15 percent clear margin on each side. Minimal elegant flat pictogram, like a professionally drawn vector icon; no shadows, no texture, no highlights, no text, no watermark. Output only the one crisp navy moka-pot symbol on real transparency.
