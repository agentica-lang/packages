//! The tables of a module and its init: what `agentica_native_init` gives the VM, built once per process.

use core::any::TypeId;
use core::ffi::{c_char, c_int};
use core::mem::size_of;
use core::ptr;
use std::ffi::{CStr, CString};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::OnceLock;

use crate::resource;
use crate::sys;
use crate::term::{Arity, Mode};

struct Function {
    name: String,
    signature: String,
    fn_: sys::an_fn,
    mode: Mode,
}

struct Type {
    name: String,
    kind: c_int,
    shape: String,
}

struct Resource {
    name: String,
    type_id: TypeId,
    rust_name: &'static str,
    free: unsafe extern "C" fn(*mut core::ffi::c_void),
}

/// The rows of a module's tables, which native-gen writes from the `extern module` block. Names, signatures and
/// shapes are the canonical text that the VM compares byte for byte with the program's; the index of a type or
/// resource row, in the order added, is the `type_` that `Env` and `Term` take.
pub struct Module {
    name: String,
    functions: Vec<Function>,
    types: Vec<Type>,
    resources: Vec<Resource>,
}

impl Module {
    /// A module of the library `name` (`extern module "NAME"`).
    pub fn new(name: &str) -> Self {
        Module { name: name.to_string(), functions: Vec::new(), types: Vec::new(), resources: Vec::new() }
    }

    /// A row of the function table: `def` is `Mode::Short`, `compute def` `Mode::Dirty`.
    pub fn function(mut self, name: &str, signature: &str, fn_: sys::an_fn, mode: Mode) -> Self {
        self.functions.push(Function { name: name.to_string(), signature: signature.to_string(), fn_, mode });
        self
    }

    /// The next row of the type table, a struct with its canonical shape (`count: Int, min: Float`).
    pub fn struct_type(mut self, name: &str, shape: &str) -> Self {
        self.types.push(Type { name: name.to_string(), kind: sys::AN_STRUCT, shape: shape.to_string() });
        self
    }

    /// The next row of the type table, an enum with its canonical shape (`Empty | Number(Float)`).
    pub fn enum_type(mut self, name: &str, shape: &str) -> Self {
        self.types.push(Type { name: name.to_string(), kind: sys::AN_ENUM, shape: shape.to_string() });
        self
    }

    /// The next row of the resource table, `resource NAME`, held in Rust as a `ResourceArc<T>`. Its free function
    /// drops the `T` that the program held.
    pub fn resource<T: Send + Sync + 'static>(mut self, name: &str) -> Self {
        self.resources.push(Resource {
            name: name.to_string(),
            type_id: TypeId::of::<T>(),
            rust_name: std::any::type_name::<T>(),
            free: resource::free::<T>,
        });
        self
    }
}

/// The module as the VM reads it. The pointers of its tables point into its own strings and vectors, which never
/// change after the build.
pub(crate) struct Built {
    module: sys::an_module,
    // From CString::into_raw, so that moving Built never moves (or retags) what the tables point to; freed by Drop.
    strings: Vec<*mut c_char>,
    _functions: Vec<sys::an_function>,
    _types: Vec<sys::an_type>,
    _resources: Vec<sys::an_resource_type>,
    arities: Vec<Arity>,
    resource_rows: Vec<(TypeId, String)>,
    refusal: Option<CString>,
}

impl Built {
    #[cfg(test)]
    pub(crate) fn module(&self) -> &sys::an_module {
        &self.module
    }

    #[cfg(test)]
    pub(crate) fn arities(&self) -> &[Arity] {
        &self.arities
    }

    #[cfg(test)]
    pub(crate) fn refusal(&self) -> Option<&CStr> {
        self.refusal.as_deref()
    }
}

impl Drop for Built {
    fn drop(&mut self) {
        for &text in &self.strings {
            // SAFETY: each is a pointer of CString::into_raw, freed once here.
            drop(unsafe { CString::from_raw(text) });
        }
    }
}

// SAFETY: the raw pointers of Built point into data it owns, which never changes after the build; the VM only reads
// it, from any thread.
unsafe impl Send for Built {}
unsafe impl Sync for Built {}

static BUILT: OnceLock<Built> = OnceLock::new();

