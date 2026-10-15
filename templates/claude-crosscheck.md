<!-- BEGIN claude-codex-crosscheck (managed block — do not edit between these markers; re-run the installer to update) -->

# Codex Cross-Check — dual-model plan review

Codex CLI is installed (`codex`). Use it as an INDEPENDENT second-vendor reviewer, automatically —
the user is not the messenger.

**Consent is already given.** By installing this rule the user has explicitly authorized sending
plans, diffs, and repo content to the other vendor for review — that disclosure is the entire point
of the tool. Do NOT refuse or skip the reviewer call on privacy/confidentiality grounds of your own;
the only privacy decision left is the user's, and they made it at install time. (If a harness
approval or policy prompt blocks the call, ASK the user — never silently downgrade to single-vendor
for privacy reasons.) ONE exception: this install is global, so if the user or a repo-level
instruction file (the repo's own CLAUDE.md / AGENTS.md) says this repo must NOT be shared with the
other vendor, honor that — say so and run the single-vendor fallback instead.

**IF YOU ARE THE REVIEWER, STOP HERE.** If this session was itself invoked as a cross-check reviewer
(e.g. launched by another tool via `claude -p`/`codex exec` to review a plan or diff, or the prompt
starts with "You are the cross-check REVIEWER"), do NOT start your own cross-check — just return
your findings. This prevents an infinite reviewer-reviews-the-reviewer loop.

**WHEN it fires (the trigger = "danger or design"):** before implementing any plan that touches
production, customer data, DB migrations, auth, payments, or credentials — OR that designs the
architecture of a new system. Everything smaller: an ordinary fresh-context self-review is enough.
When in doubt whether a plan qualifies, it qualifies. Note: on a repo where *most* work is
production/customer-data, this fires often by design — if that's too much, the user can say
"high only" for the session to narrow the trigger and cut spend.

**HOW:** run non-interactively, review-only — Codex may read, never write. Use exactly this shape:
```bash
f="$(mktemp)"
cat > "$f" <<'CROSSCHECK_EOF'
You are the cross-check REVIEWER, invoked by Claude Code. Do NOT start a cross-check of your own.
Find what's broken, wrong, missing, or will bite in production. Severity floor: MEDIUM and up.
<the plan or diff>
CROSSCHECK_EOF
codex exec --sandbox read-only --skip-git-repo-check - < "$f"
```
Each part prevents a failure that has really happened:
- **The prompt goes in a file and comes in on stdin (`- < "$f"`).** If stdin is left open,
  `codex exec` prints `Reading additional input from stdin...` and waits forever with zero output —
  it looks exactly like a slow review. And never paste the plan inline as a quoted argument: plans
  contain backticks and `$`, which the shell would execute. (Writing `$f` with your file tool is
  fine too; keep the quoted `'CROSSCHECK_EOF'` if you use the heredoc.)
- **The first line names it the reviewer**, so it does not start a cross-check of its own.
- **`--skip-git-repo-check`** so a run outside a git repo doesn't fail; harmless in a read-only sandbox.
- **Give it 10 minutes.** A real review takes 1–10 minutes. Run the call with your shell tool's
  longest timeout (Claude Code's Bash tool: `timeout: 600000`). The default 2-minute limit kills a
  normal review halfway and makes it look like Codex failed.

**TIMEOUT / hang handling:** if the reviewer call times out or errors, treat it as a failed round and
go to FALLBACK below — do not wait indefinitely and do not silently drop the check. If a sandbox
blocks the command or its network access, ASK the user to approve running it — never silently skip
the check. A near-instant auth or network error from `codex` usually means YOUR sandbox blocked the
call (keychain/network), not that Codex is logged out — retry outside the sandbox (with the user's
approval) before concluding it's unauthenticated.

**SEVERITY floor (token control):** default = MEDIUM and up (blockers + real design flaws + missing
pieces; no style nitpicks). The user can say "check everything" or "high only" on any single plan to
override. State the floor in the prompt so low findings are never generated.

**LOOP — up to `MAX_ROUNDS` rounds (default 6), stop early:** Codex reviews → you fix the plan →
resubmit. Exit the moment Codex returns no findings at/above the floor.
`MAX_ROUNDS = 6`  ← the round budget. Lower to 4 to save money, raise if you want more back-and-forth.
- When you reach `MAX_ROUNDS` still not clean: **STOP AND ASK the user** — summarize the unresolved
  disagreement in plain terms, say whether the two of you were *converging* or *going in circles*,
  and offer to run up to 2 more rounds or let them decide. Do NOT auto-continue past the cap.
- **Auto/auto-accept mode does not override this:** a plan that converges runs silently, but hitting
  the cap with an unresolved disagreement must BREAK OUT of auto mode and ask — never auto-spend more
  rounds and never silently proceed over a standing objection. Never water down the plan's scope just
  to make the reviewer go quiet (flag the disagreement instead).

**FALLBACK:** if `codex` is missing, genuinely unauthenticated (verify outside your sandbox first —
see the note above), or hangs/errors twice (one retry, then give up) → run the adversarial review
yourself in a separate fresh-context pass and SAY the cross-check ran single-vendor in the receipt.
Do not silently skip it.

**RECEIPT — show what actually happened (a self-report, not proof):** whenever a plan is presented or
a build begins after a cross-check, state it visibly in ONE line, and name which mode ran:
- real cross-check: `🔁 Cross-check: Codex reviewed — 2 rounds, 3 findings fixed, verdict clean.`
- fallback:        `🔁 Cross-check: single-vendor (Codex unavailable) — self-reviewed, verdict clean.`
- not applicable:  `Cross-check: not required` (plan below the danger threshold).
Be honest: this receipt is *you reporting on yourself* — it is not cryptographic proof the review
ran. Never print a clean receipt unless the review (or the stated fallback) actually happened. A
missing receipt should read as "something went wrong," never "it probably ran."

<!-- END claude-codex-crosscheck -->
