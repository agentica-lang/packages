/* The module of lists.agc, on the header that native-gen makes from it: each function walks its arguments with their
   cursors and makes its result with builders. _next gives -1 when an item does not decode, and the call has then
   failed, so the function only returns. */
#define LISTS_NATIVE_IMPLEMENTATION
#include "lists_native.h"

an_term lists_sums(an_env *env, lists_list_list_Float rows) {
  lists_list_Float row;
  lists_list_Float_builder out;
  int more;
  lists_list_Float_begin(env, &out, rows.len);
  while ((more = lists_list_list_Float_next(env, &rows, &row)) == 1) {
    double x, total = 0;
    int got;
    while ((got = lists_list_Float_next(env, &row, &x)) == 1) total += x;
    if (got < 0) return an_void(env);
    lists_list_Float_push(env, &out, total);
  }
  if (more < 0) return an_void(env);
  return lists_list_Float_end(env, &out);
}

an_term lists_codes(an_env *env, lists_list_String words) {
  ng_str word;
  lists_map_String_list_Int_builder out;
  int more;
  lists_map_String_list_Int_begin(env, &out);
  while ((more = lists_list_String_next(env, &words, &word)) == 1) {
    lists_list_Int_builder codes;
    lists_list_Int_begin(env, &codes, word.len);
    for (size_t k = 0; k < word.len; k++) lists_list_Int_push(env, &codes, (unsigned char)word.data[k]);
    lists_map_String_list_Int_put(env, &out, word, lists_list_Int_end(env, &codes));
  }
  if (more < 0) return an_void(env);
  return lists_map_String_list_Int_end(env, &out);
}

an_term lists_moved(an_env *env, lists_map_String_Point named, lists_Point by) {
  ng_str name;
  lists_Point point;
  lists_list_Point_builder out;
  int more;
  lists_list_Point_begin(env, &out, named.len);
  while ((more = lists_map_String_Point_next(env, &named, &name, &point)) == 1) {
    point.x += by.x;
    point.y += by.y;
    lists_list_Point_push(env, &out, point);
  }
  if (more < 0) return an_void(env);
  return lists_list_Point_end(env, &out);
}

/* The constructors of the C API do not check the item types, so a List[Int] with a String in it can be made; reading
   it fails at that item. */
an_term lists_misread_list(an_env *env, lists_list_Int values) {
  an_term items[3];
  int64_t x, total = 0;
  int more;
  items[0] = an_int(env, 1);
  items[1] = an_string(env, "a", 1);
  items[2] = an_int(env, 3);
  if (!lists_list_Int_open(env, an_list(env, items, 3), &values)) return an_void(env);
  while ((more = lists_list_Int_next(env, &values, &x)) == 1) total += x;
  if (more < 0) return an_void(env);
  return an_int(env, total);
}

an_term lists_misread_map(an_env *env, lists_map_String_Point named) {
  an_term point[2], key, value;
  ng_str name;
  lists_Point read;
  point[LISTS_Point_x] = an_string(env, "a", 1);
  point[LISTS_Point_y] = an_int(env, 2);
  key = an_string(env, "p", 1);
  value = an_struct(env, LISTS_TYPE_Point, point);
  if (!lists_map_String_Point_open(env, an_map_from(env, &key, &value, 1), &named)) return an_void(env);
  if (lists_map_String_Point_next(env, &named, &name, &read) < 0) return an_void(env);
  return an_int(env, read.x);
}

LISTS_NATIVE_MODULE(NULL)
