protected macro package derive_builder.macros

import std.ast.*
import std.collection.{ArrayList, collectArray, fold}

public macro DeriveBuilder(input: Tokens): Tokens {
    deriveBuilderImpl(input)
}

func deriveBuilderImpl(input: Tokens): Tokens {
    try {
        match (parseDecl(input)) {
            case d: StructDecl => deriveBuilderStruct(d)
            case d: ClassDecl => deriveBuilderClass(d)
            case d: Decl =>
                diagReport(DiagReportLevel.ERROR, d.keyword.toTokens(), "Failed to parse class or struct",
                    "Expect a class or struct, found ${d.keyword.value}")
                throw ASTException("Failed to parse class or struct")
        }
    } catch (e: ParseASTException) {
        diagReport(DiagReportLevel.ERROR, input[0..1], "Failed to parse class or struct", "Expect a class or struct")
        throw ASTException("Failed to parse class or struct")
    }
}

func deriveBuilderStruct(decl: StructDecl): Tokens {
    let builderId = Token(IDENTIFIER, decl.identifier.value + "Builder")
    let builderModifiers = decl.modifiers
    let body = deriveBuilderBody(decl.body, decl.identifier)
    quote($(decl)
    $(builderModifiers) class $(builderId) {
    $(body)
})
}

func deriveBuilderClass(decl: ClassDecl): Tokens {
    let builderId = Token(IDENTIFIER, decl.identifier.value + "Builder")
    let builderModifiers = decl.modifiers
    let body = deriveBuilderBody(decl.body, decl.identifier)
    quote($(decl)
    $(builderModifiers) class $(builderId) {
    $(body)
})
}

func deriveBuilderBody(body: Body, classId: Token): Tokens {
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
    if (!memberVars.isEmpty() || primaryVars.isEmpty()) {
        body.decls.add(FuncDecl(genInit(memberVars, primaryVars)))
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