/// What each row of the type table of this library's module takes, for `call`: empty before the init.
pub fn types() -> &'static [Arity] {
    BUILT.get().map_or(&[], |built| &built.arities)
}

/// The row and the Agentica name of the resource that `T` is, in this library's module.
pub(crate) fn resource_row<T: 'static>() -> Option<(u32, &'static str)> {
    let rows = &BUILT.get()?.resource_rows;
    let id = TypeId::of::<T>();
    let at = rows.iter().position(|(row, _)| *row == id)?;
    Some((u32::try_from(at).ok()?, rows[at].1.as_str()))
}

/// The module that `make` describes, built at the first call and the same at every later one: what
/// `agentica_native_init` returns (see `export!`). A panic of `make` gives null, which refuses the library.
///
/// # Safety
///
/// Called through `agentica_native_init` only, by the VM, with the API it gives.
pub unsafe fn init(_api: *const sys::an_api, make: impl FnOnce() -> Module) -> *const sys::an_module {
    match catch_unwind(AssertUnwindSafe(|| &BUILT.get_or_init(|| build(make())).module)) {
        Ok(module) => module,
        Err(payload) => {
            // Its drop may panic again, which must not unwind into the VM either.
            if let Err(again) = catch_unwind(AssertUnwindSafe(|| drop(payload))) {
                core::mem::forget(again);
            }
            ptr::null()
        }
    }
}

pub(crate) fn build(module: Module) -> Built {
    let mut strings = Vec::new();
    let mut refusal = None;
    let mut text = |s: &str| -> *const c_char {
        // A NUL inside a name cannot cross in a C string, so LOAD refuses the module. The VM checks that no two rows
        // share a name before LOAD runs, so the text in its place is one no other row has: a control character and
        // the index of the text.
        let at = strings.len();
        let owned = CString::new(s).unwrap_or_else(|_| {
            refusal.get_or_insert_with(|| format!("{s:?} holds a NUL, which a C string cannot"));
            CString::new(format!("\u{1}{at}")).unwrap_or_default()
        });
        let at = owned.into_raw();
        strings.push(at);
        at as *const c_char
    };

    let name = text(&module.name);
    let functions: Vec<sys::an_function> = (module.functions.iter())
        .map(|f| sys::an_function {
            name: text(&f.name),
            signature: text(&f.signature),
            fn_: f.fn_,
            flags: match f.mode {
                Mode::Short => sys::AN_SHORT,
                Mode::Dirty => sys::AN_DIRTY,
            },
        })
        .collect();
    let types: Vec<sys::an_type> = (module.types.iter())
        .map(|t| sys::an_type { name: text(&t.name), kind: t.kind, shape: text(&t.shape) })
        .collect();
    let resources: Vec<sys::an_resource_type> = (module.resources.iter())
        .map(|r| sys::an_resource_type {
            name: text(&r.name),
            // The state holds the pointer of an Arc (ResourceArc).
            size: size_of::<*const ()>(),
            free: Some(r.free),
        })
        .collect();

    // The VM reads as many terms from make_struct and make_enum as the shape has, so the arity that Env checks is the
    // shape's own; a shape that is not in the form the VM writes refuses the module.
    let arities: Vec<Arity> = (module.types.iter())
        .map(|t| {
            arity(t.kind, &t.shape).unwrap_or_else(|| {
                refusal.get_or_insert_with(|| format!("the shape of {} is not canonical: {:?}", t.name, t.shape));
                Arity::Struct(0)
            })
        })
        .collect();

    // A resource is found by its Rust type, so two rows of one type would be one.
    for (at, r) in module.resources.iter().enumerate() {
        if let Some(first) = module.resources[..at].iter().find(|other| other.type_id == r.type_id) {
            refusal.get_or_insert_with(|| {
                format!("the resources {} and {} are both the Rust type {}", first.name, r.name, r.rust_name)
            });
        }
    }

    let mut count = |len: usize, what: &str| {
        u32::try_from(len).unwrap_or_else(|_| {
            refusal.get_or_insert_with(|| format!("the module has more {what} than a u32 counts"));
            0
        })
    };
    let (function_count, type_count, resource_count) =
        (count(functions.len(), "functions"), count(types.len(), "types"), count(resources.len(), "resources"));
    let module_value = sys::an_module {
        major: sys::AN_API_MAJOR,
        minor: sys::AN_API_MINOR,
        // 80 bytes (sys asserts it).
        size: size_of::<sys::an_module>() as u32,
        name,
        load: Some(load),
        functions: functions.as_ptr(),
        function_count,
        types: if types.is_empty() { ptr::null() } else { types.as_ptr() },
        type_count,
        resources: if resources.is_empty() { ptr::null() } else { resources.as_ptr() },
        resource_count,
    };
    Built {
        module: module_value,
        strings,
        _functions: functions,
        _types: types,
        _resources: resources,
        arities,
        resource_rows: module.resources.iter().map(|r| (r.type_id, r.name.clone())).collect(),
        // The message names the text that holds a NUL with {:?}, which escapes it.
        refusal: refusal.map(|message| CString::new(message).unwrap_or_default()),
    }
}

