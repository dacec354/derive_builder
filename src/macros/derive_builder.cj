protected macro package derive_builder.macros

import std.ast.*
import std.collection.{ArrayList, HashMap}

struct Config {
    let _attributes = ['enable_init']
    var enable_init = true

    init() {}

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
                case _ => diagReportError(expr, this.getAdvice(key),
                    "Unsupported attribute")
            }
        }
    }

    func getAdvice(name: String): String {
        let alternatives = ArrayList<String>()
        for (a in this._attributes) {
            if (this.levenshteinDistance(name, a) <= 3) {
                alternatives.add(a)
            }
        }
        match (alternatives.size) {
            case 0 => 'Unsupported attribute'
            case 1 => 'Unsupported attribute, do you mean "${alternatives[0]}"?'
            case 2 => 'Unsupported attribute, do you mean "${alternatives[0]}" or "${alternatives[1]}"?'
            case _ => 'Unsupported attribute, do you mean "${alternatives[0]}" or "${alternatives[1]}" or "${alternatives[2]}"?'
        }
    }

    func levenshteinDistance(str1: String, str2: String): Int64 {
        let size1 = str1.runes().count()
        let size2 = str2.runes().count()
        let dp = Array(size1 + 1) {
            _ => Array(size2 + 1, repeat: 0)
        }
        for (i in 0..size1) {
            dp[i][size2] = size1 - i
        }
        for (j in 0..size2) {
            dp[size1][j] = size2 - j
        }
        for (i in size1 - 1..=0 : -1) {
            for (j in size2 - 1..=0: -1) {
                let r1 = str1.runes().at(i)
                let r2 = str2.runes().at(j)
                match ((r1, r2)) {
                    case (Some(v), Some(m)) where v == m => dp[i][j] = dp[i + 1][j + 1]
                    case (Some(v), Some(m)) => 
                        dp[i][j] = 1 + min(
                            dp[i + 1][j],
                            dp[i][j + 1],
                            dp[i + 1][j + 1]
                        )
                    case _ => ()
                }
            }
        }
        dp[0][0]
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
    let varDecls = ArrayList<VarDecl>()
    for (decl in body.decls) {
        match (decl) {
            case v: VarDecl where v.modifiers.iterator().all {m => m.keyword.kind != STATIC} &&
                !(v.keyword.kind == LET && getVarDefault(v).isSome()) =>
                varDecls.add(guaranteeVarType(v))
                memberVarCount++
            case p: PrimaryCtorDecl =>
                primaryVarCount = 0
                for (param in p.funcParams) {
                    let varDecl = VarDecl()
                    varDecl.modifiers = ArrayList([Modifier(Token(PRIVATE))])
                    varDecl.keyword = param.keyword
                    varDecl.identifier = param.identifier
                    varDecl.declType = param.paramType
                    varDecls.add(varDecl)
                    primaryVarCount++
                }
            case _ => ()
        }
    }
    // 给原类/结构体添加构造函数
    if (config.enable_init) {
        if (memberVarCount != 0 || primaryVarCount == -1) {
            body.decls.add(FuncDecl(genInit(varDecls)))
        }
    }
    varDecls
        .iterator()
        .fold(Tokens()) {
            acc, i =>
            let id = Token(IDENTIFIER, "_" + i.identifier.value)
            acc + Token(NL) + match (getVarDefault(i)) {
                case None => quote(private var $(id): ?($(i.declType)) = None)
                case Some(e) => quote(private var $(id): $(i.declType) = $(e))
            }
        } + Token(NL) + genBuilderInit() + Token(NL) + genBuilderFunctions(varDecls, classId) + Token(NL) +
        genBuild(varDecls, classId)
}

func genInit(varDecls: ArrayList<VarDecl>): Tokens {
    let params = varDecls
        .iterator()
        .map {v => quote($(v.identifier)!: $(v.declType))}
        .intersperse(quote(,))
        .fold(Tokens()) {acc, i => acc + i}
    let optNewLine = if (varDecls.isEmpty()) {
        quote()
    } else {
        quote(

        )
    }
    let assigns = varDecls
        .iterator()
        .map {v => quote(this.$(v.identifier) = $(v.identifier))}
        .intersperse(quote(
        ))
        .fold(Tokens()) {acc, i => acc + i}
    quote(public init($(params)) {$(optNewLine)$(assigns)$(optNewLine)})
}

func genBuilderFunctions(varDecls: ArrayList<VarDecl>, classId: Token): Tokens {
    varDecls
        .iterator()
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

func genBuild(varDecls: ArrayList<VarDecl>, classId: Token): Tokens {
    let params = varDecls
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
    let optNewLine = if (varDecls.isEmpty()) {
        quote()
    } else {
        quote(

        )
    }
    quote(public func build(): $(classId) {
        $(classId)($(optNewLine)$(params)$(optNewLine))
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
