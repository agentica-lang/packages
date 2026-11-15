## The records that the stages share: the limits of a parse, and the tree of nodes that the parser makes and the
## composer turns into JSON.

## The limits of a parse. The defaults fit configuration files; raise them for bigger documents.
struct Options
  ## The most nested collections.
  max_depth: Int = 256
  ## The most nodes that aliases may add to the documents, counted as if each alias were a copy of its anchor.
  max_alias_nodes: Int = 100_000
  ## The most bytes of the text.
  max_bytes: Int = 4_194_304
end

## What every node may carry: its anchor and tag ("" when it has none), and where it starts (a byte offset).
struct Meta
  anchor: String
  tag: String
  pos: Int
end

## A node of a document. A scalar knows whether it was plain, since only a plain scalar is resolved by the schema.
enum Node
  Scalar(Meta, Bool, String)
  Seq(Meta, List[Node])
  Map(Meta, List[Entry])
  Alias(String, Int)
end

struct Entry
  key: Node
  value: Node
end
