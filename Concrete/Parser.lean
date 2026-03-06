import Concrete.Token
import Concrete.AST
import Concrete.Lexer

namespace Concrete

structure ParserState where
  tokens : Array Token
  pos : Nat
  deriving Repr, Inhabited

abbrev ParseM := ExceptT String (StateM ParserState)

instance : Inhabited (ParseM α) := ⟨throw "uninhabited"⟩

def mkParserState (tokens : List Token) : ParserState :=
  { tokens := tokens.toArray, pos := 0 }

def peek : ParseM TokenKind := do
  let s ← get
  if h : s.pos < s.tokens.size then
    return s.tokens[s.pos].kind
  else
    return .eof

def peekSpan : ParseM Span := do
  let s ← get
  if h : s.pos < s.tokens.size then
    return s.tokens[s.pos].span
  else
    return { line := 0, col := 0 }

def advance : ParseM Unit := do
  modify fun s => { s with pos := s.pos + 1 }

def expect (expected : TokenKind) : ParseM Unit := do
  let actual ← peek
  let sp ← peekSpan
  if actual == expected then advance
  else throw ("expected " ++ toString expected ++ ", got " ++ toString actual ++
              " at " ++ toString sp.line ++ ":" ++ toString sp.col)

def expectIdent : ParseM String := do
  let tk ← peek
  let sp ← peekSpan
  match tk with
  | .ident name => advance; return name
  | other => throw ("expected identifier, got " ++ toString other ++
                    " at " ++ toString sp.line ++ ":" ++ toString sp.col)

partial def parseType : ParseM Ty := do
  let tk ← peek
  match tk with
  | .ident "i32" | .ident "Int" => advance; return .int
  | .ident "u32" | .ident "Uint" => advance; return .uint
  | .ident "Bool" => advance; return .bool
  | .ident "Float64" => advance; return .float64
  | .ident "String" => advance; return .string
  | .ampersand =>
    advance
    let next ← peek
    if next == .mut then
      advance
      let inner ← parseType
      return .refMut inner
    else
      let inner ← parseType
      return .ref inner
  | .lbracket =>
    -- Array type: [T; N]
    advance
    let elemTy ← parseType
    expect .semicolon
    let sizeTk ← peek
    match sizeTk with
    | .intLit n =>
      advance
      expect .rbracket
      return .array elemTy n.toNat
    | other =>
      let sp ← peekSpan
      throw ("expected array size literal, got " ++ toString other ++
             " at " ++ toString sp.line ++ ":" ++ toString sp.col)
  | .ident name =>
    advance
    -- Check for generic type: Name<T, U>
    let next ← peek
    if next == .lt then
      advance
      -- Inline parseTypeArgList
      let firstTy ← parseType
      let mut tyArgs := [firstTy]
      let mut tk3 ← peek
      while tk3 == .comma do
        advance
        let ty2 ← parseType
        tyArgs := tyArgs ++ [ty2]
        tk3 ← peek
      expect .gt
      return .generic name tyArgs
    else
      return .named name
  | other =>
    let sp ← peekSpan
    throw ("expected type, got " ++ toString other ++
           " at " ++ toString sp.line ++ ":" ++ toString sp.col)

def parseParam : ParseM Param := do
  let name ← expectIdent
  expect .colon
  let ty ← parseType
  return { name, ty }

partial def parseParamList : ParseM (List Param) := do
  let tk ← peek
  if tk == .rparen then return []
  let first ← parseParam
  let mut params := [first]
  let mut tk ← peek
  while tk == .comma do
    advance
    let p ← parseParam
    params := params ++ [p]
    tk ← peek
  return params

partial def parseTypeArgList : ParseM (List Ty) := do
  let first ← parseType
  let mut args := [first]
  let mut tk ← peek
  while tk == .comma do
    advance
    let ty ← parseType
    args := args ++ [ty]
    tk ← peek
  return args

