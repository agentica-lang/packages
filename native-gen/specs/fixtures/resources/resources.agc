## Resources through the header: a parameter is the state of its resource, `_new` makes one, `_get` reads a term, and
## the free function counts the frees.

extern module "resources"
  resource Db
  ## A Db with the id `id`.
  def open_db(id: Int) -> Db
  def db_id(db: Db) -> Int
  ## The Dbs `first` and `first + 1`, in a List.
  def pair(first: Int) -> List[Db]
  ## How many Dbs were freed.
  def freed() -> Int
  ## Whether the Int `n` is a Db, which `_get` answers: never.
  def is_db(n: Int) -> Bool
end

def main() -> Void
  task = Task.spawn do
    total = 0
    for i in 1..1000
      total += db_id(open_db(i))
    end

    total
  end

  puts(Task.await(task))
  puts(freed())
  puts(pair(7).map do |db| db_id(db) end)
  puts(is_db(3))
end
