## The native module: the extern block and the types that cross it. image.agc is the API that re-exports it.

## The pixel type of one band.
enum Format
  U8
  I8
  U16
  I16
  U32
  I32
  F32
  F64
  Complex
end

## The axis that `flip` mirrors across.
enum Direction
  Horizontal
  Vertical
end

## The colour model that `colourspace` converts to.
enum Space
  Srgb
  Grey
end

## The kernel that `resize` interpolates with, the ones of libvips.
enum Kernel
  Nearest
  Linear
  Cubic
  Lanczos2
  Lanczos3
end

extern module "image"
  resource Image
  ## Decodes the file at `path`; the format is found from its contents.
  compute def load(path: String) -> Result[Image]
  ## Decodes an encoded image held in memory.
  compute def from_bytes(data: Bytes) -> Result[Image]
  ## An image from interleaved pixels: `width * height * bands` values of `format`, in the byte order of this machine.
  compute def from_pixels(pixels: Bytes, width: Int, height: Int, bands: Int, format: Format) -> Result[Image]
  ## Writes the image to `path`; the extension picks the encoder (`.png`, `.jpg[Q=90]`).
  compute def save(image: Image, path: String) -> Result[Void]
  ## Encodes the image as `suffix`, a file extension without the dot, with the options of libvips (`png`, `jpg[Q=90]`).
  compute def to_bytes(image: Image, suffix: String) -> Result[Bytes]
  ## The pixels, interleaved, in the format of the image and the byte order of this machine.
  compute def to_pixels(image: Image) -> Result[Bytes]
  ## The image scaled to `width` by `height` with `kernel`; the aspect ratio is yours to keep.
  def resize(image: Image, width: Int, height: Int, kernel: Kernel) -> Result[Image]
  ## The `width` by `height` area whose top left pixel is at `left`, `top`; an area outside the image is an error.
  def crop(image: Image, left: Int, top: Int, width: Int, height: Int) -> Result[Image]
  ## The image mirrored left to right (`Horizontal`) or top to bottom (`Vertical`).
  def flip(image: Image, direction: Direction) -> Result[Image]
  ## The image turned clockwise by `degrees`, a multiple of 90 (negative turns counterclockwise).
  def rotate(image: Image, degrees: Int) -> Result[Image]
  ## The image in another colour model; a band of alpha is kept.
  def colourspace(image: Image, space: Space) -> Result[Image]
  ## The same values in another pixel format: out of range values are clipped, and a float is cut toward zero when it
  ## becomes an integer.
  def cast(image: Image, format: Format) -> Result[Image]
  def width(image: Image) -> Int
  def height(image: Image) -> Int
  def bands(image: Image) -> Int
  def pixel_format(image: Image) -> Format
end
