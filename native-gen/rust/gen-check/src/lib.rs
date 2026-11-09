//! The modules of the fixtures stats, shapes and kinds, each on the Rust file that native-gen makes from its `.agc`
//! (run.sh makes them, and builds one feature at a time).

#[cfg(feature = "stats")]
#[rustfmt::skip]
mod stats_native;

/// stats: a struct in an Optional, and a CSV text read into rows of typed cells.
#[cfg(feature = "stats")]
mod stats {
    use agentica_native::{Env, Raise};

    use crate::stats_native::{Cell, StatsNative, Summary, module};

    struct Stats;

    impl StatsNative for Stats {
        fn summary(_env: Env<'_>, values: Vec<f64>) -> Result<Option<Summary>, Raise> {
            if values.is_empty() {
                return Ok(None);
            }
            let min = values.iter().copied().fold(f64::INFINITY, f64::min);
            let max = values.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            let mean = values.iter().sum::<f64>() / values.len() as f64;
            Ok(Some(Summary { count: values.len() as i64, min, max, mean }))
        }

        // The signature of the trait, nested as the .agc's type is.
        #[allow(clippy::type_complexity)]
        fn rows(_env: Env<'_>, text: String) -> Result<Result<Vec<Vec<(String, Cell)>>, String>, Raise> {
            let mut lines = text.lines();
            let names: Vec<&str> = lines.next().unwrap_or("").split(',').collect();
            let mut rows = Vec::new();
            for line in lines {
                let cells: Vec<&str> = line.split(',').collect();
                if cells.len() != names.len() {
                    return Ok(Err("a row has another number of cells".to_string()));
                }
                rows.push(names.iter().zip(cells).map(|(name, text)| (name.to_string(), cell(text))).collect());
            }
            Ok(Ok(rows))
        }
    }

    fn cell(text: &str) -> Cell {
        match text.parse::<f64>() {
            _ if text.is_empty() => Cell::Empty,
            Ok(x) => Cell::Number(x),
            Err(_) => Cell::Text(text.to_string()),
        }
    }

    agentica_native::export!(module::<Stats>());
}

#[cfg(feature = "shapes")]
#[rustfmt::skip]
mod shapes_native;

/// shapes: each value comes back through its Rust value; a Tree is read again, node by node, from its terms.
#[cfg(feature = "shapes")]
mod shapes {
    use agentica_native::{Encoder, Env, Raise};

    use crate::shapes_native::{Label, Point, Shape, ShapesNative, Tree, TreeTerm, module};

    struct Shapes;

    /// The functions that only a run with an argument calls, to test the C header's reads of bad values.
    fn not_here<T>() -> Result<T, Raise> {
        Err(Raise::new("not in the Rust check"))
    }

    fn again<'a>(env: Env<'a>, tree: TreeTerm<'a>) -> Result<TreeTerm<'a>, Raise> {
        let tree: Tree = tree.0.decode()?;
        Ok(TreeTerm(Shapes::echo_tree(env, tree)?.encode(env)))
    }

    impl ShapesNative for Shapes {
        fn echo_point(_env: Env<'_>, value: Point) -> Result<Point, Raise> {
            Ok(value)
        }

        fn echo_label(_env: Env<'_>, value: Label) -> Result<Label, Raise> {
            Ok(value)
        }

        fn echo_shape(_env: Env<'_>, value: Shape) -> Result<Shape, Raise> {
            Ok(value)
        }

        fn echo_tree<'a>(env: Env<'a>, value: Tree<'a>) -> Result<Tree<'a>, Raise> {
            Ok(match value {
                Tree::Leaf(n) => Tree::Leaf(n),
                Tree::Node(left, right) => Tree::Node(again(env, left)?, again(env, right)?),
            })
        }

        fn circle(_env: Env<'_>, x: i64, y: i64, radius: f64) -> Result<Shape, Raise> {
            Ok(Shape::Circle(Point { x, y }, radius))
        }

        fn misread(_env: Env<'_>, _value: Point, _values: Vec<i64>) -> Result<Point, Raise> {
            not_here()
        }

        fn misread_nested(_env: Env<'_>, _value: Label) -> Result<Label, Raise> {
            not_here()
        }

        fn misread_payload(_env: Env<'_>, _value: Shape) -> Result<Shape, Raise> {
            not_here()
        }

        fn bad_label(_env: Env<'_>, _value: Label) -> Result<Label, Raise> {
            not_here()
        }
    }

    agentica_native::export!(module::<Shapes>());
}

#[cfg(feature = "kinds")]
#[rustfmt::skip]
mod kinds_native;

/// kinds: every kind of argument, the names native-gen changes, a compute def and a resource.
#[cfg(feature = "kinds")]
mod kinds {
    use std::sync::atomic::{AtomicI64, Ordering};

    use agentica_native::{Env, Raise, ResourceArc};

    use crate::kinds_native::{KindsNative, Point, Shape, module};

    struct Kinds;

    impl KindsNative for Kinds {
        type Counter = AtomicI64;

        fn counter(_env: Env<'_>, start: i64) -> Result<ResourceArc<AtomicI64>, Raise> {
            Ok(ResourceArc::new(AtomicI64::new(start)))
        }

