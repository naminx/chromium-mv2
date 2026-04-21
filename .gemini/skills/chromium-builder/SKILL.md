---
name: chromium-builder
description: Chromium MV2 build orchestration and compilation engine for Hetzner Cloud and local NixOS. Use when tasked with modifying the Chromium build pipeline, setting up servers, capturing the Windows SDK toolchain, or troubleshooting cloud compilation.
---

# Chromium Master Builder: Operational Laws

You are operating in a high-stakes, resource-constrained cloud environment (Hetzner cx23 4GB and ccx63 48-core). Your default training for "brevity" and "clean code" is a **LIABILITY** here. You must prioritize **proven operational reality** over aesthetic cleanliness.

## 1. The "Sacred Code" Principle
If a technical sequence (Sync loop, Toolchain order, Extraction logic) is proven to work, **it is sacred.**
* **TRANSCRIPTION OVER REFACTOR:** You are forbidden from "standardizing" or "cleaning" proven code. 
* **BACKUP IS TRUTH:** The files in `backups/` represent a higher truth than official Google/Docker documentation. If they conflict, follow the backup.

## 2. The "Amputation" Rule (No Escaping Hell)
When patching scripts that are nested (e.g., a Bash script generating a Python script that patches a third script):
* **FORBIDDEN:** Line-by-line regex or single-character `replace` calls. These lead to "escaping hell" and SyntaxErrors.
* **MANDATORY:** Use wholesale **Block Replacement**. Find the entire function or block of code and overwrite it completely. This ensures backslash and quote integrity.

## 3. Mandatory "WHY" Protection
Every technical safeguard (pkill, background rm -rf, mount retry loops, Git memory caps) is a **Technical Survival Mechanism**.
* **AI LAW:** You must never delete these lines or the "WHY" comments. They exist to prevent OOMs, disk stalls, and kernel deadlocks that a "clean" script would trigger.

## 4. Operational Status Lights (Progress)
"Dead Air" in the logs is a fatal flaw in a cloud build.
* **NO BUFFERING:** Always use flags that provide real-time progress (`git --progress`, `gclient --verbose`).
* **FORCE STREAMING:** Use `python3 -u` or `GIT_PROGRESS_DELAY=0` to bypass internal buffers.

## 5. Hardware Constraints
* **SEED (4GB RAM):** Decompression is the bottleneck. Use `-md=64m` for 7z to prevent swapping.
* **BEAST (48-CORES):** Parallelism is the win. Use RAM disks (`tmpfs`) for the `out/` directory.

## Execution Checklist
1. **REJECT BREVITY:** Do not try to find the "shortest" fix. Find the "most robust" fix.
2. **VERIFY DISCREPANCIES:** Before executing a refactor, list every technical detail from the proven code you are about to change. 
3. **RESPECT THE TRAUMA:** If a command looks "ugly", it is there for a reason. Document that reason in a "WHY" comment.
