#define IMAGE_NATIVE_IMPLEMENTATION
#include "image_native.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* The few libvips and glib calls of the module, declared here: vips.h needs the include paths of glib, which a
   `build` table cannot give. Their ABI is stable. */
typedef struct _VipsImage VipsImage;
extern int vips_init(const char *argv0);
extern char *vips_error_buffer_copy(void);
extern int vips_version(int flag);
extern void vips_cache_set_max(int max);
extern void vips_block_untrusted_set(int state);
extern VipsImage *vips_image_new_from_file(const char *name, ...);
extern VipsImage *vips_image_new_from_buffer(const void *buf, size_t len, const char *option_string, ...);
extern VipsImage *vips_image_new_from_memory_copy(const void *data, size_t size, int width, int height, int bands,
                                                  int format);
extern VipsImage *vips_image_copy_memory(VipsImage *image);
extern int vips_copy(VipsImage *in, VipsImage **out, ...);
extern int vips_resize(VipsImage *in, VipsImage **out, double scale, ...);
extern int vips_extract_area(VipsImage *in, VipsImage **out, int left, int top, int width, int height, ...);
/* An enum without a negative member is an unsigned int. */
extern int vips_flip(VipsImage *in, VipsImage **out, unsigned direction, ...);
extern int vips_rot(VipsImage *in, VipsImage **out, unsigned angle, ...);
extern int vips_colourspace(VipsImage *in, VipsImage **out, int space, ...);
extern int vips_cast(VipsImage *in, VipsImage **out, int format, ...);
extern int vips_image_write_to_file(VipsImage *image, const char *name, ...);
extern int vips_image_write_to_buffer(VipsImage *in, const char *suffix, void **buf, size_t *size, ...);
extern void *vips_image_write_to_memory(VipsImage *in, size_t *size);
extern int vips_image_get_width(const VipsImage *image);
extern int vips_image_get_height(const VipsImage *image);
extern int vips_image_get_bands(const VipsImage *image);
extern int vips_image_get_format(const VipsImage *image);
/* A newer glib.h makes these macros that call the same functions: undefined when the check of CI includes vips.h. */
#undef g_object_unref
#undef g_free
extern void g_object_unref(void *object);
extern void g_free(void *mem);

enum { UCHAR, CHAR, USHORT, SHORT, UINT, INT, FLOAT, COMPLEX, DOUBLE, DPCOMPLEX };
enum { MULTIBAND = 0, B_W = 1, SRGB = 22, RGB16 = 25, GREY16 = 26 };
/* What a resize may make: the pixels of a lazy result are made when they are read, and a huge size would fill memory
   there. */
#define MAX_PIXELS ((int64_t)1 << 28)
/* The largest side that libvips makes (VIPS_MAX_COORD): a larger scale or size makes it print a GLib critical. */
#define MAX_SIDE ((int64_t)10000000)
enum { HORIZONTAL, VERTICAL };
enum { D0, D90, D180, D270 };

/* The vips format of each image_Format_tag, in the order of the enum. */
static const int vips_formats[] = {UCHAR, CHAR, USHORT, SHORT, UINT, INT, FLOAT, DOUBLE, COMPLEX};
static const size_t format_sizes[] = {1, 1, 2, 2, 4, 4, 4, 8, 8};

/* What a buffer of pixels is taken for: libvips picks the bit depth of a PNG and converts colours by it. */
static int interpretation(int format, int bands) {
  if (format == UCHAR) return bands <= 2 ? B_W : bands <= 4 ? SRGB : MULTIBAND;
  if (format == USHORT) return bands <= 2 ? GREY16 : bands <= 4 ? RGB16 : MULTIBAND;
  return MULTIBAND;
}

struct image_Image_state {
  VipsImage *vips;
};

static void free_image(void *state) { g_object_unref(((struct image_Image_state *)state)->vips); }
#define IMAGE_Image_FREE free_image

static pthread_once_t once = PTHREAD_ONCE_INIT;
static const char *init_error;

/* The hand-written declarations above are those of libvips 8. The operation cache is off: an image owns its pixels
   already, and a cached load would answer for a file that changed. */
static void init_vips(void) {
  if (vips_init("agentica") != 0) {
    init_error = "libvips did not start";
  } else if (vips_version(0) != 8) {
    init_error = "libvips 8 is needed";
  } else {
    vips_cache_set_max(0);
    vips_block_untrusted_set(1);
  }
}

/* The message of libvips for the last failure; its buffer is one for the process, which the copy empties. */
static an_term fail(an_env *env, const char *fallback) {
  char *message = vips_error_buffer_copy();
  size_t len = strlen(message);
  while (len > 0 && message[len - 1] == '\n') len--;
  an_term out = len > 0 ? an_error(env, message, len) : an_error(env, fallback, strlen(fallback));
  g_free(message);
  return out;
}

