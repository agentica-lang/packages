# A variant with a payload named after a C macro: its member in the union would be replaced.
enum Reply
  Ok(Int)
  EOF(String)
end

extern module "stats"
  def reply(value: Reply) -> Int
end
