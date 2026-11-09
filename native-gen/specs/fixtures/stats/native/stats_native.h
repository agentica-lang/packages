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

/* The variants of Cell, in declared order. */
enum { STATS_Cell_Empty = 0, STATS_Cell_Number = 1, STATS_Cell_Text = 2 };

/* The structs as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them in C
   locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of the
   first bad part. _make makes a term. */

typedef struct {
  int64_t count;
  double min;
  double max;
  double mean;
} stats_Summary;
an_term stats_Summary_make(an_env *env, const stats_Summary *value);

/* The count, smallest, largest and mean of the values; none for no values. */
an_term stats_summary(an_env *env, an_term values);

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

an_term stats_Summary_make(an_env *env, const stats_Summary *value) {
  an_term fields[4];
  fields[0] = an_int(env, value->count);
  fields[1] = an_float(env, value->min);
  fields[2] = an_float(env, value->max);
  fields[3] = an_float(env, value->mean);
  return an_struct(env, STATS_TYPE_Summary, fields);
}

static an_term stats_native_summary(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return stats_summary(env, argv[0]);
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
