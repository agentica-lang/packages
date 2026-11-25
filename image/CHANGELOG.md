# Changelog

## [Unreleased]

- Add the optional `kernel` of `resize`, the enum `Kernel` (`Nearest`, `Linear`, `Cubic`, `Lanczos2`, `Lanczos3`); the default is `Lanczos3`, so a call with no kernel gives the pixels it gave before.

## [0.1.0] - 2026-11-24

- Add `image`, a libvips binding made with native-gen: `load`, `from_bytes`, `from_pixels`, `save`, `to_bytes`, `to_pixels`, `width`, `height`, `bands` and `pixel_format`. Needs Agentica 0.35.0 and libvips (tested with 8.15 and 8.16).
- Add `resize`, `crop`, `flip`, `rotate`, `colourspace` and `cast`, with the enums `Direction` and `Space`.
