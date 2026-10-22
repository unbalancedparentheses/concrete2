/* C side of regress_166_foreign_fn_value_abi.con: small structs passed and returned by value. */
#include <stdint.h>
typedef struct { int64_t v; } Pair;
typedef struct { int64_t a; int64_t b; } Two;
int64_t take_pair(Pair p) { return p.v; }
int64_t take_two(Two t) { return t.a + t.b; }
Pair make_pair(int64_t v) { Pair p = { v }; return p; }
