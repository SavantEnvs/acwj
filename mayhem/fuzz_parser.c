// libFuzzer harness for acwj's 02_Parser: drives the same scan -> binexpr ->
// interpretAST path as 02_Parser/main.c, but in-process over an in-memory file.
// The original Mayhem target was the raw file-input CLI (/acwj/02_Parser/parser @@);
// with halting sanitizers every malformed input exits immediately, so the CLI form
// is unproductive — this harness fuzzes the identical code path in-process instead
// (target name `parser` is preserved). The parser's error paths call exit(), which
// build.sh renames to acwj_exit (-Dexit=acwj_exit) so they longjmp back here.
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>

#include "defs.h"
#define extern_
#include "data.h"
#undef extern_
#include "decl.h"

static volatile sig_atomic_t have_env = 0;
static sigjmp_buf fuzz_env;

// Bound for exit() calls inside the parser (renamed via -Dexit=acwj_exit).
void acwj_exit(int code) {
  (void)code;
  if (have_env)
    siglongjmp(fuzz_env, 1);
}

// interp.c's interpretAST() does an UNCHECKED `leftval / rightval` (a real,
// if trivial, upstream defect — see mayhem/parser/known-findings/). This
// grammar stage's binexpr() is right-associative with no parens
// (`right = binexpr()`), so a divisor can be an arbitrary sub-expression
// computed at RUNTIME (e.g. "8 / 5 - 5" parses as 8 / (5 - 5)) — a zero
// divisor needs no literal "0" anywhere in the input, so it is reached by
// almost any mutation of the seed corpus's arithmetic expressions. Measured
// (2026-08-17): with the flood above resolved, a 120s -fork=4 run still
// recorded cov:0 ft:0 corp:0 for the entire campaign, rediscovering only
// this one crash (interp.c:37 division by zero) on virtually every
// execution — the "so crash-dense it cannot explore" failure mode.
// build.sh disables UBSan's software check for this
// (-fno-sanitize=integer-divide-by-zero) so the actual x86 idiv-by-zero
// fires as an ordinary hardware trap (SIGFPE) instead of a software abort();
// this handler catches that trap and routes it to the SAME recovery point
// as exit() above — exactly the same "don't let one fatal input path end
// the persistent fuzzer process" design the legacy harness already applies
// to exit(). ASan and every other UBSan check stay fully on and halting;
// this does not suppress any memory-safety signal, only this one
// non-memory-safety, already-documented, trivially-reachable defect.
static void fpe_handler(int sig) {
  (void)sig;
  if (have_env)
    siglongjmp(fuzz_env, 2);
  _exit(1);
}

// 02_Parser is an allocate-and-exit batch tool: mkastnode() (02_Parser/tree.c) mallocs every
// AST node and NEVER frees any of them — main.c relies on process exit to reclaim memory, a
// non-issue for the original one-shot CLI. This harness instead runs millions of iterations in
// one PERSISTENT process, so that pattern is a genuine per-iteration leak that will OOM any
// sufficiently long campaign (confirmed empirically: a 75s -fork=4 run already produced a dozen
// "oom-" artifacts from RSS growth, with no actual crash). Rather than modify upstream's tree.c
// to add frees (forbidden — additive-only), build.sh compiles tree.c with `-Dmalloc=acwj_arena_alloc`
// (the same "rename a libc call the parser makes internally" trick already used for exit() above),
// which routes every mkastnode() allocation through the bump arena below; LLVMFuzzerTestOneInput
// resets the arena's offset to 0 on EVERY call — including one entered via a longjmp/siglongjmp
// recovery — so each iteration's AST memory is reclaimed unconditionally, regardless of which path
// (normal completion, exit()-intercept, or SIGFPE-intercept) that iteration took.
#define ARENA_SIZE (16u * 1024u * 1024u)
static unsigned char arena[ARENA_SIZE];
static size_t arena_off = 0;

void *acwj_arena_alloc(size_t sz) {
  sz = (sz + 7u) & ~(size_t)7u;   // 8-byte align, matches malloc's usual guarantee
  if (sz == 0 || arena_off + sz > ARENA_SIZE)
    return malloc(sz);   // pathological single input: fall back, leaked for this iteration only
  void *p = &arena[arena_off];
  arena_off += sz;
  return p;
}

const char *__asan_default_options(void) { return "detect_leaks=0"; }

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void)argc;
  (void)argv;
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = fpe_handler;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGFPE, &sa, NULL);
  return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  arena_off = 0;
  FILE *f = fmemopen((void *)data, size, "r");
  if (f == NULL)
    return 0;
  Infile = f;
  Line = 1;
  Putback = '\n';
  Token.token = 0;
  Token.intvalue = 0;
  if (sigsetjmp(fuzz_env, 1) == 0) {
    have_env = 1;
    scan(&Token);
    struct ASTnode *n = binexpr();
    interpretAST(n);
  }
  have_env = 0;
  fclose(f);
  Infile = NULL;
  return 0;
}
