# Changelog

## [Unreleased]

- Add `resize`, `crop`, `flip`, `rotate`, `colourspace` and `cast`, with the enums `Direction` and `Space`.
- Add `image`, a libvips binding made with native-gen: `load`, `from_bytes`, `from_pixels`, `save`, `to_bytes`, `to_pixels`, `width`, `height`, `bands` and `pixel_format`. Needs Agentica 0.35.0 and libvips (tested with 8.15 and 8.16).
