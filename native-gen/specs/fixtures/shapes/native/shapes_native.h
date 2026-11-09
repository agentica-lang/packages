/* The C side of `extern module "shapes"` in shapes.agc, made by native-gen.
   Do not edit it: change the .agc and make it again. */
#ifndef SHAPES_NATIVE_H
#define SHAPES_NATIVE_H

#include "agentica_native.h"

#if AN_API_MAJOR != 1
#error "shapes_native.h needs version 1 of the native API (agentica_native.h)"
#endif
#if AN_API_MINOR < 1
#error "shapes_native.h needs version 1.1 or later of the native API (agentica_native.h)"
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
enum { SHAPES_TYPE_Point = 0, SHAPES_TYPE_Label = 1, SHAPES_TYPE_Shape = 2, SHAPES_TYPE_Tree = 3 };

/* The fields of Point, in declared order. */
enum { SHAPES_Point_x = 0, SHAPES_Point_y = 1 };

/* The fields of Label, in declared order. */
enum { SHAPES_Label_text = 0, SHAPES_Label_data = 1, SHAPES_Label_shown = 2, SHAPES_Label_weight = 3, SHAPES_Label_at = 4, SHAPES_Label_tags = 5, SHAPES_Label_class = 6 };

/* The variants of Shape, in declared order: the tag of its C value. */
typedef enum { SHAPES_Shape_Dot = 0, SHAPES_Shape_Circle = 1, SHAPES_Shape_Tagged = 2 } shapes_Shape_tag;

/* The variants of Tree, in declared order: the tag of its C value. */
typedef enum { SHAPES_Tree_Leaf = 0, SHAPES_Tree_Node = 1 } shapes_Tree_tag;

/* The structs and enums as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them
   in C locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of
   the first bad part. _make and the constructors (one per variant) make a term. */

typedef struct {
  int64_t x;
  int64_t y;
} shapes_Point;
bool shapes_Point_get(an_env *env, an_term t, shapes_Point *out);
an_term shapes_Point_make(an_env *env, const shapes_Point *value);

typedef struct {
  ng_str text;
  ng_buf data;
  bool shown;
  double weight;
  shapes_Point at;
  an_term tags;
  int64_t class_;
} shapes_Label;
bool shapes_Label_get(an_env *env, an_term t, shapes_Label *out);
an_term shapes_Label_make(an_env *env, const shapes_Label *value);

typedef struct {
  shapes_Shape_tag tag;
  union {
    struct {
      shapes_Point _0;
      double _1;
    } Circle;
    struct {
      shapes_Label _0;
    } Tagged;
  } as;
} shapes_Shape;
bool shapes_Shape_get(an_env *env, an_term t, shapes_Shape *out);
an_term shapes_Shape_make(an_env *env, const shapes_Shape *value);
an_term shapes_Shape_Dot(an_env *env);
an_term shapes_Shape_Circle(an_env *env, shapes_Point _0, double _1);
an_term shapes_Shape_Tagged(an_env *env, shapes_Label _0);

typedef struct {
  shapes_Tree_tag tag;
  union {
    struct {
      int64_t _0;
    } Leaf;
    struct {
      an_term _0;
      an_term _1;
    } Node;
  } as;
} shapes_Tree;
bool shapes_Tree_get(an_env *env, an_term t, shapes_Tree *out);
an_term shapes_Tree_make(an_env *env, const shapes_Tree *value);
an_term shapes_Tree_Leaf(an_env *env, int64_t _0);
an_term shapes_Tree_Node(an_env *env, an_term _0, an_term _1);

an_term shapes_echo_point(an_env *env, shapes_Point value);

an_term shapes_echo_label(an_env *env, shapes_Label value);

an_term shapes_echo_shape(an_env *env, shapes_Shape value);

an_term shapes_echo_tree(an_env *env, shapes_Tree value);

/* A circle made with the one-line constructor of its variant. */
an_term shapes_circle(an_env *env, int64_t x, int64_t y, double radius);

