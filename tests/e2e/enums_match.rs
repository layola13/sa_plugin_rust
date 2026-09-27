enum Shape { Circle(i32), Rect(i32, i32), Empty }

fn area(s: &Shape) -> i32 {
    match s {
        Shape::Circle(r) => 3 * r,
        Shape::Rect(w, h) => w * h,
        Shape::Empty => 0,
    }
}

fn main() {
    let c = Shape::Circle(4);
    let r = Shape::Rect(3, 5);
    let e = Shape::Empty;
    println!("areas={},{},{}", area(&c), area(&r), area(&e));
}
