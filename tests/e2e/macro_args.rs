fn pick<T>(a: T, b: T) -> T { if a > b { a } else { b } }
fn main() {
    let v = if 3 > 7 { 3 } else { 7 };
    println!("v={}", v);
    let x = 10;
    let y = 20;
    println!("pick={}", pick(x, y));
    let s = "hi";
    println!("greeting={} {}", s, 42);
}
