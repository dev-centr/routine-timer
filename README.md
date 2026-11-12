<div align="center">

<a href="https://github.com/dev-centr/routine-timer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/dev-centr/routine-timer?style=for-the-badge" alt="License"></a>
<a href="https://github.com/dev-centr/routine-timer/issues"><img src="https://img.shields.io/github/issues/dev-centr/routine-timer?style=for-the-badge" alt="Issues"></a>

# routine-timer

The ledger daemon reports when a computer or a harness process comes up, then submits the due routine through [agent-bus](https://github.com/dev-centr/agent-bus). It does not open the harness for you.

</div>

## Install

From a checkout, with LDC when DMD is not on `PATH`:

```shell
dub build --compiler=ldc2
```

`agent-bus` must be on `PATH`, or pass `--agent-bus`. Profiles come from `--profiles` or `AGENT_BUS_PROFILES`.

## Use

`status` only reports. `serve` is the daemon. A target with `launch: "wait"` (the default) and `presence.process` set is submitted after that process is already running.

```shell
routine-timer status --ledger C:\path\to\routine-ledger --machine local
routine-timer serve --ledger C:\path\to\routine-ledger --profiles C:\path\to\agent-bus\profiles
routine-timer plan --ledger C:\path\to\routine-ledger
```

`plan` shows a Task Scheduler task at user logon, not at system boot. `apply --install` registers that task and a refresh task. Neither task starts Cursor, Grok, or another harness.

To start a harness from the daemon, the target has to set `launch` to `launch` and set `launch_program`. The process name is only a signal. It is not the program that gets started.

## Built with

**Runtime**

- [D](https://dlang.org/) and [Dub](https://dub.pm/)
- [LDC](https://github.com/ldc-developers/ldc) when DMD is not installed
- [agent-bus](https://github.com/dev-centr/agent-bus) for the submit

## Changelog

See [CHANGELOG.adoc](CHANGELOG.adoc).
