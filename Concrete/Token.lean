namespace Concrete

inductive TokenKind where
  -- Literals
  | intLit (val : Int)
  | boolLit (val : Bool)
  | strLit (val : String)
  -- Identifier
  | ident (name : String)
  -- Keywords
  | fn | «let» | mut | if_ | else_ | while_ | for_ | return_
  | true_ | false_ | «mod» | struct_ | enum_ | match_ | pub_ | import_
  | as_ | impl_ | trait_
  -- Types
  | arrow  -- ->
  -- Operators
  | plus | minus | star | slash | percent
  | eq | neq | lt | gt | leq | geq
  | and_ | or_ | not_
  | ampersand  -- &
  | assign  -- =
  -- Delimiters
  | lparen | rparen | lbrace | rbrace | lbracket | rbracket
  | comma | colon | semicolon | dot
  | hash      -- #
  | fatArrow  -- =>
  | doubleColon  -- ::
  | question     -- ?
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
  | .strLit v => s!"str(\"{v}\")"
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
  | .enum_ => "enum"
  | .match_ => "match"
  | .pub_ => "pub"
  | .import_ => "import"
  | .as_ => "as"
  | .impl_ => "impl"
  | .trait_ => "trait"
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
  | .ampersand => "&"
  | .assign => "="
  | .lparen => "("
  | .rparen => ")"
  | .lbrace => "{"
  | .rbrace => "}"
  | .lbracket => "["
  | .rbracket => "]"
  | .comma => ","
  | .colon => ":"
  | .semicolon => ";"
  | .dot => "."
  | .hash => "#"
  | .fatArrow => "=>"
  | .doubleColon => "::"
  | .question => "?"
  | .eof => "<eof>"

instance : ToString TokenKind := ⟨TokenKind.toString⟩

end Concrete
