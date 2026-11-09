/* The C side of `extern module "kinds"` in kinds.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef KINDS_NATIVE_H
#define KINDS_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "kinds_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 2
#error "kinds_native.h needs version 1.2 or later of the native API (agentica_native.h)"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* A String or Bytes argument, borrowed for the call: copy it to keep it. String data is UTF-8 with no NUL at its
   end. Every header of native-gen has these two, so one file can include several. */
#ifndef AN_NATIVE_GEN_SLICES
#define AN_NATIVE_GEN_SLICES
typedef struct {
  const char *data;
  size_t len;
} an_str;
typedef struct {
  const uint8_t *data;
  size_t len;
} an_buf;
#endif

/* The rows of the type table: the TYPE of an_struct, an_enum and their getters. */
enum { KINDS_TYPE_Shape = 0, KINDS_TYPE_Point = 1 };

/* The variants of Shape, in declared order. */
enum { KINDS_Shape_Dot = 0, KINDS_Shape_Circle = 1 };

/* The fields of Point, in declared order. */
enum { KINDS_Point_x = 0, KINDS_Point_y = 1 };

/* The rows of the resource table: the TYPE of an_resource_new and an_get_resource. */
enum { KINDS_RESOURCE_Counter = 0 };

/* A count kept in C.

   Define it, and KINDS_Counter_FREE (a void (*)(void *state), or NULL), before KINDS_NATIVE_MODULE. */
struct kinds_Counter_state;

/* A new counter at `start`. */
an_term kinds_counter(an_env *env, int64_t start);

/* The counter's value after adding `step`. */
an_term kinds_bump_bang(an_env *env, an_term counter, int64_t step);

an_term kinds_describe(an_env *env, int64_t n, double x, bool flag, an_str text, an_buf data);

/* Whether `text` is empty.

   A second paragraph, and a * / that must not end the comment. */
an_term kinds_empty_p(an_env *env, an_str text);

an_term kinds_keywords(an_env *env, int64_t int_, an_str env_, bool class_);

an_term kinds_nothing(an_env *env);

an_term kinds_total(an_env *env, an_term values);

/* The center of a circle; none for a dot. */
an_term kinds_corner(an_env *env, an_term shape);

#ifdef __cplusplus
}
#endif

#ifdef KINDS_NATIVE_IMPLEMENTATION
/* Declared with C linkage, so a module built as C++ exports it under its C name. */
#ifdef __cplusplus
extern "C" {
#endif
AN_EXPORT const an_module *agentica_native_init(const an_api *api);
#ifdef __cplusplus
}
#endif

static an_term kinds_native_counter(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  return kinds_counter(env, a0);
}

static an_term kinds_native_bump_bang(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a1;
  if (!an_get_int(env, argv[1], &a1)) return an_badarg(env, 1);
  return kinds_bump_bang(env, argv[0], a1);
}

static an_term kinds_native_describe(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  double a1;
  if (!an_get_float(env, argv[1], &a1)) return an_badarg(env, 1);
  bool a2;
  if (!an_get_bool(env, argv[2], &a2)) return an_badarg(env, 2);
  an_str a3;
  if (!an_get_string(env, argv[3], &a3.data, &a3.len)) return an_badarg(env, 3);
  an_buf a4;
  if (!an_get_bytes(env, argv[4], &a4.data, &a4.len)) return an_badarg(env, 4);
  return kinds_describe(env, a0, a1, a2, a3, a4);
}

static an_term kinds_native_empty_p(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  an_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return kinds_empty_p(env, a0);
}

static an_term kinds_native_keywords(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  an_str a1;
  if (!an_get_string(env, argv[1], &a1.data, &a1.len)) return an_badarg(env, 1);
  bool a2;
  if (!an_get_bool(env, argv[2], &a2)) return an_badarg(env, 2);
  return kinds_keywords(env, a0, a1, a2);
}

static an_term kinds_native_nothing(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  (void)argv;
  return kinds_nothing(env);
}

static an_term kinds_native_total(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return kinds_total(env, argv[0]);
}

static an_term kinds_native_corner(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return kinds_corner(env, argv[0]);
}

static const an_function kinds_native_functions[] = {
  {"counter", "(Int) -> Counter", kinds_native_counter, AN_SHORT},
  {"bump!", "(Counter, Int) -> Int", kinds_native_bump_bang, AN_SHORT},
  {"describe", "(Int, Float, Bool, String, Bytes) -> String", kinds_native_describe, AN_SHORT},
  {"empty?", "(String) -> Bool", kinds_native_empty_p, AN_SHORT},
  {"keywords", "(Int, String, Bool) -> String", kinds_native_keywords, AN_SHORT},
  {"nothing", "() -> Void", kinds_native_nothing, AN_SHORT},
  {"total", "(List[Int]) -> Int", kinds_native_total, AN_DIRTY},
  {"corner", "(Shape) -> Optional[Point]", kinds_native_corner, AN_SHORT},
};

static const an_type kinds_native_types[] = {
  {"Shape", AN_ENUM, "Dot | Circle(Point, Float)"},
  {"Point", AN_STRUCT, "x: Int, y: Int"},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define KINDS_NATIVE_MODULE(LOAD) \
  static const an_resource_type kinds_native_resources[] = { \
    {"Counter", sizeof(struct kinds_Counter_state), KINDS_Counter_FREE}, \
  }; \
  AN_MODULE_TABLES("kinds", kinds_native_functions, 8, kinds_native_types, 2, kinds_native_resources, 1, LOAD)
#endif

#endif
