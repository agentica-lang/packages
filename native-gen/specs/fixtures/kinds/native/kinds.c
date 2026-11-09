/* The module of kinds.agc, on the header that native-gen makes from it. Each function answers with what it got. */
#define KINDS_NATIVE_IMPLEMENTATION
#include "kinds_native.h"

#include <stdio.h>

struct kinds_Counter_state {
  int64_t value;
};
#define KINDS_Counter_FREE NULL

an_term kinds_counter(an_env *env, int64_t start) {
  an_term out;
  struct kinds_Counter_state *state = (struct kinds_Counter_state *)an_resource_new(env, KINDS_RESOURCE_Counter, &out);
  if (state) state->value = start;
  return out;
}

an_term kinds_bump_bang(an_env *env, an_term counter, int64_t step) {
  void *state;
  if (!an_get_resource(env, counter, KINDS_RESOURCE_Counter, &state)) return an_badarg(env, 0);
  struct kinds_Counter_state *count = (struct kinds_Counter_state *)state;
  count->value += step;
  return an_int(env, count->value);
}

an_term kinds_describe(an_env *env, int64_t n, double x, bool flag, an_str text, an_buf data) {
  char line[128];
  int len = snprintf(line, sizeof line, "%lld %.1f %s %.*s (%zu bytes, last %u)", (long long)n, x,
                     flag ? "true" : "false", (int)text.len, text.data, data.len, data.len ? data.data[data.len - 1] : 0u);
  return an_string(env, line, (size_t)len);
}

an_term kinds_empty_p(an_env *env, an_str text) { return an_bool(env, text.len == 0); }

an_term kinds_keywords(an_env *env, int64_t int_, an_str env_, bool class_) {
  char line[64];
  int len = snprintf(line, sizeof line, "%lld %.*s %d", (long long)int_, (int)env_.len, env_.data, class_);
  return an_string(env, line, (size_t)len);
}

an_term kinds_nothing(an_env *env) { return an_void(env); }

an_term kinds_total(an_env *env, an_term values) {
  an_list_cursor c;
  an_term item;
  size_t n;
  int64_t sum = 0, x;
  if (!an_list_cursor_begin(env, values, &c, &n)) return an_badarg(env, 0);
  while (an_list_next(env, &c, &item)) {
    if (!an_get_int(env, item, &x)) return an_badarg(env, 0);
    sum += x;
  }
  return an_int(env, sum);
}

/* The center of a circle, or none for a dot. */
an_term kinds_corner(an_env *env, an_term shape) {
  uint32_t variant;
  an_term center;
  if (!an_get_variant(env, shape, KINDS_TYPE_Shape, &variant)) return an_badarg(env, 0);
  if (variant == KINDS_Shape_Dot) return an_none(env);
  if (!an_get_payload(env, shape, KINDS_TYPE_Shape, 0, &center)) return an_badarg(env, 0);
  return an_some(env, center);
}

KINDS_NATIVE_MODULE(NULL)
