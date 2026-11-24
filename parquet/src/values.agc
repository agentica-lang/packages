## The values of a column, one list per kind of value. A null is `none`, so a column keeps every row.

enum Values
  Booleans(List[Optional[Bool]])
  Integers(List[Optional[Int]])
  Floats(List[Optional[Float]])
  Texts(List[Optional[String]])
  Blobs(List[Optional[Bytes]])
end

def size(values: Values) -> Int
  case values
    Values.Booleans(xs) -> xs.size
    Values.Integers(xs) -> xs.size
    Values.Floats(xs) -> xs.size
    Values.Texts(xs) -> xs.size
    Values.Blobs(xs) -> xs.size
  end
end

def take(values: Values, count: Int) -> Values
  case values
    Values.Booleans(xs) -> Values.Booleans(xs.take(count))
    Values.Integers(xs) -> Values.Integers(xs.take(count))
    Values.Floats(xs) -> Values.Floats(xs.take(count))
    Values.Texts(xs) -> Values.Texts(xs.take(count))
    Values.Blobs(xs) -> Values.Blobs(xs.take(count))
  end
end

## The rows of `a`, then those of `b`; the two must be of one kind.
def join(a: Values, b: Values) -> Result[Values]
  case a
    Values.Booleans(xs) -> join_booleans(xs, b)
    Values.Integers(xs) -> join_integers(xs, b)
    Values.Floats(xs) -> join_floats(xs, b)
    Values.Texts(xs) -> join_texts(xs, b)
    Values.Blobs(xs) -> join_blobs(xs, b)
  end
end

## The values of a dictionary at each index.
def pick(dictionary: Values, indices: List[Int]) -> Result[Values]
  case dictionary
    Values.Booleans(xs) -> ok(Values.Booleans(try pick_list(xs, indices)))
    Values.Integers(xs) -> ok(Values.Integers(try pick_list(xs, indices)))
    Values.Floats(xs) -> ok(Values.Floats(try pick_list(xs, indices)))
    Values.Texts(xs) -> ok(Values.Texts(try pick_list(xs, indices)))
    Values.Blobs(xs) -> ok(Values.Blobs(try pick_list(xs, indices)))
  end
end

## The values of a page are the defined ones: a level equal to `max_level` takes the next value, any lower level is a
## null. A column that cannot be null has no levels at all.
def spread(values: Values, levels: List[Int], max_level: Int) -> Result[Values]
  return ok(values) if max_level == 0

  case values
    Values.Booleans(xs) -> ok(Values.Booleans(try spread_list(xs, levels, max_level)))
    Values.Integers(xs) -> ok(Values.Integers(try spread_list(xs, levels, max_level)))
    Values.Floats(xs) -> ok(Values.Floats(try spread_list(xs, levels, max_level)))
    Values.Texts(xs) -> ok(Values.Texts(try spread_list(xs, levels, max_level)))
    Values.Blobs(xs) -> ok(Values.Blobs(try spread_list(xs, levels, max_level)))
  end
end

private

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")

def join_booleans(xs: List[Optional[Bool]], b: Values) -> Result[Values]
  case b
    Values.Booleans(ys) -> ok(Values.Booleans(xs + ys))
    _ -> malformed("a column with two kinds of values")
  end
end

def join_integers(xs: List[Optional[Int]], b: Values) -> Result[Values]
  case b
    Values.Integers(ys) -> ok(Values.Integers(xs + ys))
    _ -> malformed("a column with two kinds of values")
  end
end

def join_floats(xs: List[Optional[Float]], b: Values) -> Result[Values]
  case b
    Values.Floats(ys) -> ok(Values.Floats(xs + ys))
    _ -> malformed("a column with two kinds of values")
  end
end

def join_texts(xs: List[Optional[String]], b: Values) -> Result[Values]
  case b
    Values.Texts(ys) -> ok(Values.Texts(xs + ys))
    _ -> malformed("a column with two kinds of values")
  end
end

def join_blobs(xs: List[Optional[Bytes]], b: Values) -> Result[Values]
  case b
    Values.Blobs(ys) -> ok(Values.Blobs(xs + ys))
    _ -> malformed("a column with two kinds of values")
  end
end

def pick_list[T](xs: List[T], indices: List[Int]) -> Result[List[T]]
  picked: List[T] = []
  for index in indices
    return malformed("dictionary index #{index} of #{xs.size} values") if index < 0 or index >= xs.size

    picked = picked.push(xs[index])
  end

  ok(picked)
end

def spread_list[T](xs: List[Optional[T]], levels: List[Int], max_level: Int) -> Result[List[Optional[T]]]
  rows: List[Optional[T]] = []
  taken = 0
  for level in levels
    return malformed("a definition level #{level} above #{max_level}") if level > max_level
    if level == max_level
      return malformed("more defined values than the page holds") if taken >= xs.size

      rows = rows.push(xs[taken])
      taken = taken + 1
    else
      rows = rows.push(none)
    end
  end

  ok(rows)
end
