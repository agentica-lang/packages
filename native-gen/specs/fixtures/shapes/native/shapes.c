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

/* The constructors of the C API check the type row and the field count, not the field types, so a Point with a String
   x can be made and put in a Label; reading it back fails with the path of the bad part. */
an_term shapes_misread_nested(an_env *env, shapes_Label value) {
  an_term point[2], label[7];
  shapes_Label read;
  point[SHAPES_Point_x] = an_string(env, "a", 1);
  point[SHAPES_Point_y] = an_int(env, 2);
  label[SHAPES_Label_text] = an_string(env, value.text.data, value.text.len);
  label[SHAPES_Label_data] = an_bytes(env, value.data.data, value.data.len);
  label[SHAPES_Label_shown] = an_bool(env, value.shown);
  label[SHAPES_Label_weight] = an_float(env, value.weight);
  label[SHAPES_Label_at] = an_struct(env, SHAPES_TYPE_Point, point);
  label[SHAPES_Label_tags] = value.tags;
  label[SHAPES_Label_class] = an_int(env, value.class_);
  if (!shapes_Label_get(env, an_struct(env, SHAPES_TYPE_Label, label), &read)) return an_void(env);
  return shapes_Label_make(env, &read);
}

an_term shapes_misread_payload(an_env *env, shapes_Shape value) {
  an_term point[2], payload[2];
  (void)value;
  point[SHAPES_Point_x] = an_string(env, "a", 1);
  point[SHAPES_Point_y] = an_int(env, 2);
  payload[0] = an_struct(env, SHAPES_TYPE_Point, point);
  payload[1] = an_float(env, 1.0);
  if (!shapes_Shape_get(env, an_enum(env, SHAPES_TYPE_Shape, SHAPES_Shape_Circle, payload), &value)) return an_void(env);
  return shapes_Shape_make(env, &value);
}

SHAPES_NATIVE_MODULE(NULL)