/* Reads `values` as a Point, which it is not: the call fails. */
an_term shapes_misread(an_env *env, shapes_Point value, an_term values);

#ifdef __cplusplus
}
#endif

#endif

/* Outside the include guard, so a file that included the header before it defined the switch still gets this
   part; its own guard keeps it to one copy. */
#if defined(SHAPES_NATIVE_IMPLEMENTATION) && !defined(SHAPES_NATIVE_IMPLEMENTATION_DONE)
#define SHAPES_NATIVE_IMPLEMENTATION_DONE
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

static bool shapes_native_get_Point(an_env *env, an_term t, shapes_Point *out, ng_fail *fail) {
  an_term x;
  if (!an_get_field(env, t, SHAPES_TYPE_Point, 0, &x)) return ng_expected(fail, "Point");
  if (!an_get_int(env, x, &out->x)) return ng_leaf(fail, "Int", "x");
  if (!an_get_field(env, t, SHAPES_TYPE_Point, 1, &x)) return ng_expected(fail, "Point");
  if (!an_get_int(env, x, &out->y)) return ng_leaf(fail, "Int", "y");
  return true;
}

bool shapes_Point_get(an_env *env, an_term t, shapes_Point *out) {
  ng_fail fail;
  return shapes_native_get_Point(env, t, out, &fail) || ng_raise(env, "", "Point", &fail);
}

an_term shapes_Point_make(an_env *env, const shapes_Point *value) {
  an_term fields[2];
  fields[0] = an_int(env, value->x);
  fields[1] = an_int(env, value->y);
  return an_struct(env, SHAPES_TYPE_Point, fields);
}

static bool shapes_native_get_Label(an_env *env, an_term t, shapes_Label *out, ng_fail *fail) {
  an_term x;
  if (!an_get_field(env, t, SHAPES_TYPE_Label, 0, &x)) return ng_expected(fail, "Label");
  if (!an_get_string(env, x, &out->text.data, &out->text.len)) return ng_leaf(fail, "String", "text");
  if (!an_get_field(env, t, SHAPES_TYPE_Label, 1, &x)) return ng_expected(fail, "Label");
  if (!an_get_bytes(env, x, &out->data.data, &out->data.len)) return ng_leaf(fail, "Bytes", "data");
  if (!an_get_field(env, t, SHAPES_TYPE_Label, 2, &x)) return ng_expected(fail, "Label");
  if (!an_get_bool(env, x, &out->shown)) return ng_leaf(fail, "Bool", "shown");
  if (!an_get_field(env, t, SHAPES_TYPE_Label, 3, &x)) return ng_expected(fail, "Label");
  if (!an_get_float(env, x, &out->weight)) return ng_leaf(fail, "Float", "weight");
  if (!an_get_field(env, t, SHAPES_TYPE_Label, 4, &x)) return ng_expected(fail, "Label");
  if (!shapes_native_get_Point(env, x, &out->at, fail)) return ng_at(fail, "at");
  if (!an_get_field(env, t, SHAPES_TYPE_Label, 5, &x)) return ng_expected(fail, "Label");
  out->tags = x;
  if (!an_get_field(env, t, SHAPES_TYPE_Label, 6, &x)) return ng_expected(fail, "Label");
  if (!an_get_int(env, x, &out->class_)) return ng_leaf(fail, "Int", "class");
  return true;
}

bool shapes_Label_get(an_env *env, an_term t, shapes_Label *out) {
  ng_fail fail;
  return shapes_native_get_Label(env, t, out, &fail) || ng_raise(env, "", "Label", &fail);
}

an_term shapes_Label_make(an_env *env, const shapes_Label *value) {
  an_term fields[7];
  fields[0] = an_string(env, value->text.data, value->text.len);
  fields[1] = an_bytes(env, value->data.data, value->data.len);
  fields[2] = an_bool(env, value->shown);
  fields[3] = an_float(env, value->weight);
  fields[4] = shapes_Point_make(env, &value->at);
  fields[5] = value->tags;
  fields[6] = an_int(env, value->class_);
  return an_struct(env, SHAPES_TYPE_Label, fields);
}

