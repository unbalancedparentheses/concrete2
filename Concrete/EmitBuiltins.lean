import Concrete.LLVM
import Concrete.Layout

namespace Concrete

/-! ## EmitBuiltins — standalone LLVM IR builtin function generation

Generates structured LLVM IR definitions for string operations, conversion
functions, and Vec operations. These functions only depend on LLVM IR types
(`Concrete.LLVM`) and layout utilities (`Concrete.Layout`) — they have no
dependency on SSA IR, Core IR, or the EmitSSA codegen state.

This module is imported by EmitSSA to provide the builtin library that gets
linked into every compiled program. -/

-- ============================================================
-- String and conversion builtins
-- ============================================================

/-- Generate structured builtin function definitions, globals, and declarations
    for the string and conversion builtins. Replaces the old raw-string getBuiltinsIR. -/
def getBuiltinFns : List LLVMFnDef × List LLVMGlobal × List LLVMFnDecl :=
  let strTy := LLVMTy.struct_ "String"
  let resTy := LLVMTy.enum_ "Result"
  -- Helper: getelementptr %struct.String, ptr %base, i32 0, i32 N
  let strGep (dst base : String) (fieldIdx : Int) : LLVMInstr :=
    .gep dst strTy (.reg base) [(.i32, .intLit 0), (.i32, .intLit fieldIdx)]
  -- Helper: dynamic memcpy as raw line (structured .memcpy only supports Nat size)
  let dynMemcpy (dst src len : String) : LLVMInstr :=
    .raw s!"  call void @llvm.memcpy.p0.p0.i64(ptr %{dst}, ptr %{src}, i64 %{len}, i1 false)"

  -- -------------------------------------------------------
  -- string_length
  -- -------------------------------------------------------
  let strLenBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "len_ptr" "s" 1,
      .load "len" .i64 (.reg "len_ptr")
    ], .ret .i64 (some (.reg "len"))⟩]
  let fnStringLength : LLVMFnDef :=
    { name := "string_length", retTy := .i64, params := [("s", .ptr)], blocks := strLenBlocks }

  -- -------------------------------------------------------
  -- drop_string
  -- -------------------------------------------------------
  let dropStrBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "data_ptr" "s" 0,
      .load "data" .ptr (.reg "data_ptr"),
      .call none .void (.global "free") [(.ptr, .reg "data")]
    ], .ret .void none⟩]
  let fnDropString : LLVMFnDef :=
    { name := "drop_string", retTy := .void, params := [("s", .ptr)], blocks := dropStrBlocks }

  -- -------------------------------------------------------
  -- string_concat
  -- -------------------------------------------------------
  let strConcatBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "a_data_ptr" "a" 0,
      .load "a_data" .ptr (.reg "a_data_ptr"),
      strGep "a_len_ptr" "a" 1,
      .load "a_len" .i64 (.reg "a_len_ptr"),
      strGep "b_data_ptr" "b" 0,
      .load "b_data" .ptr (.reg "b_data_ptr"),
      strGep "b_len_ptr" "b" 1,
      .load "b_len" .i64 (.reg "b_len_ptr"),
      .binOp "total_len" .add .i64 (.reg "a_len") (.reg "b_len"),
      .call (some "buf") .ptr (.global "malloc") [(.i64, .reg "total_len")],
      dynMemcpy "buf" "a_data" "a_len",
      .gep "dst" .i8 (.reg "buf") [(.i64, .reg "a_len")],
      dynMemcpy "dst" "b_data" "b_len",
      .call none .void (.global "free") [(.ptr, .reg "a_data")],
      .call none .void (.global "free") [(.ptr, .reg "b_data")],
      .alloca "sc_alloca" strTy,
      strGep "sc_data_ptr" "sc_alloca" 0,
      .store .ptr (.reg "buf") (.reg "sc_data_ptr"),
      strGep "sc_len_ptr" "sc_alloca" 1,
      .store .i64 (.reg "total_len") (.reg "sc_len_ptr"),
      strGep "sc_cap_ptr" "sc_alloca" 2,
      .store .i64 (.reg "total_len") (.reg "sc_cap_ptr"),
      .load "sc_result" strTy (.reg "sc_alloca")
    ], .ret strTy (some (.reg "sc_result"))⟩]
  let fnStringConcat : LLVMFnDef :=
    { name := "string_concat", retTy := strTy, params := [("a", .ptr), ("b", .ptr)], blocks := strConcatBlocks }

  -- -------------------------------------------------------
  -- string_slice
  -- -------------------------------------------------------
  let strSliceBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "len_ptr.ss" "s" 1,
      .load "len.ss" .i64 (.reg "len_ptr.ss"),
      .call (some "s_clamped") .i64 (.global "llvm.smax.i64") [(.i64, .reg "start"), (.i64, .intLit 0)],
      .call (some "s_min") .i64 (.global "llvm.smin.i64") [(.i64, .reg "s_clamped"), (.i64, .reg "len.ss")],
      .call (some "e_clamped") .i64 (.global "llvm.smax.i64") [(.i64, .reg "end_"), (.i64, .intLit 0)],
      .call (some "e_min") .i64 (.global "llvm.smin.i64") [(.i64, .reg "e_clamped"), (.i64, .reg "len.ss")],
      .call (some "e_final") .i64 (.global "llvm.smax.i64") [(.i64, .reg "e_min"), (.i64, .reg "s_min")],
      .binOp "slice_len" .sub .i64 (.reg "e_final") (.reg "s_min"),
      .call (some "slice_buf") .ptr (.global "malloc") [(.i64, .reg "slice_len")],
      strGep "data_ptr.ss" "s" 0,
      .load "data.ss" .ptr (.reg "data_ptr.ss"),
      .gep "src" .i8 (.reg "data.ss") [(.i64, .reg "s_min")],
      dynMemcpy "slice_buf" "src" "slice_len",
      .alloca "res.ss" strTy,
      strGep "res_d.ss" "res.ss" 0,
      .store .ptr (.reg "slice_buf") (.reg "res_d.ss"),
      strGep "res_l.ss" "res.ss" 1,
      .store .i64 (.reg "slice_len") (.reg "res_l.ss"),
      strGep "res_c.ss" "res.ss" 2,
      .store .i64 (.reg "slice_len") (.reg "res_c.ss"),
      .load "result.ss" strTy (.reg "res.ss")
    ], .ret strTy (some (.reg "result.ss"))⟩]
  let fnStringSlice : LLVMFnDef :=
    { name := "string_slice", retTy := strTy, params := [("s", .ptr), ("start", .i64), ("end_", .i64)], blocks := strSliceBlocks }

  -- -------------------------------------------------------
  -- string_char_at
  -- -------------------------------------------------------
  let strCharAtBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "len_ptr.sca" "s" 1,
      .load "len.sca" .i64 (.reg "len_ptr.sca"),
      .binOp "neg" .icmpSlt .i64 (.reg "index") (.intLit 0),
      .binOp "oob" .icmpSge .i64 (.reg "index") (.reg "len.sca"),
      .binOp "bad" .or_ .i1 (.reg "neg") (.reg "oob")
    ], .condBr (.reg "bad") "ret_neg" "ok_idx"⟩,
    ⟨"ret_neg", []
    , .ret .i64 (some (.intLit (-1)))⟩,
    ⟨"ok_idx", [
      strGep "data_ptr.sca" "s" 0,
      .load "data.sca" .ptr (.reg "data_ptr.sca"),
      .gep "char_ptr" .i8 (.reg "data.sca") [(.i64, .reg "index")],
      .load "byte" .i8 (.reg "char_ptr"),
      .cast "char" .zext .i8 (.reg "byte") .i64
    ], .ret .i64 (some (.reg "char"))⟩]
  let fnStringCharAt : LLVMFnDef :=
    { name := "string_char_at", retTy := .i64, params := [("s", .ptr), ("index", .i64)], blocks := strCharAtBlocks }

  -- -------------------------------------------------------
  -- string_contains
  -- -------------------------------------------------------
  let strContainsBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "h_data_ptr" "haystack" 0,
      .load "h_data" .ptr (.reg "h_data_ptr"),
      strGep "h_len_ptr" "haystack" 1,
      .load "h_len" .i64 (.reg "h_len_ptr"),
      strGep "n_data_ptr" "needle" 0,
      .load "n_data" .ptr (.reg "n_data_ptr"),
      strGep "n_len_ptr" "needle" 1,
      .load "n_len" .i64 (.reg "n_len_ptr"),
      .binOp "n_empty" .icmpEq .i64 (.reg "n_len") (.intLit 0)
    ], .condBr (.reg "n_empty") "found" "check_len"⟩,
    ⟨"check_len", [
      .binOp "too_long" .icmpUgt .i64 (.reg "n_len") (.reg "h_len")
    ], .condBr (.reg "too_long") "not_found" "loop_start"⟩,
    ⟨"loop_start", [
      .binOp "max_i" .sub .i64 (.reg "h_len") (.reg "n_len")
    ], .br "loop"⟩,
    ⟨"loop", [
      .phi "i" .i64 [(.intLit 0, "loop_start"), (.reg "i_next", "loop_cont")],
      .gep "h_ptr" .i8 (.reg "h_data") [(.i64, .reg "i")],
      .call (some "cmp") .i32 (.global "memcmp") [(.ptr, .reg "h_ptr"), (.ptr, .reg "n_data"), (.i64, .reg "n_len")],
      .binOp "match" .icmpEq .i32 (.reg "cmp") (.intLit 0)
    ], .condBr (.reg "match") "found" "loop_cont"⟩,
    ⟨"loop_cont", [
      .binOp "i_next" .add .i64 (.reg "i") (.intLit 1),
      .binOp "done" .icmpUgt .i64 (.reg "i_next") (.reg "max_i")
    ], .condBr (.reg "done") "not_found" "loop"⟩,
    ⟨"found", [], .ret .i1 (some (.boolLit true))⟩,
    ⟨"not_found", [], .ret .i1 (some (.boolLit false))⟩]
  let fnStringContains : LLVMFnDef :=
    { name := "string_contains", retTy := .i1, params := [("haystack", .ptr), ("needle", .ptr)], blocks := strContainsBlocks }

  -- -------------------------------------------------------
  -- string_eq
  -- -------------------------------------------------------
  let strEqBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "a_len_ptr" "a" 1,
      .load "a_len" .i64 (.reg "a_len_ptr"),
      strGep "b_len_ptr" "b" 1,
      .load "b_len" .i64 (.reg "b_len_ptr"),
      .binOp "len_eq" .icmpEq .i64 (.reg "a_len") (.reg "b_len")
    ], .condBr (.reg "len_eq") "cmp_data" "not_eq"⟩,
    ⟨"cmp_data", [
      .binOp "zero_len" .icmpEq .i64 (.reg "a_len") (.intLit 0)
    ], .condBr (.reg "zero_len") "eq" "do_cmp"⟩,
    ⟨"do_cmp", [
      strGep "a_data_ptr" "a" 0,
      .load "a_data" .ptr (.reg "a_data_ptr"),
      strGep "b_data_ptr" "b" 0,
      .load "b_data" .ptr (.reg "b_data_ptr"),
      .call (some "cmp_res") .i32 (.global "memcmp") [(.ptr, .reg "a_data"), (.ptr, .reg "b_data"), (.i64, .reg "a_len")],
      .binOp "eq_data" .icmpEq .i32 (.reg "cmp_res") (.intLit 0)
    ], .condBr (.reg "eq_data") "eq" "not_eq"⟩,
    ⟨"eq", [], .ret .i1 (some (.boolLit true))⟩,
    ⟨"not_eq", [], .ret .i1 (some (.boolLit false))⟩]
  let fnStringEq : LLVMFnDef :=
    { name := "string_eq", retTy := .i1, params := [("a", .ptr), ("b", .ptr)], blocks := strEqBlocks }

  -- -------------------------------------------------------
  -- int_to_string
  -- -------------------------------------------------------
  let intToStrBlocks : List LLVMBlock := [
    ⟨"entry", [
      .call (some "buf") .ptr (.global "malloc") [(.i64, .intLit 32)],
      .gep "fmt_its" (.array 4 .i8) (.global ".fmt_ld") [(.i64, .intLit 0), (.i64, .intLit 0)],
      .callVariadic (some "written") .i32 (.global "snprintf") [(.ptr, .reg "buf"), (.i64, .intLit 32), (.ptr, .reg "fmt_its"), (.i64, .reg "n")] [.ptr, .i64, .ptr],
      .cast "wext" .sext .i32 (.reg "written") .i64,
      .alloca "res.its" strTy,
      strGep "res_d.its" "res.its" 0,
      .store .ptr (.reg "buf") (.reg "res_d.its"),
      strGep "res_l.its" "res.its" 1,
      .store .i64 (.reg "wext") (.reg "res_l.its"),
      strGep "res_c.its" "res.its" 2,
      .store .i64 (.intLit 32) (.reg "res_c.its"),
      .load "result.its" strTy (.reg "res.its")
    ], .ret strTy (some (.reg "result.its"))⟩]
  let fnIntToString : LLVMFnDef :=
    { name := "int_to_string", retTy := strTy, params := [("n", .i64)], blocks := intToStrBlocks }

  -- -------------------------------------------------------
  -- string_to_int
  -- -------------------------------------------------------
  let strToIntBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "sti_data_ptr" "s" 0,
      .load "sti_data" .ptr (.reg "sti_data_ptr"),
      strGep "sti_len_ptr" "s" 1,
      .load "sti_len" .i64 (.reg "sti_len_ptr"),
      .binOp "sti_buf_sz" .add .i64 (.reg "sti_len") (.intLit 1),
      .call (some "sti_buf") .ptr (.global "malloc") [(.i64, .reg "sti_buf_sz")],
      dynMemcpy "sti_buf" "sti_data" "sti_len",
      .gep "sti_null" .i8 (.reg "sti_buf") [(.i64, .reg "sti_len")],
      .store .i8 (.intLit 0) (.reg "sti_null"),
      .alloca "endptr_alloca" .ptr,
      .call (some "sti_val") .i64 (.global "strtol") [(.ptr, .reg "sti_buf"), (.ptr, .reg "endptr_alloca"), (.i32, .intLit 10)],
      .load "endptr" .ptr (.reg "endptr_alloca"),
      .gep "end_expected" .i8 (.reg "sti_buf") [(.i64, .reg "sti_len")],
      .binOp "valid" .icmpEq .ptr (.reg "endptr") (.reg "end_expected"),
      .binOp "empty_input" .icmpEq .i64 (.reg "sti_len") (.intLit 0),
      .binOp "not_empty" .xor_ .i1 (.reg "empty_input") (.boolLit true),
      .binOp "final_ok" .and_ .i1 (.reg "valid") (.reg "not_empty"),
      .call none .void (.global "free") [(.ptr, .reg "sti_buf")],
      .alloca "res.sti" resTy
    ], .condBr (.reg "final_ok") "sti_ok" "sti_err"⟩,
    ⟨"sti_ok", [
      .store .i32 (.intLit 0) (.reg "res.sti"),
      .gep "data_ptr.sti_ok" .i8 (.reg "res.sti") [(.i64, .intLit 8)],
      .store .i64 (.reg "sti_val") (.reg "data_ptr.sti_ok")
    ], .br "sti_done"⟩,
    ⟨"sti_err", [
      .store .i32 (.intLit 1) (.reg "res.sti"),
      .gep "data_ptr.sti_err" .i8 (.reg "res.sti") [(.i64, .intLit 8)],
      .store .i64 (.intLit 1) (.reg "data_ptr.sti_err")
    ], .br "sti_done"⟩,
    ⟨"sti_done", [
      .load "result.sti" resTy (.reg "res.sti")
    ], .ret resTy (some (.reg "result.sti"))⟩]
  let fnStringToInt : LLVMFnDef :=
    { name := "string_to_int", retTy := resTy, params := [("s", .ptr)], blocks := strToIntBlocks }

  -- -------------------------------------------------------
  -- bool_to_string
  -- -------------------------------------------------------
  let boolToStrBlocks : List LLVMBlock := [
    ⟨"entry", [], .condBr (.reg "b") "bts_true" "bts_false"⟩,
    ⟨"bts_true", [
      .call (some "tbuf") .ptr (.global "malloc") [(.i64, .intLit 4)],
      .memcpy (.reg "tbuf") (.global ".str_true") 4,
      .alloca "tres" strTy,
      strGep "td" "tres" 0,
      .store .ptr (.reg "tbuf") (.reg "td"),
      strGep "tl" "tres" 1,
      .store .i64 (.intLit 4) (.reg "tl"),
      strGep "tc" "tres" 2,
      .store .i64 (.intLit 4) (.reg "tc"),
      .load "tresult" strTy (.reg "tres")
    ], .ret strTy (some (.reg "tresult"))⟩,
    ⟨"bts_false", [
      .call (some "fbuf") .ptr (.global "malloc") [(.i64, .intLit 5)],
      .memcpy (.reg "fbuf") (.global ".str_false") 5,
      .alloca "fres" strTy,
      strGep "fd" "fres" 0,
      .store .ptr (.reg "fbuf") (.reg "fd"),
      strGep "fl" "fres" 1,
      .store .i64 (.intLit 5) (.reg "fl"),
      strGep "fc" "fres" 2,
      .store .i64 (.intLit 5) (.reg "fc"),
      .load "fresult" strTy (.reg "fres")
    ], .ret strTy (some (.reg "fresult"))⟩]
  let fnBoolToString : LLVMFnDef :=
    { name := "bool_to_string", retTy := strTy, params := [("b", .i1)], blocks := boolToStrBlocks }

  -- -------------------------------------------------------
  -- float_to_string
  -- -------------------------------------------------------
  let floatToStrBlocks : List LLVMBlock := [
    ⟨"entry", [
      .call (some "fbuf.fts") .ptr (.global "malloc") [(.i64, .intLit 64)],
      .gep "fmt.fts" (.array 3 .i8) (.global ".fmt_f") [(.i64, .intLit 0), (.i64, .intLit 0)],
      .callVariadic (some "written.fts") .i32 (.global "snprintf") [(.ptr, .reg "fbuf.fts"), (.i64, .intLit 64), (.ptr, .reg "fmt.fts"), (.double, .reg "f")] [.ptr, .i64, .ptr],
      .cast "wext.fts" .sext .i32 (.reg "written.fts") .i64,
      .alloca "res.fts" strTy,
      strGep "res_d.fts" "res.fts" 0,
      .store .ptr (.reg "fbuf.fts") (.reg "res_d.fts"),
      strGep "res_l.fts" "res.fts" 1,
      .store .i64 (.reg "wext.fts") (.reg "res_l.fts"),
      strGep "res_c.fts" "res.fts" 2,
      .store .i64 (.intLit 64) (.reg "res_c.fts"),
      .load "result.fts" strTy (.reg "res.fts")
    ], .ret strTy (some (.reg "result.fts"))⟩]
  let fnFloatToString : LLVMFnDef :=
    { name := "float_to_string", retTy := strTy, params := [("f", .double)], blocks := floatToStrBlocks }

  -- -------------------------------------------------------
  -- string_trim
  -- -------------------------------------------------------
  let strTrimBlocks : List LLVMBlock := [
    ⟨"entry", [
      strGep "st_data_ptr" "s" 0,
      .load "st_data" .ptr (.reg "st_data_ptr"),
      strGep "st_len_ptr" "s" 1,
      .load "st_len" .i64 (.reg "st_len_ptr")
    ], .br "trim_left"⟩,
    ⟨"trim_left", [
      .phi "tl_i" .i64 [(.intLit 0, "entry"), (.reg "tl_next", "tl_ws")],
      .binOp "tl_done" .icmpUge .i64 (.reg "tl_i") (.reg "st_len")
    ], .condBr (.reg "tl_done") "trim_result" "tl_check"⟩,
    ⟨"tl_check", [
      .gep "tl_ptr" .i8 (.reg "st_data") [(.i64, .reg "tl_i")],
      .load "tl_ch" .i8 (.reg "tl_ptr"),
      .binOp "tl_is_sp" .icmpEq .i8 (.reg "tl_ch") (.intLit 32),
      .binOp "tl_is_tab" .icmpEq .i8 (.reg "tl_ch") (.intLit 9),
      .binOp "tl_is_nl" .icmpEq .i8 (.reg "tl_ch") (.intLit 10),
      .binOp "tl_is_cr" .icmpEq .i8 (.reg "tl_ch") (.intLit 13),
      .binOp "tl_w1" .or_ .i1 (.reg "tl_is_sp") (.reg "tl_is_tab"),
      .binOp "tl_w2" .or_ .i1 (.reg "tl_is_nl") (.reg "tl_is_cr"),
      .binOp "tl_is_ws" .or_ .i1 (.reg "tl_w1") (.reg "tl_w2")
    ], .condBr (.reg "tl_is_ws") "tl_ws" "trim_right_init"⟩,
    ⟨"tl_ws", [
      .binOp "tl_next" .add .i64 (.reg "tl_i") (.intLit 1)
    ], .br "trim_left"⟩,
    ⟨"trim_right_init", [
      .binOp "tr_start" .sub .i64 (.reg "st_len") (.intLit 1)
    ], .br "trim_right"⟩,
    ⟨"trim_right", [
      .phi "tr_i" .i64 [(.reg "tr_start", "trim_right_init"), (.reg "tr_prev", "tr_ws")],
      .binOp "tr_done" .icmpUlt .i64 (.reg "tr_i") (.reg "tl_i")
    ], .condBr (.reg "tr_done") "trim_result" "tr_check"⟩,
    ⟨"tr_check", [
      .gep "tr_ptr" .i8 (.reg "st_data") [(.i64, .reg "tr_i")],
      .load "tr_ch" .i8 (.reg "tr_ptr"),
      .binOp "tr_is_sp" .icmpEq .i8 (.reg "tr_ch") (.intLit 32),
      .binOp "tr_is_tab" .icmpEq .i8 (.reg "tr_ch") (.intLit 9),
      .binOp "tr_is_nl" .icmpEq .i8 (.reg "tr_ch") (.intLit 10),
      .binOp "tr_is_cr" .icmpEq .i8 (.reg "tr_ch") (.intLit 13),
      .binOp "tr_w1" .or_ .i1 (.reg "tr_is_sp") (.reg "tr_is_tab"),
      .binOp "tr_w2" .or_ .i1 (.reg "tr_is_nl") (.reg "tr_is_cr"),
      .binOp "tr_is_ws" .or_ .i1 (.reg "tr_w1") (.reg "tr_w2")
    ], .condBr (.reg "tr_is_ws") "tr_ws" "trim_result"⟩,
    ⟨"tr_ws", [
      .binOp "tr_prev" .sub .i64 (.reg "tr_i") (.intLit 1)
    ], .br "trim_right"⟩,
    ⟨"trim_result", [
      .phi "tr_left" .i64 [(.reg "tl_i", "trim_left"), (.reg "tl_i", "trim_right"), (.reg "tl_i", "tr_check")],
      .phi "tr_right_raw" .i64 [(.intLit 0, "trim_left"), (.reg "tl_i", "trim_right"), (.reg "tr_i", "tr_check")],
      .binOp "tr_right" .add .i64 (.reg "tr_right_raw") (.intLit 1),
      .binOp "tr_empty" .icmpUge .i64 (.reg "tr_left") (.reg "tr_right")
    ], .condBr (.reg "tr_empty") "trim_empty" "trim_copy"⟩,
    ⟨"trim_empty", [
      .call (some "te_buf") .ptr (.global "malloc") [(.i64, .intLit 1)],
      .alloca "te_res" strTy,
      strGep "te_d" "te_res" 0,
      .store .ptr (.reg "te_buf") (.reg "te_d"),
      strGep "te_l" "te_res" 1,
      .store .i64 (.intLit 0) (.reg "te_l"),
      strGep "te_c" "te_res" 2,
      .store .i64 (.intLit 1) (.reg "te_c"),
      .load "te_result" strTy (.reg "te_res")
    ], .ret strTy (some (.reg "te_result"))⟩,
    ⟨"trim_copy", [
      .binOp "tc_len" .sub .i64 (.reg "tr_right") (.reg "tr_left"),
      .call (some "tc_buf") .ptr (.global "malloc") [(.i64, .reg "tc_len")],
      .gep "tc_src" .i8 (.reg "st_data") [(.i64, .reg "tr_left")],
      dynMemcpy "tc_buf" "tc_src" "tc_len",
      .alloca "tc_res" strTy,
      strGep "tc_d" "tc_res" 0,
      .store .ptr (.reg "tc_buf") (.reg "tc_d"),
      strGep "tc_l" "tc_res" 1,
      .store .i64 (.reg "tc_len") (.reg "tc_l"),
      strGep "tc_c" "tc_res" 2,
      .store .i64 (.reg "tc_len") (.reg "tc_c"),
      .load "tc_result" strTy (.reg "tc_res")
    ], .ret strTy (some (.reg "tc_result"))⟩]
  let fnStringTrim : LLVMFnDef :=
    { name := "string_trim", retTy := strTy, params := [("s", .ptr)], blocks := strTrimBlocks }

  -- -------------------------------------------------------
  -- Globals
  -- -------------------------------------------------------
  let globals : List LLVMGlobal := [
    { name := ".fmt_ld", ty := .array 4 .i8, value := "c\"%ld\\00\"" },
    { name := ".str_true", ty := .array 4 .i8, value := "c\"true\"" },
    { name := ".str_false", ty := .array 5 .i8, value := "c\"false\"" },
    { name := ".fmt_f", ty := .array 3 .i8, value := "c\"%g\\00\"" }
  ]

  -- -------------------------------------------------------
  -- Declarations
  -- Note: memcmp, strtol, snprintf are already declared in emitExternDecls,
  -- so we only add the intrinsics that are not declared there.
  -- -------------------------------------------------------
  let decls : List LLVMFnDecl := [
    { name := "llvm.smax.i64", retTy := .i64, params := [.i64, .i64] },
    { name := "llvm.smin.i64", retTy := .i64, params := [.i64, .i64] }
  ]

  let fns : List LLVMFnDef := [
    fnStringLength, fnDropString, fnStringConcat, fnStringSlice, fnStringCharAt,
    fnStringContains, fnStringEq, fnIntToString, fnStringToInt, fnBoolToString,
    fnFloatToString, fnStringTrim
  ]
  (fns, globals, decls)

