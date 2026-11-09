# A parameter that is a C macro and one that has its new name: both are `errno_`.
extern module "stats"
  def pair(errno: Int, errno_: Int) -> Int
end
