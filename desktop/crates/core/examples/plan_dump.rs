//! `cargo run -p monetshot-core --example plan_dump -- <reel> <t>...`: the
//! FramePlans of a recording as JSON (for eyeballing, and checking core-wasm).
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let p = monetshot_core::Project::load(std::path::Path::new(&args[1])).expect("load");
    let planner = monetshot_core::Planner::from_project(&p);
    let plans: Vec<_> = args[2..].iter().map(|t| planner.plan(t.parse().unwrap())).collect();
    println!("{}", serde_json::to_string(&plans).unwrap());
}
