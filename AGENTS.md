# routine-timer

This repository is the routine-ledger daemon. The `routine-timer` executable is its control interface. `serve` is the daemon process. It waits until the user has opened the harness, then submits the job through `agent-bus`.

Do not add a default that launches Cursor, Grok, or another desktop app. `launch: "wait"` stays the default. A target may opt in with `launch: "launch"` and an explicit `launch_program`.
