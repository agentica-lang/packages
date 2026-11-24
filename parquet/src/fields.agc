## Reads of the fields of a decoded Thrift struct: a missing optional field gives its default, a required one is an error,
## and a field of another kind is an error too.

import Errors from "errors"
import Thrift from "thrift"

def number(fields: Map[Int, Thrift.Value], id: Int, default: Int) -> Result[Int]
  case fields.get(id)
    some(Thrift.Value.Number(n)) -> ok(n)
    none -> ok(default)
    _ -> wrong_kind(id, "a number")
  end
end

def required_number(fields: Map[Int, Thrift.Value], id: Int) -> Result[Int]
  case fields.get(id)
    some(Thrift.Value.Number(n)) -> ok(n)
    _ -> missing(id, "a number")
  end
end

def flag(fields: Map[Int, Thrift.Value], id: Int, default: Bool) -> Result[Bool]
  case fields.get(id)
    some(Thrift.Value.Flag(b)) -> ok(b)
    none -> ok(default)
    _ -> wrong_kind(id, "a flag")
  end
end

def text(fields: Map[Int, Thrift.Value], id: Int) -> Result[String]
  case fields.get(id)
    some(Thrift.Value.Blob(bytes)) -> strict_text(id, bytes)
    _ -> missing(id, "a string")
  end
end

def struct_at(fields: Map[Int, Thrift.Value], id: Int) -> Result[Map[Int, Thrift.Value]]
  case fields.get(id)
    some(Thrift.Value.Fields(inner)) -> ok(inner)
    _ -> missing(id, "a struct")
  end
end

def items_at(fields: Map[Int, Thrift.Value], id: Int) -> Result[List[Thrift.Value]]
  case fields.get(id)
    some(Thrift.Value.Items(values)) -> ok(values)
    none -> ok([])
    _ -> wrong_kind(id, "a list")
  end
end

def as_text(value: Thrift.Value) -> Result[String]
  case value
    Thrift.Value.Blob(bytes) -> strict_text(-1, bytes)
    _ -> Errors.malformed("a list item is not a string")
  end
end

def as_struct(value: Thrift.Value) -> Result[Map[Int, Thrift.Value]]
  case value
    Thrift.Value.Fields(inner) -> ok(inner)
    _ -> Errors.malformed("a list item is not a struct")
  end
end

private

def missing[T](id: Int, kind: String) -> Result[T] = Errors.malformed("field #{id} is missing or not #{kind}")

def wrong_kind[T](id: Int, kind: String) -> Result[T] = Errors.malformed("field #{id} is not #{kind}")

def strict_text(id: Int, bytes: Bytes) -> Result[String]
  case String.from_bytes(bytes)
    ok(s) -> ok(s)
    error(_) -> Errors.malformed("field #{id} is not valid UTF-8")
  end
end
