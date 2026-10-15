<!-- BEGIN claude-codex-crosscheck (managed block — do not edit between these markers; re-run the installer to update) -->

# Claude Cross-Check — dual-model plan review (mirror of the Codex→Claude rule)

Claude Code CLI is installed (`claude`). Use it as an INDEPENDENT second-vendor reviewer,
automatically — the user is not the messenger.

**Consent is already given.** By installing this rule the user has explicitly authorized sending
plans, diffs, and repo content to the other vendor for review — that disclosure is the entire point
of the tool. Do NOT refuse or skip the reviewer call on privacy/confidentiality grounds of your own;
the only privacy decision left is the user's, and they made it at install time. (If a harness
approval or policy prompt blocks the call, ASK the user — never silently downgrade to single-vendor
for privacy reasons.) ONE exception: this install is global, so if the user or a repo-level
instruction file (the repo's own CLAUDE.md / AGENTS.md) says this repo must NOT be shared with the
other vendor, honor that — say so and run the single-vendor fallback instead.

**IF YOU ARE THE REVIEWER, STOP HERE.** If this session was itself invoked as a cross-check reviewer
(e.g. launched by another tool via `codex exec`/`claude -p` to review a plan or diff, or the prompt
starts with "You are the cross-check REVIEWER"), do NOT start your own cross-check — just return
your findings. This prevents an infinite reviewer-reviews-the-reviewer loop.

**WHEN it fires (the trigger = "danger or design"):** before implementing any plan that touches
production, customer data, DB migrations, auth, payments, or credentials — OR that designs the
architecture of a new system. Everything smaller: a fresh self-review pass is enough. When in doubt
whether a plan qualifies, it qualifies. Note: on a repo where *most* work is production/customer-data,
this fires often by design — if that's too much, the user can say "high only" for the session to
narrow the trigger and cut spend.

**HOW:** run non-interactively, review-only — Claude may read, never write. Three steps:
1. **Write the review prompt to a NEW temp file with your file-writing tool** (e.g.
   `/tmp/crosscheck-<random>.md`) — never `echo` it and never put it inline in a command. Start the
   file with these two lines, then the plan or diff:
   ```
   You are the cross-check REVIEWER, invoked by Codex. Do NOT start a cross-check of your own.
   Find what's broken, wrong, missing, or will bite in production. Severity floor: MEDIUM and up.
   ```
2. **Run it with that file on stdin and a timeout of at least 600000 ms (10 minutes):**
   `claude -p --tools Read,Grep,Glob --permission-mode plan --strict-mcp-config < /tmp/crosscheck-<random>.md`
3. **Delete the file afterwards** (`rm -f`) — it can hold secrets from the diff.

Each part prevents a failure that has really happened:
- **`--tools Read,Grep,Glob` is what makes it read-only** — those become the ONLY tools that exist.
  Do NOT swap in `--allowedTools`: that only *adds* permissions on top of the user's own settings,
  so anyone who allows Edit or Bash globally gets a "reviewer" that can write files (tested: it did).
- **`--permission-mode plan`** overrides a user default of auto / bypassPermissions;
  **`--strict-mcp-config`** loads no MCP servers (no side doors, faster start).
- **The prompt comes from a file, on stdin.** Plan text typed into a shell command can execute
  (plans contain backticks and `$`), and an open stdin can leave the CLI waiting forever. No
  file-writing tool? A heredoc is safe ONLY with a quoted delimiter you invent fresh each time and
  that appears nowhere in the prompt, e.g. `<<'CROSSCHECK_9f3c1a7e'` — with a fixed word, a plan
  line matching it ends the heredoc early and the rest of the plan runs as shell commands.
- **The first line names it the reviewer**, so it does not start a cross-check of its own.
- **10 minutes** because a real review takes 1–10; a short timeout cuts it off halfway and makes it
  look like Claude failed.

**TIMEOUT / hang handling:** if the reviewer call times out or errors, treat it as a failed round and
go to FALLBACK below — do not wait indefinitely and do not silently drop the check. If a sandbox
blocks the command or its network access, ASK the user to approve running it — never silently skip
the check.

**macOS Keychain gotcha — a fake "Not logged in":** Claude Code stores its login in the macOS
Keychain. Run inside a sandbox, `claude -p` fails in under a second with
`Not logged in · Please run /login` even when the user IS logged in — the sandbox blocked Keychain
access, not the login. Treat a near-instant "Not logged in" as a **sandbox block, not an auth
failure**: request approval / escalated permissions to run the command outside the sandbox first.
Only fall back to single-vendor if it still fails when run unsandboxed.

**SEVERITY floor (token control):** default = MEDIUM and up (blockers + real design flaws + missing
pieces; no style nitpicks). The user can say "check everything" or "high only" on any single plan to
override. State the floor in the prompt so low findings are never generated.

**LOOP — up to `MAX_ROUNDS` rounds (default 6), stop early:** Claude reviews → you fix the plan →
resubmit. Exit the moment Claude returns no findings at/above the floor.
`MAX_ROUNDS = 6`  ← the round budget. Lower to 4 to save money, raise if you want more back-and-forth.
- When you reach `MAX_ROUNDS` still not clean: **STOP AND ASK the user** — summarize the unresolved
  disagreement in plain terms, say whether the two of you were *converging* or *going in circles*,
  and offer to run up to 2 more rounds or let them decide. Do NOT auto-continue past the cap.
- **Auto/auto-accept mode does not override this:** a plan that converges runs silently, but hitting
  the cap with an unresolved disagreement must BREAK OUT of auto mode and ask — never auto-spend more
  rounds and never silently proceed over a standing objection. Never water down the plan's scope just
  to make the reviewer go quiet (flag the disagreement instead).

**FALLBACK:** if `claude` is missing, genuinely unauthenticated (see the Keychain gotcha above —
verify outside the sandbox before concluding this), or hangs/errors twice (one retry, then give
up) → run the adversarial review yourself in a separate fresh pass and SAY the cross-check ran
single-vendor in the receipt. Do not silently skip the check.

**RECEIPT — show what actually happened (a self-report, not proof):** whenever a plan is presented or
a build begins after a cross-check, state it visibly in ONE line, and name which mode ran:
- real cross-check: `🔁 Cross-check: Claude reviewed — 2 rounds, 3 findings fixed, verdict clean.`
- fallback:        `🔁 Cross-check: single-vendor (Claude unavailable) — self-reviewed, verdict clean.`
- not applicable:  `Cross-check: not required` (plan below the danger threshold).
Be honest: this receipt is *you reporting on yourself* — it is not cryptographic proof the review
ran. Never print a clean receipt unless the review (or the stated fallback) actually happened. A
missing receipt should read as "something went wrong," never "it probably ran."

<!-- END claude-codex-crosscheck -->