static an_term refuse(an_env *env, const char *message) { return an_error(env, message, strlen(message)); }

static an_term ready(an_env *env, int *ok) {
  pthread_once(&once, init_vips);
  *ok = init_error == NULL;
  return *ok ? an_void(env) : refuse(env, init_error);
}

static an_term make(an_env *env, VipsImage *vips) {
  an_term out;
  struct image_Image_state *state = image_Image_new(env, &out);
  if (!state) {
    g_object_unref(vips);
    return an_void(env);
  }
  state->vips = vips;
  return image_result_Image_ok(env, out);
}

/* Decodes at once and drops the source, so that a bad file fails here and the image never reads the file or the
   buffer again. */
static an_term wrap(an_env *env, VipsImage *source) {
  if (!source) return fail(env, "cannot decode the image");
  VipsImage *vips = vips_image_copy_memory(source);
  g_object_unref(source);
  if (!vips) return fail(env, "cannot decode the image");
  return make(env, vips);
}

static bool has_nul(ng_str s) { return memchr(s.data, 0, s.len) != NULL; }

static char *cstring(ng_str s) {
  char *copy = malloc(s.len + 1);
  if (!copy) return NULL;
  memcpy(copy, s.data, s.len);
  copy[s.len] = 0;
  return copy;
}

#define READY(env) \
  do { \
    int ok_; \
    an_term failed_ = ready(env, &ok_); \
    if (!ok_) return failed_; \
  } while (0)

an_term image_load(an_env *env, ng_str path) {
  READY(env);
  if (has_nul(path)) return refuse(env, "the path has a NUL byte");
  char *name = cstring(path);
  if (!name) return an_raise(env, "out of memory");
  VipsImage *source = vips_image_new_from_file(name, NULL);
  free(name);
  return wrap(env, source);
}

an_term image_from_bytes(an_env *env, ng_buf data) {
  READY(env);
  return wrap(env, vips_image_new_from_buffer(data.data, data.len, "", NULL));
}

an_term image_from_pixels(an_env *env, ng_buf pixels, int64_t width, int64_t height, int64_t bands,
                          image_Format format) {
  READY(env);
  if (format.tag == IMAGE_Format_Complex) return refuse(env, "complex pixels are not supported");
  if (width < 1 || height < 1 || bands < 1) return refuse(env, "the width, the height and the bands must be positive");
  if (width > INT32_MAX || height > INT32_MAX) {
    return refuse(env, "the width and the height must be at most 2147483647");
  }
  if (bands > 65535) return refuse(env, "the bands must be at most 65535");
  size_t item = format_sizes[format.tag];
  size_t count;
  if (__builtin_mul_overflow((size_t)width, (size_t)height, &count) ||
      __builtin_mul_overflow(count, (size_t)bands, &count) || __builtin_mul_overflow(count, item, &count) ||
      count != pixels.len) {
    return refuse(env, "the size of the pixels does not match width * height * bands * the size of the format");
  }
  VipsImage *source = vips_image_new_from_memory_copy(pixels.data, pixels.len, (int)width, (int)height, (int)bands,
                                                      vips_formats[format.tag]);
  if (!source) return fail(env, "cannot make the image");
  VipsImage *vips;
  int status = vips_copy(source, &vips, "interpretation", interpretation(vips_formats[format.tag], (int)bands), NULL);
  g_object_unref(source);
  if (status != 0) return fail(env, "cannot make the image");
  return make(env, vips);
}

an_term image_save(an_env *env, struct image_Image_state *image, ng_str path) {
  if (has_nul(path)) return refuse(env, "the path has a NUL byte");
  char *name = cstring(path);
  if (!name) return an_raise(env, "out of memory");
  int status = vips_image_write_to_file(image->vips, name, NULL);
  free(name);
  return status == 0 ? image_result_Void_ok(env, an_void(env)) : fail(env, "cannot save the image");
}

an_term image_to_bytes(an_env *env, struct image_Image_state *image, ng_str format) {
  if (has_nul(format)) return refuse(env, "the suffix has a NUL byte");
  char *suffix = malloc(format.len + 2);
  if (!suffix) return an_raise(env, "out of memory");
  suffix[0] = '.';
  memcpy(suffix + 1, format.data, format.len);
  suffix[format.len + 1] = 0;
  void *buffer;
  size_t len;
  int status = vips_image_write_to_buffer(image->vips, suffix, &buffer, &len, NULL);
  free(suffix);
  if (status != 0) return fail(env, "cannot encode the image");
  an_term out = image_result_Bytes_ok(env, (ng_buf){buffer, len});
  g_free(buffer);
  return out;
}

