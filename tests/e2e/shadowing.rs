fn main() {
    let x = 1;
    {
        let x = 2;
        println!("inner={}", x);
    }
    println!("outer={}", x);
    let y = if x > 0 { "pos" } else { "neg" };
    println!("sign={}", y);
}
