module ledger.scheduler;

import std.algorithm.searching : canFind;
import std.string : indexOf;

// Native timers wake the daemon. They do not start a harness.
// The installed daemon task runs at user logon, not at system boot.

struct PlannedTask
{
    string name;
    string when;
    string command;
}

PlannedTask daemonTask(string exe, string ledger)
{
    PlannedTask task;
    task.name = `RoutineLedger\daemon`;
    task.when = "ONLOGON";
    task.command = exe ~ " serve --ledger " ~ quote(ledger);
    return task;
}

PlannedTask refreshTask(string exe, string ledger, string every)
{
    PlannedTask task;
    task.name = `RoutineLedger\refresh`;
    task.when = every.length ? every : "30m";
    task.command = exe ~ " serve --once --ledger " ~ quote(ledger);
    return task;
}

PlannedTask fireTask(string exe, string ledger, string routine)
{
    PlannedTask task;
    task.name = `RoutineLedger\` ~ routine;
    task.when = "routine";
    task.command = exe ~ " fire " ~ routine ~ " --ledger " ~ quote(ledger);
    return task;
}

string[] schtasks(PlannedTask task)
{
    string[] args = ["schtasks", "/Create", "/F", "/TN", `\` ~ task.name, "/TR", task.command];
    if (task.when == "ONLOGON")
        args ~= ["/SC", "ONLOGON"];
    else if (task.when.length >= 2 && task.when[$ - 1] == 'm')
        args ~= ["/SC", "MINUTE", "/MO", task.when[0 .. $ - 1]];
    else if (task.when.length >= 2 && task.when[$ - 1] == 'h')
        args ~= ["/SC", "HOURLY", "/MO", task.when[0 .. $ - 1]];
    else
        args ~= ["/SC", "DAILY"];
    return args;
}

private string quote(string text)
{
    if (text.indexOf(' ') < 0)
        return text;
    return `"` ~ text ~ `"`;
}

unittest
{
    auto daemon = daemonTask("routine-timer", `C:\ledger`);
    assert(daemon.when == "ONLOGON");
    auto args = schtasks(daemon);
    bool onLogon;
    bool onStart;
    foreach (arg; args)
    {
        if (arg == "ONLOGON")
            onLogon = true;
        if (arg == "ONSTART")
            onStart = true;
    }
    assert(onLogon);
    assert(!onStart);
    assert(daemon.command.indexOf("serve") > 0);
    auto refresh = schtasks(refreshTask("routine-timer", "C:/ledger", "30m"));
    assert(canFind(refresh, "MINUTE"));
}
