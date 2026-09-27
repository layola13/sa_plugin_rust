struct Counter { n: i32 }
impl Counter {
    fn new() -> Counter { Counter { n: 0 } }
    fn bump(&mut self) { self.n = self.n + 1; }
    fn get(&self) -> i32 { self.n }
}
fn main() {
    let mut c = Counter::new();
    c.bump();
    c.bump();
    c.bump();
    println!("count={}", c.get());
}
