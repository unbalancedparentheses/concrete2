# Evidence producer matrix (R-0004, ProofBodyCanonicalV2 step 3)

Every `Expr` and `Stmt` constructor classified **before** the producer is wired, so
each case is a decision rather than whatever the traversal happened to do. Filled from
`Concrete/Frontend/AST.lean`.

Columns:

- **Node** — the `EvidenceExprV2`/`EvidenceStmtV2` constructor emitted.
- **Identity** — the semantic identity that must resolve first. `—` means none.
- **Binding** — what the construct binds, and *when* it comes into scope. This column
  exists because the three constructs already measured give three different answers:
  a `let` is not in scope in its own initializer, a loop variable **is** in scope in
  the condition, and an arm pattern opens its own frame.
- **Gap code** — emitted when the identity cannot resolve. Compilation must still
  succeed; only the evidence is refused.
- **Fixture** — the behavioural case proving it.

## Expressions

| Constructor | Node | Identity | Binding | Gap code | Fixture |
|---|---|---|---|---|---|
| `intLit` | `intLit value ty` | — (width from Check) | — | `unhandledExpr` if width unresolved | `1i32` vs `1i64` differ |
| `floatLit` | `floatLit bits ty` | — | — | — | `0.0` vs `-0.0` differ |
| `boolLit` / `strLit` / `charLit` | same | — | — | — | distinct literals differ |
| `ident` (local) | `binderRef out idx` | frame position | reads a binder | `unplaceableBinder` | rename-invariance |
| `ident` (constant) | `constRef id` | `ConstId` | — | `unresolvedConst` | `LIMIT` edit invalidates |
| `ident` (fn value) | `fnRef id` | `CallableId` | — | `unresolvedCallee` | fn-ref identity |
| `binOp` | `binary op l r` | — | — | — | `p+1` vs `p*2` differ |
| `unaryOp` | `unary op x` | — | — | — | `-p` vs `!p` differ |
| `call` | `call callee args` | `CallableId` (complete) | — | `unresolvedCallee` | arg order matters |
| `methodCall` | `call callee args` | `CallableId` after receiver resolution | — | `unresolvedCallee` | **pressure point** |
| `staticMethodCall` | `call callee args` | `CallableId` via type | — | `unresolvedCallee` | **pressure point** |
| `allocCall` | `call` + allocator arg | `CallableId` + allocator identity | — | `unresolvedCallee` | **pressure point** |
| `paren` | *transparent* | — | — | — | `(p)` ≡ `p` |
| `structLit` | `structLit ty fields` | `TypeId` + `FieldId` each | — | `unresolvedType` / `unresolvedField` | field order normalized |
| `enumLit` | `variantLit id fields` | `VariantId` + `FieldId` | — | `unresolvedVariant` | variant identity |
| `fieldAccess` | `field id object` | `FieldId` (owner-relative) | — | `unresolvedField` | needs receiver type |
| `match_` | via `EvidenceStmtV2.match_` | `VariantId` per arm | arm opens a frame | `unhandledPattern` | outer-from-arm |
| `borrow` / `borrowMut` | `borrow isMut x` | — | — | — | `&p` vs `&mut p` differ |
| `deref` | `deref x` | — | — | — | `*p` vs `p` differ |
| `try_` | **undecided** — desugars | callee of the `?` path | — | `unhandledExpr` | open |
| `arrayLit` | **undecided** | element `TypeId` | — | `unhandledExpr` | open |
| `arrayIndex` | `index c i` | — | — | — | `a[i]` vs `a[j]` differ |
| `cast` | `cast target x` | `TypeId` | — | `unresolvedType` | width-changing cast |
| `ifExpr` | via `EvidenceStmtV2.branch` | — | branches bind nothing | — | empty-scope leg |

## Statements

| Constructor | Node | Identity | Binding | Gap code | Fixture |
|---|---|---|---|---|---|
| `letDecl` (incl. ghost) | `letBind ty init` | optional `TypeId` | binds 1, **after** its own initializer | `unresolvedType` | progressive scope |
| `assign` | `assign place value` | — | binds **nothing** | — | assignment ≠ declaration |
| `return_` | `ret value` | — | — | — | value vs bare return |
| `expr` | `exprStmt value isValue` | — | — | — | statement vs trailing value |
| `ifElse` | `branch cond then else` | — | branch frames lazy | — | empty-scope leg |
| `while_` | `loop cond invs var body` | — | condition sees enclosing binders | — | invariant edit moves body |
| `forLoop` | `loop` + init/step | — | init binds into enclosing frame | — | loop-variable timing |
| `fieldAssign` | `assign (field …) value` | `FieldId` | — | `unresolvedField` | field write |
| `derefAssign` | `assign (deref …) value` | — | — | — | `*p = v` |
| `arrayIndexAssign` | `assign (index …) value` | — | — | — | `a[i] = v` |
| `break_` | `breakStmt target value` | relative loop depth | — | `unresolvedLoopTarget` | label → depth |
| `continue_` | `continueStmt target` | relative loop depth | — | `unresolvedLoopTarget` | label → depth |
| `defer` | **undecided** — runs at scope exit | — | — | `unhandledStmt` | open |
| `assert_` / `assume_` | **undecided** — proof-relevant | — | — | `unhandledStmt` | open |
| `borrowIn` | `block` + binder | — | binds 1 for its body | — | region binder |
| `letDestructure` | `match_` with one arm | `VariantId` + `FieldId` | binds N from pattern | `unresolvedVariant` | else-branch |
| `letStructDestructure` | `letBind` + field reads | `TypeId` + `FieldId` | binds N from pattern | `unresolvedField` | field order |

## Open decisions

Five constructors are deliberately **undecided** rather than guessed: `try_`,
`arrayLit`, `defer`, `assert_`, `assume_`. Each gets its gap code until decided, so an
unfinished decision is a refused subject rather than a silently thin body.

`assert_`/`assume_` need the most thought: an `assume` is proof-relevant in a way a
runtime statement is not, and treating it as an ordinary expression statement would let
a proof lean on an assumption the subject does not record.

## Pressure points

`methodCall`, `staticMethodCall` and `allocCall` all resolve a callee through
information the AST does not carry. Ordinary compilation must continue when evidence
cannot resolve them; shadow validation reports `unresolvedCallee`. These are the
cases most likely to be resolvable-for-compilation but not resolvable-for-evidence,
which is the class `constRef` already demonstrated.