static bool shapes_native_get_Shape(an_env *env, an_term t, shapes_Shape *out, ng_fail *fail) {
  uint32_t variant;
  an_term x;
  if (!an_get_variant(env, t, SHAPES_TYPE_Shape, &variant)) return ng_expected(fail, "Shape");
  out->tag = (shapes_Shape_tag)variant;
  switch (out->tag) {
    case SHAPES_Shape_Dot:
      return true;
    case SHAPES_Shape_Circle:
      if (!an_get_payload(env, t, SHAPES_TYPE_Shape, 0, &x)) return ng_expected(fail, "Shape");
      if (!shapes_native_get_Point(env, x, &out->as.Circle._0, fail)) return ng_at(fail, "Circle.0");
      if (!an_get_payload(env, t, SHAPES_TYPE_Shape, 1, &x)) return ng_expected(fail, "Shape");
      if (!an_get_float(env, x, &out->as.Circle._1)) return ng_leaf(fail, "Float", "Circle.1");
      return true;
    case SHAPES_Shape_Tagged:
      if (!an_get_payload(env, t, SHAPES_TYPE_Shape, 0, &x)) return ng_expected(fail, "Shape");
      if (!shapes_native_get_Label(env, x, &out->as.Tagged._0, fail)) return ng_at(fail, "Tagged.0");
      return true;
  }
  return ng_expected(fail, "Shape");
}

bool shapes_Shape_get(an_env *env, an_term t, shapes_Shape *out) {
  ng_fail fail;
  return shapes_native_get_Shape(env, t, out, &fail) || ng_raise(env, "", "Shape", &fail);
}

an_term shapes_Shape_make(an_env *env, const shapes_Shape *value) {
  switch (value->tag) {
    case SHAPES_Shape_Dot:
      return shapes_Shape_Dot(env);
    case SHAPES_Shape_Circle:
      return shapes_Shape_Circle(env, value->as.Circle._0, value->as.Circle._1);
    case SHAPES_Shape_Tagged:
      return shapes_Shape_Tagged(env, value->as.Tagged._0);
  }
  return an_raise(env, "Shape: the tag is not one of its variants");
}

an_term shapes_Shape_Dot(an_env *env) {
  return an_enum(env, SHAPES_TYPE_Shape, SHAPES_Shape_Dot, NULL);
}

an_term shapes_Shape_Circle(an_env *env, shapes_Point _0, double _1) {
  an_term payload[2];
  payload[0] = shapes_Point_make(env, &_0);
  payload[1] = an_float(env, _1);
  return an_enum(env, SHAPES_TYPE_Shape, SHAPES_Shape_Circle, payload);
}

an_term shapes_Shape_Tagged(an_env *env, shapes_Label _0) {
  an_term payload[1];
  payload[0] = shapes_Label_make(env, &_0);
  return an_enum(env, SHAPES_TYPE_Shape, SHAPES_Shape_Tagged, payload);
}

static bool shapes_native_get_Tree(an_env *env, an_term t, shapes_Tree *out, ng_fail *fail) {
  uint32_t variant;
  an_term x;
  if (!an_get_variant(env, t, SHAPES_TYPE_Tree, &variant)) return ng_expected(fail, "Tree");
  out->tag = (shapes_Tree_tag)variant;
  switch (out->tag) {
    case SHAPES_Tree_Leaf:
      if (!an_get_payload(env, t, SHAPES_TYPE_Tree, 0, &x)) return ng_expected(fail, "Tree");
      if (!an_get_int(env, x, &out->as.Leaf._0)) return ng_leaf(fail, "Int", "Leaf.0");
      return true;
    case SHAPES_Tree_Node:
      if (!an_get_payload(env, t, SHAPES_TYPE_Tree, 0, &x)) return ng_expected(fail, "Tree");
      out->as.Node._0 = x;
      if (!an_get_payload(env, t, SHAPES_TYPE_Tree, 1, &x)) return ng_expected(fail, "Tree");
      out->as.Node._1 = x;
      return true;
  }
  return ng_expected(fail, "Tree");
}

