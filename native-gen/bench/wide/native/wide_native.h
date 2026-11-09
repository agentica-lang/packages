/* The C side of `extern module "wide"` in wide.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef WIDE_NATIVE_H
#define WIDE_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "wide_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 1
#error "wide_native.h needs version 1.1 or later of the native API (agentica_native.h)"
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
enum { WIDE_TYPE_Wide = 0 };

/* The fields of Wide, in declared order. */
enum { WIDE_Wide_a = 0, WIDE_Wide_b = 1, WIDE_Wide_c = 2, WIDE_Wide_d = 3, WIDE_Wide_e = 4, WIDE_Wide_f = 5, WIDE_Wide_g = 6, WIDE_Wide_h = 7, WIDE_Wide_i = 8, WIDE_Wide_j = 9, WIDE_Wide_k = 10, WIDE_Wide_l = 11, WIDE_Wide_m = 12, WIDE_Wide_n = 13, WIDE_Wide_o = 14, WIDE_Wide_p = 15, WIDE_Wide_q = 16, WIDE_Wide_r = 17, WIDE_Wide_s = 18, WIDE_Wide_t = 19, WIDE_Wide_u = 20, WIDE_Wide_v = 21, WIDE_Wide_w = 22, WIDE_Wide_x = 23, WIDE_Wide_y = 24, WIDE_Wide_z = 25 };

/* The structs and enums as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them
   in C locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of
   the first bad part. _make and the constructors (one per variant) make a term. */

typedef struct {
  int64_t a;
  double b;
  bool c;
  ng_str d;
  int64_t e;
  double f;
  bool g;
  ng_str h;
  int64_t i;
  double j;
  bool k;
  ng_str l;
  int64_t m;
  double n;
  bool o;
  ng_str p;
  int64_t q;
  double r;
  bool s;
  ng_str t;
  int64_t u;
  double v;
  bool w;
  ng_str x;
  int64_t y;
  double z;
} wide_Wide;
bool wide_Wide_get(an_env *env, an_term t, wide_Wide *out);
an_term wide_Wide_make(an_env *env, const wide_Wide *value);

/* The field `a`, after reading the whole struct. */
an_term wide_first(an_env *env, wide_Wide value);

an_term wide_echo(an_env *env, wide_Wide value);

an_term wide_floor(an_env *env, int64_t value);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(WIDE_NATIVE_IMPLEMENTATION) && !defined(WIDE_NATIVE_IMPLEMENTATION_DONE)
#define WIDE_NATIVE_IMPLEMENTATION_DONE
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

static bool wide_native_get_Wide(an_env *env, an_term t, wide_Wide *out, ng_fail *fail) {
  an_term x;
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 0, &x)) return ng_expected(fail, "Wide");
  if (!an_get_int(env, x, &out->a)) return ng_leaf(fail, "Int", "a");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 1, &x)) return ng_expected(fail, "Wide");
  if (!an_get_float(env, x, &out->b)) return ng_leaf(fail, "Float", "b");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 2, &x)) return ng_expected(fail, "Wide");
  if (!an_get_bool(env, x, &out->c)) return ng_leaf(fail, "Bool", "c");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 3, &x)) return ng_expected(fail, "Wide");
  if (!an_get_string(env, x, &out->d.data, &out->d.len)) return ng_leaf(fail, "String", "d");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 4, &x)) return ng_expected(fail, "Wide");
  if (!an_get_int(env, x, &out->e)) return ng_leaf(fail, "Int", "e");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 5, &x)) return ng_expected(fail, "Wide");
  if (!an_get_float(env, x, &out->f)) return ng_leaf(fail, "Float", "f");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 6, &x)) return ng_expected(fail, "Wide");
  if (!an_get_bool(env, x, &out->g)) return ng_leaf(fail, "Bool", "g");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 7, &x)) return ng_expected(fail, "Wide");
  if (!an_get_string(env, x, &out->h.data, &out->h.len)) return ng_leaf(fail, "String", "h");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 8, &x)) return ng_expected(fail, "Wide");
  if (!an_get_int(env, x, &out->i)) return ng_leaf(fail, "Int", "i");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 9, &x)) return ng_expected(fail, "Wide");
  if (!an_get_float(env, x, &out->j)) return ng_leaf(fail, "Float", "j");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 10, &x)) return ng_expected(fail, "Wide");
  if (!an_get_bool(env, x, &out->k)) return ng_leaf(fail, "Bool", "k");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 11, &x)) return ng_expected(fail, "Wide");
  if (!an_get_string(env, x, &out->l.data, &out->l.len)) return ng_leaf(fail, "String", "l");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 12, &x)) return ng_expected(fail, "Wide");
  if (!an_get_int(env, x, &out->m)) return ng_leaf(fail, "Int", "m");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 13, &x)) return ng_expected(fail, "Wide");
  if (!an_get_float(env, x, &out->n)) return ng_leaf(fail, "Float", "n");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 14, &x)) return ng_expected(fail, "Wide");
  if (!an_get_bool(env, x, &out->o)) return ng_leaf(fail, "Bool", "o");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 15, &x)) return ng_expected(fail, "Wide");
  if (!an_get_string(env, x, &out->p.data, &out->p.len)) return ng_leaf(fail, "String", "p");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 16, &x)) return ng_expected(fail, "Wide");
  if (!an_get_int(env, x, &out->q)) return ng_leaf(fail, "Int", "q");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 17, &x)) return ng_expected(fail, "Wide");
  if (!an_get_float(env, x, &out->r)) return ng_leaf(fail, "Float", "r");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 18, &x)) return ng_expected(fail, "Wide");
  if (!an_get_bool(env, x, &out->s)) return ng_leaf(fail, "Bool", "s");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 19, &x)) return ng_expected(fail, "Wide");
  if (!an_get_string(env, x, &out->t.data, &out->t.len)) return ng_leaf(fail, "String", "t");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 20, &x)) return ng_expected(fail, "Wide");
  if (!an_get_int(env, x, &out->u)) return ng_leaf(fail, "Int", "u");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 21, &x)) return ng_expected(fail, "Wide");
  if (!an_get_float(env, x, &out->v)) return ng_leaf(fail, "Float", "v");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 22, &x)) return ng_expected(fail, "Wide");
  if (!an_get_bool(env, x, &out->w)) return ng_leaf(fail, "Bool", "w");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 23, &x)) return ng_expected(fail, "Wide");
  if (!an_get_string(env, x, &out->x.data, &out->x.len)) return ng_leaf(fail, "String", "x");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 24, &x)) return ng_expected(fail, "Wide");
  if (!an_get_int(env, x, &out->y)) return ng_leaf(fail, "Int", "y");
  if (!an_get_field(env, t, WIDE_TYPE_Wide, 25, &x)) return ng_expected(fail, "Wide");
  if (!an_get_float(env, x, &out->z)) return ng_leaf(fail, "Float", "z");
  return true;
}

