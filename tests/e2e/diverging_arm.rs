enum Sign {
    Pos,
    Neg,
    Zero,
}

fn sign_name(s: Sign) -> &str {
    match s {
        Sign::Pos => "pos",
        Sign::Neg => "neg",
        Sign::Zero => "zero",
    }
}

fn checked(n: i32) -> i32 {
    if n > 0 { 1 } else { panic!("non-positive") }
}

fn strict(n: i32) -> i32 {
    if n > 10 {
        2
    } else if n > 0 {
        1
    } else {
        panic!("non-positive")
    }
}

fn main() {
    let p = Sign::Pos;
    let z = Sign::Zero;
    println!("{} {}", sign_name(p), sign_name(z));
    println!("ok={}", checked(5));
    println!("strict={} {}", strict(20), strict(5));
}
