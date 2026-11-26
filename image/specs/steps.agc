## The steps of image.feature. The fixtures of specs/fixtures are written by peer.py, an independent PNG codec: each
## PNG next to the raw pixels it holds (little endian), and a ramp of floats.

import BDD from "std/bdd"
import Image from "../image"

struct GoldenInput
  width: Int
  height: Int
  bands: Int
  hex: String
end

struct GoldenCase
  input: String
  kernel: String
  kind: String
  width: Int
  height: Int
  hex: String
end

struct Golden
  inputs: Map[String, GoldenInput]
  cases: List[GoldenCase]
end

private

FIXTURES = "specs/fixtures"

def main() -> Void
  BDD.run([
    BDD.step("{string} decodes as {int} by {int} with {int} bands of {string}, the pixels of {string}", &decodes),
    BDD.step("the pixels {string} as {int} by {int} with {int} bands of {string} come back from the image", &pixels),
    BDD.step("the pixels {string} as {int} by {int} with {int} bands of {string} survive {string}", &survive),
    BDD.step("the pixels {string} as {int} by {int} with {int} bands of {string} are decoded by the peer", &peer),
    BDD.step("the pixels {string} as {int} by {int} with {int} bands of {string} encode as {string}", &encodes),
    BDD.step("a file that is loaded and then written with other pixels loads as the new pixels", &rewritten),
    BDD.step(
      "the pixels {string} as {int} by {int} with {int} bands of {string} under {string} are the peer's within {int}",
      &transformed,
    ),
    BDD.step(
      "the pixels {string} as {int} by {int} with {int} bands of {string} turn a quarter and back",
      &turned_back,
    ),
    BDD.step(
      "{int} tasks resize an image of {string} repeated to {int} by {int} down to {int} by {int}",
      &parallel_resize,
    ),
    BDD.step(
      "the pixels {string} as {int} by {int} with {int} bands of {string} resized to {int} by {int} differ by kernel",
      &kernels,
    ),
    BDD.step(
      "the {string} {string} resizes of the {string} image in the Pillow golden are within {int} levels of Pillow's",
      &against_pillow,
    ),
    BDD.step(
      "the pixels {string} as {int} by {int} with {int} bands of {string} enlarged to {int} by {int} are the same for Cubic, Lanczos 2 and Lanczos 3",
      &lanczos_enlarge,
    ),
    BDD.step("an enlarge keeps the colour of a pixel that is next to a transparent one", &alpha_enlarge),
    BDD.step("a failed decode leaves no message behind", &clean_error),
    BDD.step("a resize to {int} by {int} is accepted", &accepted),
    BDD.step("{int} tasks decode {string} to the pixels of {string}", &parallel),
    BDD.step("these calls fail:", &failures),
  ])
end

def decodes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  img = Image.load(fixture_path(args[0])).unwrap!
  return BDD.assert(ctx, false, "#{args[0]} has the wrong shape") if not shaped?(img, args.drop(1))

  BDD.assert(ctx, Image.to_pixels(img).unwrap! == read(args[5]), "#{args[0]} decodes to other pixels")
end

def pixels(ctx: BDD.Context, args: List[String]) -> BDD.Context
  img = from_raw(args)
  return BDD.assert(ctx, false, "#{args[0]} came back with another shape") if not shaped?(img, args.drop(1))

  BDD.assert(ctx, Image.to_pixels(img).unwrap! == read(args[0]), "#{args[0]} came back changed")
end

# A lossless format keeps the pixels in memory and on disk.
def survive(ctx: BDD.Context, args: List[String]) -> BDD.Context
  raw = read(args[0])
  img = from_raw(args)
  in_memory = Image.from_bytes(Image.to_bytes(img, args[5]).unwrap!).unwrap!
  return BDD.assert(ctx, false, "#{args[5]} in memory changed the pixels") if Image.to_pixels(in_memory).unwrap! != raw

  with_folder(ctx) do |kept, folder|
    path = Path.join([folder, "image.#{args[5]}"]).unwrap!
    Image.save(img, path).unwrap!
    BDD.assert(kept, Image.to_pixels(Image.load(path).unwrap!).unwrap! == raw, "#{args[5]} on disk changed the pixels")
  end
end

