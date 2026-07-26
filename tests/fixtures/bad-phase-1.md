---
name: bad-phase-1
description: "FATAL fixture. Only ever placed in dirs whose tests expect exit 3."
phase: execution
order: 10
---

`execution` is documented in HOOKS.md as a hook that deliberately never existed,
so it is a realistic thing for a user to hand-write.
