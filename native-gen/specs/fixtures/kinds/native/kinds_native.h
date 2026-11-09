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
   end. Every header of this version of native-gen has these two, so one file can include several. */
#ifndef NATIVE_GEN_SLICES_1
#define NATIVE_GEN_SLICES_1
typedef struct {
  const char *data;
  size_t len;
} ng_str;
typedef struct {
  const uint8_t *data;
  size_t len;
} ng_buf;
#endif

/* The rows of the type table: the TYPE of an_struct, an_enum and their getters. */
enum { KINDS_TYPE_Shape = 0, KINDS_TYPE_Point = 1 };

/* The variants of Shape, in declared order: the tag of its C value. */
typedef enum { KINDS_Shape_Dot = 0, KINDS_Shape_Circle = 1 } kinds_Shape_tag;

/* The fields of Point, in declared order. */
enum { KINDS_Point_x = 0, KINDS_Point_y = 1 };

/* The rows of the resource table: the TYPE of an_resource_new and an_get_resource. */
enum { KINDS_RESOURCE_Counter = 0 };

/* A count kept in C.

   Define it, and KINDS_Counter_FREE (a void (*)(void *state), or NULL), before KINDS_NATIVE_MODULE. */
struct kinds_Counter_state;

/* The structs and enums as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them
   in C locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of
   the first bad part. _make and the constructors (one per variant) make a term. */

typedef struct {
  int64_t x;
  int64_t y;
} kinds_Point;
bool kinds_Point_get(an_env *env, an_term t, kinds_Point *out);
an_term kinds_Point_make(an_env *env, const kinds_Point *value);

typedef struct {
  kinds_Shape_tag tag;
  union {
    struct {
      kinds_Point _0;
      double _1;
    } Circle;
  } as;
} kinds_Shape;
bool kinds_Shape_get(an_env *env, an_term t, kinds_Shape *out);

/* A new counter at `start`. */
an_term kinds_counter(an_env *env, int64_t start);

/* The counter's value after adding `step`. */
an_term kinds_bump_bang(an_env *env, an_term counter, int64_t step);

an_term kinds_describe(an_env *env, int64_t n, double x, bool flag, ng_str text, ng_buf data);

/* Whether `text` is empty.

   A second paragraph, with a * / that must not end the comment, a / * that must not open one, and a ? ?/ that must not
   be a trigraph. */
an_term kinds_empty_p(an_env *env, ng_str text);

an_term kinds_keywords(an_env *env, int64_t int_, ng_str env_, bool class_, int64_t size_t_, int64_t an_term_);

an_term kinds_nothing(an_env *env);

an_term kinds_total(an_env *env, an_term values);

/* The center of a circle; none for a dot. */
an_term kinds_corner(an_env *env, kinds_Shape shape);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(KINDS_NATIVE_IMPLEMENTATION) && !defined(KINDS_NATIVE_IMPLEMENTATION_DONE)
#define KINDS_NATIVE_IMPLEMENTATION_DONE
/* Declared with C linkage, so a module built as C++ exports it under its C name. */
#ifdef __cplusplus
extern "C" {
#endif
AN_EXPORT const an_module *agentica_native_init(const an_api *api);
#ifdef __cplusplus
}
#endif

#ifndef NATIVE_GEN_FAIL_1
#define NATIVE_GEN_FAIL_1
#include <stdio.h>
#include <string.h>

/* Where a decode failed: the path from the outer value in, and the type that was expected there. */
typedef struct {
  char path[192];
  size_t len;
  const char *expected;
} ng_fail;

static inline bool ng_expected(ng_fail *fail, const char *expected) {
  fail->path[0] = '\0';
  fail->len = 0;
  fail->expected = expected;
  return false;
}

/* Puts SEGMENT in front of the path; a path that would not fit keeps its inner part. */
static inline bool ng_at(ng_fail *fail, const char *segment) {
  size_t n = strlen(segment), dot = fail->len > 0 ? 1 : 0;
  if (n + dot + fail->len >= sizeof fail->path) return false;
  memmove(fail->path + n + dot, fail->path, fail->len + 1);
  memcpy(fail->path, segment, n);
  if (dot) fail->path[n] = '.';
  fail->len += n + dot;
  return false;
}

static inline bool ng_leaf(ng_fail *fail, const char *expected, const char *segment) {
  ng_expected(fail, expected);
  return ng_at(fail, segment);
}

