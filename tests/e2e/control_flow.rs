fn classify(n: i32) -> i32 {
    if n > 0 { 1 } else if n < 0 { -1 } else { 0 }
}
fn main() {
    let mut i = 0;
    let mut acc = 0;
    while i < 5 {
        let t = i * i;
        acc = acc + t;
        i = i + 1;
    }
    println!("acc={}", acc);
    for k in 0..4 {
        let d = k * 2;
        acc = acc + d;
    }
    println!("total={}", acc);
    println!("signs={}{}{}", classify(5), classify(-5), classify(0));
}
