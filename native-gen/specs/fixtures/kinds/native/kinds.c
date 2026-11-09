/* The module of kinds.agc, on the header that native-gen makes from it. Each function answers with what it got. The
   header is included first without the switch, as another file of the module would, then with it, then once more:
   the implementation comes once, after the switch. */
#include "kinds_native.h"
#define KINDS_NATIVE_IMPLEMENTATION
#include "kinds_native.h"
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

an_term kinds_describe(an_env *env, int64_t n, double x, bool flag, ng_str text, ng_buf data) {
  char line[128];
  int len = snprintf(line, sizeof line, "%lld %.1f %s %.*s (%zu bytes, last %u)", (long long)n, x,
                     flag ? "true" : "false", (int)text.len, text.data, data.len, data.len ? data.data[data.len - 1] : 0u);
  return an_string(env, line, (size_t)len);
}

an_term kinds_empty_p(an_env *env, ng_str text) { return an_bool(env, text.len == 0); }

an_term kinds_keywords(an_env *env, int64_t int_, ng_str env_, bool class_, int64_t size_t_, int64_t an_term_) {
  char line[64];
  int len = snprintf(line, sizeof line, "%lld %.*s %d %lld %lld", (long long)int_, (int)env_.len, env_.data, class_,
                     (long long)size_t_, (long long)an_term_);
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
an_term kinds_corner(an_env *env, kinds_Shape shape) {
  switch (shape.tag) {
    case KINDS_Shape_Dot:
      return an_none(env);
    case KINDS_Shape_Circle:
      return an_some(env, kinds_Point_make(env, &shape.as.Circle._0));
  }
  return an_raise(env, "not a shape");
}

KINDS_NATIVE_MODULE(NULL)
