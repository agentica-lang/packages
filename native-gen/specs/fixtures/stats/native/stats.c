/* The native module of agentica's examples/native_module, written on the header that native-gen makes from stats.agc:
   `summary` gives a struct in an Optional, and `rows` reads a small CSV text into typed rows in one call. */
#define STATS_NATIVE_IMPLEMENTATION
#include "stats_native.h"

#include <stdlib.h>
#include <string.h>

/* The most columns of a CSV text. */
#define MAX_COLUMNS 32
#define ROW_ERROR "a row has another number of cells"

an_term stats_summary(an_env *env, an_term values) {
  an_list_cursor c;
  an_term item;
  size_t n;
  double min = 0, max = 0, total = 0, x;
  if (!an_list_cursor_begin(env, values, &c, &n)) return an_badarg(env, 0);
  if (n == 0) return an_none(env);
  for (size_t k = 0; an_list_next(env, &c, &item); k++) {
    if (!an_get_float(env, item, &x)) return an_badarg(env, 0);
    min = k == 0 || x < min ? x : min;
    max = k == 0 || x > max ? x : max;
    total += x;
  }
  an_term fields[4];
  fields[STATS_Summary_count] = an_int(env, (int64_t)n);
  fields[STATS_Summary_min] = an_float(env, min);
  fields[STATS_Summary_max] = an_float(env, max);
  fields[STATS_Summary_mean] = an_float(env, total / (double)n);
  return an_some(env, an_struct(env, STATS_TYPE_Summary, fields));
}

/* Empty for no text, a Number when the whole text is a number, else its Text. A number is what strtod reads: leading
   spaces, a hex number, inf and nan too, with the decimal point of the C locale, which a program that never calls
   setlocale keeps at "." */
static an_term cell(an_env *env, const char *text, size_t len) {
  char number[64], *end;
  if (len == 0) return an_enum(env, STATS_TYPE_Cell, STATS_Cell_Empty, NULL);
  if (len < sizeof number) {
    memcpy(number, text, len);
    number[len] = '\0';
    double x = strtod(number, &end);
    an_term value = an_float(env, x);
    if (end == number + len) return an_enum(env, STATS_TYPE_Cell, STATS_Cell_Number, &value);
  }
  an_term value = an_string(env, text, len);
  return an_enum(env, STATS_TYPE_Cell, STATS_Cell_Text, &value);
}

/* The lines after the header, each a Map from the header's names to its cells; a line with another number of cells
   is an error. A comma always separates: there is no quoting. */
an_term stats_rows(an_env *env, ng_str text) {
  size_t columns = 0;
  an_term names[MAX_COLUMNS], cells[MAX_COLUMNS];
  an_list_builder b;
  an_list_begin(env, &b, 0);
  const char *at = text.data, *end = text.data + text.len;
  for (size_t line = 0; at < end; line++) {
    const char *stop = (const char *)memchr(at, '\n', (size_t)(end - at));
    if (!stop) stop = end;
    size_t n = 0;
    for (const char *field = at;;) {
      const char *comma = (const char *)memchr(field, ',', (size_t)(stop - field));
      const char *cut = comma ? comma : stop;
      if (n == MAX_COLUMNS) return an_error(env, "too many columns", sizeof "too many columns" - 1);
      if (line == 0)
        names[n++] = an_string(env, field, (size_t)(cut - field));
      else
        cells[n++] = cell(env, field, (size_t)(cut - field));
      if (!comma) break;
      field = comma + 1;
    }
    if (line == 0)
      columns = n;
    else if (n != columns)
      return an_error(env, ROW_ERROR, sizeof ROW_ERROR - 1);
    else
      an_list_push(env, &b, an_map_from(env, names, cells, n));
    at = stop < end ? stop + 1 : end;
  }
  return an_ok(env, an_list_end(env, &b));
}

STATS_NATIVE_MODULE(NULL)
