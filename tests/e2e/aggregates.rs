struct Point { x: i32, y: i32 }
struct Pair<T> { a: T, b: T }
fn sum_pair<T>(p: Pair<T>) -> T { p.a + p.b }
fn shift(p: Point) -> Point { Point { x: p.x + 1, y: p.y + 1 } }
fn main() {
    let p = Point { x: 1, y: 2 };
    let q = shift(p);
    println!("shifted={},{}", q.x, q.y);
    let s = Pair { a: 3, b: 4 };
    println!("pair={}", sum_pair(s));
    let f = Pair { a: 1.5, b: 2.5 };
    println!("fpair={}", sum_pair(f));
}
