#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Build upstream (EDIT: the project's real build). Apply $DEBUG_FLAGS alongside $SANITIZER_FLAGS so
#    the project carries DWARF < 4 symbols (put $DEBUG_FLAGS AFTER $SANITIZER_FLAGS — its -gdwarf-3 then
#    wins over any -g the base may carry).
#    cmake:  cmake -B build -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
#                  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
#                  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
#            && cmake --build build -j"$MAYHEM_JOBS"
#    autotools:  ./configure CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" && make -j"$MAYHEM_JOBS"
#    Rust (cargo-fuzz):  RUSTFLAGS="${RUSTFLAGS:-} $RUST_DEBUG_FLAGS -Zsanitizer=address" \
#            cargo fuzz build --release <target> --fuzz-dir mayhem/fuzz
#    Go (go-fuzz/libFuzzer):  go build $GO_DEBUG_FLAGS -tags gofuzz ...  (do NOT pass -ldflags=-s -w)

# 2) Compile each harness in mayhem/ TWICE (EDIT): once linking the fuzzing engine (the fuzzer
#    binary), once linking the standalone driver $STANDALONE_FUZZ_MAIN (a NON-fuzzer run-once
#    reproducer: takes an input file, runs LLVMFuzzerTestOneInput once, crashes naturally — no
#    libFuzzer runtime). Both respect $SANITIZER_FLAGS and $DEBUG_FLAGS (so the empty sanitizer
#    off-switch still keeps DWARF symbols).
#    $CC  $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
#        "$SRC/mayhem/fuzz_example.c" -I"$SRC/include" "$SRC/build/libexample.a" \
#        -o /mayhem/fuzz_example
#    $CC  $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" \
#        "$SRC/mayhem/fuzz_example.c" -I"$SRC/include" "$SRC/build/libexample.a" \
#        -o /mayhem/fuzz_example-standalone
#    (If the project ships its own file-input driver — e.g. fio's onefile.c, built when
#     LIB_FUZZING_ENGINE is unset — use that instead of $STANDALONE_FUZZ_MAIN.)
#    C++ HARNESS: compile the driver as C first so its LLVMFuzzerTestOneInput ref keeps C linkage
#    (clang++ would mangle it and miss the harness's extern "C" def):
#       $CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
#       $CXX $SANITIZER_FLAGS $DEBUG_FLAGS <c++flags> harness.cpp /tmp/standalone_main.o lib.a -o /mayhem/fuzz_example-standalone

# 3) Build the project's TEST suite too, with NORMAL flags (independent of the sanitized build above)
#    so mayhem/test.sh only RUNS it. Put the runner where test.sh looks (EDIT). Examples:
#    cmake:    cmake -B build-tests -DCMAKE_BUILD_TYPE=Release <enable-tests> -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" && cmake --build build-tests -j"$MAYHEM_JOBS" --target <test-target>
#    autotools/make: (env -u CFLAGS -u LDFLAGS) ./configure CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" && make -j"$MAYHEM_JOBS" <test-binary>
#    single-file: $CC -O2 $COVERAGE_FLAGS -o /mayhem/<name>_selftest "$SRC/mayhem/<selftest>.c"
#    Append $COVERAGE_FLAGS (empty by default) so a coverage build instruments the suite; no effect otherwise.
#    If the repo has NO tests meaningful for RL, build nothing here and ship no mayhem/test.sh.

: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"

# One benign-but-UB flood found empirically while integrating this repo (measured: a 120s
# libFuzzer -fork=4 run from the seed corpus recorded cov:0 ft:0 corp:0 the ENTIRE run, with
# oom/timeout/crash counting essentially 1:1 against total jobs — i.e. the target could not
# explore past this single bug on almost any mutated input). 02_Parser/scan.c's scanint()
# accumulates a numeric literal with the classic teaching-compiler idiom `val = val*10 + k`
# and NO overflow bound (see the file: it is the whole function body) — any digit run beyond
# ~10 chars trips signed-integer-overflow. Because the seed corpus is arithmetic expressions
# (all digits) and libFuzzer's mutators readily grow/duplicate byte runs, an input containing
# a long digit run is reached almost immediately by mutation, so with this check halting the
# process aborts on the FIRST scanint() call of virtually every execution, before scan()/
# binexpr()/interpretAST() ever see a second token — starving the target of coverage (the
# xdelta/cc65 precedent: "a halting UBSan check can silently starve a target of coverage").
# This is a real (if functionally harmless — it only yields a numerically wrong value, no
# memory-safety impact) defect in upstream's scanner; upstream files stay unmodified (branch
# invariant), so it is relaxed here at the SANITIZER level instead, and recorded as a known
# finding rather than fixed: mayhem/parser/known-findings/scanint-signed-overflow.md. Relax
# ONLY this specific sub-check; ASan and the rest of UBSan (real OOB, use-after-free, null
# deref, ...) stay fully on and halting.
case "$SANITIZER_FLAGS" in
  *signed-integer-overflow*) ;;
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fno-sanitize=signed-integer-overflow" ;;
esac

