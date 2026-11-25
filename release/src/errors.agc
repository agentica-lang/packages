## The error kinds of this package: `release.invalid` for a bad argument or manifest, `release.failed` for a program
## that did not do its job, `release.corrupt` for a release that does not match its manifest.

def invalid[T](message: String) -> Result[T] = error("release: #{message}", kind: "release.invalid")

def failed[T](message: String) -> Result[T] = error("release: #{message}", kind: "release.failed")

def corrupt[T](message: String) -> Result[T] = error("release: #{message}", kind: "release.corrupt")