an_term image_to_pixels(an_env *env, struct image_Image_state *image) {
  size_t len;
  void *buffer = vips_image_write_to_memory(image->vips, &len);
  if (!buffer) return fail(env, "cannot read the pixels");
  an_term out = image_result_Bytes_ok(env, (ng_buf){buffer, len});
  g_free(buffer);
  return out;
}

/* The operations are lazy: the result holds the image it came from, and the pixels are made when they are read. */
an_term image_resize(an_env *env, struct image_Image_state *image, int64_t width, int64_t height) {
  VipsImage *in = image->vips;
  if (width < 1 || height < 1) return refuse(env, "the width and the height must be positive");
  if (width > MAX_SIDE || height > MAX_SIDE) return refuse(env, "the width and the height must be at most 10000000");
  if (width * height > MAX_PIXELS) return refuse(env, "the size is more than 268435456 pixels");
  VipsImage *out;
  double horizontal = (double)width / vips_image_get_width(in);
  double vertical = (double)height / vips_image_get_height(in);
  if (vips_resize(in, &out, horizontal, "vscale", vertical, NULL) != 0) return fail(env, "cannot resize the image");
  if (vips_image_get_width(out) != width || vips_image_get_height(out) != height) {
    g_object_unref(out);
    return refuse(env, "cannot resize the image to that size");
  }
  return make(env, out);
}

an_term image_crop(an_env *env, struct image_Image_state *image, int64_t left, int64_t top, int64_t width,
                   int64_t height) {
  int64_t in_width = vips_image_get_width(image->vips);
  int64_t in_height = vips_image_get_height(image->vips);
  if (left < 0 || top < 0 || width < 1 || height < 1 || width > in_width || height > in_height ||
      left > in_width - width || top > in_height - height) {
    return refuse(env, "the area is outside the image");
  }
  VipsImage *out;
  if (vips_extract_area(image->vips, &out, (int)left, (int)top, (int)width, (int)height, NULL) != 0) {
    return fail(env, "cannot crop the image");
  }
  return make(env, out);
}

an_term image_flip(an_env *env, struct image_Image_state *image, image_Direction direction) {
  VipsImage *out;
  if (vips_flip(image->vips, &out, direction.tag == IMAGE_Direction_Horizontal ? HORIZONTAL : VERTICAL, NULL) != 0) {
    return fail(env, "cannot flip the image");
  }
  return make(env, out);
}

an_term image_rotate(an_env *env, struct image_Image_state *image, int64_t degrees) {
  if (degrees % 90 != 0) return refuse(env, "the angle must be a multiple of 90 degrees");
  static const int angles[] = {D0, D90, D180, D270};
  VipsImage *out;
  if (vips_rot(image->vips, &out, angles[((degrees / 90) % 4 + 4) % 4], NULL) != 0) {
    return fail(env, "cannot rotate the image");
  }
  return make(env, out);
}

an_term image_colourspace(an_env *env, struct image_Image_state *image, image_Space space) {
  int format = vips_image_get_format(image->vips);
  if (format != UCHAR && format != USHORT) return refuse(env, "colourspace needs a U8 or U16 image");
  bool grey = space.tag == IMAGE_Space_Grey;
  bool sixteen = format == USHORT;
  VipsImage *out;
  if (vips_colourspace(image->vips, &out, grey ? (sixteen ? GREY16 : B_W) : (sixteen ? RGB16 : SRGB), NULL) != 0) {
    return fail(env, "cannot convert the colours of the image");
  }
  return make(env, out);
}

an_term image_cast(an_env *env, struct image_Image_state *image, image_Format format) {
  if (format.tag == IMAGE_Format_Complex) return refuse(env, "complex pixels are not supported");
  VipsImage *out;
  if (vips_cast(image->vips, &out, vips_formats[format.tag], NULL) != 0) return fail(env, "cannot cast the image");
  return make(env, out);
}

an_term image_width(an_env *env, struct image_Image_state *image) {
  return an_int(env, vips_image_get_width(image->vips));
}

an_term image_height(an_env *env, struct image_Image_state *image) {
  return an_int(env, vips_image_get_height(image->vips));
}

an_term image_bands(an_env *env, struct image_Image_state *image) {
  return an_int(env, vips_image_get_bands(image->vips));
}

an_term image_pixel_format(an_env *env, struct image_Image_state *image) {
  switch (vips_image_get_format(image->vips)) {
    case UCHAR: return image_Format_U8(env);
    case CHAR: return image_Format_I8(env);
    case USHORT: return image_Format_U16(env);
    case SHORT: return image_Format_I16(env);
    case UINT: return image_Format_U32(env);
    case INT: return image_Format_I32(env);
    case FLOAT: return image_Format_F32(env);
    case DOUBLE: return image_Format_F64(env);
    default: return image_Format_Complex(env);
  }
}

IMAGE_NATIVE_MODULE(NULL)
