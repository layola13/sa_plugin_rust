struct Point {
    x: i32,
    y: i32,
}

struct Partial {
    a: i32,
    b: i32,
    c: i32,
}

const LIMIT: i32 = 10;

fn bucket(n: i32) -> &str {
    match n {
        0 => "zero",
        1 | 2 | 3 => "small",
        4..=9 => "mid",
        10 => "ten",
        x if x > LIMIT => "over",
        _ => "other",
    }
}

fn double(n: i32) -> i32 {
    match n {
        x => x * 2,
    }
}

fn main() {
    let (a, b) = (2, 5);
    println!("sum={}", a + b);

    let (t, u, v) = (10, 20, 30);
    println!("t={} u={} v={}", t, u, v);

    let p = Point { x: 3, y: 4 };
    let Point { x, y } = p;
    println!("x={} y={}", x, y);

    let q = Partial { a: 1, b: 2, c: 3 };
    let Partial { a, c, .. } = q;
    println!("a={} c={}", a, c);

    println!("{} {} {}", bucket(0), bucket(2), bucket(5));
    println!("{} {} {}", bucket(10), bucket(11), bucket(-1));
    println!("d={}", double(21));

    // 3_000_000_000 is above MAX_INT: a signed comparison would say "out of range".
    println!("u={} {}", in_range_u(3), in_range_u(3_000_000_000));
    println!("b={} {} {} {}", boundaries(-2), boundaries(0), boundaries(1), boundaries(99));
    println!("o={} {}", or_chain(8), or_chain(7_000_000_000));

    // The extremes of i64, as both patterns and arguments.
    println!("i={} {} {} {}", int_bounds(-9223372036854775808), int_bounds(9223372036854775807), int_bounds(0), int_bounds(-1));
}

fn in_range_u(n: u32) -> i32 {
    match n {
        1..=5 => 1,
        _ => 0,
    }
}

fn boundaries(n: i32) -> i32 {
    match n {
        -2..=-1 => 10,
        0 => 20,
        1..=2 => 30,
        _ => 40,
    }
}

fn or_chain(n: i32) -> i32 {
    match n {
        7 | 8 | 9 => 1,
        _ => 0,
    }
}

fn int_bounds(n: i64) -> i64 {
    match n {
        -9223372036854775808 => 1,
        9223372036854775807 => 2,
        0 => 3,
        -1 => 4,
        _ => 0,
    }
}
