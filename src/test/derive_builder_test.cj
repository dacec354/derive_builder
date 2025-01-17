protected package derive_builder.test

import derive_builder.macros.DeriveBuilder
import std.unittest.*
import std.unittest.testmacro.*

@DeriveBuilder
class A {
    let a: Int64
    let b: ?String
    let c: Float64 = 1.0
    var d: Rune = r'1'
    var e: Bool
    static var f: UInt64 = 1
}

@DeriveBuilder
struct B {
    public B(let a: Int64, public let b: String, protected var c: Float64) {}
}

@DeriveBuilder
struct C {
    let a: Int64 = 1
    let b: String = "1343"
    public C(let c: ?String, let d: ?String) {}
}

@DeriveBuilder[enable_init = false]
struct D {
    let a: Int64
    let b: ?String
    let c: Float64 = 1.0

    public init(a: Int64, b: ?String) {
        this.a = a
        this.b = b
    }
}

@DeriveBuilder
class E {
    E(let a: Int64, let b: String, let c!: Float64) {}
}

@Test
class DeriveBuilderTests {
    @TestCase
    func testMemberVarDecl(): Unit {
        let a = ABuilder()
            .a(1)
            .b(None)
            .d(r'3')
            .e(true)
            .build();
        @Expect(a.a, 1)
        @Expect(a.b, None)
        @Expect(a.c, 1.0)
        @Expect(a.d, r'3')
        @Expect(a.e, true)
        @Expect(A.f, 1)
    }

    @TestCase
    func testPrimaryVarDecl(): Unit {
        let b = BBuilder()
            .a(1)
            .b("2")
            .c(3.0)
            .build()
        @Expect(b.a, 1)
        @Expect(b.b, "2")
        @Expect(b.c, 3.0)
    }

    @TestCase
    func testMixedVarDecl(): Unit {
        let c = CBuilder()
            .c("1")
            .d("2")
            .build()
        @Expect(c.a, 1)
        @Expect(c.b, "1343")
        @Expect(c.c, "1")
        @Expect(c.d, "2")
    }

    @TestCase
    func testNoInit(): Unit {
        let d = DBuilder()
            .a(1)
            .b("2")
            .build()
        @Expect(d.a, 1)
        @Expect(d.b, "2")
    }

    @TestCase
    func testNamedParamVarDecl(): Unit {
        let e = EBuilder()
            .a(1)
            .b("2")
            .c(3.0)
            .build()
        @Expect(e.a, 1)
        @Expect(e.b, "2")
        @Expect(e.c, 3.0)
    }
}