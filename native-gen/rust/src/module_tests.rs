//! `Module`, `init` and `ResourceArc` on the mock VM: the tables the VM reads, and each resource dropped once.

use core::ffi::{CStr, c_int};
use core::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::mock::{self, MockEnv, V};
use crate::module::build;
use crate::tests::run_or_raise;
use crate::*;

/// A resource value that counts its drops.
struct Counted {
    drops: Arc<AtomicUsize>,
}

impl Drop for Counted {
    fn drop(&mut self) {
        self.drops.fetch_add(1, Ordering::SeqCst);
    }
}

/// A resource value whose drop panics.
struct Panicky;

impl Drop for Panicky {
    fn drop(&mut self) {
        panic!("dropped");
    }
}

/// A type that no row of the module is.
struct Unlisted;

unsafe extern "C" fn nothing(env: *mut sys::an_env, argc: c_int, argv: *const sys::an_term) -> sys::an_term {
    unsafe { call(env, argc, argv, Mode::Short, types(), |env, _| Ok(env.void())) }
}

/// The module of the tests, the same as the mock's tables: one per process, like the library's.
fn module() -> Module {
    Module::new("mock")
        .function("nothing", "() -> Void", nothing, Mode::Short)
        .function("slow?", "(Int) -> Int", nothing, Mode::Dirty)
        .struct_type("Point", "x: Int, y: Int", 2)
        .enum_type("Shape", "Empty | Circle(Point)", &[0, 1])
        .resource::<Counted>("Counter")
        .resource::<Panicky>("Panicky")
}

fn init_module() -> &'static sys::an_module {
    // SAFETY: init ignores the API, and the module lives as long as the process.
    unsafe { &*init(ptr::null(), module) }
}

fn text(p: *const core::ffi::c_char) -> &'static str {
    // SAFETY: the tables' strings are NUL-terminated and live as long as the module.
    unsafe { CStr::from_ptr(p) }.to_str().unwrap()
}

#[test]
fn the_tables_hold_each_row_in_order_and_init_builds_them_once() {
    let m = init_module();
    assert!(ptr::eq(m, init_module()));
    assert_eq!((m.major, m.minor, m.size as usize), (1, 2, size_of::<sys::an_module>()));
    assert_eq!(text(m.name), "mock");
    // SAFETY: each table has its count of rows.
    let (functions, rows, resources) = unsafe {
        (
            core::slice::from_raw_parts(m.functions, m.function_count as usize),
            core::slice::from_raw_parts(m.types, m.type_count as usize),
            core::slice::from_raw_parts(m.resources, m.resource_count as usize),
        )
    };
    let functions: Vec<_> = functions.iter().map(|f| (text(f.name), text(f.signature), f.flags)).collect();
    assert_eq!(functions, [("nothing", "() -> Void", sys::AN_SHORT), ("slow?", "(Int) -> Int", sys::AN_DIRTY)]);
    let rows: Vec<_> = rows.iter().map(|t| (text(t.name), t.kind, text(t.shape))).collect();
    assert_eq!(rows, [("Point", sys::AN_STRUCT, "x: Int, y: Int"), ("Shape", sys::AN_ENUM, "Empty | Circle(Point)")]);
    let resources: Vec<_> = resources.iter().map(|r| (text(r.name), r.size)).collect();
    assert_eq!(resources, [("Counter", size_of::<usize>()), ("Panicky", size_of::<usize>())]);
    assert_eq!(types(), mock::TYPES);
    // SAFETY: LOAD takes nothing, and returns null for a module it does not refuse.
    assert!(unsafe { m.load.unwrap()() }.is_null());
}

