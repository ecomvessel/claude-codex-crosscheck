# Claude ⇄ Codex Cross-Check

**Two AI coding assistants review each other's risky plans before either writes a line of code.**

When Claude Code is about to do something that touches production, customer data, a database
migration, auth, payments, or credentials, this asks it to pause and have **Codex** tear the plan
apart first — and Codex to do the same in reverse, calling **Claude**. Each acts as an independent
second-vendor reviewer, without you copy-pasting anything between them.

> **This is not a plugin, a program, or an enforced gate.** It's two small Markdown rule-files — one
> that Claude Code auto-reads (`~/.claude/CLAUDE.md`), one that Codex auto-reads (`~/.codex/AGENTS.md`).
> Each *instructs* its assistant to shell out to the *other* CLI as a read-only reviewer. Because it's
> a prompt to a probabilistic model — not a hook the tool is unable to skip — it's **best-effort: it
> nudges strongly and follows the rule the vast majority of the time, but it is not a guarantee.** If
> you need a hard, unskippable gate, enforce it in CI or a git hook; this makes the habit automatic,
> not unbreakable.

## What you need first

- [Claude Code](https://claude.com/claude-code) installed and logged in (`claude`)
- [Codex CLI](https://developers.openai.com/codex/cli) installed and logged in (`codex`)

Last tested end to end on 2026-10-15 against **`claude` 2.1.300** and **`codex` 0.160.1** on macOS.
The rules call each CLI with specific flags (`codex exec --sandbox read-only …`,
`claude -p --tools Read,Grep,Glob --permission-mode plan …`); if a future version renames a flag,
`./install.sh --check` tells you, and **Troubleshooting** below says what to do. The Codex→Claude direction also assumes Codex
auto-loads `~/.codex/AGENTS.md` as global instructions — confirm your Codex version does (see *Verify
it's live*).

You can install with only one CLI present, but then only the tool you actually run will act — and when
it tries to call the *absent* one, it falls back to a single-vendor self-review (you're not getting
true dual-vendor coverage until both are installed).

## Quickstart

One command:

```bash
curl -fsSL https://raw.githubusercontent.com/ecomvessel/claude-codex-crosscheck/main/quick-install.sh | bash
```

Prefer to read it before running (recommended)?

```bash
curl -fsSL https://raw.githubusercontent.com/ecomvessel/claude-codex-crosscheck/main/quick-install.sh -o quick-install.sh
less quick-install.sh
bash quick-install.sh
```

Or clone and run:

```bash
git clone https://github.com/ecomvessel/claude-codex-crosscheck
cd claude-codex-crosscheck
./install.sh
```

Then check it, and start a **new** session in either tool:

```bash
./install.sh --check      # or: curl -fsSL …/quick-install.sh | bash -s -- --check
```

`--check` changes nothing and calls no model. It confirms both blocks are installed and current,
both CLIs are on your PATH, and both still support every flag the rules use.

**Already have your own cross-check rule** (a "Cross-Check" heading you wrote yourself in
`CLAUDE.md` / `AGENTS.md`)? On a first install the installer leaves that file alone rather than add
a second rule that disagrees with yours. Delete or rename your section and re-run, or use
`./install.sh --force`. Once this block is in a file, plain re-runs always update it.

## How it behaves

- **Trigger = "danger or design."** It fires before any plan that touches production, customer
  data, DB migrations, auth, payments, or credentials — or that designs a brand-new system.
  Routine edits skip it. When in doubt, it treats the plan as qualifying.
- **Review-only.** The reviewer can read your code and the plan but cannot write, commit, or deploy.
  The two directions enforce this differently: Codex runs in a real OS **sandbox** (`--sandbox
  read-only`), while Claude is given **only read tools** (`--tools Read,Grep,Glob`, plus
  `--permission-mode plan`) — a tool restriction rather than a sandbox. Both were tested by asking
  the reviewer to create a file; both refused. (Earlier versions used `--allowedTools`, which only
  *adds* permissions: anyone whose settings allow Edit or Bash got a reviewer that could write.
  Re-run the installer to pick up the fix.)
- **The plan is never typed into a shell command.** The rule has the assistant write the review
  prompt to a temp file with its file-writing tool, feed it to the reviewer on stdin, then delete
  it. Plan text in a command line can execute (backticks, `$`), so this matters. It also fixes the
  classic hang where `codex exec` waits forever on an open stdin (`Reading additional input from
  stdin...`, zero output).
- **Loops, then asks — default up to 6 rounds.** Reviewer finds issues → author fixes → resubmit →
  repeat until clean. Most plans settle in 1–2 rounds. If the two models still disagree at the cap, it
  **stops and asks you** ("still disagreeing after 6 — run 2 more, or you decide?") rather than looping
  forever or spending silently. The cap is one editable number (`MAX_ROUNDS`, default 6) in each rule —
  lower it to 4 to save money, raise it for more back-and-forth. A genuine disagreement also **breaks
  out of auto-accept mode** to ask you — it never auto-spends more rounds on a stalemate.
- **Leaves a receipt (a self-report, not proof).** Qualifying plans print a line like
  `🔁 Cross-check: Codex reviewed — 2 rounds, 3 findings fixed, verdict clean.`, and plans below the
  danger threshold say `Cross-check: not required`. Treat a missing receipt as a red flag worth
  questioning. **But be clear-eyed:** the receipt is the model reporting on itself — a model *can*
  print it without having actually run the other tool. It's a strong convention and a useful tripwire,
  not cryptographic proof the review happened. If you need certainty on a given check, watch for the
  actual `codex exec` / `claude -p` call, or ask to see the reviewer's raw output.
- **Graceful fallback.** If the other CLI is missing or errors out, the assistant runs the
  adversarial review itself in a fresh pass and tells you it went single-vendor. It never silently
  skips the check.

## What it costs

Each cross-check spins up a **second AI on the other vendor's bill** to review the risky plan before
code is written — like paying a second contractor for a real second opinion before you build. Be
clear-eyed about what that costs — this is not a one-line API call:

- **The reviewer is a full agent, not "one short reply."** Each round is a fresh `codex exec` /
  `claude -p` process that **re-explores your repo from scratch** (reading files, grepping) with none
  of your session's cache — and it does that again on *every* round. On a large plan or diff in a big
  repo, **a single cross-check can cost as much as the planning turn it's protecting**, and a stubborn
  plan can run several rounds (default cap 6).
- **Billed to that vendor's account** — a Codex review hits your OpenAI usage, a Claude review hits
  your Anthropic usage. There is no single combined meter.
- **It fires often for prod-heavy work.** The trigger is "danger or design, and when in doubt it
  qualifies" — so if most of your work touches production/customer-data, expect it to fire a lot. Say
  "high only" for a session to narrow it, or lower `MAX_ROUNDS`, to control spend.
- **No built-in per-check meter.** A precise number isn't cleanly available (raw logs are inflated by
  cache re-reads). For a real figure on the Claude side, run its review with `--output-format json`
  and read `total_cost_usd` / `usage`.

Bottom line: it's insurance on your most expensive-to-get-wrong moments — but it's real spend that
scales with your repo and diff size, not a rounding error. Tune `MAX_ROUNDS` and the severity floor to
fit your budget.

## Privacy — what gets sent where

Cross-checking involves **both vendors** (OpenAI *and* Anthropic), because each acts as the other's
reviewer. Read this carefully — the blast radius is bigger than "your diff":

- The reviewer is an **autonomous agent given read access to your working tree**, not a function that
  receives only the diff. To "find what's broken," it reads whatever files it judges relevant — which
  **can include `.env` files, key material, `~/.aws`, config with tokens, and other secrets** — and
  the contents it reads are sent to that vendor's model.
- So a Codex review can send parts of your repo to OpenAI, and a Claude review can send parts to
  Anthropic. It's the same *channel* those CLIs already use — but this makes them read and transmit
  **more** than you might expect.
- **Use it only where sending code (including anything readable in the tree) to both providers is
  acceptable — and note the install is global**: the rule files apply to every repo the CLI opens,
  not just the one you installed from. To carve out a specific repo (client NDA, data residency),
  add a line to that repo's own `CLAUDE.md` / `AGENTS.md` — e.g. *"Do not send this repo's contents
  to other vendors; run cross-checks single-vendor only."* — the rule honors repo-level opt-outs.
  If most of your work can't be shared with one of the vendors, don't install it at all. The only real boundary is keeping secrets **outside any path
  the reviewer can read** — a secrets manager, the OS keychain, env vars injected at runtime.
  **`.gitignore` is not a privacy boundary:** a gitignored, untracked `.env` still sits in the
  working tree, is still readable, and can still be sent.

The reviewer runs locally in read-only mode and cannot write, commit, or deploy — but "read-only"
bounds *writes*, not *what it reads and sends*.

## Verify it's live

Because this is an instruction file (not enforced machinery), a half-broken install can fail
**silently** — nothing errors, the check just never fires. Confirm it works once after installing:

1. Run `./install.sh --check`. It must end with "All good".
2. Start a **new** session in the tool.
3. Give it a small qualifying plan, e.g. *"Plan a change to an auth or payments file"* (something in
   the "danger or design" trigger).
4. You should see the reviewer actually run (a `codex exec` / `claude -p` call) and a
   `🔁 Cross-check:` receipt. No receipt on a clearly-qualifying plan = that direction isn't wired up.

## Known failure behavior

It degrades rather than crashing, but the fallbacks are **best-effort** (a model following prose), not
guaranteed machinery. What to expect:

| Situation | What happens | What you'll see |
|---|---|---|
| Other CLI **not installed** | Falls back to single-vendor self-review | Receipt says `single-vendor` |
| Other CLI **not logged in / errors** | Retries once, then single-vendor fallback | Receipt says `single-vendor` |
| Reviewer **hangs** | The #1 cause (Codex waiting on stdin) is fixed by feeding the prompt from a file. Otherwise the rule tells the assistant to use a 10-minute shell timeout, then treat a timeout as a failed round → fallback | Receipt says `single-vendor` (may be slow) |
| Review **cut off at 2 minutes** | Claude Code's Bash tool defaults to a 2-minute limit; the rule tells Claude to use the 10-minute maximum, since real reviews take 1–10 minutes | Normal receipt |
| Run **outside a git repo** | `--skip-git-repo-check` is always passed (harmless in a read-only sandbox) | Normal receipt |
| **Sandbox blocks the reviewer** (most common: Codex's sandbox blocks `claude`'s macOS Keychain access → a fake `Not logged in` in <1s) | Rule says: treat as a sandbox block, ask to re-run outside the sandbox — only then fall back | Approval prompt, or receipt says `single-vendor` if declined |
| Codex doesn't auto-load `~/.codex/AGENTS.md` | That direction is **silently inert** | **No receipt** — catch it with *Verify it's live* |
| Reviewer reads its own rule | Recursion guard tells it not to re-cross-check | Single review, no nested loop |

## Troubleshooting

- **It keeps saying `single-vendor` even though both CLIs are installed and logged in.** On macOS
  the usual culprit is the **Keychain**: Claude Code stores its login there, and when Codex runs
  `claude -p` inside its sandbox, the sandbox blocks Keychain access — `claude` instantly reports
  `Not logged in · Please run /login` even though you are. Confirm by running the same `claude -p …`
  line yourself in a plain terminal (works = it's the sandbox). The rule tells Codex to ask for
  approval to run the reviewer outside the sandbox in that case — approve it, or run Codex with a
  sandbox/approval mode that allows escalation.
- **Still `single-vendor` and the terminal test also fails?** The flags in the rule files may be
  stale for your CLI version. Check them against `codex --help` / `claude --help` and update the
  `codex exec …` / `claude -p …` lines in `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`.
- **You never see a receipt at all.** The rule file may not be loading. Confirm the managed block is
  present in the right file, and run *Verify it's live*.
- **Codex "review" sits there forever with no output.** That's `codex exec` waiting on stdin. The
  current rule feeds the prompt from a file, which prevents it; if you see it, your installed block
  is old. Run `./install.sh --check`, then re-run the installer.
- **The installer says a file "already has its own cross-check rule".** It found a heading containing
  "Cross-Check" that it didn't write, and left the file alone so you don't get two rules that
  disagree. Remove or rename your section, or re-run with `--force` to keep both.

## Stacks cleanly with other rule packs

The installer only ever adds or updates **its own clearly-marked block** between
`<!-- BEGIN claude-codex-crosscheck -->` and `<!-- END claude-codex-crosscheck -->` markers.
Everything else in your `CLAUDE.md` / `AGENTS.md` is left untouched, and any file it changes is
backed up first. So if you already run something like
[claude-code-model-switch](https://github.com/ecomvessel/claude-code-model-switch), install both —
they coexist.

## Updating and removing

- **Update:** re-run the installer. It replaces only its own block.
- **Check:** `./install.sh --check` (or `curl -fsSL …/quick-install.sh | bash -s -- --check`). Run
  it after updating either CLI.
- **Remove:** `./install.sh --uninstall` (or `curl -fsSL …/quick-install.sh | bash -s -- --uninstall`).
  It strips only its own block and leaves the rest of your rules alone.
- **Backups:** every change first saves a unique `*.bak-crosscheck.*` copy of the file next to it in
  `~/.claude` / `~/.codex`. These are never auto-deleted — delete them yourself whenever you like.

## What's in this repo

```
templates/claude-crosscheck.md   the block installed into ~/.claude/CLAUDE.md
templates/codex-crosscheck.md    the block installed into ~/.codex/AGENTS.md
install.sh                       installs / updates / --check / --uninstall
quick-install.sh                 curl|bash wrapper that downloads + runs install.sh
scripts/validate.sh              self-test CI runs on every push (macOS + Linux)
```

## License

MIT — see [LICENSE](LICENSE).
