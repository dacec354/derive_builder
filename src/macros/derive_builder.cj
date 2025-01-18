protected macro package derive_builder.macros

import std.ast.*
import std.collection.{ArrayList, HashMap, collectArray, fold}

struct Config {
    var enable_init = true

    init() {}

    // TODO: 用编辑距离提示用户可能的选项，无选项时直接报错
    init(attr: Tokens) {
        for ((key, (expr, rightExpr)) in parseCommaSeparatedAttrs(attr)) {
            match (key) {
                case "enable_init" => match (rightExpr) {
                    case e: LitConstExpr where e.literal.kind == TokenKind.BOOL_LITERAL => 
                        this.enable_init = if (e.literal.value == "false") {false} else {true}
                    case _ => 
                        diagReportError(rightExpr, 'Value can only be "true" or "false"', "Invalid attribute value")
                }
                case _ =>
                    diagReportError(expr, 'Unsupported attribute, do you mean "enable_init"?', "Unsupported attribute")
            }
        }
    }

    static func parseCommaSeparatedAttrs(attr: Tokens): HashMap<String, (AssignExpr, Expr)> {
        let table = HashMap<String, (AssignExpr, Expr)>()
        var index = 0
        while (true) {
            try {
                let (expr, nextIndex) = parseExprFragment(attr, startFrom: index) // throws ParseASTException
                match (expr) { // cjlint-ignore !G.EXP.01
                    case a: AssignExpr where a.leftExpr.toTokens().size == 1 => match (table.add(
                        a.leftExpr.toTokens()[0].value, (a, a.rightExpr))) {
                        case Some(_) =>
                            diagReportError(attr[index..nextIndex], 'Attribute can only be defined once', "Duplicated attribute")
                        case None => ()
                    }
                    case e =>
                        diagReportError(attr[index..nextIndex], 'Expected "attr = value", found \"${e.toTokens()}\"', "Invalid attribute")
                }
                if (nextIndex >= attr.size) {
                    break
                }
                if (attr[nextIndex].kind != TokenKind.COMMA) {
                    diagReportError(attr[nextIndex..nextIndex + 1], "Expected \",\", found \"${attr[nextIndex].value}\"",
                        "Input must be a comma-separated list of assign expressions")
                }
                if (nextIndex == attr.size - 1) {
                    diagReportError(attr[nextIndex..nextIndex + 1], "Expected expression after \",\"",
                        "Input does not allow trailing comma")
                }
                index = nextIndex + 1
            } catch (_: ParseASTException) {
                diagReportError(attr[index..], 'Expected "attr = value", found \"${attr[index..]}\"',
                    "Invalid attribute")
            }
        }
        table
    }
}

public macro DeriveBuilder(input: Tokens): Tokens {
    deriveBuilderImpl(input)
}

public macro DeriveBuilder(attr: Tokens, input: Tokens): Tokens {
    deriveBuilderImpl(input, config: Config(attr))
}

func deriveBuilderImpl(input: Tokens, config!: Config = Config()): Tokens {
    try {
        match (parseDecl(input)) {
            case d: StructDecl => deriveBuilderStruct(d, config)
            case d: ClassDecl => deriveBuilderClass(d, config)
            case d: Decl =>
                diagReportError(d.keyword.toTokens(), "Failed to parse class or struct",
                    "Expect a class or struct, found ${d.keyword.value}")
        }
    } catch (e: ParseASTException) {
        diagReportError(input[0..1], "Failed to parse class or struct", "Expect a class or struct")
    }
}

func deriveBuilderStruct(decl: StructDecl, config: Config): Tokens {
    let builderId = Token(IDENTIFIER, decl.identifier.value + "Builder")
    let builderModifiers = decl.modifiers
    let body = deriveBuilderBody(decl.body, decl.identifier, config)
    quote($(decl)
    $(builderModifiers) class $(builderId) {
    $(body)
})
}

func deriveBuilderClass(decl: ClassDecl, config: Config): Tokens {
    let builderId = Token(IDENTIFIER, decl.identifier.value + "Builder")
    let builderModifiers = decl.modifiers
    let body = deriveBuilderBody(decl.body, decl.identifier, config)
    quote($(decl)
    $(builderModifiers) class $(builderId) {
    $(body)
})
}

