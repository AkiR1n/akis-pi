Delegate this task using the most appropriate configured pi-subagents role.

Build a self-contained task packet with the goal, exact paths and ownership,
known evidence, constraints, forbidden changes, required checks, acceptance
criteria, and return format. Use fresh context by default. The main Pi session
owns MC project memory and compaction; child sessions receive only their task,
role, applicable instructions, explicit tools, and selected extensions.

Use explorer for low-cost non-thinking discovery, analyst for unusually large
read-only evidence sets, implementer for normal implementation, planner for
architecture or repeated failure, and reviewer for independent read-only review.
Keep configured models and thinking levels unless explicitly asked to change them.
Do not run multiple writers in the same worktree.

Use the subagent tool (consult action: "guide" when needed). Keep the returned run
ID and session path; use status, resume, steer, stop and bg_wait for that run.
If a delegated run gets stuck, stop it and report what you observed. Do not silently switch
delegation engines mid-task, and do not rewrite the history of an old run to make it fit.
