## Images on libvips: decode, encode, and the pixels as one `Bytes` buffer.

import Vips from "src/libvips"

export Vips.Image
export Vips.Format
export Vips.Direction
export Vips.Space
export Vips.Kernel
export Vips.load
export Vips.from_bytes
export Vips.from_pixels
export Vips.save
export Vips.to_bytes
export Vips.to_pixels
export Vips.crop
export Vips.flip
export Vips.rotate
export Vips.colourspace
export Vips.cast
export Vips.width
export Vips.height
export Vips.bands
export Vips.pixel_format

## The image scaled to `width` by `height` with `kernel`, Lanczos 3 unless you pick another; the aspect ratio is yours
## to keep.
def resize(
  image: Vips.Image,
  width: Int,
  height: Int,
  kernel: Vips.Kernel = Vips.Kernel.Lanczos3,
) -> Result[Vips.Image]
  Vips.resize(image, width, height, kernel)
end
