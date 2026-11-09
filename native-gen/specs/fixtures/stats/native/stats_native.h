/* The C side of `extern module "stats"` in stats.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef STATS_NATIVE_H
#define STATS_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "stats_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 1
#error "stats_native.h needs version 1.1 or later of the native API (agentica_native.h)"
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
enum { STATS_TYPE_Summary = 0, STATS_TYPE_Cell = 1 };

/* The fields of Summary, in declared order. */
enum { STATS_Summary_count = 0, STATS_Summary_min = 1, STATS_Summary_max = 2, STATS_Summary_mean = 3 };

/* The variants of Cell, in declared order: the tag of its C value. */
typedef enum { STATS_Cell_Empty = 0, STATS_Cell_Number = 1, STATS_Cell_Text = 2 } stats_Cell_tag;

/* The structs and enums as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them
   in C locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of
   the first bad part. A function whose signature does not reach the type reads none ("Point: expected Point").
   _make and the constructors (one per variant) make a term. */

typedef struct {
  int64_t count;
  double min;
  double max;
  double mean;
} stats_Summary;
an_term stats_Summary_make(an_env *env, const stats_Summary *value);

typedef struct {
  stats_Cell_tag tag;
  union {
    struct {
      double _0;
    } Number;
    struct {
      ng_str _0;
    } Text;
  } as;
} stats_Cell;
an_term stats_Cell_make(an_env *env, const stats_Cell *value);
an_term stats_Cell_Empty(an_env *env);
an_term stats_Cell_Number(an_env *env, double _0);
an_term stats_Cell_Text(an_env *env, ng_str _0);

/* The Lists, Maps, Optionals and Results. A List or Map that is read is a cursor: _next gives 1 for an item, 0 at
   the end, and -1 when the item does not decode: the call has then failed with the path of the item in its own
   List or Map (an item of a List or Map read from another has the path from the inner one, `List[Float].1`), and
   every later _next gives -1 too, as after a failed _open. A builder makes one: _begin, then _push (_put for a
   Map), then _end. Cursors and builders hold terms: keep them in C locals, for this call only. An Optional or
   Result that is read is a struct, whose value is zero when there is none and whose error is borrowed as a String
   argument is; _get reads one held as a term. One that is made has _some or _ok (an_none and an_error make the
   others). */

typedef struct {
  an_term term;
  an_list_cursor cursor;
  size_t len;
  size_t at;
  bool failed;
  int argument; /* 1 + the index of the argument of the call it was opened for, or 0 (_open) */
} stats_list_Float;
bool stats_list_Float_open(an_env *env, an_term t, stats_list_Float *out);
int stats_list_Float_next(an_env *env, stats_list_Float *list, double *out);

an_term stats_optional_Summary_some(an_env *env, stats_Summary value);

typedef struct {
  an_term map;
} stats_map_String_Cell_builder;
void stats_map_String_Cell_begin(an_env *env, stats_map_String_Cell_builder *b);
void stats_map_String_Cell_put(an_env *env, stats_map_String_Cell_builder *b, ng_str key, stats_Cell value);
an_term stats_map_String_Cell_end(an_env *env, stats_map_String_Cell_builder *b);

typedef struct {
  an_list_builder builder;
} stats_list_map_String_Cell_builder;
void stats_list_map_String_Cell_begin(an_env *env, stats_list_map_String_Cell_builder *b, size_t hint);
void stats_list_map_String_Cell_push(an_env *env, stats_list_map_String_Cell_builder *b, an_term value);
an_term stats_list_map_String_Cell_end(an_env *env, stats_list_map_String_Cell_builder *b);

an_term stats_result_list_map_String_Cell_ok(an_env *env, an_term value);

/* The count, smallest, largest and mean of the values; none for no values. */
an_term stats_summary(an_env *env, stats_list_Float values);

/* The lines of a CSV text after its header, as maps from the header's names to typed cells. */
an_term stats_rows(an_env *env, ng_str text);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(STATS_NATIVE_IMPLEMENTATION) && !defined(STATS_NATIVE_IMPLEMENTATION_DONE)
#define STATS_NATIVE_IMPLEMENTATION_DONE
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
  bool cut;
  const char *expected;
} ng_fail;

static inline bool ng_expected(ng_fail *fail, const char *expected) {
  fail->path[0] = '\0';
  fail->len = 0;
  fail->cut = false;
  fail->expected = expected;
  return false;
}

/* Puts SEGMENT in front of the path. The first one that does not fit becomes "..." and ends the path, which
   keeps its inner part. */