func deriveBuilderBody(body: Body, classId: Token, config: Config): Tokens {
    let memberVars = ArrayList<VarDecl>()
    let primaryVars = ArrayList<VarDecl>()
    for (decl in body.decls) {
        match (decl) {
            case v: VarDecl where v.modifiers.iterator().all {m => m.keyword.kind != STATIC} &&
                !(v.keyword.kind == LET && getVarDefault(v).isSome()) => memberVars.add(guaranteeVarType(v))
            case p: PrimaryCtorDecl => for (param in p.funcParams) {
                let varDecl = VarDecl()
                varDecl.modifiers = ArrayList([Modifier(Token(PRIVATE))])
                varDecl.keyword = param.keyword
                varDecl.identifier = param.identifier
                varDecl.declType = param.paramType
                primaryVars.add(varDecl)
            }
            case _ => ()
        }
    }
    // 给原类/结构体添加构造函数
    if (config.enable_init) {
        if (!memberVars.isEmpty() || primaryVars.isEmpty()) {
            body.decls.add(FuncDecl(genInit(memberVars, primaryVars)))
        }
    }
    memberVars
        .iterator()
        .concat(primaryVars.iterator())
        .fold(Tokens()) {
            acc, i =>
            let id = Token(IDENTIFIER, "_" + i.identifier.value)
            acc + Token(NL) + match (getVarDefault(i)) {
                case None => quote(private var $(id): ?($(i.declType)) = None)
                case Some(e) => quote(private var $(id): $(i.declType) = $(e))
            }
        } + Token(NL) + genBuilderInit() + Token(NL) + genBuilderFunctions(memberVars, primaryVars, classId) + Token(NL) +
        genBuild(memberVars, primaryVars, classId)
}

func genInit(memberVars: ArrayList<VarDecl>, primaryVars: ArrayList<VarDecl>): Tokens {
    let params = memberVars
        .iterator()
        .concat(primaryVars.iterator())
        .map {v => quote($(v.identifier): $(v.declType))}
        .intersperse(quote(,))
        .fold(Tokens()) {acc, i => acc + i}
    let assigns = memberVars
        .iterator()
        .concat(primaryVars.iterator())
        .map {v => quote(this.$(v.identifier) = $(v.identifier))}
        .intersperse(quote(
        ))
        .fold(Tokens()) {acc, i => acc + i}
    quote(public init($(params)) {$(assigns)})
}

func genBuilderFunctions(memberVars: ArrayList<VarDecl>, primaryVars: ArrayList<VarDecl>, classId: Token): Tokens {
    memberVars
        .iterator()
        .concat(primaryVars.iterator())
        .fold(Tokens()) {
            acc, i =>
            let id = Token(IDENTIFIER, "_" + i.identifier.value)
            let builderId = Token(IDENTIFIER, classId.value + "Builder")
            acc + quote(
                public func $(i.identifier)(value: $(i.declType)): $(builderId) {
                this.$(id) = value
                this
            })
        }
}

func genBuild(memberVars: ArrayList<VarDecl>, primaryVars: ArrayList<VarDecl>, classId: Token): Tokens {
    let params = memberVars
        .iterator()
        .concat(primaryVars.iterator())
        .map {
            v =>
            let id = Token(IDENTIFIER, "_" + v.identifier.value)
            let errorMsg = "Field ${v.identifier.value} is not set"
            match (getVarDefault(v)) {
                case None => quote(this.$(id) ?? throw IllegalStateException($(errorMsg)))
                case Some(_) => quote(this.$(id))
            }
        }
        .intersperse(quote(,
        ))
        .fold(Tokens()) {acc, i => acc + i}
    quote(public func build(): $(classId) {
        $(classId)($(params))
    })
}

func genBuilderInit(): Tokens {
    quote(public init() {})
}

func getVarDefault(varDecl: VarDecl): ?Expr {
    try {
        varDecl.expr
    } catch (_) {
        None
    }
}

func guaranteeVarType(vardecl: VarDecl): VarDecl {
    try {
        vardecl.declType
        vardecl
    } catch (_) {
        diagReport(DiagReportLevel.ERROR, vardecl.toTokens(), "Type declaration not found",
            "Variable declaration must have type declaration")
        throw ASTException("Type declaration not found")
    }
}


func diagReportError<T>(node: T, message: String, hint: String): Nothing where T <: ToTokens{
    diagReport(DiagReportLevel.ERROR, node.toTokens(), message, hint)
    throw ASTException(hint)
}

func diagReportError<T>(node: T, message: String, hint: String, errorMessage: String): Nothing where T <: ToTokens {
    diagReport(DiagReportLevel.ERROR, node.toTokens(), message, hint)
    throw ASTException(errorMessage)
}