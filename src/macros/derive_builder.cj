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
                    case e: LitConstExpr where e.literal.kind == TokenKind.BOOL_LITERAL => this.enable_init = if (e
                        .literal
                        .value == "false") {
                        false
                    } else {
                        true
                    }
                    case _ => diagReportError(rightExpr, 'Value can only be "true" or "false"',
                        "Invalid attribute value")
                }
                case _ => diagReportError(expr, 'Unsupported attribute, do you mean "enable_init"?',
                    "Unsupported attribute")
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
                        case Some(_) => diagReportError(attr[index..nextIndex], 'Attribute can only be defined once',
                            "Duplicated attribute")
                        case None => ()
                    }
                    case e => diagReportError(attr[index..nextIndex],
                        'Expected "attr = value", found \"${e.toTokens()}\"', "Invalid attribute")
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
            case d: Decl => diagReportError(d.keyword.toTokens(), "Failed to parse class or struct",
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

func deriveBuilderBody(body: Body, classId: Token, config: Config): Tokens { // cjlint-ignore G.FUN.01
    var memberVarCount = 0
    var primaryVarCount = -1 // -1代表不存在主构造函数
    let unnamedVars = ArrayList<VarDecl>()
    let namedVars = ArrayList<VarDecl>()
    for (decl in body.decls) {
        match (decl) {
            case v: VarDecl where v.modifiers.iterator().all {m => m.keyword.kind != STATIC} &&
                !(v.keyword.kind == LET && getVarDefault(v).isSome()) =>
                unnamedVars.add(guaranteeVarType(v))
                memberVarCount++
            case p: PrimaryCtorDecl =>
                primaryVarCount = 0
                for (param in p.funcParams) {
                    let varDecl = VarDecl()
                    varDecl.modifiers = ArrayList([Modifier(Token(PRIVATE))])
                    varDecl.keyword = param.keyword
                    varDecl.identifier = param.identifier
                    varDecl.declType = param.paramType
                    if (param |> isNamedParam) {
                        namedVars.add(varDecl)
                    } else {
                        unnamedVars.add(varDecl)
                    }
                    primaryVarCount++
                }
            case _ => ()
        }
    }
    // 给原类/结构体添加构造函数
    if (config.enable_init) {
        if (memberVarCount != 0 || primaryVarCount == -1) {
            body.decls.add(FuncDecl(genInit(unnamedVars, namedVars)))
        }
    }
    unnamedVars
        .iterator()
        .concat(namedVars.iterator())
        .fold(Tokens()) {
            acc, i =>
            let id = Token(IDENTIFIER, "_" + i.identifier.value)
            acc + Token(NL) + match (getVarDefault(i)) {
                case None => quote(private var $(id): ?($(i.declType)) = None)
                case Some(e) => quote(private var $(id): $(i.declType) = $(e))
            }
        } + Token(NL) + genBuilderInit() + Token(NL) + genBuilderFunctions(unnamedVars, namedVars, classId) + Token(NL) +
        genBuild(unnamedVars, namedVars, classId)
}

func genInit(unnamedVars: ArrayList<VarDecl>, namedVars: ArrayList<VarDecl>): Tokens {
    let unnamedParams = unnamedVars
        .iterator()
        .map {v => quote($(v.identifier): $(v.declType))}
        .intersperse(quote(,))
        .fold(Tokens()) {acc, i => acc + i}
    let namedParams = namedVars
        .iterator()
        .map {v => quote($(v.identifier)!: $(v.declType))}
        .intersperse(quote(,))
        .fold(Tokens()) {acc, i => acc + i}
    let optComma = if (!namedVars.isEmpty() && !unnamedVars.isEmpty()) {
        quote(,)
    } else {
        quote()
    }
    let optNewLine = if (namedVars.isEmpty() && unnamedVars.isEmpty()) {
        quote()
    } else {
        quote(

        )
    }
    let assigns = unnamedVars
        .iterator()
        .concat(namedVars.iterator())
        .map {v => quote(this.$(v.identifier) = $(v.identifier))}
        .intersperse(quote(
        ))
        .fold(Tokens()) {acc, i => acc + i}
    quote(public init($(unnamedParams)$(optComma)$(namedParams)) {$(optNewLine)$(assigns)$(optNewLine)})
}

func genBuilderFunctions(unnamedVars: ArrayList<VarDecl>, namedVars: ArrayList<VarDecl>, classId: Token): Tokens {
    unnamedVars
        .iterator()
        .concat(namedVars.iterator())
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

func genBuild(unnamedVars: ArrayList<VarDecl>, namedVars: ArrayList<VarDecl>, classId: Token): Tokens {
    let unnamedParams = unnamedVars
        .iterator()
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
    let namedParams = namedVars
        .iterator()
        .map {
            v =>
            let id = Token(IDENTIFIER, "_" + v.identifier.value)
            let errorMsg = "Field ${v.identifier.value} is not set"
            quote($(v.identifier): ) + match (getVarDefault(v)) {
                case None => quote(this.$(id) ?? throw IllegalStateException($(errorMsg)))
                case Some(_) => quote(this.$(id))
            }
        }
        .intersperse(quote(,
        ))
        .fold(Tokens()) {acc, i => acc + i}
    let optLineBreak = if (!unnamedVars.isEmpty() && !namedVars.isEmpty()) {
        quote(,
        )
    } else {
        quote()
    }
    quote(public func build(): $(classId) {
        $(classId)($(unnamedParams)$(optLineBreak)$(namedParams))
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
        diagReportError(vardecl.toTokens(), "Type declaration not found",
            "Variable declaration must have type declaration")
    }
}

func diagReportError<T>(node: T, message: String, hint: String): Nothing where T <: ToTokens {
    diagReport(DiagReportLevel.ERROR, node.toTokens(), message, hint)
    throw ASTException(hint)
}

func diagReportError<T>(node: T, message: String, hint: String, errorMessage: String): Nothing where T <: ToTokens {
    diagReport(DiagReportLevel.ERROR, node.toTokens(), message, hint)
    throw ASTException(errorMessage)
}

func isNamedParam(param: FuncParam): Bool {
    match (param.not.kind) {
        case ILLEGAL => false
        case _ => true
    }
}