static inline bool ng_at(ng_fail *fail, const char *segment) {
  size_t n = strlen(segment), dot = fail->len > 0 ? 1 : 0;
  if (fail->cut) return false;
  if (n + dot + fail->len >= sizeof fail->path) {
    fail->cut = true;
    segment = "...";
    n = 3;
    if (n + dot + fail->len >= sizeof fail->path) return false;
  }
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

/* Fails the call at item INDEX (and PART of it, "key" or "value", or NULL) of a List or Map, with the
   "argument N: " prefix when ARGUMENT (1 + its index) is not 0; -1 for _next. */
static inline int ng_fail_item(an_env *env, ng_fail *fail, const char *type, int argument, size_t index,
                               const char *part) {
  char segment[48];
  char where[32] = "";
  if (part)
    snprintf(segment, sizeof segment, "%zu.%s", index, part);
  else
    snprintf(segment, sizeof segment, "%zu", index);
  if (argument) snprintf(where, sizeof where, "argument %d: ", argument);
  ng_at(fail, segment);
  ng_raise(env, where, type, fail);
  return -1;
}

static inline an_term ng_fail_argument(an_env *env, ng_fail *fail, const char *type, int index) {
  char where[32];
  snprintf(where, sizeof where, "argument %d: ", index + 1);
  ng_raise(env, where, type, fail);
  return an_void(env);
}
#endif

an_term stats_Summary_make(an_env *env, const stats_Summary *value) {
  an_term fields[4];
  fields[0] = an_int(env, value->count);
  fields[1] = an_float(env, value->min);
  fields[2] = an_float(env, value->max);
  fields[3] = an_float(env, value->mean);
  return an_struct(env, STATS_TYPE_Summary, fields);
}

an_term stats_Cell_make(an_env *env, const stats_Cell *value) {
  switch (value->tag) {
    case STATS_Cell_Empty:
      return stats_Cell_Empty(env);
    case STATS_Cell_Number:
      return stats_Cell_Number(env, value->as.Number._0);
    case STATS_Cell_Text:
      return stats_Cell_Text(env, value->as.Text._0);
  }
  return an_raise(env, "Cell: the tag is not one of its variants");
}

an_term stats_Cell_Empty(an_env *env) {
  return an_enum(env, STATS_TYPE_Cell, STATS_Cell_Empty, NULL);
}

an_term stats_Cell_Number(an_env *env, double _0) {
  an_term payload[1];
  payload[0] = an_float(env, _0);
  return an_enum(env, STATS_TYPE_Cell, STATS_Cell_Number, payload);
}

an_term stats_Cell_Text(an_env *env, ng_str _0) {
  an_term payload[1];
  payload[0] = an_string(env, _0.data, _0.len);
  return an_enum(env, STATS_TYPE_Cell, STATS_Cell_Text, payload);
}

static bool stats_native_item_Float(an_env *env, an_term x, double *out, ng_fail *fail) {
  return an_get_float(env, x, &(*out)) || ng_expected(fail, "Float");
}

static bool stats_native_open_list_Float(an_env *env, an_term t, stats_list_Float *out, ng_fail *fail) {
  memset(out, 0, sizeof *out);
  out->term = t;
  if (an_list_cursor_begin(env, t, &out->cursor, &out->len)) return true;
  out->failed = true;
  return ng_expected(fail, "List[Float]");
}

bool stats_list_Float_open(an_env *env, an_term t, stats_list_Float *out) {
  ng_fail fail;
  return stats_native_open_list_Float(env, t, out, &fail) || ng_raise(env, "", "List[Float]", &fail);
}

int stats_list_Float_next(an_env *env, stats_list_Float *list, double *out) {
  an_term x;
  ng_fail fail;
  size_t at = list->at;
  if (list->failed) return -1;
  if (!an_list_next(env, &list->cursor, &x)) return 0;
  list->at++;
  if (stats_native_item_Float(env, x, out, &fail)) return 1;
  list->failed = true;
  return ng_fail_item(env, &fail, "List[Float]", list->argument, at, NULL);
}

an_term stats_optional_Summary_some(an_env *env, stats_Summary value) {
  return an_some(env, stats_Summary_make(env, &value));
}

void stats_map_String_Cell_begin(an_env *env, stats_map_String_Cell_builder *b) { b->map = an_map_from(env, NULL, NULL, 0); }

void stats_map_String_Cell_put(an_env *env, stats_map_String_Cell_builder *b, ng_str key, stats_Cell value) {
  b->map = an_map_put(env, b->map, an_string(env, key.data, key.len), stats_Cell_make(env, &value));
}

an_term stats_map_String_Cell_end(an_env *env, stats_map_String_Cell_builder *b) {
  (void)env;
  return b->map;
}

void stats_list_map_String_Cell_begin(an_env *env, stats_list_map_String_Cell_builder *b, size_t hint) { an_list_begin(env, &b->builder, hint); }

void stats_list_map_String_Cell_push(an_env *env, stats_list_map_String_Cell_builder *b, an_term value) {
  an_list_push(env, &b->builder, value);
}

an_term stats_list_map_String_Cell_end(an_env *env, stats_list_map_String_Cell_builder *b) { return an_list_end(env, &b->builder); }

an_term stats_result_list_map_String_Cell_ok(an_env *env, an_term value) {
  return an_ok(env, value);
}

static an_term stats_native_summary(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  stats_list_Float a0;
  if (!stats_native_open_list_Float(env, argv[0], &a0, &fail))
    return ng_fail_argument(env, &fail, "List[Float]", 0);
  a0.argument = 1;
  return stats_summary(env, a0);
}

static an_term stats_native_rows(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return stats_rows(env, a0);
}

static const an_function stats_native_functions[] = {
  {"summary", "(List[Float]) -> Optional[Summary]", stats_native_summary, AN_SHORT},
  {"rows", "(String) -> Result[List[Map[String, Cell]]]", stats_native_rows, AN_SHORT},
};

static const an_type stats_native_types[] = {
  {"Summary", AN_STRUCT, "count: Int, min: Float, max: Float, mean: Float"},
  {"Cell", AN_ENUM, "Empty | Number(Float) | Text(String)"},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define STATS_NATIVE_MODULE(LOAD) AN_MODULE_TABLES("stats", stats_native_functions, 2, stats_native_types, 2, NULL, 0, LOAD)
#endif