#[test]
fn a_module_with_a_nul_or_two_resources_of_one_type_is_refused() {
    let empty = build(Module::new("empty"));
    assert!(empty.refusal().is_none());
    assert!(empty.module().types.is_null() && empty.module().resources.is_null());
    let nul = build(Module::new("mock").struct_type("Po\0int", "x: Int", 1));
    assert_eq!(nul.refusal().unwrap().to_str().unwrap(), r#""Po\0int" holds a NUL, which a C string cannot"#);
    let twice = build(Module::new("mock").resource::<Counted>("A").resource::<Counted>("B"));
    let message = twice.refusal().unwrap().to_str().unwrap();
    assert!(message.starts_with("the resources A and B are both the Rust type "), "{message}");
}

#[test]
fn a_thousand_resources_are_each_dropped_once_when_the_vm_frees_them() {
    let m = init_module();
    // SAFETY: the resource table has two rows.
    let (free_counted, free_panicky) = unsafe { ((*m.resources).free.unwrap(), (*m.resources.add(1)).free.unwrap()) };
    let drops = Arc::new(AtomicUsize::new(0));
    let vm = MockEnv::new(false);
    let mut made = Vec::new();
    for _ in 0..1000 {
        let value = ResourceArc::new(Counted { drops: Arc::clone(&drops) });
        made.push(run_or_raise(&vm, Mode::Short, vec![], |env, _| Ok(value.encode(env))).unwrap());
    }
    // An argument decodes to a handle on the same value, which Rust may keep after the call.
    let kept = std::cell::RefCell::new(None);
    let first = made[0].clone();
    let read = run_or_raise(&vm, Mode::Short, vec![first.clone(), first], |env, args| {
        let (a, b) = (args.decode::<ResourceArc<Counted>>(0)?, args.decode::<ResourceArc<Counted>>(1)?);
        assert!(ResourceArc::ptr_eq(&a, &b));
        kept.replace(Some(a));
        Ok(env.void())
    });
    assert_eq!(read, Ok(V::Void));
    assert_eq!(drops.load(Ordering::SeqCst), 0);

    // The VM frees each state once, with the free function of its row.
    let states: Vec<_> = vm.states.borrow().iter().map(|&(row, state)| (row, state)).collect();
    assert_eq!(states.len(), 1000);
    for (row, state) in states {
        assert_eq!(row, 0);
        // SAFETY: a state of row 0 that encode wrote, freed once.
        unsafe { free_counted(state) };
    }
    assert_eq!(drops.load(Ordering::SeqCst), 999);
    drop(kept.take());
    assert_eq!(drops.load(Ordering::SeqCst), 1000);

    // A panic of Drop stops in the free function, and a state still zeroed holds nothing to drop.
    let panicky = run_or_raise(&vm, Mode::Short, vec![], |env, _| Ok(ResourceArc::new(Panicky).encode(env))).unwrap();
    let V::Resource(1, state) = panicky else { panic!("{panicky:?}") };
    // SAFETY: a state of row 1 that encode wrote, then a zeroed one.
    unsafe { free_panicky(state) };
    let mut zeroed = 0usize;
    unsafe { free_counted(&mut zeroed as *mut usize as *mut core::ffi::c_void) };
}

#[test]
fn a_resource_of_another_row_or_type_is_refused() {
    let m = init_module();
    let drops = Arc::new(AtomicUsize::new(0));
    let vm = MockEnv::new(false);
    let value = ResourceArc::new(Counted { drops: Arc::clone(&drops) });
    let made = run_or_raise(&vm, Mode::Short, vec![], |env, _| Ok(value.encode(env))).unwrap();
    drop(value);
    let misread = run_or_raise(&vm, Mode::Short, vec![made.clone()], |env, args| {
        Ok(args.decode::<ResourceArc<Panicky>>(0)?.encode(env))
    });
    assert_eq!(misread, Err("argument 1: Panicky: expected Panicky".to_string()));
    let unlisted =
        run_or_raise(&MockEnv::new(false), Mode::Short, vec![], |env, _| Ok(ResourceArc::new(Unlisted).encode(env)));
    assert_eq!(unlisted, Err(format!("{} is not a resource of the module", std::any::type_name::<Unlisted>())));
    let decoded = run_or_raise(&MockEnv::new(false), Mode::Short, vec![made], |env, args| {
        Ok(args.decode::<ResourceArc<Unlisted>>(0)?.encode(env))
    });
    assert_eq!(decoded, Err("argument 1: a resource: expected a resource".to_string()));
    let (_, state) = vm.states.borrow()[0];
    // SAFETY: the one state of row 0 that encode wrote, freed once.
    unsafe { (*m.resources).free.unwrap()(state) };
    assert_eq!(drops.load(Ordering::SeqCst), 1);
}
