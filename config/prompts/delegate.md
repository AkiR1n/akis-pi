Delegate this task using the most appropriate configured pi-subagents role.

Build a self-contained task packet with the goal, exact paths and ownership,
known evidence, constraints, forbidden changes, required checks, acceptance
criteria, and return format. Use fresh context by default. The main Pi session
owns MC project memory and compaction; child sessions receive only their task,
role, applicable instructions, explicit tools, and selected extensions.

Pick the role by tool face, not by model: explore for recon, implement for
writing, analyze for evidence, options and external sources, review for
verification, lead when a strong model must drive a change and fan out.
Roles carry no model; pass model: on the launch only when the task needs a
different tier than the role default. Do not run multiple writers in the same
worktree.

Use the subagent tool (consult action: "guide" when needed). Keep the returned run
ID and session path; use status, resume, steer, stop and bg_wait for that run.
If a delegated run gets stuck, stop it and report what you observed. Do not silently switch
delegation engines mid-task, and do not rewrite the history of an old run to make it fit.
