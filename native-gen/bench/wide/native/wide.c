/* The module of wide.agc: the codecs of a struct of 26 fields. */
#define WIDE_NATIVE_IMPLEMENTATION
#include "wide_native.h"

an_term wide_first(an_env *env, wide_Wide value) { return an_int(env, value.a); }

an_term wide_echo(an_env *env, wide_Wide value) { return wide_Wide_make(env, &value); }

an_term wide_floor(an_env *env, int64_t value) { return an_int(env, value); }

WIDE_NATIVE_MODULE(NULL)
