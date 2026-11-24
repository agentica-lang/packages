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

  with_folder(ctx) do |folder|
    path = Path.join([folder, "image.#{args[5]}"]).unwrap!
    Image.save(img, path).unwrap!
    BDD.assert(ctx, Image.to_pixels(Image.load(path).unwrap!).unwrap! == raw, "#{args[5]} on disk changed the pixels")
  end
end

# What the peer reads from the PNG that this package writes.
def peer(ctx: BDD.Context, args: List[String]) -> BDD.Context
  raw = read(args[0])
  img = from_raw(args)
  with_folder(ctx) do |folder|
    png = Path.join([folder, "image.png"]).unwrap!
    out = Path.join([folder, "peer.raw"]).unwrap!
    write_path(png, Image.to_bytes(img, "png").unwrap!)
    process = Process.spawn_captured("python3", ["#{FIXTURES}/peer.py", "decode", png, out]).unwrap!
    printed = Process.output(process, 20000).unwrap!.stdout.strip
    shape = "#{args[1]} #{args[2]} #{args[3]}"
    return BDD.assert(ctx, false, "the peer read #{printed}, not #{shape}") if printed != shape

    BDD.assert(ctx, read_path(out) == raw, "the peer read other pixels")
  end
end

# A lossy format keeps the size, and the encoded bytes decode again.
def encodes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  img = from_raw(args)
  back = Image.from_bytes(Image.to_bytes(img, args[5]).unwrap!).unwrap!
  same = Image.width(back) == Image.width(img) and Image.height(back) == Image.height(img)
  BDD.assert(ctx, same, "#{args[5]} changed the size")
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

# A private folder for the block, removed after it.
def with_folder(ctx: BDD.Context, body: Fn[String, BDD.Context]) -> BDD.Context
  base = System.env("TMPDIR").unwrap_or("/tmp")
  folder = Path.join([base, "image-#{System.pid()}-#{Time.now.to_us}"]).unwrap!
  Dir.mkdir_private(folder).unwrap!
  done = body.call(folder)
  Path.remove(folder).unwrap!
  done
end
