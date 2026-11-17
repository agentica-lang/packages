/* The module of the test of native-prebuilt.yml. Built with -DTWICE_LINKED, it takes its factor from gen/factor.c,
   which the test's `prepare` writes, as a package links a source it fetches at release time. */
#include "agentica_native.h"

#ifdef TWICE_LINKED
int twice_factor(void);
#else
static int twice_factor(void) { return 2; }
#endif

static an_term twice(an_env *env, int argc, const an_term *argv) {
  int64_t n;
  (void)argc;
  if (!an_get_int(env, argv[0], &n)) return an_badarg(env, 0);
  return an_int(env, n * twice_factor());
}

static const an_function functions[] = {
  {"twice", "(Int) -> Int", twice, AN_SHORT},
};

AN_MODULE("twice", functions, NULL)
