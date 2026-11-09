/* The module of options.agc, on the header that native-gen makes from it: an Optional or Result argument is a struct,
   and a result is made with the constructors _some and _ok, or an_none and an_error. */
#define OPTIONS_NATIVE_IMPLEMENTATION
#include "options_native.h"

an_term options_echo_optional(an_env *env, options_optional_Point value) {
  return value.some ? options_optional_Point_some(env, value.value) : an_none(env);
}

an_term options_echo_result(an_env *env, options_result_Int value) {
  if (!value.ok) return an_error(env, value.error.data, value.error.len);
  return options_result_Int_ok(env, value.value);
}

an_term options_echo_nested(an_env *env, options_optional_result_list_Int value) {
  options_result_list_Int *result = &value.value;
  options_list_Int_builder b;
  int64_t x;
  int more;
  if (!value.some) return an_none(env);
  if (!result->ok) return options_optional_result_list_Int_some(env, an_error(env, result->error.data, result->error.len));
  options_list_Int_begin(env, &b, result->value.len);
  while ((more = options_list_Int_next(env, &result->value, &x)) == 1) options_list_Int_push(env, &b, x);
  if (more < 0) return an_void(env);
  return options_optional_result_list_Int_some(env, options_result_list_Int_ok(env, options_list_Int_end(env, &b)));
}

an_term options_first_some(an_env *env, options_list_optional_String values) {
  options_optional_String item;
  int more;
  while ((more = options_list_optional_String_next(env, &values, &item)) == 1)
    if (item.some) return options_optional_String_some(env, item.value);
  if (more < 0) return an_void(env);
  return an_none(env);
}

/* The constructors of the C API do not check what they hold, so a List[Result[Int]] can hold an ok String, and a
   List[Optional[Point]] a Point with a String x; reading the item fails with its path. */
an_term options_misread_result(an_env *env, options_list_result_Int values) {
  options_result_Int item;
  an_term bad = an_ok(env, an_string(env, "a", 1));
  if (!options_list_result_Int_open(env, an_list(env, &bad, 1), &values)) return an_void(env);
  if (options_list_result_Int_next(env, &values, &item) < 0) return an_void(env);
  return an_int(env, item.value);
}

an_term options_misread_optional(an_env *env, options_list_optional_Point values) {
  options_optional_Point item;
  an_term point[2], bad;
  point[OPTIONS_Point_x] = an_string(env, "a", 1);
  point[OPTIONS_Point_y] = an_int(env, 2);
  bad = an_some(env, an_struct(env, OPTIONS_TYPE_Point, point));
  if (!options_list_optional_Point_open(env, an_list(env, &bad, 1), &values)) return an_void(env);
  if (options_list_optional_Point_next(env, &values, &item) < 0) return an_void(env);
  return an_int(env, item.value.x);
}

OPTIONS_NATIVE_MODULE(NULL)
