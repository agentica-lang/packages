## The steps of image.feature. The fixtures of specs/fixtures are written by peer.py, an independent PNG codec: each
## PNG next to the raw pixels it holds (little endian), and a ramp of floats.

import BDD from "std/bdd"
import Image from "../image"

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
    "resize" -> Image.resize(img, words[1].to_i!, words[2].to_i!)
    "grey" -> Image.colourspace(img, Image.Space.Grey)
    "srgb" -> Image.colourspace(img, Image.Space.Srgb)
    _ -> Image.cast(img, format_of(words[1].upcase))
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

# One row per call: its name, then the arguments it takes.
def failures(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  rows = BDD.table(ctx).drop(1)
  good = read("rgb.raw")
  img = Image.from_pixels(good, 16, 12, 3, Image.Format.U8).unwrap!
  for row in rows
    failed = case row[0]
      "from_bytes" -> not Image.from_bytes(row[1].bytes).ok?
      "load" -> not Image.load(row[1]).ok?
      "from_pixels" -> not Image.from_pixels(good, row[1].to_i!, row[2].to_i!, row[3].to_i!, format_of(row[4])).ok?
      "to_bytes" -> not Image.to_bytes(img, row[1]).ok?
      "crop" -> not Image.crop(img, row[1].to_i!, row[2].to_i!, row[3].to_i!, row[4].to_i!).ok?
      "rotate" -> not Image.rotate(img, row[1].to_i!).ok?
      "resize" -> not Image.resize(img, row[1].to_i!, row[2].to_i!).ok?
      "cast" -> not Image.cast(img, format_of(row[1])).ok?
      _ -> false
    end

    return BDD.assert(ctx, false, "#{row.join(" ")} did not fail") if not failed
  end

  BDD.assert(ctx, rows.size > 0, "no calls to check")
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
