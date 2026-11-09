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
  struct kinds_Counter_state *state = kinds_Counter_new(env, &out);
  if (state) state->value = start;
  return out;
}

an_term kinds_bump_bang(an_env *env, struct kinds_Counter_state *counter, int64_t step) {
  counter->value += step;
  return an_int(env, counter->value);
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

an_term kinds_total(an_env *env, kinds_list_Int values) {
  int64_t sum = 0, x;
  int more;
  while ((more = kinds_list_Int_next(env, &values, &x)) == 1) sum += x;
  if (more < 0) return an_void(env);
  return an_int(env, sum);
}

/* The center of a circle, or none for a dot. */
an_term kinds_corner(an_env *env, kinds_Shape shape) {
  switch (shape.tag) {
    case KINDS_Shape_Dot:
      return an_none(env);
    case KINDS_Shape_Circle:
      return kinds_optional_Point_some(env, shape.as.Circle._0);
  }
  return an_raise(env, "not a shape");
}

/* How many of the results are ok. */
an_term kinds_oks(an_env *env, kinds_list_result_Void results) {
  int64_t count = 0;
  kinds_result_Void x;
  int more;
  while ((more = kinds_list_result_Void_next(env, &results, &x)) == 1) count += x.ok;
  if (more < 0) return an_void(env);
  return an_int(env, count);
}

KINDS_NATIVE_MODULE(NULL)
