## The errors of the decoder: one kind for each class of failure.

def malformed[T](message: String) -> Result[T] = error("zstd: #{message}", kind: "zstd.malformed")

def unsupported[T](message: String) -> Result[T] = error("zstd: #{message}", kind: "zstd.unsupported")

def too_large[T](message: String) -> Result[T] = error("zstd: #{message}", kind: "zstd.too_large")