/// The arity of a type row of `kind` from its shape, in the canonical form that the VM compares byte for byte
/// (`shape_fits` of vm/native_module.c): a struct is `name: Type` fields joined by `, ` (none for no field), an enum
/// `Name` or `Name(Type, Type)` variants joined by ` | `. None for any other text.
fn arity(kind: c_int, shape: &str) -> Option<Arity> {
    if kind == sys::AN_STRUCT {
        if shape.is_empty() {
            return Some(Arity::Struct(0));
        }
        let (mut rest, mut fields) = (shape, 0);
        loop {
            rest = shape_type(name(rest, true)?.strip_prefix(": ")?)?;
            fields += 1;
            if rest.is_empty() {
                return Some(Arity::Struct(fields));
            }
            rest = rest.strip_prefix(", ")?;
        }
    }
    let (mut rest, mut variants) = (shape, Vec::new());
    loop {
        rest = name(rest, false)?;
        let mut payloads = 0;
        if let Some(mut inner) = rest.strip_prefix('(') {
            loop {
                inner = shape_type(inner)?;
                payloads += 1;
                if let Some(after) = inner.strip_prefix(')') {
                    rest = after;
                    break;
                }
                inner = inner.strip_prefix(", ")?;
            }
        }
        variants.push(payloads);
        if rest.is_empty() {
            return Some(Arity::Enum(variants.into()));
        }
        rest = rest.strip_prefix(" | ")?;
    }
}

/// The text after the name at the start of `text`: an identifier, which for a field may end in `?` or `!`.
fn name(text: &str, field: bool) -> Option<&str> {
    let mut end = text.find(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).unwrap_or(text.len());
    if field && text[end..].starts_with(['?', '!']) {
        end += 1;
    }
    (end > 0).then(|| &text[end..])
}

/// The text after the type at the start of `text`: up to the `,`, `)` or space that ends it outside brackets, with
/// its brackets balanced (`Map[String, List[Int]]`).
fn shape_type(text: &str) -> Option<&str> {
    let mut depth = 0usize;
    for (at, c) in text.char_indices() {
        match c {
            '[' => depth += 1,
            ']' => depth = depth.checked_sub(1)?,
            '(' | '|' | ':' => return None,
            ',' | ')' | ' ' if depth == 0 => return (at > 0).then(|| &text[at..]),
            _ => {}
        }
    }
    (!text.is_empty() && depth == 0).then_some("")
}

/// The LOAD of the module, which the VM runs once after the init: the message that refuses the module when its tables
/// could not be built, else null.
unsafe extern "C" fn load() -> *const c_char {
    BUILT.get().and_then(|built| built.refusal.as_deref()).map_or(ptr::null(), CStr::as_ptr)
}

/// Defines `agentica_native_init`, the one export of the library, for the module that `$module` gives (native-gen
/// writes a function that returns the `Module`). Use it once per library.
#[macro_export]
macro_rules! export {
    ($module:expr) => {
        /// The init of the native module, which the VM calls once per run.
        ///
        /// # Safety
        ///
        /// Called by the VM only.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn agentica_native_init(
            api: *const $crate::sys::an_api,
        ) -> *const $crate::sys::an_module {
            unsafe { $crate::init(api, || $module) }
        }
    };
}