partial def parseTypeParams : ParseM (List String) := do
  let tk ← peek
  if tk == .lt then
    advance
    let mut params : List String := []
    let firstName ← expectIdent
    params := [firstName]
    let mut tk2 ← peek
    while tk2 == .comma do
      advance
      let name ← expectIdent
      params := params ++ [name]
      tk2 ← peek
    expect .gt
    return params
  else
    return []

mutual

partial def parsePrimary : ParseM Expr := do
  let tk ← peek
  match tk with
  | .intLit v => advance; return .intLit v
  | .boolLit v => advance; return .boolLit v
  | .strLit v => advance; return .strLit v
  | .true_ => advance; return .boolLit true
  | .false_ => advance; return .boolLit false
  | .ident name =>
    advance
    -- Check for turbofish: name::<Type, ...>
    let next ← peek
    let typeArgs ← if next == .doubleColon then
      advance
      expect .lt
      let targs ← parseTypeArgList
      expect .gt
      pure targs
    else
      pure []
    let next2 ← peek
    if next2 == .lparen then
      advance
      let args ← parseCallArgs
      expect .rparen
      return .call name typeArgs args
    else if next2 == .hash then
      -- Enum literal or static method call: Name#Variant { ... } or Name#method(args)
      advance
      let variant ← expectIdent
      let next3 ← peek
      if next3 == .lparen then
        -- Static method call: TypeName#method(args)
        advance
        let args ← parseCallArgs
        expect .rparen
        return .staticMethodCall name variant typeArgs args
      else
        expect .lbrace
        let fields ← parseStructLitFields
        expect .rbrace
        return .enumLit name variant typeArgs fields
    else if next2 == .lbrace then
      -- Could be struct literal: Name[::<Type>] { field: val, ... }
      if name.length > 0 && (name.toList.head!).isUpper then
        advance
        let fields ← parseStructLitFields
        expect .rbrace
        return .structLit name typeArgs fields
      else
        return .ident name
    else
      return .ident name
  | .match_ =>
    advance
    let scrutinee ← parseExpr
    expect .lbrace
    let arms ← parseMatchArms
    expect .rbrace
    return .match_ scrutinee arms
  | .lparen =>
    advance
    let inner ← parseExpr
    expect .rparen
    return .paren inner
  | .ampersand =>
    advance
    let next ← peek
    if next == .mut then
      advance
      let operand ← parsePrimary
      return .borrowMut operand
    else
      let operand ← parsePrimary
      return .borrow operand
  | .star =>
    advance
    let operand ← parsePrimary
    return .deref operand
  | .minus =>
    advance
    let operand ← parsePrimary
    return .unaryOp .neg operand
  | .not_ =>
    advance
    let operand ← parsePrimary
    return .unaryOp .not_ operand
  | .lbracket =>
    -- Array literal: [expr, expr, ...]
    advance
    let mut elems : List Expr := []
    let tk ← peek
    if tk != .rbracket then
      let first ← parseExpr
      elems := [first]
      let mut tk2 ← peek
      while tk2 == .comma do
        advance
        tk2 ← peek
        if tk2 == .rbracket then break  -- trailing comma
        let e ← parseExpr
        elems := elems ++ [e]
        tk2 ← peek
    expect .rbracket
    return .arrayLit elems
  | other =>
    let sp ← peekSpan
    throw ("expected expression, got " ++ toString other ++
           " at " ++ toString sp.line ++ ":" ++ toString sp.col)

partial def parseStructLitFields : ParseM (List (String × Expr)) := do
  let tk ← peek
  if tk == .rbrace then return []
  let mut fields : List (String × Expr) := []
  let firstName ← expectIdent
  expect .colon
  let firstVal ← parseExpr
  fields := [(firstName, firstVal)]
  let mut tk ← peek
  while tk == .comma do
    advance
    tk ← peek
    if tk == .rbrace then break  -- trailing comma
    let fieldName ← expectIdent
    expect .colon
    let fieldVal ← parseExpr
    fields := fields ++ [(fieldName, fieldVal)]
    tk ← peek
  return fields

