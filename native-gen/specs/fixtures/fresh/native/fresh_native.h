/* The C side of `extern module "fresh"` in fresh.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef FRESH_NATIVE_H
#define FRESH_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "fresh_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 5
#error "fresh_native.h needs version 1.5 or later of the native API (agentica_native.h)"
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

/* The rows of the resource table: the TYPE of an_resource_new and an_get_resource. */
enum { FRESH_RESOURCE_Handle = 0 };

/* Define it, and FRESH_Handle_FREE (a void (*)(void *state), or NULL), before FRESH_NATIVE_MODULE.
   A parameter of this type is its state. _new makes one, with zeroed state. _get gives the state of a term
   that is an argument of this call, and NULL for any other, one made by _new in the same call included. The
   state is valid until the call returns: do not keep the pointer. */
struct fresh_Handle_state;
static inline struct fresh_Handle_state *fresh_Handle_new(an_env *env, an_term *out) {
  return (struct fresh_Handle_state *)an_resource_new(env, FRESH_RESOURCE_Handle, out);
}
static inline struct fresh_Handle_state *fresh_Handle_get(an_env *env, an_term t) {
  void *state;
  return an_get_resource(env, t, FRESH_RESOURCE_Handle, &state) ? (struct fresh_Handle_state *)state : NULL;
}

/* The Lists, Maps, Optionals and Results. A List or Map that is read is a cursor: _next gives 1 for an item, 0 at
   the end, and -1 when the item does not decode: the call has then failed with the path of the item in its own
   List or Map (an item of a List or Map read from another has the path from the inner one, `List[Float].1`),
   after `argument N: ` when the cursor came from an argument (`argument` is then N; it is 0 after _open), and
   every later _next gives -1 too, as after a failed _open. A builder makes one: _begin, then _push (_put for a
   Map), then _end. Cursors and builders hold terms: keep them in C locals, for this call only. An Optional or
   Result that is read is a struct, whose value is zero when there is none and whose error is borrowed as a String
   argument is; _get reads one held as a term. One that is made has _some or _ok (an_none and an_error make the
   others). */

an_term fresh_result_Handle_ok(an_env *env, an_term value);

/* A handle that owns all its memory. */
an_term fresh_make(an_env *env, int64_t size);

an_term fresh_small(an_env *env, int64_t size);

/* A handle made from another one, which it keeps alive. */
an_term fresh_view(an_env *env, struct fresh_Handle_state *handle);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(FRESH_NATIVE_IMPLEMENTATION) && !defined(FRESH_NATIVE_IMPLEMENTATION_DONE)
#define FRESH_NATIVE_IMPLEMENTATION_DONE
/* Declared with C linkage, so a module built as C++ exports it under its C name. */
#ifdef __cplusplus
extern "C" {
#endif
AN_EXPORT const an_module *agentica_native_init(const an_api *api);
#ifdef __cplusplus
}
#endif

an_term fresh_result_Handle_ok(an_env *env, an_term value) {
  return an_ok(env, value);
}

static an_term fresh_native_make(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  return fresh_make(env, a0);
}

static an_term fresh_native_small(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  return fresh_small(env, a0);
}

static an_term fresh_native_view(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct fresh_Handle_state *a0 = fresh_Handle_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  return fresh_view(env, a0);
}

static const an_function fresh_native_functions[] = {
  {"make", "(Int) -> Result[Handle]", fresh_native_make, AN_DIRTY | AN_FRESH},
  {"small", "(Int) -> Handle", fresh_native_small, AN_SHORT | AN_FRESH},
  {"view", "(Handle) -> Handle", fresh_native_view, AN_SHORT},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define FRESH_NATIVE_MODULE(LOAD) \
  static const an_resource_type fresh_native_resources[] = { \
    {"Handle", sizeof(struct fresh_Handle_state), FRESH_Handle_FREE}, \
  }; \
  AN_MODULE_TABLES("fresh", fresh_native_functions, 3, NULL, 0, fresh_native_resources, 1, LOAD)
#endif
