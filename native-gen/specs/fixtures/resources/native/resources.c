/* The module of resources.agc, on the header that native-gen makes from it. A Db parameter is its state; the free
   function counts the frees, which the VM runs when the task that owns a Db ends. */
#define RESOURCES_NATIVE_IMPLEMENTATION
#include "resources_native.h"

struct resources_Db_state {
  int64_t id;
};

/* The frees so far; the VM may free on another thread than the calls, so it is atomic. */
static int64_t freed;

static void free_db(void *state) {
  (void)state;
  __atomic_add_fetch(&freed, 1, __ATOMIC_RELAXED);
}
#define RESOURCES_Db_FREE free_db

an_term resources_open_db(an_env *env, int64_t id) {
  an_term out;
  struct resources_Db_state *db = resources_Db_new(env, &out);
  if (db) db->id = id;
  return out;
}

an_term resources_db_id(an_env *env, struct resources_Db_state *db) { return an_int(env, db->id); }

an_term resources_pair(an_env *env, int64_t first) {
  resources_list_Db_builder b;
  resources_list_Db_begin(env, &b, 2);
  for (int64_t k = 0; k < 2; k++) {
    an_term out;
    struct resources_Db_state *db = resources_Db_new(env, &out);
    if (!db) return an_void(env);
    db->id = first + k;
    resources_list_Db_push(env, &b, out);
  }
  return resources_list_Db_end(env, &b);
}

an_term resources_freed(an_env *env) { return an_int(env, __atomic_load_n(&freed, __ATOMIC_RELAXED)); }

an_term resources_is_db(an_env *env, int64_t n) { return an_bool(env, resources_Db_get(env, an_int(env, n)) != NULL); }

RESOURCES_NATIVE_MODULE(NULL)