partial def parsePostfix (e : Expr) : ParseM Expr := do
  let mut result := e
  let mut tk ← peek
  while tk == .dot || tk == .question || tk == .lbracket || tk == .as_ do
    if tk == .dot then
      advance
      let fieldName ← expectIdent
      -- Check if this is a method call: .name(args)
      let next ← peek
      if next == .lparen then
        advance
        let args ← parseCallArgs
        expect .rparen
        result := .methodCall result fieldName [] args
      else
        result := .fieldAccess result fieldName
    else if tk == .question then
      advance
      result := .try_ result
    else if tk == .lbracket then
      -- Array index: expr[index]
      advance
      let index ← parseExpr
      expect .rbracket
      result := .arrayIndex result index
    else  -- .as_
      advance
      let targetTy ← parseType
      result := .cast result targetTy
    tk ← peek
  return result

partial def parseCallArgs : ParseM (List Expr) := do
  let tk ← peek
  if tk == .rparen then return []
  let first ← parseExpr
  let mut args := [first]
  let mut tk ← peek
  while tk == .comma do
    advance
    let e ← parseExpr
    args := args ++ [e]
    tk ← peek
  return args

partial def binOpPrec (tk : TokenKind) : Option (Nat × BinOp) :=
  match tk with
  | .or_ => some (1, .or_)
  | .and_ => some (2, .and_)
  | .eq => some (3, .eq)
  | .neq => some (3, .neq)
  | .lt => some (4, .lt)
  | .gt => some (4, .gt)
  | .leq => some (4, .leq)
  | .geq => some (4, .geq)
  | .plus => some (5, .add)
  | .minus => some (5, .sub)
  | .star => some (6, .mul)
  | .slash => some (6, .div)
  | .percent => some (6, .mod)
  | _ => none

partial def parseExprPrec (minPrec : Nat) : ParseM Expr := do
  let mut lhs ← parsePrimary >>= parsePostfix
  let mut tk ← peek
  while true do
    match binOpPrec tk with
    | some (prec, op) =>
      if prec < minPrec then break
      advance
      let rhs ← parseExprPrec (prec + 1)
      lhs := .binOp op lhs rhs
      tk ← peek
    | none => break
  return lhs

partial def parseExpr : ParseM Expr :=
  parseExprPrec 0

partial def parseBlock : ParseM (List Stmt) := do
  expect .lbrace
  let stmts ← parseStmtList
  expect .rbrace
  return stmts

partial def parseStmtList : ParseM (List Stmt) := do
  let mut stmts : List Stmt := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    let stmt ← parseStmt
    stmts := stmts ++ [stmt]
    tk ← peek
  return stmts

partial def parseStmt : ParseM Stmt := do
  let tk ← peek
  match tk with
  | .«let» => parseLet
  | .return_ => parseReturn
  | .if_ => parseIf
  | .while_ => parseWhile
  | .match_ => parseMatchStmt
  | _ => parseExprOrAssign

partial def parseLet : ParseM Stmt := do
  expect .«let»
  let tk ← peek
  let isMut := tk == .mut
  if isMut then advance
  let name ← expectIdent
  let tk ← peek
  let ty ← if tk == .colon then
    advance
    let t ← parseType
    pure (some t)
  else
    pure none
  expect .assign
  let value ← parseExpr
  expect .semicolon
  return .letDecl name isMut ty value

partial def parseReturn : ParseM Stmt := do
  expect .return_
  let tk ← peek
  let value ← if tk == .semicolon then
    pure none
  else
    let e ← parseExpr
    pure (some e)
  expect .semicolon
  return .return_ value

partial def parseIf : ParseM Stmt := do
  expect .if_
  let cond ← parseExpr
  let thenBody ← parseBlock
  let tk ← peek
  let elseBody ← if tk == .else_ then
    advance
    let body ← parseBlock
    pure (some body)
  else
    pure none
  return .ifElse cond thenBody elseBody

partial def parseWhile : ParseM Stmt := do
  expect .while_
  let cond ← parseExpr
  let body ← parseBlock
  return .while_ cond body

