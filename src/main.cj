package derive_builder

import derive_builder.macros.DeriveBuilder

// public class A {
//     static let a: Int64
// }

@DeriveBuilder
protected class Hello {
    let name: String
    let age: Int = 1
    let is_admin: Bool
    let desc: ?String = "234"
    let op: ??Int64
    static let s: Int64 = 1
}

main(): Unit {
    let h = HelloBuilder()
        .name("John")
        // .age(30)
        .is_admin(true)
        // .desc("Hello, world!")
        .op(1)
        .build()
    println(h.name)
    println(h.age)
    println(h.is_admin)
    println(h.desc)
    println(h.op)
}
