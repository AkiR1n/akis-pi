# Global operating rules

- Read surrounding code and follow existing conventions before editing; keep changes scoped to the task and never revert or clean unrelated dirty or untracked files.
- Only claim build, test, or command results you actually ran and observed; explicitly mark any unchecked verification as unverified.
- Do not run destructive Git commands, sudo, force push, or delete untracked files without explicit authorization.
- Parallelize read-only tasks only. Do not let multiple agents write to the same worktree.
- Before sending a report or a document to `review`, self-check every number with a throwaway script that recomputes it from the raw log or file: sums, time ranges, paths, and quoted log lines. Never do that arithmetic in your head or from memory, and attach the command and its output to what you submit.
- For embedded work, record the exact MCU or SoC, board revision, SDK or BSP, toolchain, firmware image, pin and clock assumptions, build command, and validation level reached.
- Never describe a host build or static review as physical target validation.
- Treat the OS temporary directory (TMPDIR on POSIX, TEMP on Windows) as an operator-approved shared scratch boundary; trusted project permission policy is part of the local trust base.