partial def parseMatchStmt : ParseM Stmt := do
  advance  -- consume match_
  let scrutinee ← parseExpr
  expect .lbrace
  let arms ← parseMatchArms
  expect .rbrace
  return .expr (.match_ scrutinee arms)

partial def parseMatchArms : ParseM (List MatchArm) := do
  let mut arms : List MatchArm := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    let arm ← parseMatchArm
    arms := arms ++ [arm]
    tk ← peek
  return arms

partial def parseMatchArm : ParseM MatchArm := do
  let enumName ← expectIdent
  expect .hash
  let variant ← expectIdent
  expect .lbrace
  -- Parse bindings: field names without types
  let mut bindings : List String := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    let name ← expectIdent
    bindings := bindings ++ [name]
    tk ← peek
    if tk == .comma then advance; tk ← peek
  expect .rbrace
  expect .fatArrow
  let body ← parseBlock
  -- Optional trailing comma after the arm block
  let tk2 ← peek
  if tk2 == .comma then advance
  return .mk enumName variant bindings body

partial def parseExprOrAssign : ParseM Stmt := do
  let e ← parseExpr
  let tk ← peek
  match tk with
  | .assign =>
    match e with
    | .ident name =>
      advance
      let value ← parseExpr
      expect .semicolon
      return .assign name value
    | .fieldAccess obj field =>
      advance
      let value ← parseExpr
      expect .semicolon
      return .fieldAssign obj field value
    | .deref inner =>
      advance
      let value ← parseExpr
      expect .semicolon
      return .derefAssign inner value
    | .arrayIndex arr index =>
      advance
      let value ← parseExpr
      expect .semicolon
      return .arrayIndexAssign arr index value
    | _ =>
      let sp ← peekSpan
      throw ("invalid assignment target at " ++ toString sp.line ++ ":" ++ toString sp.col)
  | .semicolon =>
    advance
    return .expr e
  | other =>
    let sp ← peekSpan
    throw ("expected ';' or '=', got " ++ toString other ++
           " at " ++ toString sp.line ++ ":" ++ toString sp.col)

end

partial def parseMethodParamList (selfKind : Option SelfKind) : ParseM (List Param) := do
  -- If we already consumed self/&self/&mut self, check for comma then rest
  if selfKind.isSome then
    let tk ← peek
    if tk == .comma then
      advance
      let rest ← parseParamList
      return rest
    else
      return []
  else
    parseParamList

partial def parseMethodDef : ParseM (FnDef × Option SelfKind) := do
  expect .fn
  let name ← expectIdent
  let typeParams ← parseTypeParams
  expect .lparen
  -- Check for self, &self, &mut self
  let tk ← peek
  let (selfKind, params) ← match tk with
  | .ampersand =>
    -- Could be &self or &mut self
    let saved ← get
    advance
    let tk2 ← peek
    if tk2 == .mut then
      advance
      let tk3 ← peek
      match tk3 with
      | .ident "self" =>
        advance
        let params ← parseMethodParamList (some .refMut)
        pure (some SelfKind.refMut, params)
      | _ =>
        -- Not &mut self, backtrack
        set saved
        let params ← parseParamList
        pure (none, params)
    else
      match tk2 with
      | .ident "self" =>
        advance
        let params ← parseMethodParamList (some .ref)
        pure (some SelfKind.ref, params)
      | _ =>
        -- Not &self, backtrack
        set saved
        let params ← parseParamList
        pure (none, params)
  | .ident "self" =>
    advance
    let params ← parseMethodParamList (some .value)
    pure (some SelfKind.value, params)
  | _ =>
    let params ← parseParamList
    pure (none, params)
  expect .rparen
  let tk ← peek
  let retTy ← if tk == .arrow then
    advance
    parseType
  else
    pure .unit
  let body ← parseBlock
  return ({ name, typeParams, params, retTy, body }, selfKind)