bool wide_Wide_get(an_env *env, an_term t, wide_Wide *out) {
  ng_fail fail;
  return wide_native_get_Wide(env, t, out, &fail) || ng_raise(env, "", "Wide", &fail);
}

an_term wide_Wide_make(an_env *env, const wide_Wide *value) {
  an_term fields[26];
  fields[0] = an_int(env, value->a);
  fields[1] = an_float(env, value->b);
  fields[2] = an_bool(env, value->c);
  fields[3] = an_string(env, value->d.data, value->d.len);
  fields[4] = an_int(env, value->e);
  fields[5] = an_float(env, value->f);
  fields[6] = an_bool(env, value->g);
  fields[7] = an_string(env, value->h.data, value->h.len);
  fields[8] = an_int(env, value->i);
  fields[9] = an_float(env, value->j);
  fields[10] = an_bool(env, value->k);
  fields[11] = an_string(env, value->l.data, value->l.len);
  fields[12] = an_int(env, value->m);
  fields[13] = an_float(env, value->n);
  fields[14] = an_bool(env, value->o);
  fields[15] = an_string(env, value->p.data, value->p.len);
  fields[16] = an_int(env, value->q);
  fields[17] = an_float(env, value->r);
  fields[18] = an_bool(env, value->s);
  fields[19] = an_string(env, value->t.data, value->t.len);
  fields[20] = an_int(env, value->u);
  fields[21] = an_float(env, value->v);
  fields[22] = an_bool(env, value->w);
  fields[23] = an_string(env, value->x.data, value->x.len);
  fields[24] = an_int(env, value->y);
  fields[25] = an_float(env, value->z);
  return an_struct(env, WIDE_TYPE_Wide, fields);
}

static an_term wide_native_first(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  wide_Wide a0;
  if (!wide_native_get_Wide(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Wide", 0);
  return wide_first(env, a0);
}

static an_term wide_native_echo(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  wide_Wide a0;
  if (!wide_native_get_Wide(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Wide", 0);
  return wide_echo(env, a0);
}

static an_term wide_native_floor(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  return wide_floor(env, a0);
}

static const an_function wide_native_functions[] = {
  {"first", "(Wide) -> Int", wide_native_first, AN_SHORT},
  {"echo", "(Wide) -> Wide", wide_native_echo, AN_SHORT},
  {"floor", "(Int) -> Int", wide_native_floor, AN_SHORT},
};

static const an_type wide_native_types[] = {
  {"Wide", AN_STRUCT, "a: Int, b: Float, c: Bool, d: String, e: Int, f: Float, g: Bool, h: String, i: Int, j: Float, k: Bool, l: String, m: Int, n: Float, o: Bool, p: String, q: Int, r: Float, s: Bool, t: String, u: Int, v: Float, w: Bool, x: String, y: Int, z: Float"},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define WIDE_NATIVE_MODULE(LOAD) AN_MODULE_TABLES("wide", wide_native_functions, 3, wide_native_types, 1, NULL, 0, LOAD)
#endif
