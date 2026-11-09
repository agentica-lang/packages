/* The module of shapes.agc: each echo reads its argument into the C value of the header and makes it again. */
#define SHAPES_NATIVE_IMPLEMENTATION
#include "shapes_native.h"

an_term shapes_echo_point(an_env *env, shapes_Point value) { return shapes_Point_make(env, &value); }

an_term shapes_echo_label(an_env *env, shapes_Label value) { return shapes_Label_make(env, &value); }

an_term shapes_misread(an_env *env, shapes_Point value, an_term values) {
  if (!shapes_Point_get(env, values, &value)) return an_void(env);
  return shapes_Point_make(env, &value);
}

/* The constructors of the C API check the type row and the field count, not the field types, so a Point with a String
   x can be made and put in a Label; reading it back fails with the path of the bad part. */
static an_term bad_label(an_env *env, const shapes_Label *value) {
  an_term point[2], label[7];
  point[SHAPES_Point_x] = an_string(env, "a", 1);
  point[SHAPES_Point_y] = an_int(env, 2);
  label[SHAPES_Label_text] = an_string(env, value->text.data, value->text.len);
  label[SHAPES_Label_data] = an_bytes(env, value->data.data, value->data.len);
  label[SHAPES_Label_shown] = an_bool(env, value->shown);
  label[SHAPES_Label_weight] = an_float(env, value->weight);
  label[SHAPES_Label_at] = an_struct(env, SHAPES_TYPE_Point, point);
  label[SHAPES_Label_tags] = value->tags;
  label[SHAPES_Label_class] = an_int(env, value->class_);
  return an_struct(env, SHAPES_TYPE_Label, label);
}

an_term shapes_misread_nested(an_env *env, shapes_Label value) {
  shapes_Label read;
  if (!shapes_Label_get(env, bad_label(env, &value), &read)) return an_void(env);
  return shapes_Label_make(env, &read);
}

an_term shapes_bad_label(an_env *env, shapes_Label value) { return bad_label(env, &value); }

SHAPES_NATIVE_MODULE(NULL)