        fn bump_bang(_env: Env<'_>, counter: ResourceArc<AtomicI64>, step: i64) -> Result<i64, Raise> {
            Ok(counter.fetch_add(step, Ordering::SeqCst) + step)
        }

        fn describe(_env: Env<'_>, n: i64, x: f64, flag: bool, text: String, data: Vec<u8>) -> Result<String, Raise> {
            let last = data.last().map_or(-1, |&b| i64::from(b));
            Ok(format!("{n} {x} {flag} {text} ({} bytes, last {last})", data.len()))
        }

        fn empty_p(_env: Env<'_>, text: String) -> Result<bool, Raise> {
            Ok(text.is_empty())
        }

        fn keywords(
            _env: Env<'_>,
            int: i64,
            env_: String,
            class: bool,
            size_t: i64,
            an_term: i64,
        ) -> Result<String, Raise> {
            Ok(format!("{int} {env_} {} {size_t} {an_term}", i64::from(class)))
        }

        fn nothing(_env: Env<'_>) -> Result<(), Raise> {
            Ok(())
        }

        fn total(_env: Env<'_>, values: Vec<i64>) -> Result<i64, Raise> {
            Ok(values.iter().sum())
        }

        fn oks(_env: Env<'_>, results: Vec<Result<(), String>>) -> Result<i64, Raise> {
            Ok(results.iter().filter(|result| result.is_ok()).count() as i64)
        }

        fn corner(_env: Env<'_>, shape: Shape) -> Result<Option<Point>, Raise> {
            Ok(match shape {
                Shape::Dot => None,
                Shape::Circle(center, _) => Some(center),
            })
        }
    }

    agentica_native::export!(module::<Kinds>());
}

#[cfg(feature = "shapes2")]
#[rustfmt::skip]
mod shapes2_native;

/// shapes2: the recursive and borrowing types, Maps of Int and Bytes keys, resources in results, and the names clippy
/// would flag.
#[cfg(feature = "shapes2")]
mod shapes2 {
    use agentica_native::{Encoder, Env, Raise, ResourceArc};

    use crate::shapes2_native::{Call, Color, Expr, HTTP, Node, NodeTerm, Shapes2Native, Unit, module};

    struct Shapes2;

    /// The values of the chain at `node`, each node read from the term of the one before.
    fn sum(node: Node<'_>) -> Result<i64, Raise> {
        let rest = match node.next {
            Some(next) => sum(next.0.decode()?)?,
            None => 0,
        };
        Ok(node.value + rest)
    }

    /// An Int, or the sum of the arguments of a Call, each read from its term.
    fn value(expr: Expr<'_>) -> Result<i64, Raise> {
        match expr {
            Expr::Num(n) => Ok(n),
            Expr::Apply(call) => {
                let call: Call = call.0.decode()?;
                call.args.into_iter().map(|arg| value(arg.0.decode()?)).sum()
            }
        }
    }

    impl Shapes2Native for Shapes2 {
        type Handle = i64;

        fn chain<'a>(env: Env<'a>, n: i64) -> Result<Node<'a>, Raise> {
            let mut node = Node { value: 1.min(n), next: None };
            for value in 2..=n {
                node = Node { value, next: Some(NodeTerm(node.encode(env))) };
            }
            Ok(node)
        }

        fn total<'a>(_env: Env<'a>, node: Node<'a>) -> Result<i64, Raise> {
            sum(node)
        }

        fn eval<'a>(_env: Env<'a>, expr: Expr<'a>) -> Result<i64, Raise> {
            value(expr)
        }

        fn lengths(_env: Env<'_>, words: Vec<(i64, String)>) -> Result<Vec<(i64, i64)>, Raise> {
            Ok(words.into_iter().map(|(k, word)| (k, word.len() as i64)).collect())
        }

        fn sizes(_env: Env<'_>, blobs: Vec<(Vec<u8>, i64)>) -> Result<i64, Raise> {
            Ok(blobs.iter().map(|(key, n)| key.len() as i64 + n).sum())
        }

        fn handles(_env: Env<'_>, n: i64) -> Result<Vec<ResourceArc<i64>>, Raise> {
            Ok((0..n).map(ResourceArc::new).collect())
        }

        fn maybe(_env: Env<'_>, n: i64) -> Result<Option<ResourceArc<i64>>, Raise> {
            Ok((n > 0).then(|| ResourceArc::new(n)))
        }

        fn handle_id(_env: Env<'_>, handle: ResourceArc<i64>) -> Result<i64, Raise> {
            Ok(*handle)
        }

        fn unit(_env: Env<'_>, u: Unit) -> Result<Unit, Raise> {
            Ok(u)
        }

        fn colors(_env: Env<'_>, color: Color) -> Result<Color, Raise> {
            Ok(match color {
                Color::RedColor => Color::BlueColor,
                Color::BlueColor => Color::RedColor,
            })
        }

        fn http(_env: Env<'_>, value: HTTP) -> Result<HTTP, Raise> {
            Ok(value)
        }

        // The signature of the trait: seven Ints and the env.
        #[allow(clippy::too_many_arguments)]
        fn seven(_env: Env<'_>, a: i64, b: i64, c: i64, d: i64, e: i64, f: i64, g: i64) -> Result<i64, Raise> {
            Ok(a + b + c + d + e + f + g)
        }
    }

    agentica_native::export!(module::<Shapes2>());
}