# What the peer reads from the PNG that this package writes.
def peer(ctx: BDD.Context, args: List[String]) -> BDD.Context
  raw = read(args[0])
  img = from_raw(args)
  with_folder(ctx) do |kept, folder|
    png = Path.join([folder, "image.png"]).unwrap!
    out = Path.join([folder, "peer.raw"]).unwrap!
    write_path(png, Image.to_bytes(img, "png").unwrap!)
    process = Process.spawn_captured("python3", ["#{FIXTURES}/peer.py", "decode", png, out]).unwrap!
    printed = Process.output(process, 20000).unwrap!.stdout.strip
    shape = "#{args[1]} #{args[2]} #{args[3]}"
    return BDD.assert(kept, false, "the peer read #{printed}, not #{shape}") if printed != shape

    BDD.assert(kept, read_path(out) == raw, "the peer read other pixels")
  end
end

# A lossy format keeps the size, and the encoded bytes decode again.
def encodes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  img = from_raw(args)
  back = Image.from_bytes(Image.to_bytes(img, args[5]).unwrap!).unwrap!
  same = Image.width(back) == Image.width(img) and Image.height(back) == Image.height(img)
  BDD.assert(ctx, same, "#{args[5]} changed the size")
end

# The load of a path does not answer from an earlier load of it.
def rewritten(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  first = Image.from_pixels(read("rgb.raw"), 16, 12, 3, Image.Format.U8).unwrap!
  second_raw = read("rgba.raw")
  second = Image.from_pixels(second_raw, 9, 7, 4, Image.Format.U8).unwrap!
  with_folder(ctx) do |kept, folder|
    path = Path.join([folder, "image.png"]).unwrap!
    Image.save(first, path).unwrap!
    Image.load(path).unwrap!
    Image.save(second, path).unwrap!
    loaded = Image.load(path).unwrap!
    BDD.assert(kept, Image.to_pixels(loaded).unwrap! == second_raw, "the load gave the pixels of the file before")
  end
end

# A transform of the image, as the peer takes it: `crop 3 2 5 4`, `flip h`, `rotate 90`, `resize 32 24`, `grey`,
# `srgb` or `cast f32`. The source is closed before the pixels are read: the result keeps what it needs.
def transformed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  words = args[5].split(" ")
  img = from_raw(args)
  result = apply_transform(img, words).unwrap!
  Native.close(img)
  actual = Image.to_pixels(result).unwrap!
  with_folder(ctx) do |kept, folder|
    out = Path.join([folder, "peer.raw"]).unwrap!
    peer_args = ["#{FIXTURES}/peer.py", "apply", words[0], fixture_path(args[0]), out]
    shape = [args[1], args[2], args[3]]
    extra = words.drop(1)
    if words[0] == "cast"
      extra = [args[4].downcase, words[1]]
    end

    process = Process.spawn_captured("python3", peer_args + shape + extra).unwrap!
    printed = Process.output(process, 20000).unwrap!.stdout.strip
    seen = "#{Image.width(result)} #{Image.height(result)} #{Image.bands(result)}"
    return BDD.assert(kept, false, "#{args[5]} gave #{seen}, the peer #{printed}") if printed != seen

    worst = difference(actual, read_path(out))
    BDD.assert(kept, worst <= args[6].to_i!, "#{args[5]} is #{worst} levels from the peer, not #{args[6]}")
  end
end

def apply_transform(img: Image.Image, words: List[String]) -> Result[Image.Image]
  case words[0]
    "crop" -> Image.crop(img, words[1].to_i!, words[2].to_i!, words[3].to_i!, words[4].to_i!)
    "flip" -> Image.flip(img, direction_of(words[1]))
    "rotate" -> Image.rotate(img, words[1].to_i!)
    "resize" -> resize_with(img, words)
    "grey" -> Image.colourspace(img, Image.Space.Grey)
    "srgb" -> Image.colourspace(img, Image.Space.Srgb)
    _ -> Image.cast(img, format_of(words[1].upcase))
  end
end

# `resize 32 24` is the default kernel, `resize 32 24 cubic` names one.
def resize_with(img: Image.Image, words: List[String]) -> Result[Image.Image]
  return Image.resize(img, words[1].to_i!, words[2].to_i!) if words.size == 3

  Image.resize(img, words[1].to_i!, words[2].to_i!, kernel_of(words[3]))
end

def kernel_of(name: String) -> Image.Kernel
  case name
    "nearest" -> Image.Kernel.Nearest
    "linear" -> Image.Kernel.Linear
    "cubic" -> Image.Kernel.Cubic
    "lanczos2" -> Image.Kernel.Lanczos2
    _ -> Image.Kernel.Lanczos3
  end
end

def direction_of(name: String) -> Image.Direction
  case name
    "h" -> Image.Direction.Horizontal
    _ -> Image.Direction.Vertical
  end
end

# The largest difference between two bytes at the same place; a different length is more than any byte can differ.
def difference(a: Bytes, b: Bytes) -> Int
  return 256 if a.size != b.size

  worst = 0
  for i in 0...a.size
    gap = (a[i] - b[i]).abs
    if gap > worst
      worst = gap
    end
  end

  worst
end

def parallel(ctx: BDD.Context, args: List[String]) -> BDD.Context
  data = read(args[1])
  expected = read(args[2])
  results = Task.map((1..args[0].to_i!).to_a, 4, 30000) do |_n|
    ok(Image.to_pixels(try Image.from_bytes(data)) == ok(expected))
  end

  BDD.assert(ctx, results.all?(->(r) { r == ok(true) }), "a task decoded other pixels")
end

# A chain of two transforms reads fine after both images it came through are closed.
def turned_back(ctx: BDD.Context, args: List[String]) -> BDD.Context
  first = from_raw(args)
  middle = Image.rotate(first, 90).unwrap!
  last = Image.rotate(middle, 270).unwrap!
  Native.close(first)
  Native.close(middle)
  BDD.assert(ctx, Image.to_pixels(last).unwrap! == read(args[0]), "the chain gave other pixels")
end

# Each of the five kernels gives its own pixels, and a resize with no kernel is the one with Lanczos 3.
def kernels(ctx: BDD.Context, args: List[String]) -> BDD.Context
  img = from_raw(args)
  width = args[5].to_i!
  height = args[6].to_i!
  by_kernel = ["nearest", "linear", "cubic", "lanczos2", "lanczos3"].map do |name|
    Image.to_pixels(Image.resize(img, width, height, kernel_of(name)).unwrap!).unwrap!
  end

  default = Image.to_pixels(Image.resize(img, width, height).unwrap!).unwrap!
  return BDD.assert(ctx, false, "the default is not Lanczos 3") if default != by_kernel[4]

  distinct = by_kernel.uniq.size
  BDD.assert(ctx, distinct == 5, "#{distinct} of the 5 kernels gave different pixels")
end

# The resizes of one input and kernel in pillow_resize.json (written by pillow.py) against what Pillow made: the golden
# holds each input and each size, so the enlarges and the shrinks of every factor on each axis are checked. A failure
# lists each size that is too far, with its distance.
def against_pillow(ctx: BDD.Context, args: List[String]) -> BDD.Context
  golden = JSON.decode(String.from_bytes(read("pillow_resize.json")).unwrap!, Golden).unwrap!
  source = golden.inputs[args[2]]
  pixels = OpenSSL.Digest.hexdecode(source.hex).unwrap!
  cases = golden.cases.select(->(c) { c.input == args[2] and c.kernel == args[0] and c.kind == args[1] })
  limit = args[3].to_i!
  too_far: List[String] = []
  for c in cases
    img = Image.from_pixels(pixels, source.width, source.height, source.bands, Image.Format.U8).unwrap!
    result = Image.resize(img, c.width, c.height, kernel_of(c.kernel)).unwrap!
    Native.close(img)
    gap = difference(Image.to_pixels(result).unwrap!, OpenSSL.Digest.hexdecode(c.hex).unwrap!)
    if gap > limit
      too_far = too_far.push("#{c.width}x#{c.height}: #{gap}")
    end
  end

  BDD.assert(ctx, cases.size > 0 and too_far.empty?, "#{cases.size} sizes, too far: #{too_far.join(", ")}")
end

# libvips enlarges with Lanczos 2 and Lanczos 3 as with Cubic (it has no wider interpolator for an enlarge), so
# the three
# give the same pixels; Pillow's LANCZOS is another filter.
def lanczos_enlarge(ctx: BDD.Context, args: List[String]) -> BDD.Context
  img = from_raw(args)
  width = args[5].to_i!
  height = args[6].to_i!
  pixels = ["cubic", "lanczos2", "lanczos3"].map do |name|
    Image.to_pixels(Image.resize(img, width, height, kernel_of(name)).unwrap!).unwrap!
  end

  BDD.assert(ctx, pixels[0] == pixels[1] and pixels[0] == pixels[2], "Lanczos 2 or 3 enlarges other than Cubic")
end

# An enlarge keeps the colour of a pixel that is next to a transparent one (the alpha band is premultiplied inside, as
# for a shrink it is not): the middle of an opaque red pixel and a transparent blue one is red with half the alpha.
def alpha_enlarge(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  img = Image.from_pixels(Bytes.from_list([255, 0, 0, 255, 0, 0, 255, 0]).unwrap!, 2, 1, 4, Image.Format.U8).unwrap!
  pixels = Image.to_pixels(Image.resize(img, 6, 1, Image.Kernel.Linear).unwrap!).unwrap!
  middle = pixels.drop(8).take(4).to_a
  BDD.assert(ctx, middle == [255, 0, 0, 170], "the pixel next to a transparent one is #{middle}")
end

# Each task makes, resizes and reads an image of its own, a large one so that libvips works on several tiles at once;
# no image is shared, since a resource belongs to its task.
def parallel_resize(ctx: BDD.Context, args: List[String]) -> BDD.Context
  width = args[2].to_i!
  height = args[3].to_i!
  need = width * height * 3
  tile = read(args[1])
  pixels = Bytes.concat((1..(need / tile.size + 1)).to_a.map(->(_i) { tile })).take(need)
  target_width = args[4].to_i!
  target_height = args[5].to_i!
  expected = resized_pixels(pixels, width, height, target_width, target_height).unwrap!
  results = Task.map((1..args[0].to_i!).to_a, 4, 60000) do |_n|
    ok(resized_pixels(pixels, width, height, target_width, target_height) == ok(expected))
  end

  BDD.assert(ctx, results.all?(->(r) { r == ok(true) }), "a task read other pixels")
end

def resized_pixels(pixels: Bytes, width: Int, height: Int, target_width: Int, target_height: Int) -> Result[Bytes]
  image = try Image.from_pixels(pixels, width, height, 3, Image.Format.U8)
  Image.to_pixels(try Image.resize(image, target_width, target_height))
end

# A decode that libvips only warns about (the PNG lacks its last bytes, which it forgives) and one that it refuses must
# not leave their text for the error of another call.
def clean_error(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  png = read("rgb.png")
  _ = Image.from_bytes(png.take(470))
  with_folder(ctx) do |kept, folder|
    path = Path.join([folder, "truncated.png"]).unwrap!
    write_path(path, png.take(300))
    _ = Image.load(path)
    case Image.load("#{FIXTURES}/missing")
      ok(_) -> BDD.assert(kept, false, "a missing file loaded")
      error(e) ->
        clean = e.message.include?("does not exist") and not e.message.include?("\n") and not e.message.include?("png")
        BDD.assert(kept, clean, "the message of a missing file is #{e.message}")
    end
  end
end

# A size that is allowed is accepted (nothing is read, so a large one costs nothing).
def accepted(ctx: BDD.Context, args: List[String]) -> BDD.Context
  img = Image.from_pixels(read("rgb.raw"), 16, 12, 3, Image.Format.U8).unwrap!
  result = Image.resize(img, args[0].to_i!, args[1].to_i!)
  BDD.assert(ctx, result.ok?, "resize to #{args[0]} by #{args[1]} failed: #{result.message}")
end

# One row per call: its name, the arguments it takes, and the message when this package makes it (libvips makes the
# others).
def failures(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  rows = BDD.table(ctx).drop(1)
  good = read("rgb.raw")
  img = Image.from_pixels(good, 16, 12, 3, Image.Format.U8).unwrap!
  nul = String.from_bytes(Bytes.from_list([0]).unwrap!).unwrap!
  five = Image.from_pixels(good.take(15), 3, 1, 5, Image.Format.U8).unwrap!
  ramp = Image.from_pixels(read("ramp_f32.raw"), 4, 3, 2, Image.Format.F32).unwrap!
  for row in rows
    failure = case row[0]
      "from_bytes" -> refusal(Image.from_bytes(row[1].bytes))
      "load" -> refusal(Image.load(row[1]))
      "from_pixels" -> refusal(Image.from_pixels(good, row[1].to_i!, row[2].to_i!, row[3].to_i!, format_of(row[4])))
      "to_bytes" -> refusal(Image.to_bytes(img, row[1]))
      "save" -> refusal(Image.save(img, row[1]))
      "load_nul" -> refusal(Image.load("a.png#{nul}x"))
      "save_nul" -> refusal(Image.save(img, "a.png#{nul}x"))
      "to_bytes_nul" -> refusal(Image.to_bytes(img, "png#{nul}x"))
      "crop" -> refusal(Image.crop(img, row[1].to_i!, row[2].to_i!, row[3].to_i!, row[4].to_i!))
      "rotate" -> refusal(Image.rotate(img, row[1].to_i!))
      "resize" -> refusal(Image.resize(img, row[1].to_i!, row[2].to_i!))
      "cast" -> refusal(Image.cast(img, format_of(row[1])))
      "colourspace5" -> refusal(Image.colourspace(five, space_of(row[1])))
      _ -> refusal(Image.colourspace(ramp, space_of(row[1])))
    end

    message = failure.unwrap_or("")
    return BDD.assert(ctx, false, "#{row[0]} #{row[1]} did not fail") if failure == none
    if not row[5].empty? and message != row[5]
      return BDD.assert(ctx, false, "#{row[0]} #{row[1]} failed with #{message}, not #{row[5]}")
    end
  end

  BDD.assert(ctx, rows.size > 0, "no calls to check")
end

def refusal[T](result: Result[T]) -> Optional[String]
  case result
    ok(_) -> none
    error(e) -> some(e.message)
  end
end

def space_of(name: String) -> Image.Space
  case name
    "Grey" -> Image.Space.Grey
    _ -> Image.Space.Srgb
  end
end

# The image of the pixels of args[0] as the width, the height, the bands and the format that follow.
def from_raw(args: List[String]) -> Image.Image
  Image.from_pixels(read(args[0]), args[1].to_i!, args[2].to_i!, args[3].to_i!, format_of(args[4])).unwrap!
end

# `shape` is the width, the height, the bands and the format.
def shaped?(img: Image.Image, shape: List[String]) -> Bool
  dimensions = Image.width(img) == shape[0].to_i! and Image.height(img) == shape[1].to_i!
  dimensions and Image.bands(img) == shape[2].to_i! and Image.pixel_format(img) == format_of(shape[3])
end

def format_of(name: String) -> Image.Format
  case name
    "U8" -> Image.Format.U8
    "I8" -> Image.Format.I8
    "U16" -> Image.Format.U16
    "I16" -> Image.Format.I16
    "U32" -> Image.Format.U32
    "I32" -> Image.Format.I32
    "F32" -> Image.Format.F32
    "F64" -> Image.Format.F64
    _ -> Image.Format.Complex
  end
end

def fixture_path(name: String) -> String = "#{FIXTURES}/#{name}"

def read(name: String) -> Bytes = read_path(fixture_path(name))

def read_path(path: String) -> Bytes
  file = File.open(path).unwrap!
  bytes = File.read_bytes(file, 1_048_576).unwrap!
  File.close(file).unwrap!
  bytes
end

def write_path(path: String, bytes: Bytes) -> Void
  file = File.open(path, "write").unwrap!
  File.write_bytes(file, bytes).unwrap!
  File.close(file).unwrap!
end

# A private folder for the block, which gets the context that removes it when the scenario ends.
def with_folder(ctx: BDD.Context, body: Fn[BDD.Context, String, BDD.Context]) -> BDD.Context
  base = System.env("TMPDIR").unwrap_or("/tmp")
  folder = Path.join([base, "image-#{System.pid()}-#{Time.now.to_us}"]).unwrap!
  Dir.mkdir_private(folder).unwrap!
  body.call(BDD.after(ctx) do |_done| Path.remove(folder) end, folder)
end
