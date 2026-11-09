/* The module of shapes.agc: each echo reads its argument into the C value of the header and makes it again. */
#define SHAPES_NATIVE_IMPLEMENTATION
#include "shapes_native.h"

an_term shapes_echo_point(an_env *env, shapes_Point value) { return shapes_Point_make(env, &value); }

an_term shapes_echo_label(an_env *env, shapes_Label value) { return shapes_Label_make(env, &value); }

an_term shapes_echo_shape(an_env *env, shapes_Shape value) { return shapes_Shape_make(env, &value); }

/* A Tree is recursive, so its payloads are terms: the echo reads one level and makes it again. */
an_term shapes_echo_tree(an_env *env, shapes_Tree value) { return shapes_Tree_make(env, &value); }

an_term shapes_circle(an_env *env, int64_t x, int64_t y, double radius) {
  shapes_Point center = {x, y};
  return shapes_Shape_Circle(env, center, radius);
}

an_term shapes_misread(an_env *env, shapes_Point value, an_term values) {
  if (!shapes_Point_get(env, values, &value)) return an_void(env);
  return shapes_Point_make(env, &value);
}

SHAPES_NATIVE_MODULE(NULL)
