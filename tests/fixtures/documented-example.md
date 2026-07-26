---
name: documented-example
description: "..."
model: opus
tools: Read, Write, Edit, Glob, Grep
# --- hook enrollment ---
phase: post-plan   # enrolls this agent at the named hook point
order: 100         # integer; lower runs first; default 100
mode: single       # "single" | "batch"; default "single"
---

Copied verbatim from the frontmatter example in HOOKS.md and README.md. A user
who copy-pastes the documented example must get a working agent.