-- ============================================================
-- Vec builtins
-- ============================================================

/-- Generate standalone Vec builtin function definitions for the SSA path.
    Size-independent ops (vec_len, vec_free) are emitted once.
    Size-dependent ops (vec_new, vec_push, vec_get, vec_set) are emitted per
    distinct element size. vec_pop is emitted per (size, payloadOffset) pair
    because the Option enum payload offset depends on element alignment.
    All per-size ops use ptr-based value passing with memcpy for correctness.
    Note: GEPs omit `inbounds` — semantically identical, slightly less optimizable. -/
def getVecBuiltinFns (specs : List (Nat × Nat)) : List LLVMFnDef :=
  let vecTy := LLVMTy.struct_ "Vec"
  let optTy := LLVMTy.enum_ "Option"
  let ic : Int := 8   -- initial capacity
  -- Helper: getelementptr %struct.Vec, ptr %base, i32 0, i32 N
  let vecGep (dst base : String) (fieldIdx : Int) : LLVMInstr :=
    .gep dst vecTy (.reg base) [(.i32, .intLit 0), (.i32, .intLit fieldIdx)]
  -- -------------------------------------------------------
  -- Size-independent: vec_len
  -- -------------------------------------------------------
  let vecLen : LLVMFnDef := { name := "vec_len", retTy := .i64, params := [("vec", .ptr)], blocks := [
    ⟨"entry", [
      vecGep "lp" "vec" 1, .load "len" .i64 (.reg "lp")
    ], .ret .i64 (some (.reg "len"))⟩] }
  -- -------------------------------------------------------
  -- Size-independent: vec_free
  -- -------------------------------------------------------
  let vecFree : LLVMFnDef := { name := "vec_free", retTy := .void, params := [("vec", .ptr)], blocks := [
    ⟨"entry", [
      vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
      .call none .void (.global "free") [(.ptr, .reg "data")]
    ], .ret .void none⟩] }
  -- -------------------------------------------------------
  -- Deduplicate sizes for push/get/set/new (only need elem size)
  -- -------------------------------------------------------
  let uniqueSizes := specs.foldl (fun (acc : List Nat) (sz, _) =>
    if acc.contains sz then acc else acc ++ [sz]) []
  -- -------------------------------------------------------
  -- Per-size: vec_new_{es}, vec_push_{es}, vec_get_{es}, vec_set_{es}
  -- All use ptr-based value passing with memcpy.
  -- -------------------------------------------------------
  let sizedFns := uniqueSizes.foldl (fun (acc : List LLVMFnDef) (esNat : Nat) =>
    let es : Int := esNat
    let ib : Int := ic * es
    let newName := s!"vec_new_{esNat}"
    let pushName := s!"vec_push_{esNat}"
    let getName := s!"vec_get_{esNat}"
    let setName := s!"vec_set_{esNat}"
    -- vec_new_{es}() -> %struct.Vec
    let vecNewBlocks : List LLVMBlock := [
      ⟨"entry", [
        .call (some "buf") .ptr (.global "malloc") [(.i64, .intLit ib)],
        .alloca "v" vecTy,
        vecGep "bp" "v" 0, .store .ptr (.reg "buf") (.reg "bp"),
        vecGep "lp" "v" 1, .store .i64 (.intLit 0) (.reg "lp"),
        vecGep "cp" "v" 2, .store .i64 (.intLit ic) (.reg "cp"),
        .load "r" vecTy (.reg "v")
      ], .ret vecTy (some (.reg "r"))⟩]
    let vecNew : LLVMFnDef := { name := newName, retTy := vecTy, params := [], blocks := vecNewBlocks }
    -- vec_push_{es}(vec: ptr, val: ptr) -> void
    let vecPushBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "lp" "vec" 1, .load "len" .i64 (.reg "lp"),
        vecGep "cp" "vec" 2, .load "cap" .i64 (.reg "cp"),
        .binOp "full" .icmpEq .i64 (.reg "len") (.reg "cap")
      ], .condBr (.reg "full") "grow" "store"⟩,
      ⟨"grow", [
        .binOp "newcap" .mul .i64 (.reg "cap") (.intLit 2),
        .binOp "newbytes" .mul .i64 (.reg "newcap") (.intLit es),
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .call (some "newbuf") .ptr (.global "realloc") [(.ptr, .reg "data"), (.i64, .reg "newbytes")],
        .store .ptr (.reg "newbuf") (.reg "dp"),
        .store .i64 (.reg "newcap") (.reg "cp")
      ], .br "store"⟩,
      ⟨"store", [
        vecGep "dp2" "vec" 0, .load "data2" .ptr (.reg "dp2"),
        .binOp "offset" .mul .i64 (.reg "len") (.intLit es),
        .gep "slot" .i8 (.reg "data2") [(.i64, .reg "offset")],
        .memcpy (.reg "slot") (.reg "val") esNat,
        .binOp "newlen" .add .i64 (.reg "len") (.intLit 1),
        .store .i64 (.reg "newlen") (.reg "lp")
      ], .ret .void none⟩]
    let vecPush : LLVMFnDef := { name := pushName, retTy := .void, params := [("vec", .ptr), ("val", .ptr)], blocks := vecPushBlocks }
    -- vec_get_{es}(vec: ptr, idx: i64) -> ptr
    let vecGetBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .binOp "offset" .mul .i64 (.reg "idx") (.intLit es),
        .gep "slot" .i8 (.reg "data") [(.i64, .reg "offset")]
      ], .ret .ptr (some (.reg "slot"))⟩]
    let vecGet : LLVMFnDef := { name := getName, retTy := .ptr, params := [("vec", .ptr), ("idx", .i64)], blocks := vecGetBlocks }
    -- vec_set_{es}(vec: ptr, idx: i64, val: ptr) -> void
    let vecSetBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .binOp "offset" .mul .i64 (.reg "idx") (.intLit es),
        .gep "slot" .i8 (.reg "data") [(.i64, .reg "offset")],
        .memcpy (.reg "slot") (.reg "val") esNat
      ], .ret .void none⟩]
    let vecSet : LLVMFnDef := { name := setName, retTy := .void, params := [("vec", .ptr), ("idx", .i64), ("val", .ptr)], blocks := vecSetBlocks }
    acc ++ [vecNew, vecPush, vecGet, vecSet]
  ) ([] : List LLVMFnDef)
  -- -------------------------------------------------------
  -- Per-spec: vec_pop_{es}_{payOff} (needs both size and payload offset)
  -- Uses memcpy for buffer read and correct Option payload placement.
  -- -------------------------------------------------------
  let popFns := specs.foldl (fun (acc : List LLVMFnDef) ((esNat, payOff) : Nat × Nat) =>
    let es : Int := esNat
    let popName := s!"vec_pop_{esNat}_{payOff}"
    let vecPopBlocks : List LLVMBlock := [
      ⟨"entry", [
        vecGep "lp" "vec" 1, .load "len" .i64 (.reg "lp"),
        .binOp "empty" .icmpEq .i64 (.reg "len") (.intLit 0)
      ], .condBr (.reg "empty") "none" "some"⟩,
      ⟨"some", [
        .binOp "newlen" .sub .i64 (.reg "len") (.intLit 1),
        .store .i64 (.reg "newlen") (.reg "lp"),
        vecGep "dp" "vec" 0, .load "data" .ptr (.reg "dp"),
        .binOp "offset" .mul .i64 (.reg "newlen") (.intLit es),
        .gep "slot" .i8 (.reg "data") [(.i64, .reg "offset")],
        -- Zero-initialize the Option, then copy element into payload
        .alloca "res" optTy,
        .call none .void (.global "memset") [(.ptr, .reg "res"), (.i32, .intLit 0), (.i64, .intLit (Layout.alignUp (payOff + esNat) (Nat.max 4 (Nat.min esNat 8))))],
        .store .i32 (.intLit 0) (.reg "res"),
        .gep "payload" .i8 (.reg "res") [(.i64, .intLit payOff)],
        .memcpy (.reg "payload") (.reg "slot") esNat,
        .load "r" optTy (.reg "res")
      ], .ret optTy (some (.reg "r"))⟩,
      ⟨"none", [
        .alloca "res2" optTy,
        .call none .void (.global "memset") [(.ptr, .reg "res2"), (.i32, .intLit 0), (.i64, .intLit (Layout.alignUp (payOff + esNat) (Nat.max 4 (Nat.min esNat 8))))],
        .store .i32 (.intLit 1) (.reg "res2"),
        .load "r2" optTy (.reg "res2")
      ], .ret optTy (some (.reg "r2"))⟩]
    let vecPop : LLVMFnDef := { name := popName, retTy := optTy, params := [("vec", .ptr)], blocks := vecPopBlocks }
    acc ++ [vecPop]
  ) ([] : List LLVMFnDef)
  [vecLen, vecFree] ++ sizedFns ++ popFns

end Concrete
