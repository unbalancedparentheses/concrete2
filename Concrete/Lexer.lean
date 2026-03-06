import Concrete.Token

namespace Concrete

structure LexerState where
  source : Array Char
  pos : Nat
  line : Nat
  col : Nat
  deriving Repr, Inhabited

def LexerState.init (source : String) : LexerState :=
  { source := source.toList.toArray, pos := 0, line := 1, col := 1 }

def LexerState.peek (s : LexerState) : Option Char :=
  if h : s.pos < s.source.size then some s.source[s.pos]
  else none

def LexerState.advance (s : LexerState) : LexerState :=
  match s.peek with
  | some '\n' => { s with pos := s.pos + 1, line := s.line + 1, col := 1 }
  | some _ => { s with pos := s.pos + 1, col := s.col + 1 }
  | none => s

def LexerState.span (s : LexerState) : Span :=
  { line := s.line, col := s.col }

def LexerState.atEnd (s : LexerState) : Bool :=
  s.pos ≥ s.source.size

def lookupKeyword : String → Option TokenKind
  | "fn" => some .fn
  | "let" => some .«let»
  | "mut" => some .mut
  | "if" => some .if_
  | "else" => some .else_
  | "while" => some .while_
  | "for" => some .for_
  | "return" => some .return_
  | "true" => some .true_
  | "false" => some .false_
  | "mod" => some .«mod»
  | "struct" => some .struct_
  | "enum" => some .enum_
  | "match" => some .match_
  | "pub" => some .pub_
  | "import" => some .import_
  | "as" => some .as_
  | "impl" => some .impl_
  | "trait" => some .trait_
  | _ => none

private def isIdentStart (c : Char) : Bool :=
  c.isAlpha || c == '_'

private def isIdentCont (c : Char) : Bool :=
  c.isAlphanum || c == '_'

/-- Skip whitespace and line comments. -/
partial def skipWhitespace (s : LexerState) : LexerState :=
  match s.peek with
  | some ' ' | some '\t' | some '\n' | some '\r' =>
    skipWhitespace s.advance
  | some '/' =>
    let s2 := s.advance
    match s2.peek with
    | some '/' => skipLineComment s2.advance
    | _ => s
  | _ => s
where
  skipLineComment (s : LexerState) : LexerState :=
    match s.peek with
    | some '\n' => skipWhitespace s.advance
    | some _ => skipLineComment s.advance
    | none => s

/-- Lex an identifier or keyword. -/
partial def lexIdentLoop (s : LexerState) (acc : String) : LexerState × TokenKind :=
  match s.peek with
  | some c =>
    if isIdentCont c then
      lexIdentLoop s.advance (acc.push c)
    else
      (s, (lookupKeyword acc).getD (.ident acc))
  | none =>
    (s, (lookupKeyword acc).getD (.ident acc))

/-- Lex an integer literal. -/
partial def lexNumberLoop (s : LexerState) (acc : Nat) : LexerState × TokenKind :=
  match s.peek with
  | some c =>
    if c.isDigit then
      lexNumberLoop s.advance (acc * 10 + (c.toNat - '0'.toNat))
    else
      (s, .intLit acc)
  | none => (s, .intLit acc)

/-- Lex a string literal (after opening quote). -/
partial def lexStringLoop (s : LexerState) (acc : String) : LexerState × TokenKind :=
  match s.peek with
  | some '"' => (s.advance, .strLit acc)
  | some '\\' =>
    let s := s.advance
    match s.peek with
    | some 'n' => lexStringLoop s.advance (acc.push '\n')
    | some 't' => lexStringLoop s.advance (acc.push '\t')
    | some '\\' => lexStringLoop s.advance (acc.push '\\')
    | some '"' => lexStringLoop s.advance (acc.push '"')
    | some c => lexStringLoop s.advance (acc.push c)
    | none => (s, .strLit acc)
  | some c => lexStringLoop s.advance (acc.push c)
  | none => (s, .strLit acc)

/-- Lex a single token. -/
partial def lexToken (s : LexerState) : LexerState × TokenKind :=
  let s := skipWhitespace s
  if s.atEnd then (s, .eof)
  else
    match s.peek with
    | some c =>
      if isIdentStart c then lexIdentLoop s.advance (String.singleton c)
      else if c.isDigit then lexNumberLoop s.advance (c.toNat - '0'.toNat)
      else if c == '"' then lexStringLoop s.advance ""
      else
        let s := s.advance
        match c with
        | '+' => (s, .plus)
        | '*' => (s, .star)
        | '/' => (s, .slash)
        | '%' => (s, .percent)
        | '(' => (s, .lparen)
        | ')' => (s, .rparen)
        | '{' => (s, .lbrace)
        | '}' => (s, .rbrace)
        | '[' => (s, .lbracket)
        | ']' => (s, .rbracket)
        | ',' => (s, .comma)
        | ':' =>
          match s.peek with
          | some ':' => (s.advance, .doubleColon)
          | _ => (s, .colon)
        | ';' => (s, .semicolon)
        | '.' => (s, .dot)
        | '-' =>
          match s.peek with
          | some '>' => (s.advance, .arrow)
          | _ => (s, .minus)
        | '#' => (s, .hash)
        | '?' => (s, .question)
        | '=' =>
          match s.peek with
          | some '=' => (s.advance, .eq)
          | some '>' => (s.advance, .fatArrow)
          | _ => (s, .assign)
        | '!' =>
          match s.peek with
          | some '=' => (s.advance, .neq)
          | _ => (s, .not_)
        | '<' =>
          match s.peek with
          | some '=' => (s.advance, .leq)
          | _ => (s, .lt)
        | '>' =>
          match s.peek with
          | some '=' => (s.advance, .geq)
          | _ => (s, .gt)
        | '&' =>
          match s.peek with
          | some '&' => (s.advance, .and_)
          | _ => (s, .ampersand)
        | '|' =>
          match s.peek with
          | some '|' => (s.advance, .or_)
          | _ => (s, .eof)
        | _ => (s, .eof)
    | none => (s, .eof)

/-- Tokenize entire source string. -/
partial def tokenize (source : String) : List Token :=
  go (LexerState.init source) []
where
  go (s : LexerState) (acc : List Token) : List Token :=
    let sp := (skipWhitespace s).span
    let (s', kind) := lexToken s
    let tok : Token := { kind, span := sp }
    match kind with
    | .eof => acc ++ [tok]
    | _ => go s' (acc ++ [tok])

end Concrete
