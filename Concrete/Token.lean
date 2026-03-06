namespace Concrete

inductive TokenKind where
  -- Literals
  | intLit (val : Int)
  | boolLit (val : Bool)
  -- Identifier
  | ident (name : String)
  -- Keywords
  | fn | «let» | mut | if_ | else_ | while_ | for_ | return_
  | true_ | false_ | «mod» | struct_
  -- Types
  | arrow  -- ->
  -- Operators
  | plus | minus | star | slash | percent
  | eq | neq | lt | gt | leq | geq
  | and_ | or_ | not_
  | assign  -- =
  -- Delimiters
  | lparen | rparen | lbrace | rbrace
  | comma | colon | semicolon | dot
  -- Special
  | eof
  deriving Repr, BEq, Inhabited

structure Span where
  line : Nat
  col : Nat
  deriving Repr, Inhabited

structure Token where
  kind : TokenKind
  span : Span
  deriving Repr, Inhabited

def TokenKind.toString : TokenKind → String
  | .intLit v => s!"int({v})"
  | .boolLit v => s!"bool({v})"
  | .ident n => s!"ident({n})"
  | .fn => "fn"
  | .«let» => "let"
  | .mut => "mut"
  | .if_ => "if"
  | .else_ => "else"
  | .while_ => "while"
  | .for_ => "for"
  | .return_ => "return"
  | .true_ => "true"
  | .false_ => "false"
  | .«mod» => "mod"
  | .struct_ => "struct"
  | .arrow => "->"
  | .plus => "+"
  | .minus => "-"
  | .star => "*"
  | .slash => "/"
  | .percent => "%"
  | .eq => "=="
  | .neq => "!="
  | .lt => "<"
  | .gt => ">"
  | .leq => "<="
  | .geq => ">="
  | .and_ => "&&"
  | .or_ => "||"
  | .not_ => "!"
  | .assign => "="
  | .lparen => "("
  | .rparen => ")"
  | .lbrace => "{"
  | .rbrace => "}"
  | .comma => ","
  | .colon => ":"
  | .semicolon => ";"
  | .dot => "."
  | .eof => "<eof>"

instance : ToString TokenKind := ⟨TokenKind.toString⟩

end Concrete
