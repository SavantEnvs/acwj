# `interpretAST()` unchecked division by zero (relaxed at the sanitizer level, caught in-harness)

**Location:** `02_Parser/interp.c`, `interpretAST()`:

```c
case A_DIVIDE:
  return (leftval / rightval);
```

No check that `rightval != 0` anywhere in this stage's interpreter.

**Why the divisor doesn't need a literal `0`:** this stage's `binexpr()` (`02_Parser/expr.c`) is
**right-associative with no operator precedence and no parentheses** — `right = binexpr()`
recurses over the *entire* remainder of the expression. So `8 / 5 - 5` parses as `8 / (5 - 5)`,
not `(8 / 5) - 5`: the divisor is whatever the rest of the expression evaluates to at runtime, and
a zero divisor is reached by ordinary cancellation, not just by typing a literal `0`. Given the
seed corpus is short arithmetic expressions over small digits, almost any mutation produces some
`a - a` (or `a * 0`, or a chain that reduces to zero) somewhere in the remaining right-hand
sub-expression.

**Measured (2026-08-17):** after relaxing the `signed-integer-overflow` flood (see
`scanint-signed-overflow.md`), a repeat `libFuzzer -fork=4 -ignore_crashes=1 -max_total_time=120`
run from the seed corpus *still* recorded `cov:0 ft:0 corp:0` for the entire 120s campaign — over
15,000 fork jobs, essentially every one crashing at the same PC (`interp.c:37:23: runtime error:
division by zero`) before any new coverage was recorded. This is exactly the "rediscovering one
bug forever, burning the whole budget" failure mode (`docs/netnew-worker-prompt.md` §6c), not
"crashes often but still explores."

**Resolution:** `mayhem/build.sh` disables UBSan's software `integer-divide-by-zero` check for the
fuzz build. That alone does **not** suppress the crash — it just means the actual `idiv`
instruction executes with a zero divisor and the CPU raises a genuine hardware `SIGFPE` instead of
a software `abort()`. `mayhem/fuzz_parser.c` installs a `SIGFPE` handler
(`LLVMFuzzerInitialize`) that `siglongjmp`s back to the same recovery point already used for
`exit()` interception — the harness's existing design for "don't let one fatal input path end the
persistent fuzzer process," now extended to this trap. Upstream's `interp.c` is **not modified**.

ASan and every other UBSan check (OOB reads/writes, use-after-free, null-deref, shift, ...) remain
fully on and halting; only this one non-memory-safety, already-documented, trivially-reachable
divide-by-zero is routed around so the campaign can explore past it instead of re-finding it on
every single execution.

**Residual note.** This stage's `binexpr()` is also unbounded right-recursion (one recursive call
per remaining operator, no depth cap) — a sufficiently long operator chain could in principle
exhaust the stack. Not separately mitigated here (not observed to dominate the campaign the way
the two arithmetic UB cases above did); worth watching if a future run reports a stack-overflow
SIGSEGV as the dominant crash.
