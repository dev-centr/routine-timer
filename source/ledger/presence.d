module ledger.presence;

import std.string : indexOf;

// The daemon reports when a host or a harness process comes up.
// It submits a due job only after the harness is already running.
// Starting the harness is opt-in. The default is to wait for the user.

enum Launch : int
{
    wait,
    launch,
}

enum Action : int
{
    hostDown,
    remoteOnline,
    waitHarness,
    submit,
    launchHarness,
}

struct TargetWake
{
    string id;
    string kind;
    Launch launch = Launch.wait;
    string process;
    bool assumeRunning;
    string launchProgram;
    string[] machines;
}

struct Observe
{
    string thisMachine;
    bool thisHostOnline;
    bool targetHostOnline;
    bool probed;
    bool running;
    TargetWake target;
}

struct Decision
{
    Action action;
    string report;
    bool spawnHarness;
    bool callAgentBus;
}

bool onThisMachine(TargetWake target, string machine)
{
    if (target.machines.length == 0)
        return true;
    foreach (name; target.machines)
        if (name == machine)
            return true;
    return false;
}

Decision decide(Observe observed)
{
    Decision decision;
    if (!onThisMachine(observed.target, observed.thisMachine))
    {
        if (observed.targetHostOnline)
        {
            decision.action = Action.remoteOnline;
            decision.report = "host-online machine=remote target=" ~ observed.target.id;
        }
        else
        {
            decision.action = Action.hostDown;
            decision.report = "host-offline machine=remote target=" ~ observed.target.id;
        }
        return decision;
    }
    if (!observed.thisHostOnline)
    {
        decision.action = Action.hostDown;
        decision.report = "host-offline machine=" ~ observed.thisMachine ~ " target=" ~ observed.target.id;
        return decision;
    }
    bool up = observed.target.assumeRunning || (observed.probed && observed.running);
    if (up)
    {
        decision.action = Action.submit;
        decision.callAgentBus = observed.target.kind == "agent_bus";
        decision.report = "harness-online target=" ~ observed.target.id;
        return decision;
    }
    if (observed.target.launch == Launch.launch)
    {
        if (observed.target.launchProgram.length == 0)
        {
            decision.action = Action.waitHarness;
            decision.report = "launch-refused target=" ~ observed.target.id
                ~ " reason=no-launch-program";
            return decision;
        }
        decision.action = Action.launchHarness;
        decision.spawnHarness = true;
        decision.report = "launch target=" ~ observed.target.id ~ " program=" ~ observed.target.launchProgram;
        return decision;
    }
    decision.action = Action.waitHarness;
    if (observed.target.process.length == 0 && !observed.target.assumeRunning)
        decision.report = "waiting target=" ~ observed.target.id ~ " reason=no-presence-signal";
    else
        decision.report = "waiting target=" ~ observed.target.id ~ " reason=harness-absent";
    return decision;
}

struct Presence
{
    bool hostOnline;
    bool[string] harnessOnline;
}

struct Notice
{
    string line;
}

Notice[] notices(Presence before, Presence after, bool hadBefore)
{
    Notice[] lines;
    if (!hadBefore)
        lines ~= Notice("state host=" ~ (after.hostOnline ? "online" : "offline"));
    else if (!before.hostOnline && after.hostOnline)
        lines ~= Notice("spun-up host");
    else if (before.hostOnline && !after.hostOnline)
        lines ~= Notice("offline host");

    foreach (id, online; after.harnessOnline)
    {
        auto previous = id in before.harnessOnline;
        bool known = hadBefore && previous !is null;
        if (!known)
            lines ~= Notice("state harness=" ~ id ~ " " ~ (online ? "online" : "offline"));
        else if (!(*previous) && online)
            lines ~= Notice("spun-up harness=" ~ id);
        else if (*previous && !online)
            lines ~= Notice("offline harness=" ~ id);
    }
    return lines;
}