bool shapes_Tree_get(an_env *env, an_term t, shapes_Tree *out) {
  ng_fail fail;
  return shapes_native_get_Tree(env, t, out, &fail) || ng_raise(env, "", "Tree", &fail);
}

an_term shapes_Tree_make(an_env *env, const shapes_Tree *value) {
  switch (value->tag) {
    case SHAPES_Tree_Leaf:
      return shapes_Tree_Leaf(env, value->as.Leaf._0);
    case SHAPES_Tree_Node:
      return shapes_Tree_Node(env, value->as.Node._0, value->as.Node._1);
  }
  return an_raise(env, "Tree: the tag is not one of its variants");
}

an_term shapes_Tree_Leaf(an_env *env, int64_t _0) {
  an_term payload[1];
  payload[0] = an_int(env, _0);
  return an_enum(env, SHAPES_TYPE_Tree, SHAPES_Tree_Leaf, payload);
}

an_term shapes_Tree_Node(an_env *env, an_term _0, an_term _1) {
  an_term payload[2];
  payload[0] = _0;
  payload[1] = _1;
  return an_enum(env, SHAPES_TYPE_Tree, SHAPES_Tree_Node, payload);
}

static an_term shapes_native_echo_point(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  shapes_Point a0;
  if (!shapes_native_get_Point(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Point", 0);
  return shapes_echo_point(env, a0);
}

static an_term shapes_native_echo_label(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  shapes_Label a0;
  if (!shapes_native_get_Label(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Label", 0);
  return shapes_echo_label(env, a0);
}

static an_term shapes_native_echo_shape(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  shapes_Shape a0;
  if (!shapes_native_get_Shape(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Shape", 0);
  return shapes_echo_shape(env, a0);
}

static an_term shapes_native_echo_tree(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  shapes_Tree a0;
  if (!shapes_native_get_Tree(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Tree", 0);
  return shapes_echo_tree(env, a0);
}

static an_term shapes_native_circle(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  int64_t a0;
  if (!an_get_int(env, argv[0], &a0)) return an_badarg(env, 0);
  int64_t a1;
  if (!an_get_int(env, argv[1], &a1)) return an_badarg(env, 1);
  double a2;
  if (!an_get_float(env, argv[2], &a2)) return an_badarg(env, 2);
  return shapes_circle(env, a0, a1, a2);
}

static an_term shapes_native_misread(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  ng_fail fail;
  shapes_Point a0;
  if (!shapes_native_get_Point(env, argv[0], &a0, &fail)) return ng_fail_argument(env, &fail, "Point", 0);
  return shapes_misread(env, a0, argv[1]);
}

static const an_function shapes_native_functions[] = {
  {"echo_point", "(Point) -> Point", shapes_native_echo_point, AN_SHORT},
  {"echo_label", "(Label) -> Label", shapes_native_echo_label, AN_SHORT},
  {"echo_shape", "(Shape) -> Shape", shapes_native_echo_shape, AN_SHORT},
  {"echo_tree", "(Tree) -> Tree", shapes_native_echo_tree, AN_SHORT},
  {"circle", "(Int, Int, Float) -> Shape", shapes_native_circle, AN_SHORT},
  {"misread", "(Point, List[Int]) -> Point", shapes_native_misread, AN_SHORT},
};

static const an_type shapes_native_types[] = {
  {"Point", AN_STRUCT, "x: Int, y: Int"},
  {"Label", AN_STRUCT, "text: String, data: Bytes, shown: Bool, weight: Float, at: Point, tags: List[String], class: Int"},
  {"Shape", AN_ENUM, "Dot | Circle(Point, Float) | Tagged(Label)"},
  {"Tree", AN_ENUM, "Leaf(Int) | Node(Tree, Tree)"},
};

/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)
   that runs once at the first call, and refuses the module with the message it returns. */
#define SHAPES_NATIVE_MODULE(LOAD) AN_MODULE_TABLES("shapes", shapes_native_functions, 6, shapes_native_types, 4, NULL, 0, LOAD)
#endif
