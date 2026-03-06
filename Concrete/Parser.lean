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

def parseType : ParseM Ty := do
  let tk ← peek
  match tk with
  | .ident "i32" | .ident "Int" => advance; return .int
  | .ident "u32" | .ident "Uint" => advance; return .uint
  | .ident "Bool" => advance; return .bool
  | .ident "Float64" => advance; return .float64
  | .ident name => advance; return .named name
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

mutual

partial def parsePrimary : ParseM Expr := do
  let tk ← peek
  match tk with
  | .intLit v => advance; return .intLit v
  | .boolLit v => advance; return .boolLit v
  | .true_ => advance; return .boolLit true
  | .false_ => advance; return .boolLit false
  | .ident name =>
    advance
    let next ← peek
    if next == .lparen then
      advance
      let args ← parseCallArgs
      expect .rparen
      return .call name args
    else if next == .lbrace then
      -- Could be struct literal: Name { field: val, ... }
      -- Only if name starts with uppercase (convention)
      if name.length > 0 && (name.toList.head!).isUpper then
        advance
        let fields ← parseStructLitFields
        expect .rbrace
        return .structLit name fields
      else
        return .ident name
    else
      return .ident name
  | .lparen =>
    advance
    let inner ← parseExpr
    expect .rparen
    return .paren inner
  | .minus =>
    advance
    let operand ← parsePrimary
    return .unaryOp .neg operand
  | .not_ =>
    advance
    let operand ← parsePrimary
    return .unaryOp .not_ operand
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
  while tk == .dot do
    advance
    let fieldName ← expectIdent
    result := .fieldAccess result fieldName
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

partial def parseFnDef : ParseM FnDef := do
  expect .fn
  let name ← expectIdent
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
  return { name, params, retTy, body }

partial def parseStructDef : ParseM StructDef := do
  expect .struct_
  let name ← expectIdent
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
  return { name, fields }

partial def parseModule : ParseM Module := do
  expect .«mod»
  let name ← expectIdent
  expect .lbrace
  let mut structs : List StructDef := []
  let mut fns : List FnDef := []
  let mut tk ← peek
  while tk != .rbrace && tk != .eof do
    if tk == .struct_ then
      let s ← parseStructDef
      structs := structs ++ [s]
    else
      let f ← parseFnDef
      fns := fns ++ [f]
    tk ← peek
  expect .rbrace
  return { name, structs, functions := fns }

partial def parseToplevel : ParseM Module := do
  let tk ← peek
  match tk with
  | .«mod» => parseModule
  | _ =>
    let mut structs : List StructDef := []
    let mut fns : List FnDef := []
    let mut tk ← peek
    while tk != .eof do
      if tk == .struct_ then
        let s ← parseStructDef
        structs := structs ++ [s]
      else
        let f ← parseFnDef
        fns := fns ++ [f]
      tk ← peek
    return { name := "main", structs, functions := fns }

def parse (source : String) : Except String Module :=
  let tokens := tokenize source
  let st := mkParserState tokens
  match (parseToplevel.run.run st).1 with
  | .ok m => .ok m
  | .error e => .error e

end Concrete