string actionName(Action action)
{
    final switch (action)
    {
    case Action.hostDown:
        return "host-down";
    case Action.remoteOnline:
        return "remote-online";
    case Action.waitHarness:
        return "wait";
    case Action.submit:
        return "submit";
    case Action.launchHarness:
        return "launch";
    }
}

string jobLine(string routine, Decision decision)
{
    final switch (decision.action)
    {
    case Action.waitHarness:
        return "waiting routine=" ~ routine ~ " " ~ decision.report;
    case Action.submit:
        return decision.callAgentBus
            ? "submit routine=" ~ routine ~ " via=agent-bus"
            : "ready routine=" ~ routine ~ " submit=needs-agent-bus-target";
    case Action.launchHarness:
        return "launch routine=" ~ routine ~ " explicit=launch";
    case Action.hostDown:
        return "waiting routine=" ~ routine ~ " reason=host-offline";
    case Action.remoteOnline:
        return "remote routine=" ~ routine ~ " host=online";
    }
}

bool reportJob(string previous, string action)
{
    if (previous != action)
        return true;
    return action == "submit" || action == "launch";
}

unittest
{
    TargetWake target;
    target.id = "cursor-desktop";
    target.kind = "agent_bus";
    target.launch = Launch.wait;
    target.process = "Cursor.exe";
    target.machines = ["local"];

    Observe observed;
    observed.thisMachine = "local";
    observed.thisHostOnline = true;
    observed.targetHostOnline = true;
    observed.probed = true;
    observed.running = false;
    observed.target = target;

    auto waiting = decide(observed);
    assert(waiting.action == Action.waitHarness);
    assert(!waiting.spawnHarness);
    assert(!waiting.callAgentBus);
    assert(waiting.report == "waiting target=cursor-desktop reason=harness-absent");

    observed.running = true;
    auto ready = decide(observed);
    assert(ready.action == Action.submit);
    assert(ready.callAgentBus);
    assert(!ready.spawnHarness);

    observed.running = false;
    observed.target.launch = Launch.launch;
    auto refused = decide(observed);
    assert(refused.action == Action.waitHarness);
    assert(!refused.spawnHarness);
    assert(refused.report == "launch-refused target=cursor-desktop reason=no-launch-program");

    observed.target.launchProgram = "C:/Tools/cursor/Cursor.exe";
    auto launching = decide(observed);
    assert(launching.action == Action.launchHarness);
    assert(launching.spawnHarness);
    assert(!launching.callAgentBus);

    observed.thisHostOnline = false;
    auto down = decide(observed);
    assert(down.action == Action.hostDown);
    assert(!down.spawnHarness);
    assert(!down.callAgentBus);

    observed.thisHostOnline = true;
    observed.thisMachine = "other";
    observed.targetHostOnline = false;
    auto remoteDown = decide(observed);
    assert(remoteDown.action == Action.hostDown);
    assert(!remoteDown.spawnHarness);

    observed.targetHostOnline = true;
    auto remoteUp = decide(observed);
    assert(remoteUp.action == Action.remoteOnline);
    assert(!remoteUp.callAgentBus);
}

unittest
{
    Presence before;
    before.hostOnline = false;
    before.harnessOnline["cursor-desktop"] = false;
    Presence after;
    after.hostOnline = true;
    after.harnessOnline["cursor-desktop"] = true;
    auto lines = notices(before, after, true);
    assert(lines.length == 2);
    assert(lines[0].line == "spun-up host");
    assert(lines[1].line == "spun-up harness=cursor-desktop");

    auto again = notices(after, after, true);
    assert(again.length == 0);

    assert(reportJob("wait", "wait") == false);
    assert(reportJob("wait", "submit") == true);
    assert(jobLine("watch", decide(Observe(thisMachine: "local", thisHostOnline: true,
        targetHostOnline: true, probed: true, running: false,
        target: TargetWake(id: "cursor-desktop", kind: "agent_bus", process: "Cursor.exe"))))
        .indexOf("waiting routine=watch") == 0);
}
