/* The C side of `extern module "image"` in image.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef IMAGE_NATIVE_H
#define IMAGE_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "image_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 2
#error "image_native.h needs version 1.2 or later of the native API (agentica_native.h)"
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
enum { IMAGE_TYPE_Format = 0 };

/* The variants of Format, in declared order: the tag of its C value. */
typedef enum { IMAGE_Format_U8 = 0, IMAGE_Format_I8 = 1, IMAGE_Format_U16 = 2, IMAGE_Format_I16 = 3, IMAGE_Format_U32 = 4, IMAGE_Format_I32 = 5, IMAGE_Format_F32 = 6, IMAGE_Format_F64 = 7, IMAGE_Format_Complex = 8 } image_Format_tag;

/* The rows of the resource table: the TYPE of an_resource_new and an_get_resource. */
enum { IMAGE_RESOURCE_Image = 0 };

/* Define it, and IMAGE_Image_FREE (a void (*)(void *state), or NULL), before IMAGE_NATIVE_MODULE.
   A parameter of this type is its state. _new makes one, with zeroed state. _get gives the state of a term
   that is an argument of this call, and NULL for any other, one made by _new in the same call included. The
   state is valid until the call returns: do not keep the pointer. */
struct image_Image_state;
static inline struct image_Image_state *image_Image_new(an_env *env, an_term *out) {
  return (struct image_Image_state *)an_resource_new(env, IMAGE_RESOURCE_Image, out);
}
static inline struct image_Image_state *image_Image_get(an_env *env, an_term t) {
  void *state;
  return an_get_resource(env, t, IMAGE_RESOURCE_Image, &state) ? (struct image_Image_state *)state : NULL;
}

/* The structs and enums as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them
   in C locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of
   the first bad part. A function whose signature does not reach the type reads none ("Point: expected Point").
   _make and the constructors (one per variant) make a term. */

typedef struct {
  image_Format_tag tag;
} image_Format;
bool image_Format_get(an_env *env, an_term t, image_Format *out);
an_term image_Format_make(an_env *env, const image_Format *value);
an_term image_Format_U8(an_env *env);
an_term image_Format_I8(an_env *env);
an_term image_Format_U16(an_env *env);
an_term image_Format_I16(an_env *env);
an_term image_Format_U32(an_env *env);
an_term image_Format_I32(an_env *env);
an_term image_Format_F32(an_env *env);
an_term image_Format_F64(an_env *env);
an_term image_Format_Complex(an_env *env);

/* The Lists, Maps, Optionals and Results. A List or Map that is read is a cursor: _next gives 1 for an item, 0 at
   the end, and -1 when the item does not decode: the call has then failed with the path of the item in its own
   List or Map (an item of a List or Map read from another has the path from the inner one, `List[Float].1`),
   after `argument N: ` when the cursor came from an argument (`argument` is then N; it is 0 after _open), and
   every later _next gives -1 too, as after a failed _open. A builder makes one: _begin, then _push (_put for a
   Map), then _end. Cursors and builders hold terms: keep them in C locals, for this call only. An Optional or
   Result that is read is a struct, whose value is zero when there is none and whose error is borrowed as a String
   argument is; _get reads one held as a term. One that is made has _some or _ok (an_none and an_error make the
   others). */

an_term image_result_Image_ok(an_env *env, an_term value);

an_term image_result_Void_ok(an_env *env, an_term value);

an_term image_result_Bytes_ok(an_env *env, ng_buf value);

/* Decodes the file at `path`; the format is found from its contents. */
an_term image_load(an_env *env, ng_str path);

/* Decodes an encoded image held in memory. */
an_term image_from_bytes(an_env *env, ng_buf data);

/* An image from interleaved pixels: `width * height * bands` values of `format`, in the byte order of this machine. */
an_term image_from_pixels(an_env *env, ng_buf pixels, int64_t width, int64_t height, int64_t bands, image_Format format);

/* Writes the image to `path`; the extension picks the encoder (`.png`, `.jpg[Q=90]`). */
an_term image_save(an_env *env, struct image_Image_state *image, ng_str path);

