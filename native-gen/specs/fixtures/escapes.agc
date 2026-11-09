# A library name that the C string of the table must escape: a tab, quotes and a trigraph.
extern module "tab\there \"q\" ??="
  def count(values: List[Int]) -> Int
end
