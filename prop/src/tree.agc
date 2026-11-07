## Shrink trees. A tree holds a value and, computed only when asked, the simpler values it can shrink to, simplest
## first, as a lazy list (`Candidates`): a candidate is built only when `check` pulls it, so the work of shrinking is
## the work of the candidates tried. Every combinator builds the tree of its result from the trees of its parts, so a
## mapped, paired or listed value shrinks through the shrinking of its parts, with no inverse function.

# Below this distance from the origin a float is only offered the origin: halving a float that is already tiny would
# spend the whole budget on values nobody can tell apart.
CLOSE = 0.000001

export struct Tree[T]
  value: T
  shrinks: Fn[Optional[Candidates[T]]]
end

## A lazy list of trees: the first one, and what follows it once asked.
export struct Candidates[T]
  first: Tree[T]
  rest: Fn[Optional[Candidates[T]]]
end

## The tree of `value` whose candidates `shrinks` computes on demand.
export def grow[T](value: T, shrinks: Fn[Optional[Candidates[T]]]) -> Tree[T]
  return Tree(value: value, shrinks: shrinks)
end

## A value that does not shrink.
export def leaf[T](value: T) -> Tree[T]
  return grow(value) do none end
end

## The tree of `f` applied to every value of `tree`.
export def map_tree[A, B](tree: Tree[A], f: Fn[A, B]) -> Tree[B]
  return grow(f.call(tree.value)) do map_candidates(tree.shrinks()) do |child| map_tree(child, f) end end
end

## The tree of `f(a, b)`: it shrinks `a` first, then `b`.
export def zip_trees[A, B, C](a: Tree[A], b: Tree[B], f: Fn[A, B, C]) -> Tree[C]
  return grow(f.call(a.value, b.value)) do
    append(map_candidates(a.shrinks()) do |child| zip_trees(child, b, f) end) do
      map_candidates(b.shrinks()) do |child| zip_trees(a, child, f) end
    end
  end
end

## The tree of `some(value)`, which shrinks to `none` first, then as the tree of the value does.
export def some_tree[T](tree: Tree[T]) -> Tree[Optional[T]]
  absent: Tree[Optional[T]] = leaf(none)
  return grow(some(tree.value)) do
    cons(absent) do map_candidates(tree.shrinks()) do |child| some_tree(child) end end
  end
end

## An Int that shrinks toward `origin`: to it first, then by halving the distance.
export def int_tree(n: Int, origin: Int) -> Tree[Int]
  return grow(n) do from_list(int_shrinks(n, origin), 0) end
end

## A Float that shrinks toward `origin`: to it, to the whole number toward it, then by half the distance, a quarter,
## and so on. Every candidate is strictly closer to `origin` and between it and `x`, so it never goes back and never
## leaves the range of `x` and `origin`.
export def float_tree(x: Float, origin: Float) -> Tree[Float]
  return grow(x) do from_list(float_shrinks(x, origin), 0) end
end

## The tree of the list of values. It shrinks by dropping items (all of them, a half, one), then by shrinking one item.
export def list_tree[T](trees: List[Tree[T]]) -> Tree[List[T]]
  return shaped(trees, false, 0)
end

# The candidates that follow `first`, once asked: the one place where a lazy list is made lazy.
def cons[T](first: Tree[T], rest: Fn[Optional[Candidates[T]]]) -> Optional[Candidates[T]]
  return some(Candidates(first: first, rest: rest))
end

def append[T](head: Optional[Candidates[T]], tail: Fn[Optional[Candidates[T]]]) -> Optional[Candidates[T]]
  case head
    some(candidates) -> return cons(candidates.first) do append(candidates.rest(), tail) end
    none -> return tail.call()
  end
end

def map_candidates[A, B](head: Optional[Candidates[A]], f: Fn[Tree[A], Tree[B]]) -> Optional[Candidates[B]]
  case head
    some(candidates) -> return cons(f.call(candidates.first)) do map_candidates(candidates.rest(), f) end
    none -> return none
  end
end

def from_list[T](trees: List[Tree[T]], index: Int) -> Optional[Candidates[T]]
  if index >= trees.size
    return none
  end

  return cons(trees[index]) do from_list(trees, index + 1) end
end