# Second relaxation, same rationale, different mechanism: interp.c's interpretAST() does an
# unchecked `leftval / rightval` (see mayhem/parser/known-findings/interp-division-by-zero.md).
# This grammar stage is right-associative with no parens, so a runtime-zero divisor needs no
# literal "0" in the input (e.g. "8 / 5 - 5" parses as 8 / (5 - 5)) — reached by almost any
# mutation of the seed corpus. Measured: even after relaxing signed-integer-overflow above, a
# 120s -fork=4 run still recorded cov:0 ft:0 corp:0 for the ENTIRE campaign, rediscovering only
# this one crash. Disabling UBSan's software check here does NOT suppress the crash by itself —
# the actual x86 idiv-by-zero then fires as a normal hardware SIGFPE trap — mayhem/fuzz_parser.c
# installs a SIGFPE handler that routes that trap to the same recovery point as exit(), so the
# persistent fuzzer process survives it exactly as it already survives exit(). ASan and every
# other UBSan check stay fully on and halting.
case "$SANITIZER_FLAGS" in
  *integer-divide-by-zero*) ;;
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fno-sanitize=integer-divide-by-zero" ;;
esac

# Coverage instrumentation (SPEC §6.2 item 11 — a Mayhem run must record edges_covered>0).
# $LIB_FUZZING_ENGINE (-fsanitize=fuzzer) is only passed at the FINAL link below, to bring in
# libFuzzer's own main()/driver — SanitizerCoverage instrumentation of the PROJECT's own code
# is a per-compile-unit flag, so without it here scan.o/expr.o/interp.o/tree.o/fuzz_parser.o
# would carry ZERO trace-pc-guard callbacks and libFuzzer would report cov:0/ft:0 forever
# regardless of how the target runs (measured empirically: fixing this is what turned this
# target from apparently-flat into one that visibly explores). `fuzzer-no-link` gives every
# compiled object the SAME coverage instrumentation as `-fsanitize=fuzzer` without each one
# trying to pull in its own libFuzzer main (cc65/qcbor convention).
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
export SANITIZER_FLAGS

# 1+2) Fuzz target `parser`: the 02_Parser scanner/parser/interpreter, compiled with
#      sanitizers + DWARF-3, with exit() routed to the harness's longjmp bound
#      (-Dexit=acwj_exit) so parser error paths return to the fuzzer instead of exiting, and
#      tree.c's malloc() routed to the harness's per-iteration bump arena (-Dmalloc=acwj_arena_alloc)
#      so AST nodes (never freed by upstream — see mayhem/fuzz_parser.c) don't leak across the
#      millions of iterations a persistent fuzzer process runs.
OBJ=/tmp/acwj-fuzz-obj
mkdir -p "$OBJ"
for f in scan expr interp tree; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC/02_Parser" -Dexit=acwj_exit -Dmalloc=acwj_arena_alloc \
    -c "$SRC/02_Parser/$f.c" -o "$OBJ/$f.o"
done
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC/02_Parser" \
  -c "$SRC/mayhem/fuzz_parser.c" -o "$OBJ/fuzz_parser.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
  "$OBJ"/scan.o "$OBJ"/expr.o "$OBJ"/interp.o "$OBJ"/tree.o "$OBJ"/fuzz_parser.o \
  -o "$SRC/parser"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" \
  "$OBJ"/scan.o "$OBJ"/expr.o "$OBJ"/interp.o "$OBJ"/tree.o "$OBJ"/fuzz_parser.o \
  -o "$SRC/parser-standalone"

# 3) Test suite: 62_Cleanup is the final full self-hosting compiler with the complete
#    149-test golden-output suite (tests/runtests compiles each input with cwj, runs it,
#    and diffs against the known-good out.*/err.* files). Build cwj with the project's
#    NORMAL flags per its Makefile; stage its include dir at INCDIR=/tmp/include (what
#    the Makefile's `install` does, minus the rsync dependency) so cwj can compile the
#    test inputs. test.sh only runs tests/runtests.
mkdir -p /tmp/include
cp -r "$SRC/62_Cleanup/include/." /tmp/include/
make -C "$SRC/62_Cleanup" cwj