/* Encodes the image as `format`, a suffix without the dot and with the options of libvips (`png`, `jpg[Q=90]`). */
an_term image_to_bytes(an_env *env, struct image_Image_state *image, ng_str format);

/* The pixels, interleaved, in the format of the image and the byte order of this machine. */
an_term image_to_pixels(an_env *env, struct image_Image_state *image);

an_term image_width(an_env *env, struct image_Image_state *image);

an_term image_height(an_env *env, struct image_Image_state *image);

an_term image_bands(an_env *env, struct image_Image_state *image);

an_term image_pixel_format(an_env *env, struct image_Image_state *image);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(IMAGE_NATIVE_IMPLEMENTATION) && !defined(IMAGE_NATIVE_IMPLEMENTATION_DONE)
#define IMAGE_NATIVE_IMPLEMENTATION_DONE
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

/* A block of its own: the block above is the same in every header since 0.1.0, so a file that includes an older
   header first keeps that copy, and this one still comes in. */
#ifndef NATIVE_GEN_FAIL_ITEM_2
#define NATIVE_GEN_FAIL_ITEM_2
/* As ng_fail_item, with the "argument N: " prefix when ARGUMENT (1 + the index of the argument the cursor was
   opened for) is not 0. */
static inline int ng_fail_cursor_item(an_env *env, ng_fail *fail, const char *type, int argument, size_t index,
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
#endif

static bool image_native_get_Format(an_env *env, an_term t, image_Format *out, ng_fail *fail) {
  uint32_t variant;
  if (!an_get_variant(env, t, IMAGE_TYPE_Format, &variant)) return ng_expected(fail, "Format");
  out->tag = (image_Format_tag)variant;
  switch (out->tag) {
    case IMAGE_Format_U8:
      return true;
    case IMAGE_Format_I8:
      return true;
    case IMAGE_Format_U16:
      return true;
    case IMAGE_Format_I16:
      return true;
    case IMAGE_Format_U32:
      return true;
    case IMAGE_Format_I32:
      return true;
    case IMAGE_Format_F32:
      return true;
    case IMAGE_Format_F64:
      return true;
    case IMAGE_Format_Complex:
      return true;
  }
  return ng_expected(fail, "Format");
}

bool image_Format_get(an_env *env, an_term t, image_Format *out) {
  ng_fail fail;
  return image_native_get_Format(env, t, out, &fail) || ng_raise(env, "", "Format", &fail);
}

an_term image_Format_make(an_env *env, const image_Format *value) {
  switch (value->tag) {
    case IMAGE_Format_U8:
      return image_Format_U8(env);
    case IMAGE_Format_I8:
      return image_Format_I8(env);
    case IMAGE_Format_U16:
      return image_Format_U16(env);
    case IMAGE_Format_I16:
      return image_Format_I16(env);
    case IMAGE_Format_U32:
      return image_Format_U32(env);
    case IMAGE_Format_I32:
      return image_Format_I32(env);
    case IMAGE_Format_F32:
      return image_Format_F32(env);
    case IMAGE_Format_F64:
      return image_Format_F64(env);
    case IMAGE_Format_Complex:
      return image_Format_Complex(env);
  }
  return an_raise(env, "Format: the tag is not one of its variants");
}

an_term image_Format_U8(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_U8, NULL);
}

an_term image_Format_I8(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_I8, NULL);
}

an_term image_Format_U16(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_U16, NULL);
}

an_term image_Format_I16(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_I16, NULL);
}

an_term image_Format_U32(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_U32, NULL);
}

an_term image_Format_I32(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_I32, NULL);
}

an_term image_Format_F32(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_F32, NULL);
}

an_term image_Format_F64(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_F64, NULL);
}

an_term image_Format_Complex(an_env *env) {
  return an_enum(env, IMAGE_TYPE_Format, IMAGE_Format_Complex, NULL);
}

an_term image_result_Image_ok(an_env *env, an_term value) {
  return an_ok(env, value);
}