/* Fails the call with "WHERE TYPE.PATH: expected X". */
static inline bool ng_raise(an_env *env, const char *where, const char *type, ng_fail *fail) {
  char message[256];
  ng_at(fail, type);
  snprintf(message, sizeof message, "%s%s: expected %s", where, fail->path, fail->expected);
  an_raise(env, message);
  return false;
}

static inline an_term ng_fail_argument(an_env *env, ng_fail *fail, const char *type, int index) {
  char where[32];
  snprintf(where, sizeof where, "argument %d: ", index + 1);
  ng_raise(env, where, type, fail);
  return an_void(env);
}
#endif

static bool kinds_native_get_Point(an_env *env, an_term t, kinds_Point *out, ng_fail *fail) {
  an_term x;
  if (!an_get_field(env, t, KINDS_TYPE_Point, 0, &x)) return ng_expected(fail, "Point");
  if (!an_get_int(env, x, &out->x)) return ng_leaf(fail, "Int", "x");
  if (!an_get_field(env, t, KINDS_TYPE_Point, 1, &x)) return ng_expected(fail, "Point");
  if (!an_get_int(env, x, &out->y)) return ng_leaf(fail, "Int", "y");
  return true;
}

bool kinds_Point_get(an_env *env, an_term t, kinds_Point *out) {
  ng_fail fail;
  return kinds_native_get_Point(env, t, out, &fail) || ng_raise(env, "", "Point", &fail);
}

an_term kinds_Point_make(an_env *env, const kinds_Point *value) {
  an_term fields[2];
  fields[0] = an_int(env, value->x);
  fields[1] = an_int(env, value->y);
  return an_struct(env, KINDS_TYPE_Point, fields);
}

static bool kinds_native_get_Shape(an_env *env, an_term t, kinds_Shape *out, ng_fail *fail) {
  uint32_t variant;
  an_term x;
  if (!an_get_variant(env, t, KINDS_TYPE_Shape, &variant)) return ng_expected(fail, "Shape");
  out->tag = (kinds_Shape_tag)variant;
  switch (out->tag) {
    case KINDS_Shape_Dot:
      return true;
    case KINDS_Shape_Circle:
      if (!an_get_payload(env, t, KINDS_TYPE_Shape, 0, &x)) return ng_expected(fail, "Shape");
      if (!kinds_native_get_Point(env, x, &out->as.Circle._0, fail)) return ng_at(fail, "Circle.0");
      if (!an_get_payload(env, t, KINDS_TYPE_Shape, 1, &x)) return ng_expected(fail, "Shape");
      if (!an_get_float(env, x, &out->as.Circle._1)) return ng_leaf(fail, "Float", "Circle.1");
      return true;
  }
  return ng_expected(fail, "Shape");
}

bool kinds_Shape_get(an_env *env, an_term t, kinds_Shape *out) {
  ng_fail fail;
  return kinds_native_get_Shape(env, t, out, &fail) || ng_raise(env, "", "Shape", &fail);
}

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
  ng_str a3;
  if (!an_get_string(env, argv[3], &a3.data, &a3.len)) return an_badarg(env, 3);
  ng_buf a4;
  if (!an_get_bytes(env, argv[4], &a4.data, &a4.len)) return an_badarg(env, 4);
  return kinds_describe(env, a0, a1, a2, a3, a4);
}

static an_term kinds_native_empty_p(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return kinds_empty_p(env, a0);
}

static an_term kinds_native_keywords(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  ng_str a1;
  if (!an_get_string(env, argv[1], &a1.data, &a1.len)) return an_badarg(env, 1);
  bool a2;
  if (!an_get_bool(env, argv[2], &a2)) return an_badarg(env, 2);
  int64_t a3;
  if (!an_get_int(env, argv[3], &a3)) return an_badarg(env, 3);
  int64_t a4;
  if (!an_get_int(env, argv[4], &a4)) return an_badarg(env, 4);
  return kinds_keywords(env, a0, a1, a2, a3, a4);
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
  ng_fail fail;
  kinds_Shape a0;
  if (!kinds_native_get_Shape(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Shape", 0);
  return kinds_corner(env, a0);
}

static const an_function kinds_native_functions[] = {
  {"counter", "(Int) -> Counter", kinds_native_counter, AN_SHORT},
  {"bump!", "(Counter, Int) -> Int", kinds_native_bump_bang, AN_SHORT},
  {"describe", "(Int, Float, Bool, String, Bytes) -> String", kinds_native_describe, AN_SHORT},
  {"empty?", "(String) -> Bool", kinds_native_empty_p, AN_SHORT},
  {"keywords", "(Int, String, Bool, Int, Int) -> String", kinds_native_keywords, AN_SHORT},
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
