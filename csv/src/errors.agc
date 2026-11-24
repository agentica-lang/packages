## The error kinds of this package: `csv.malformed` for text that is not CSV, `csv.invalid` for a bad argument.

def malformed[T](message: String) -> Result[T] = error("csv: #{message}", kind: "csv.malformed")

def invalid[T](message: String) -> Result[T] = error("csv: #{message}", kind: "csv.invalid")