def int_shrinks(n: Int, origin: Int) -> List[Tree[Int]]
  out: List[Tree[Int]] = []
  distance = n - origin
  if distance == 0
    return out
  end

  out = out.push(int_tree(origin, origin))
  step = distance / 2
  while step != 0
    out = out.push(int_tree(n - step, origin))
    step = step / 2
  end

  return out
end

def float_shrinks(x: Float, origin: Float) -> List[Tree[Float]]
  out: List[Tree[Float]] = []
  distance = (x - origin).abs
  if distance == 0.0
    return out
  end

  out = out.push(float_tree(origin, origin))
  if distance <= CLOSE
    return out
  end

  # Only a whole number between the origin and x: with a fractional origin, rounding could cross it and leave
  # the range.
  whole = toward(x, origin)
  if between?(whole, x, origin) and whole != origin and whole != x
    out = out.push(float_tree(whole, origin))
  end

  # x moved toward the origin by half the distance, then a quarter, ...: the last ones are the closest to x. A step
  # under half an ulp of x moves nothing, and the ones after it are smaller still.
  step = distance / 2.0
  while step > CLOSE
    moved = toward_by(x, origin, step)
    if moved == x or moved == origin
      break
    end

    out = out.push(float_tree(moved, origin))
    step = step / 2.0
  end

  return out
end

# Whether `y` is on the segment from `x` to `origin`.
def between?(y: Float, x: Float, origin: Float) -> Bool
  if x > origin
    return y >= origin and y <= x
  end

  return y <= origin and y >= x
end

def toward_by(x: Float, origin: Float, step: Float) -> Float
  if x > origin
    return x - step
  end

  return x + step
end

# `x` rounded to a whole number on the side of `origin`.
def toward(x: Float, origin: Float) -> Float
  if x > origin
    return x.floor.to_f
  end

  return x.ceil.to_f
end

# A list tree. After an item shrank (`items_first`), the next candidates are the shrinks of that item and the ones
# after it, because a shrink that worked tends to work again; after a drop, the drops go on from the same position.
# The rest follows, so the shrinking still ends only when no candidate falsifies the law.
def shaped[T](trees: List[Tree[T]], items_first: Bool, start: Int) -> Tree[List[T]]
  return grow(trees.map do |tree| tree.value end) do list_candidates(trees, items_first, start) end
end

def list_candidates[T](trees: List[Tree[T]], items_first: Bool, start: Int) -> Optional[Candidates[List[T]]]
  if trees.empty?
    return none
  end

  if items_first
    return append(item_shrinks(trees, start, 0)) do append(halves(trees, 0)) do drops(trees, 0, 0) end end
  end

  return append(halves(trees, 0)) do append(drops(trees, start, 0)) do item_shrinks(trees, 0, 0) end end
end

# The empty list, then (from 4 items) each half.
def halves[T](trees: List[Tree[T]], step: Int) -> Optional[Candidates[List[T]]]
  half = trees.size / 2
  if step == 0
    return cons(shaped(trees.take(0), false, 0)) do halves(trees, 1) end
  elsif step == 1 and trees.size >= 4
    return cons(shaped(trees.drop(half), false, 0)) do halves(trees, 2) end
  elsif step == 2 and trees.size >= 4
    return cons(shaped(trees.take(half), false, 0)) do halves(trees, 3) end
  end

  return none
end

# Each list with one item less, from position `start` and around (`count` of them done).
def drops[T](trees: List[Tree[T]], start: Int, count: Int) -> Optional[Candidates[List[T]]]
  size = trees.size
  if size < 2 or count >= size
    return none
  end

  index = (start + count) % size
  fewer = trees.take(index).concat(trees.drop(index + 1))
  return cons(shaped(fewer, false, index)) do drops(trees, start, count + 1) end
end

# The shrinks of each item, from item `start` and around (`count` of them done).
def item_shrinks[T](trees: List[Tree[T]], start: Int, count: Int) -> Optional[Candidates[List[T]]]
  if count >= trees.size
    return none
  end

  index = (start + count) % trees.size
  return append(map_candidates(trees[index].shrinks()) do |child| shaped(trees.set(index, child), true, index) end) do
    item_shrinks(trees, start, count + 1)
  end
end