partial def parseImplBlock : ParseM (ImplBlock ⊕ ImplTraitBlock) := do
  expect .impl_
  let typeParams ← parseTypeParams
  let firstName ← expectIdent
  -- Check: is it "impl Trait for Type" or "impl Type"?
  let tk ← peek
  match tk with
  | .for_ =>
    -- Trait impl: impl TraitName for TypeName { ... }
    advance
    let typeName ← expectIdent
    expect .lbrace
    let mut methods : List FnDef := []
    let mut tk ← peek
    while tk != .rbrace && tk != .eof do
      let isPub := tk == .pub_
      if isPub then advance; tk ← peek
      let (f, selfKind) ← parseMethodDef
      let selfParam : List Param := match selfKind with
        | some .value => [{ name := "self", ty := .named typeName }]
        | some .ref => [{ name := "self", ty := .ref (.named typeName) }]
        | some .refMut => [{ name := "self", ty := .refMut (.named typeName) }]
        | none => []
      let f := { f with params := selfParam ++ f.params, isPublic := isPub }
      methods := methods ++ [f]
      tk ← peek
    expect .rbrace
    return .inr { traitName := firstName, typeName, typeParams, methods }
  | _ =>
    -- Inherent impl: impl TypeName { ... }
    let typeName := firstName
    expect .lbrace
    let mut methods : List FnDef := []
    let mut tk ← peek
    while tk != .rbrace && tk != .eof do
      let isPub := tk == .pub_
      if isPub then advance; tk ← peek
      let (f, selfKind) ← parseMethodDef
      -- Inject self parameter based on selfKind
      let selfParam : List Param := match selfKind with
        | some .value => [{ name := "self", ty := .named typeName }]
        | some .ref => [{ name := "self", ty := .ref (.named typeName) }]
        | some .refMut => [{ name := "self", ty := .refMut (.named typeName) }]
        | none => []
      let f := { f with params := selfParam ++ f.params, isPublic := isPub }
      methods := methods ++ [f]
      tk ← peek
    expect .rbrace
    return .inl { typeName, typeParams, methods }

partial def parseTraitDef : ParseM TraitDef := do
  expect .trait_
  let name ← expectIdent
  let typeParams ← parseTypeParams
  expect .lbrace
  let mut methods : List FnSigDef := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    expect .fn
    let methodName ← expectIdent
    let methodTypeParams ← parseTypeParams
    expect .lparen
    -- Check for self variants
    let tk2 ← peek
    let (selfKind, params) ← match tk2 with
    | .ampersand =>
      let saved ← get
      advance
      let tk3 ← peek
      if tk3 == .mut then
        advance
        let tk4 ← peek
        match tk4 with
        | .ident "self" =>
          advance
          let params ← parseMethodParamList (some .refMut)
          pure (some SelfKind.refMut, params)
        | _ => set saved; let params ← parseParamList; pure (none, params)
      else
        match tk3 with
        | .ident "self" =>
          advance
          let params ← parseMethodParamList (some .ref)
          pure (some SelfKind.ref, params)
        | _ => set saved; let params ← parseParamList; pure (none, params)
    | .ident "self" =>
      advance
      let params ← parseMethodParamList (some .value)
      pure (some SelfKind.value, params)
    | _ =>
      let params ← parseParamList
      pure (none, params)
    expect .rparen
    let tk3 ← peek
    let retTy ← if tk3 == .arrow then
      advance
      parseType
    else
      pure .unit
    expect .semicolon
    let _ := methodTypeParams  -- unused for now
    methods := methods ++ [{ name := methodName, params, retTy, selfKind }]
    tk ← peek
  expect .rbrace
  return { name, typeParams, methods }

partial def parseFnDef : ParseM FnDef := do
  expect .fn
  let name ← expectIdent
  let typeParams ← parseTypeParams
  expect .lparen
  let params ← parseParamList
  expect .rparen
  let tk ← peek
  let retTy ← if tk == .arrow then
    advance
    parseType
  else
    pure .unit
  let body ← parseBlock
  return { name, typeParams, params, retTy, body }

