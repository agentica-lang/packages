/* The module of samples.agc, on the header that native-gen makes from it: each function reads its List[Float32] run by
   run, as C floats inside the list, and makes its result from C floats. _run gives -1 when the argument is not a
   List[Float32], and the call has then failed, so the function only returns. */
#define SAMPLES_NATIVE_IMPLEMENTATION
#include "samples_native.h"

#include <stdlib.h>

an_term samples_energy(an_env *env, samples_list_Float32 samples) {
  const float *data;
  size_t n;
  int more;
  double total = 0;
  while ((more = samples_list_Float32_run(env, &samples, &data, &n)) == 1)
    for (size_t i = 0; i < n; i++) total += (double)data[i] * data[i];
  if (more < 0) return an_void(env);
  return an_float(env, total);
}

an_term samples_scaled(an_env *env, samples_list_Float32 samples, double by) {
  const float *data;
  size_t n, at = 0;
  int more;
  float *out = (float *)malloc(samples.len * sizeof *out + 1);
  an_term list;
  if (!out) return an_void(env);
  while ((more = samples_list_Float32_run(env, &samples, &data, &n)) == 1)
    for (size_t i = 0; i < n; i++) out[at++] = (float)(data[i] * by);
  if (more < 0) {
    free(out);
    return an_void(env);
  }
  list = samples_list_Float32_make(env, out, at);
  free(out);
  return list;
}

an_term samples_reversed(an_env *env, samples_list_list_Float32 rows) {
  samples_list_Float32 row;
  samples_list_list_Float32_builder out;
  int more;
  samples_list_list_Float32_begin(env, &out, rows.len);
  while ((more = samples_list_list_Float32_next(env, &rows, &row)) == 1) {
    const float *data;
    size_t n, at = 0;
    int got;
    float *back = (float *)malloc(row.len * sizeof *back + 1);
    if (!back) return an_void(env);
    while ((got = samples_list_Float32_run(env, &row, &data, &n)) == 1)
      for (size_t i = 0; i < n; i++) back[row.len - 1 - at++] = data[i];
    if (got < 0) {
      free(back);
      return an_void(env);
    }
    samples_list_list_Float32_push(env, &out, samples_list_Float32_make(env, back, at));
    free(back);
  }
  if (more < 0) return an_void(env);
  return samples_list_list_Float32_end(env, &out);
}

/* This calls the internal wrapper of the header (samples_native_energy) on purpose: a program cannot pass a List[Int],
   and only the wrapper sets the argument of a cursor. */
an_term samples_misread_argument(an_env *env) {
  an_term items[2], argv[1];
  items[0] = an_int(env, 1);
  items[1] = an_int(env, 2);
  argv[0] = an_list(env, items, 2);
  (void)samples_native_energy(env, 1, argv);
  return an_void(env);
}

SAMPLES_NATIVE_MODULE(NULL)
