/* The module of shapes.agc: each echo reads its argument into the C value of the header and makes it again. */
#define SHAPES_NATIVE_IMPLEMENTATION
#include "shapes_native.h"

an_term shapes_echo_point(an_env *env, shapes_Point value) { return shapes_Point_make(env, &value); }

an_term shapes_echo_label(an_env *env, shapes_Label value) { return shapes_Label_make(env, &value); }

an_term shapes_misread(an_env *env, shapes_Point value, an_term values) {
  if (!shapes_Point_get(env, values, &value)) return an_void(env);
  return shapes_Point_make(env, &value);
}

SHAPES_NATIVE_MODULE(NULL)
