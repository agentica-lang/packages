## Shrink trees. A tree holds a value and, computed only when asked, the simpler values it can shrink to, simplest
## first. Every combinator builds the tree of its result from the trees of its parts, so a mapped, paired or listed
## value shrinks through the shrinking of its parts, with no inverse function.

export struct Tree[T]
  value: T
  children: Fn[List[Tree[T]]]
end

## The tree of `value` whose shrinks `children` computes on demand.
export def grow[T](value: T, children: Fn[List[Tree[T]]]) -> Tree[T]
  return Tree(value: value, children: children)
end

## A value that does not shrink.
export def leaf[T](value: T) -> Tree[T]
  return grow(value) do no_children() end
end

## The tree of `f` applied to every value of `tree`.
export def map_tree[A, B](tree: Tree[A], f: Fn[A, B]) -> Tree[B]
  return grow(f.call(tree.value)) do tree.children().map do |child| map_tree(child, f) end end
end

## The tree of `f(a, b)`: it shrinks `a` first, then `b`.
export def zip_trees[A, B, C](a: Tree[A], b: Tree[B], f: Fn[A, B, C]) -> Tree[C]
  return grow(f.call(a.value, b.value)) do
    left = a.children().map do |child| zip_trees(child, b, f) end
    right = b.children().map do |child| zip_trees(a, child, f) end
    left.concat(right)
  end
end

## The tree of the list of values: it shrinks by dropping items (all of them, a half, one), then by shrinking one item.
export def list_tree[T](trees: List[Tree[T]]) -> Tree[List[T]]
  return grow(trees.map do |tree| tree.value end) do list_children(trees) end
end

## An Int that shrinks toward `origin`: to it first, then by halving the distance.
export def int_tree(n: Int, origin: Int) -> Tree[Int]
  return grow(n) do int_children(n, origin) end
end

## A Float in `min` ..= `max` that shrinks toward `origin` (in the range): to it, to the whole number below, then to
## the middle.
export def float_tree(x: Float, origin: Float, min: Float, max: Float) -> Tree[Float]
  return grow(x) do float_children(x, origin, min, max) end
end

def no_children[T]() -> List[Tree[T]]
  return []
end

def int_children(n: Int, origin: Int) -> List[Tree[Int]]
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

def float_children(x: Float, origin: Float, min: Float, max: Float) -> List[Tree[Float]]
  out: List[Tree[Float]] = []
  if x == origin
    return out
  end

  out = out.push(float_tree(origin, origin, min, max))
  whole = x.floor.to_f
  if whole != x and whole != origin and whole >= min and whole <= max
    out = out.push(float_tree(whole, origin, min, max))
  end

  middle = origin + (x - origin) / 2.0
  if middle != x and middle != origin and middle != whole
    out = out.push(float_tree(middle, origin, min, max))
  end

  return out
end

def list_children[T](trees: List[Tree[T]]) -> List[Tree[List[T]]]
  out: List[Tree[List[T]]] = []
  size = trees.size
  if size == 0
    return out
  end

  out = out.push(list_tree(without(trees, 0, size)))
  if size >= 4
    half = size / 2
    out = out.push(list_tree(trees.drop(half)))
    out = out.push(list_tree(trees.take(half)))
  end

  if size >= 2
    for i in 0...size
      out = out.push(list_tree(without(trees, i, 1)))
    end
  end

  for i in 0...size
    for child in trees[i].children()
      out = out.push(list_tree(trees.set(i, child)))
    end
  end

  return out
end

# The trees without `count` of them from `start`.
def without[T](trees: List[Tree[T]], start: Int, count: Int) -> List[Tree[T]]
  return trees.take(start).concat(trees.drop(start + count))
end
