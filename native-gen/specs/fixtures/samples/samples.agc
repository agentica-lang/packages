## List[Float32] through the header: a function reads its samples run by run, as C floats, and makes a List[Float32]
## from C floats.

extern module "samples"
  ## The sum of the squares of the samples.
  def energy(samples: List[Float32]) -> Float
  ## The samples times `by`.
  def scaled(samples: List[Float32], by: Float) -> List[Float32]
  ## Each row backwards.
  def reversed(rows: List[List[Float32]]) -> List[List[Float32]]
  ## Calls the wrapper of `energy` with a List[Int] in its argument: the call fails at
  ## `argument 1: List[Float32].0: expected Float32`.
  def misread_argument() -> Float
end

def main() -> Void
  if System.args().join(" ") == "misread_argument"
    puts(misread_argument())
  else
    samples: List[Float32] = [1.5, 2.0, 0.5]
    rows: List[List[Float32]] = [[1.0, 2.0, 3.0], [], [4.0]]
    puts(energy(samples))
    puts(energy(samples.concat(samples)))
    puts(scaled(samples, 2.0))
    puts(reversed(rows))
  end
end