an_term image_result_Void_ok(an_env *env, an_term value) {
  return an_ok(env, value);
}

an_term image_result_Bytes_ok(an_env *env, ng_buf value) {
  return an_ok(env, an_bytes(env, value.data, value.len));
}

static an_term image_native_load(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_str a0;
  if (!an_get_string(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return image_load(env, a0);
}

static an_term image_native_from_bytes(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_buf a0;
  if (!an_get_bytes(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  return image_from_bytes(env, a0);
}

static an_term image_native_from_pixels(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  ng_buf a0;
  if (!an_get_bytes(env, argv[0], &a0.data, &a0.len)) return an_badarg(env, 0);
  int64_t a1;
  if (!an_get_int(env, argv[1], &a1)) return an_badarg(env, 1);
  int64_t a2;
  if (!an_get_int(env, argv[2], &a2)) return an_badarg(env, 2);
  int64_t a3;
  if (!an_get_int(env, argv[3], &a3)) return an_badarg(env, 3);
  image_Format a4;
  if (!image_native_get_Format(env, argv[4], &a4, &fail)) return ng_fail_argument(env, &fail, "Format", 4);
  return image_from_pixels(env, a0, a1, a2, a3, a4);
}

static an_term image_native_save(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct image_Image_state *a0 = image_Image_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  ng_str a1;
  if (!an_get_string(env, argv[1], &a1.data, &a1.len)) return an_badarg(env, 1);
  return image_save(env, a0, a1);
}

static an_term image_native_to_bytes(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct image_Image_state *a0 = image_Image_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  ng_str a1;
  if (!an_get_string(env, argv[1], &a1.data, &a1.len)) return an_badarg(env, 1);
  return image_to_bytes(env, a0, a1);
}

static an_term image_native_to_pixels(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct image_Image_state *a0 = image_Image_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  return image_to_pixels(env, a0);
}

static an_term image_native_width(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct image_Image_state *a0 = image_Image_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  return image_width(env, a0);
}

static an_term image_native_height(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct image_Image_state *a0 = image_Image_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  return image_height(env, a0);
}

static an_term image_native_bands(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct image_Image_state *a0 = image_Image_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  return image_bands(env, a0);
}

static an_term image_native_pixel_format(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  struct image_Image_state *a0 = image_Image_get(env, argv[0]);
  if (!a0) return an_badarg(env, 0);
  return image_pixel_format(env, a0);
}

static const an_function image_native_functions[] = {
  {"load", "(String) -> Result[Image]", image_native_load, AN_DIRTY},
  {"from_bytes", "(Bytes) -> Result[Image]", image_native_from_bytes, AN_DIRTY},
  {"from_pixels", "(Bytes, Int, Int, Int, Format) -> Result[Image]", image_native_from_pixels, AN_DIRTY},
  {"save", "(Image, String) -> Result[Void]", image_native_save, AN_DIRTY},
  {"to_bytes", "(Image, String) -> Result[Bytes]", image_native_to_bytes, AN_DIRTY},
  {"to_pixels", "(Image) -> Result[Bytes]", image_native_to_pixels, AN_DIRTY},
  {"width", "(Image) -> Int", image_native_width, AN_SHORT},
  {"height", "(Image) -> Int", image_native_height, AN_SHORT},
  {"bands", "(Image) -> Int", image_native_bands, AN_SHORT},
  {"pixel_format", "(Image) -> Format", image_native_pixel_format, AN_SHORT},
};

static const an_type image_native_types[] = {
  {"Format", AN_ENUM, "U8 | I8 | U16 | I16 | U32 | I32 | F32 | F64 | Complex"},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define IMAGE_NATIVE_MODULE(LOAD) \
  static const an_resource_type image_native_resources[] = { \
    {"Image", sizeof(struct image_Image_state), IMAGE_Image_FREE}, \
  }; \
  AN_MODULE_TABLES("image", image_native_functions, 10, image_native_types, 1, image_native_resources, 1, LOAD)
#endif
