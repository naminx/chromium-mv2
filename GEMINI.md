# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

# PROJECT-SPECIFIC MANDATES (Hetzner/Chromium)

These rules are foundational and take precedence over general AI instructions.

## 1. The "Sacred Code" Principle
If a specific technical sequence (e.g., the Sync loop, Toolchain order) has been proven to work in the Hetzner Cloud environment, **it is sacred.** 
*   Refactoring should move this code to a new location (e.g., from Monolith to `build-docker.sh`) but **MUST NOT** modify the command-line flags or logic sequence unless specifically asked to fix a bug in that logic.

## 2. Mandatory "WHY" Protection
Any code snippet preceded by a `# WHY:` comment is a **Technical Survival Mechanism**.
*   This includes `pkill` massacres, background `rm -rf`, `mount` retry loops, and Git memory caps.
*   **AI LAW:** You are forbidden from "simplifying" or deleting these lines. They exist because of historical cloud environment failures (OOMs, disk stalls, deadlocks).

## 3. The "Bake-and-Ship" Architecture
For all remote execution (Hetzner User-Data or SSH):
*   **NEVER** rely on remote environment variables being available at boot.
*   **ALWAYS** use the "Baking" strategy: expand variables locally and write a monolithic, self-contained script (`cat << BASH`) before uploading.
*   The remote server should receive a script with **static strings**, not dynamic shell expansions.

## 4. Operational Status Lights (Progress)
In a cloud build, "Dead Air" in the logs is a fatal flaw.
*   Always use raw command flags that provide real-time progress (e.g., `git fetch --progress`, `gclient --verbose`).
*   Bypass middle-man wrappers (like silent Python scripts) if they swallow the status light of the underlying process.

## 5. I/O Locality
*   Heavy file operations (110GB source sync, toolchain extraction) **MUST** run on the host's native ext4 filesystem.
*   **NEVER** run high-bandwidth I/O through a Docker volume driver unless the build is strictly local. Cloud volume drivers are too slow for the initial 300,000 file Chromium sync.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
