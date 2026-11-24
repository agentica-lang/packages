## The error kinds of this package. A caller can tell a damaged file from one this package does not read.

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")

def unsupported[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.unsupported")

def invalid[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.invalid")
