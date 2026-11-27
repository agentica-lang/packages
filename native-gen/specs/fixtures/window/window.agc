## A struct whose name starts with Float32 is not a List[Float32]: --lang rust writes it.

struct Float32Window
  size: Int
end

extern module "window"
  ## The size of `window`.
  def size(window: Float32Window) -> Int
end
