# `scanint()` signed-integer-overflow (relaxed, not fixed)

**Location:** `02_Parser/scan.c`, `scanint()`:

```c
static int scanint(int c) {
  int k, val = 0;

  // Convert each character into an int value
  while ((k = chrpos("0123456789", c)) >= 0) {
    val = val * 10 + k;
    c = next();
  }
  ...
}
```

**What it is:** a classic teaching-compiler idiom — accumulate a numeric literal digit-by-digit
into a plain `int` with no width/overflow check. Any digit run whose value exceeds `INT_MAX`
(roughly 10+ digits) makes `val * 10 + k` a signed-integer-overflow: undefined behavior per the C
standard, and a real (if minor) defect — a sufficiently long numeric literal silently produces a
wrong value instead of erroring. It is **not** a memory-safety bug: no OOB read/write, no
use-after-free, nothing ASan would ever flag.

**Why it matters for fuzzing:** the harness's seed corpus (`mayhem/parser/testsuite/`) is
arithmetic expressions built entirely from digits, and libFuzzer's mutators readily grow/duplicate
byte runs — so a mutated input containing a 10+ digit run is reached almost immediately. With
UBSan's `signed-integer-overflow` check halting, the process aborts inside `scanint()` on
essentially the *first* token of virtually every execution, before `scan()`/`binexpr()`/
`interpretAST()` ever see a second token.

**Measured (2026-08-17), before relaxing the check:** `libFuzzer -fork=4 -ignore_crashes=1
-max_total_time=120` from the seed corpus ran ~32.4M total executions across ~15,283 fork jobs,
and recorded `cov:0 ft:0 corp:0` for the *entire* 120s run — i.e. zero net coverage/corpus growth.
Nearly every job's crash count matched its total; the single most common crash was exactly this
overflow (`scan.c:58:15: runtime error: signed integer overflow: NNNNNNNNN * 10 cannot be
represented in type 'int'`). This is the "so crash-dense it cannot explore" failure mode: a target
that would burn an entire fuzzing campaign re-discovering the same trivial bug on every input,
never reaching the parser/interpreter logic the harness exists to exercise.

**Resolution:** `mayhem/build.sh` relaxes only the `signed-integer-overflow` UBSan sub-check
(`-fno-sanitize=signed-integer-overflow`) for the fuzz build. ASan and every other UBSan check
(OOB, use-after-free, null-deref, shift, etc.) stay fully on and halting. Upstream's `scan.c` is
**not modified** — the branch invariant (mayhem = purely additive over upstream) forbids patching
it, and the bug is genuine-but-harmless, not a reason to give up on fuzzing the rest of the parser.

After relaxing, a repeat `-fork=4 -max_total_time=120` run explores normally (coverage/corpus grow
past the initial seeds; see the PR description / integration report for the exact numbers) instead
of flatlining at `cov:0 ft:0 corp:0`.

**If re-enabling this check is ever desired** (e.g. to specifically hunt overflow bugs), the fix
would be a `val > (INT_MAX - k) / 10` bound check in `scanint()` before the multiply — additive to
apply, but out of scope here since upstream files must stay unmodified in this integration.
