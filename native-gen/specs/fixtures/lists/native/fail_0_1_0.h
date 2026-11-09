/* The shared helpers of a header of native-gen 0.1.0 (its NATIVE_GEN_FAIL_1 block, copied as it is), included before
   lists_native.h: the newer header keeps this copy and still brings its own NATIVE_GEN_FAIL_ITEM_2 block. */
#include "agentica_native.h"

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

/* Fails the call at item INDEX (and PART of it, "key" or "value", or NULL) of a List or Map; -1 for _next. */
static inline int ng_fail_item(an_env *env, ng_fail *fail, const char *type, size_t index, const char *part) {
  char segment[48];
  if (part)
    snprintf(segment, sizeof segment, "%zu.%s", index, part);
  else
    snprintf(segment, sizeof segment, "%zu", index);
  ng_at(fail, segment);
  ng_raise(env, "", type, fail);
  return -1;
}

static inline an_term ng_fail_argument(an_env *env, ng_fail *fail, const char *type, int index) {
  char where[32];
  snprintf(where, sizeof where, "argument %d: ", index + 1);
  ng_raise(env, where, type, fail);
  return an_void(env);
}
#endif