partial def parseStructDef : ParseM StructDef := do
  expect .struct_
  let name ← expectIdent
  let typeParams ← parseTypeParams
  expect .lbrace
  let mut fields : List StructField := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    let fieldName ← expectIdent
    expect .colon
    let ty ← parseType
    fields := fields ++ [{ name := fieldName, ty }]
    tk ← peek
    if tk == .comma then
      advance
      tk ← peek
  expect .rbrace
  return { name, typeParams, fields }

partial def parseEnumDef : ParseM EnumDef := do
  expect .enum_
  let name ← expectIdent
  let typeParams ← parseTypeParams
  expect .lbrace
  let mut variants : List EnumVariant := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    let variantName ← expectIdent
    expect .lbrace
    let mut fields : List StructField := []
    let mut tk2 ← peek
    while tk2 != .rbrace && tk2 != .eof do
      let fieldName ← expectIdent
      expect .colon
      let ty ← parseType
      fields := fields ++ [{ name := fieldName, ty }]
      tk2 ← peek
      if tk2 == .comma then advance; tk2 ← peek
    expect .rbrace
    variants := variants ++ [{ name := variantName, fields }]
    tk ← peek
    if tk == .comma then advance; tk ← peek
  expect .rbrace
  return { name, typeParams, variants }

partial def parseImport : ParseM ImportDecl := do
  expect .import_
  let modName ← expectIdent
  expect .dot
  expect .lbrace
  let mut symbols : List String := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    let sym ← expectIdent
    symbols := symbols ++ [sym]
    tk ← peek
    if tk == .comma then advance; tk ← peek
  expect .rbrace
  expect .semicolon
  return { moduleName := modName, symbols }

/-- Parse the body of a module (shared between mod blocks and top-level). -/
partial def parseModuleBody (stopToken : TokenKind) : ParseM Module := do
  let mut structs : List StructDef := []
  let mut enums : List EnumDef := []
  let mut fns : List FnDef := []
  let mut imports : List ImportDecl := []
  let mut implBlocks : List ImplBlock := []
  let mut traits : List TraitDef := []
  let mut traitImpls : List ImplTraitBlock := []
  let mut tk ← peek
  while tk != stopToken && tk != .eof do
    if tk == .import_ then
      let imp ← parseImport
      imports := imports ++ [imp]
    else
      let isPub := tk == .pub_
      if isPub then advance; tk ← peek
      if tk == .struct_ then
        let s ← parseStructDef
        structs := structs ++ [{ s with isPublic := isPub }]
      else if tk == .enum_ then
        let e ← parseEnumDef
        enums := enums ++ [{ e with isPublic := isPub }]
      else if tk == .impl_ then
        let result ← parseImplBlock
        match result with
        | .inl ib => implBlocks := implBlocks ++ [ib]
        | .inr tb => traitImpls := traitImpls ++ [tb]
      else if tk == .trait_ then
        let t ← parseTraitDef
        traits := traits ++ [{ t with isPublic := isPub }]
      else
        let f ← parseFnDef
        fns := fns ++ [{ f with isPublic := isPub }]
    tk ← peek
  return { name := "", structs, enums, functions := fns, imports, implBlocks, traits, traitImpls }

partial def parseModule : ParseM Module := do
  expect .«mod»
  let name ← expectIdent
  expect .lbrace
  let m ← parseModuleBody .rbrace
  expect .rbrace
  return { m with name }

partial def parseProgram : ParseM (List Module) := do
  let tk ← peek
  if tk == .«mod» then
    let mut modules : List Module := []
    let mut tk ← peek
    while tk == .«mod» do
      let m ← parseModule
      modules := modules ++ [m]
      tk ← peek
    return modules
  else
    let m ← parseModuleBody .eof
    return [{ m with name := "main" }]

def parse (source : String) : Except String (List Module) :=
  let tokens := tokenize source
  let st := mkParserState tokens
  match (parseProgram.run.run st).1 with
  | .ok modules => .ok modules
  | .error e => .error e

end Concrete
