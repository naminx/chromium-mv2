# AI Assistant Context: Target Environment

When interacting with this system or writing testable terminal commands, keep the following environment quirks and constraints in mind:

## 1. Default Shell (Fish) & Aliases
- The system heavily utilizes the **fish shell** as its default interactive shell, not bash or zsh!
- Typical `bash`-isms like `VAR=value command_name` will fail natively in fish. Instead, they must be formatted using the `env` command (e.g., `env VAR=value command_name`). Ensure any copy-paste instructions you give the user respect fish syntax!
- Complex `bash` background executions and grouping semantics (e.g., `{ ( command git push ) > /tmp/ag_output.txt 2>&1; echo "--DONE--" >> /tmp/ag_output.txt; } &`) will **fail in the fish shell**. If you absolutely must propose chained background commands, you must wrap the entire expression explicitly under bash: `bash -c '{ ( command git push ) > /tmp/ag_output.txt 2>&1; echo "--DONE--" >> /tmp/ag_output.txt; } &'`
- Many standard POSIX commands are heavily aliased (e.g., `cat` -> `bat`, `ls` -> `eza`, `grep` -> `rg`, `rm` -> `rm2trash`, `find` -> `fd`, `git`). When automating terminal scripts or needing raw, predictable output without hanging the execution runner or triggering interactive behaviors, you **must prepend `command`** to EVERY external utility command (e.g., `command cat`, `command rm`, `command git`) to safely bypass these aliases and call the raw system binary.
- **Xargs Warning:** When grouping these unaliased shell commands using `xargs` (e.g., `... | xargs command gh ...`), the inner `command` syntax will often fail because `xargs` itself evaluates as an external utility that bypasses standard fish shell syntax parsing. You **must** prefix `xargs` with `command` as well: `... | command xargs gh ...` or `... | command xargs -r command gh`.
- **Subshell Redirection Trap:** When writing shell scripts (even ones executed with a `bash` shebang), if they are executed from the user's `fish` environment, be incredibly careful with `stderr` redirection inside subshells. Constructing `VERSION=$(nix eval ... 2>/dev/null)` will unexpectedly swallow its own output or fail syntax parsing due to how fish leaks its parser semantics into child executions. Always redirect the output **outside** of the subshell variable assignment or pipe it cleanly (e.g., `(nix eval ...) 2>/dev/null`).
## 2. Nix & NixOS Ecosystem
- The user is running **NixOS**, configured natively using modern **Flakes** (`flake.nix`).
- Commands like `nix-env`, `nix-shell`, or updates to legacy nix-channels should be avoided in favor of modern standard commands like `nix run`, `nix shell`, `nix build .#`, or `nixos-rebuild switch --flake .`.
- Because the system uses Flakes, any Nix derivations, `import` statements, or scripts fetching URLs that are evaluated locally will run under **strict pure evaluation**. This means fetching remote tarballs requires strict `sha256` hashes, and local paths (like `./patches`) resolve securely within the Git repository structure, which can cause derivation hash mismatches if tested against older impure `nix-build` environments.

## 3. Git Commits & Pagers (The "Hanging Process" Bug)
- The user has commit signing configured (GPG) and pre-commit hooks that strictly require user interaction (TTY prompts).
- **DO NOT** attempt to run `git commit` as a background tool! The GPG pinentry prompt will permanently freeze the background AI execution runner since it cannot natively see the screen to securely enter the passphrase or access the interactive UI.
- Similarly, standard terminal commands that invoke a pager like `less` or `bat` (e.g., `git log`, `git diff`, `git status`) may hang AI execution loops forever. You must use `--no-pager`, pipe them to a file/`command cat`, or terminate the command explicitly.
- For git work: Always stage your changes remotely using your file writer tools or `git add`, and then explicitly ask the user to manually run the `git commit` and `push` commands themselves directly in their active terminal.

## 4. Hardware Profiles & Architecture
- **Target Machine:** Intel Core i3-12100 (4 cores). Heavy C++ compilation tasks (like building `chromium` or LLVM from scratch) will take approximately ~6 hours locally if there is a cache miss.
- **Sole Hardware Support:** The user ONLY plans to support **Intel x64 on Linux** (`x86_64-linux`).
- **Nix Boilerplate Rule:** Because of this strict x64 support rule, you **do not** need to generate comprehensive `forAllSystems` loops or mention other architectures (like ARM/MacOS) when writing `flake.nix` files, derivation overrides, or standard `.nix` scripts for this user. Hardcode to `x86_64-linux` securely to save space.
