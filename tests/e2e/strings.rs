struct Tag {
    label: &str,
    rank: i32,
}

enum Size {
    Empty,
    Small,
    Big,
}

fn banner(s: &str) -> &str {
    if s.len() == 0 { "empty" } else if s.len() > 4 { "long" } else { "short" }
}

fn size_name(s: Size) -> &str {
    match s {
        Size::Empty => "empty",
        Size::Small => "small",
        _ => "big",
    }
}

fn main() {
    let a = "hi";
    println!("a={} n={} empty={}", a, a.len(), a.is_empty());

    let b = if a.len() > 1 { "bigger" } else { "small" };
    println!("b={} n={}", b, b.len());

    let t = Tag { label: "tag", rank: 7 };
    println!("t={} {} n={}", t.label, t.rank, t.label.len());

    println!("{} {} {}", banner("ab"), banner("hello"), banner(""));

    let e = Size::Empty;
    let m = Size::Small;
    let l = Size::Big;
    println!("{} {} {}", size_name(e), size_name(m), size_name(l));

    // The same string printed twice must still be intact.
    println!("{a} {a}");

    let empty = "";
    println!("e=[{}] n={} empty={}", empty, empty.len(), empty.is_empty());
}
