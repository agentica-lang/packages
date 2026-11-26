# Changelog

## [Unreleased]

- Fix `resize` when it enlarges with `Linear`, `Cubic`, `Lanczos2` or `Lanczos3`: the centre of an output pixel is now at `(x + 0.5) / scale - 0.5` of the input, as Pillow, OpenCV and Hugging Face place it, where it was a fraction of an input pixel off (a step edge enlarged 2 times started one output pixel late). `Lanczos2` and `Lanczos3` enlarge as `Cubic`, as before. The pixels of an enlarged image change; a shrink and `Nearest` do not.

## [0.2.0] - 2026-11-25

- Add the optional `kernel` of `resize`, the enum `Kernel` (`Nearest`, `Linear`, `Cubic`, `Lanczos2`, `Lanczos3`); the default is `Lanczos3`, so a call with no kernel gives the pixels it gave before.

## [0.1.0] - 2026-11-24

- Add `image`, a libvips binding made with native-gen: `load`, `from_bytes`, `from_pixels`, `save`, `to_bytes`, `to_pixels`, `width`, `height`, `bands` and `pixel_format`. Needs Agentica 0.35.0 and libvips (tested with 8.15 and 8.16).
- Add `resize`, `crop`, `flip`, `rotate`, `colourspace` and `cast`, with the enums `Direction` and `Space`.
