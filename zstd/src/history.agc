## What a frame has written so far, in chunks that a match reads back from.

## The output as full chunks and a tail shorter than a chunk.
struct History
  chunks: List[Bytes]
  tail: Bytes
  produced: Int
end

## A history with nothing written.
def empty() -> History = History(chunks: [], tail: "".bytes, produced: 0)

## The history with `piece` written after it.
def append(history: History, piece: Bytes) -> History
  return history if piece.empty?

  tail = history.tail + piece
  chunks = history.chunks
  if tail.size >= CHUNK
    full = tail.size / CHUNK
    for j in 0...full
      chunks = chunks.push(tail.slice(j * CHUNK, CHUNK))
    end

    tail = tail.drop(full * CHUNK)
  end

  History(chunks: chunks, tail: tail, produced: history.produced + piece.size)
end

## `length` bytes that start `offset` bytes before the end, as a match reads them: when `offset` is shorter than
## `length` the bytes repeat. The caller checked that `offset` is at most `produced`.
def match(history: History, offset: Int, length: Int) -> Bytes
  start = history.produced - offset
  return window(history, start, length) if offset >= length

  repeat(window(history, start, offset), length)
end

## `length` bytes made of `pattern` over and over; the pattern is not empty.
def repeat(pattern: Bytes, length: Int) -> Bytes
  piece = pattern
  while piece.size < length
    piece = piece + piece
  end

  piece.take(length)
end

## Everything written, as one `Bytes`.
def output(history: History) -> Bytes = Bytes.concat(history.chunks.push(history.tail))

private

CHUNK = 4096

def window(history: History, start: Int, length: Int) -> Bytes
  chunks = history.chunks
  index = start / CHUNK
  skip = start - index * CHUNK
  full = chunks.size
  return history.tail.slice(start - full * CHUNK, length) if index >= full
  return chunks[index].slice(skip, length) if skip + length <= CHUNK

  parts: List[Bytes] = []
  need = length
  at = index
  from = skip
  while need > 0
    if at >= full
      parts = parts.push(history.tail.slice(from, need))
      need = 0
    else
      size = CHUNK - from
      if size > need
        size = need
      end

      parts = parts.push(chunks[at].slice(from, size))
      need = need - size
      at = at + 1
      from = 0
    end
  end

  Bytes.concat(parts)
end
