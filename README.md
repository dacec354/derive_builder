# Derive Builder

`Derive Builder` 是一个用于自动生成构建器模式的宏库。它允许开发者通过简单的注解自动生成构建器类，从而简化对象的创建过程。构建器模式特别适用于需要创建具有多个可选参数的复杂对象的场景。

## 使用方法

### 1. 定义类或结构体

首先，定义一个类或结构体，并使用 `@DeriveBuilder` 宏注解。

```cj
@DeriveBuilder
class Hello {
    let a: Int64
    let b:?String
    let c: Float64 = 1.0
    var d: Rune = r'1'
    var e: Bool
    static var f: UInt64 = 1
}
```

### 2. 使用构建器

宏会自动生成一个构建器类，你可以使用这个构建器来创建类的实例。

```cj
let instance = HelloBuilder()
    .a(42)
    .b("Hello")
    .d(r'2')
    .e(true)
    .build()
```

### 3. 处理未设置的字段

如果某个必填字段未设置，构建器会在调用 `build()` 方法时抛出 `IllegalStateException` 异常。

```cj
let instance = HelloBuilder()
    .a(42)
    .d(r'2')
    .e(true)
    .build()  // 抛出 IllegalStateException("Field b is not set")
```

## 特性
- @DeriveBuilder会自动为被修饰的类或结构体生成一个包括所有成员变量的构造函数，以下满足以下条件的成员变量除外
    - 不可变带默认值的变量 `let a: XX = xx`
    - 静态变量 `static var a: XX = xx`
- 生成的构造器类的命名规则为`<类名>Builder`，例如 `HelloBuilder`。
- 生成的构造器类的访问修饰符和原类一致。`public class Hello` -> `public class HelloBuilder`
- 使用`<变量名称>(<值>)`设置变量值。`XXBuilder().name("13").build()`
- 未赋值的变量在调用`build`时会抛出 `IllegalStateException` 异常。
- 带默认值的变量在构建时默认值会被使用。

## 宏展开示例
代码：
```cj
@DeriveBuilder
protected class Hello {
    let name: String
    let age: Int = 1
    let is_admin: Bool
    var desc: ?String = "234"
    let op: ??Int64
    static let s: Int64 = 1
}
```
宏展开：
```cj
protected class Hello {
    let name: String
    let age: Int = 1
    let is_admin: Bool
    var desc:?String = "234"
    let op:??Int64
    static let s: Int64 = 1
    public init(name: String, is_admin: Bool, desc:?String, op:??Int64) {
        this.name = name
        this.is_admin = is_admin
        this.desc = desc
        this.op = op
    }
}

protected class HelloBuilder {
    
    private var _name:?(String) = None
    private var _is_admin:?(Bool) = None
    private var _desc:?String = "234"
    private var _op:?(??Int64) = None
    public init() { }
    
    public func name(value: String): HelloBuilder {
        this._name = value
        this
    }
    public func is_admin(value: Bool): HelloBuilder {
        this._is_admin = value
        this
    }
    public func desc(value:?String): HelloBuilder {
        this._desc = value
        this
    }
    public func op(value:??Int64): HelloBuilder {
        this._op = value
        this
    }
    public func build(): Hello {
        Hello(this._name??throw IllegalStateException("Field name is not set"),
        this._is_admin??throw IllegalStateException("Field is_admin is not set"),
        this._desc,
        this._op??throw IllegalStateException("Field op is not set"))
    }
}

```

## 贡献

欢迎贡献代码、报告问题或提出改进建议。请遵循项目的代码风格和贡献指南。

## 许可证

本项目采用 MIT 许可证。详情请参阅 [LICENSE](LICENSE) 文件。