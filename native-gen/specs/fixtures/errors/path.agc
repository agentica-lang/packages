# A library named by a path whose name is no C identifier: the prefix must be given.
extern module "/opt/native/lib-stats.so"
  def count(values: List[Int]) -> Int
end
