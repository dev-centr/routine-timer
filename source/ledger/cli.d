module ledger.cli;

import std.conv : to;
import std.datetime : Clock, Duration, SysTime, UTC;
import std.file : exists, mkdirRecurse, readText, thisExePath, write;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.process : Config, environment, execute, spawnProcess;
import std.stdio : stderr, writeln;
import std.string : indexOf, split;

import ledger.claims : Note, judge;
import ledger.json5 : parseJson5;
import ledger.model : Ledger, MachineFile, Routine, Target, findTarget, loadLedger, runHandled;
import ledger.presence : Action, Decision, Launch, Observe, Presence, TargetWake, actionName, decide, jobLine, notices, reportJob;
import ledger.schedule : Due, latestDue, parseDuration, parseTimestamp, runId;
import ledger.scheduler : daemonTask, fireTask, refreshTask, schtasks;
import ledger.wake : WakeTarget, agentBusSubmit;

enum timerVersion = "0.1.0";

struct Options
{
    string ledger;
    string machine = "local";
    string profiles;
    string agentBus = "agent-bus";
    bool once;
    bool install;
    Duration poll;
    string positional;
}

int run(string[] argv)
{
    string command;
    Options options;
    string error;
    if (!parseArgs(argv, command, options, error))
    {
        stderr.writeln(error);
        return 1;
    }
    if (command == "version")
    {
        writeln(timerVersion);
        return 0;
    }
    if (command == "help")
    {
        writeln(usage());
        return 0;
    }
    fillEnv(options);
    if (options.ledger.length == 0)
    {
        stderr.writeln("Pass --ledger or set ROUTINE_TIMER_LEDGER.");
        return 1;
    }
    if (command == "serve")
        return serve(options);
    if (command == "status")
    {
        options.once = true;
        return serve(options, true);
    }
    if (command == "plan")
        return plan(options);
    if (command == "apply")
        return apply(options);
    if (command == "fire")
        return fire(options);
    if (command == "missed")
        return missed(options);
    if (command == "targets")
        return targets(options);
    stderr.writeln("Unknown command " ~ command);
    stderr.writeln(usage());
    return 1;
}

private string usage()
{
    return "Usage: routine-timer [--ledger DIR] [--machine ID] [--profiles DIR] "
        ~ "[--agent-bus BIN] version|help|status|serve|plan|apply|fire|missed|targets";
}

private void fillEnv(ref Options options)
{
    if (options.ledger.length == 0)
        options.ledger = environment.get("ROUTINE_TIMER_LEDGER", "");
    auto machine = environment.get("ROUTINE_TIMER_MACHINE", "");
    if (machine.length && options.machine == "local")
        options.machine = machine;
    if (options.profiles.length == 0)
        options.profiles = environment.get("AGENT_BUS_PROFILES", "");
    auto bin = environment.get("AGENT_BUS_BIN", "");
    if (bin.length)
        options.agentBus = bin;
    if (options.poll == Duration.zero)
    {
        string error;
        options.poll = parseDuration("15s", error);
    }
}

private bool parseArgs(string[] argv, ref string command, ref Options options, out string error)
{
    if (argv.length < 2)
    {
        error = usage();
        return false;
    }
    size_t index = 1;
    string[] words;
    while (index < argv.length)
    {
        auto arg = argv[index];
        if (arg == "--once")
        {
            options.once = true;
            index++;
            continue;
        }
        if (arg == "--install")
        {
            options.install = true;
            index++;
            continue;
        }
        if (arg == "--ledger" || arg == "--machine" || arg == "--profiles"
                || arg == "--agent-bus" || arg == "--poll")
        {
            if (index + 1 >= argv.length)
            {
                error = "Missing value for " ~ arg;
                return false;
            }
            auto value = argv[index + 1];
            if (arg == "--ledger")
                options.ledger = value;
            else if (arg == "--machine")
                options.machine = value;
            else if (arg == "--profiles")
                options.profiles = value;
            else if (arg == "--agent-bus")
                options.agentBus = value;
            else
            {
                string durationError;
                options.poll = parseDuration(value, durationError);
                if (durationError.length)
                {
                    error = durationError;
                    return false;
                }
            }
            index += 2;
            continue;
        }
        if (arg.length >= 2 && arg[0 .. 2] == "--")
        {
            error = "Unknown argument " ~ arg;
            return false;
        }
        words ~= arg;
        index++;
    }
    if (words.length == 0)
    {
        error = "Missing command.";
        return false;
    }
    command = words[0];
    if (words.length > 1)
        options.positional = words[1];
    return true;
}

int serve(Options options, bool reportOnly = false)
{
    auto previous = machineById(loadLedger(options.ledger), options.machine);
    Presence before;
    before.hostOnline = previous.hasHost && previous.hostOnline;
    before.harnessOnline = previous.harnessOnline;
    bool hadBefore = previous.hasHost;
    string[string] lastAction = previous.lastAction;
    while (true)
    {
        auto ledger = loadLedger(options.ledger);
        foreach (message; ledger.errors)
            stderr.writeln(message);
        auto now = Clock.currTime(UTC());
        Presence after;
        after.hostOnline = true;
        bool[string] running;
        foreach (target; ledger.targets)
        {
            if (target.process.length == 0 || target.id in running)
                continue;
            running[target.id] = imageRunning(target.process);
            after.harnessOnline[target.id] = running[target.id];
        }
        foreach (notice; notices(before, after, hadBefore))
            writeln(notice.line);
        if (!reportOnly)
        {
            foreach (routine; ledger.routines)
            {
                if (routine.status != "active")
                    continue;
                int code = consider(options, ledger, routine, now, running, lastAction);
                if (code != 0)
                    return code;
            }
        }
        writeMachine(options, after, lastAction, now);
        if (options.once || reportOnly)
            break;
        import core.thread : Thread;
        Thread.sleep(options.poll);
        before = after;
        hadBefore = true;
    }
    return 0;
}

private int consider(Options options, Ledger ledger, Routine routine, SysTime now,
        bool[string] running, ref string[string] lastAction)
{
    auto due = latestDue(routine.triggerType, routine.cron, routine.tz, routine.every,
            routine.at, routine.createdAt, now);
    if (due.error.length)
    {
        writeln("routine=" ~ routine.id ~ " error=" ~ due.error);
        return 0;
    }
    if (!due.found)
        return 0;
    auto id = runId(due.at);
    if (runHandled(ledger, routine.id, id))
        return 0;
    if (heldBySomeoneElse(options, routine, id, now))
    {
        writeln("locked routine=" ~ routine.id ~ " run=" ~ id);
        return 0;
    }
    Target target;
    if (!findTarget(ledger, routine, options.machine, target))
    {
        writeln("no-target routine=" ~ routine.id);
        return 0;
    }
    auto decision = decisionFor(options, ledger, target, running);
    auto name = actionName(decision.action);
    auto previous = routine.id in lastAction ? lastAction[routine.id] : "";
    if (reportJob(previous, name))
        writeln(jobLine(routine.id, decision));
    lastAction[routine.id] = name;
    if (decision.spawnHarness)
        spawnHarness(target);
    if (!decision.callAgentBus)
        return 0;
    return submit(options, routine, target, id);
}

private Decision decisionFor(Options options, Ledger ledger, Target target, bool[string] running)
{
    Observe observed;
    observed.thisMachine = options.machine;
    observed.thisHostOnline = true;
    observed.target = toWake(target);
    if (!containsMachine(target, options.machine) && target.machines.length)
    {
        observed.targetHostOnline = remoteOnline(ledger, target, options.machine);
        return decide(observed);
    }
    observed.targetHostOnline = true;
    if (target.assumeRunning)
    {
        observed.running = true;
        return decide(observed);
    }
    if (target.process.length)
    {
        observed.probed = true;
        if (auto known = target.id in running)
            observed.running = *known;
        else
            observed.running = imageRunning(target.process);
    }
    return decide(observed);
}

private TargetWake toWake(Target target)
{
    TargetWake wake;
    wake.id = target.id;
    wake.kind = target.kind;
    wake.launch = target.launch == "launch" ? Launch.launch : Launch.wait;
    wake.process = target.process;
    wake.assumeRunning = target.assumeRunning;
    wake.launchProgram = target.launchProgram;
    wake.machines = target.machines;
    return wake;
}

private bool containsMachine(Target target, string machine)
{
    if (target.machines.length == 0)
        return true;
    foreach (name; target.machines)
        if (name == machine)
            return true;
    return false;
}

private bool remoteOnline(Ledger ledger, Target target, string thisMachine)
{
    import std.datetime : hours;
    auto now = Clock.currTime(UTC());
    foreach (name; target.machines)
    {
        if (name == thisMachine)
            continue;
        foreach (machine; ledger.machines)
        {
            if (machine.id != name || !machine.hasHost || !machine.hostOnline)
                continue;
            string error;
            auto at = parseTimestamp(machine.updatedAt, error);
            if (error.length == 0 && now - at < 2.hours)
                return true;
        }
    }
    return false;
}

private int submit(Options options, Routine routine, Target target, string id)
{
    WakeTarget wake;
    wake.app = target.app;
    wake.versionText = target.versionText;
    wake.operation = target.operation;
    wake.chatId = target.chatId;
    auto text = routine.prompt ~ "\n\nrun_id=" ~ id;
    auto command = agentBusSubmit(wake, options.agentBus, options.profiles, text, false, false, "");
    if (command.error.length)
    {
        stderr.writeln(command.error);
        return 2;
    }
    try
    {
        auto result = execute([command.bin] ~ command.args);
        if (result.output.length)
            writeln(result.output);
        if (result.status != 0)
        {
            stderr.writeln("agent-bus exit " ~ to!string(result.status));
            return 2;
        }
    }
    catch (Exception exc)
    {
        stderr.writeln("agent-bus failed: " ~ exc.msg);
        return 2;
    }
    writeRun(options, routine, id, "running");
    return 0;
}

private void spawnHarness(Target target)
{
    if (target.launchProgram.length == 0)
        return;
    try
    {
        spawnProcess([target.launchProgram] ~ target.launchArgs, null, Config.detached);
        writeln("spawned program=" ~ target.launchProgram);
    }
    catch (Exception exc)
    {
        stderr.writeln("launch failed: " ~ exc.msg);
    }
}

private bool imageRunning(string image)
{
    if (image.length == 0 || image.indexOf('"') >= 0)
        return false;
    try
    {
        auto result = execute(["tasklist", "/FI", "IMAGENAME eq " ~ image, "/NH", "/FO", "CSV"]);
        return result.status == 0 && result.output.indexOf(image) >= 0;
    }
    catch (Exception)
    {
        return false;
    }
}

int plan(Options options)
{
    auto daemon = daemonTask(exeName(), options.ledger);
    auto refresh = refreshTask(exeName(), options.ledger, "30m");
    writeln("task=" ~ daemon.name ~ " when=" ~ daemon.when ~ " command=" ~ daemon.command);
    writeln("task=" ~ refresh.name ~ " when=" ~ refresh.when ~ " command=" ~ refresh.command);
    auto ledger = loadLedger(options.ledger);
    foreach (routine; ledger.routines)
    {
        if (routine.status != "active")
            continue;
        auto task = fireTask(exeName(), options.ledger, routine.id);
        writeln("task=" ~ task.name ~ " when=" ~ task.when ~ " command=" ~ task.command);
    }
    writeln("install=off");
    writeln("The daemon starts at logon. It does not start a harness.");
    return 0;
}

int apply(Options options)
{
    plan(options);
    if (!options.install)
    {
        writeln("Pass --install to register the logon task and the refresh task.");
        return 0;
    }
    auto tasks = [
        schtasks(daemonTask(exeName(), options.ledger)),
        schtasks(refreshTask(exeName(), options.ledger, "30m")),
    ];
    foreach (args; tasks)
    {
        auto result = execute(args);
        writeln(result.output);
        if (result.status != 0)
            return result.status;
    }
    return 0;
}

int fire(Options options)
{
    if (options.positional.length == 0)
    {
        stderr.writeln("Usage: routine-timer fire <routine> --ledger DIR");
        return 1;
    }
    auto ledger = loadLedger(options.ledger);
    foreach (routine; ledger.routines)
    {
        if (routine.id != options.positional)
            continue;
        bool[string] running;
        string[string] lastAction;
        return consider(options, ledger, routine, Clock.currTime(UTC()), running, lastAction);
    }
    stderr.writeln("No routine " ~ options.positional);
    return 1;
}

int missed(Options options)
{
    auto ledger = loadLedger(options.ledger);
    auto now = Clock.currTime(UTC());
    foreach (routine; ledger.routines)
    {
        if (routine.status != "active")
            continue;
        auto due = latestDue(routine.triggerType, routine.cron, routine.tz, routine.every,
                routine.at, routine.createdAt, now);
        if (due.error.length)
        {
            writeln("routine=" ~ routine.id ~ " error=" ~ due.error);
            continue;
        }
        if (!due.found)
            continue;
        auto id = runId(due.at);
        if (runHandled(ledger, routine.id, id))
            continue;
        writeln("missed routine=" ~ routine.id ~ " run=" ~ id ~ " catch_up=" ~ routine.catchUp);
    }
    return 0;
}

int targets(Options options)
{
    auto ledger = loadLedger(options.ledger);
    if (options.positional == "validate")
    {
        if (ledger.errors.length)
        {
            foreach (message; ledger.errors)
                writeln(message);
            return 1;
        }
        writeln("targets=" ~ to!string(ledger.targets.length));
        return 0;
    }
    foreach (target; ledger.targets)
        writeln("target=" ~ target.id ~ " kind=" ~ target.kind ~ " launch=" ~ target.launch
                ~ " process=" ~ target.process);
    return 0;
}

private MachineFile machineById(Ledger ledger, string id)
{
    foreach (machine; ledger.machines)
        if (machine.id == id)
            return machine;
    MachineFile empty;
    empty.id = id;
    return empty;
}

private bool heldBySomeoneElse(Options options, Routine routine, string id, SysTime now)
{
    auto path = buildPath(options.ledger, ".routine-timer", "claims", routine.id, id ~ ".jsonl");
    if (!exists(path))
        return false;
    Note[] notes;
    foreach (line; readText(path).split('\n'))
    {
        if (line.length == 0)
            continue;
        auto value = parseJson5(line);
        Note note;
        note.kind = value["kind"].str;
        note.harness = value["harness"].str;
        note.sessionId = value["session_id"].str;
        if ("capabilities" in value)
        {
            foreach (item; value["capabilities"].array)
                note.capabilities ~= item.str;
        }
        note.trusted = true;
        if ("lease_expires" in value && value["lease_expires"].type == JSONType.string)
        {
            string error;
            note.leaseExpires = parseTimestamp(value["lease_expires"].str, error);
            note.hasLease = error.length == 0;
        }
        notes ~= note;
    }
    auto lock = judge(notes, routine.requires, now);
    return lock.held && lock.harness != options.machine;
}

private void writeRun(Options options, Routine routine, string id, string status)
{
    auto now = Clock.currTime(UTC());
    auto folder = buildPath(options.ledger, "runs", to!string(now.year),
            pad(cast(int) now.month), routine.id);
    mkdirRecurse(folder);
    auto body = "{\n  \"schema\": \"routine-ledger/run/1\",\n  \"routine\": \"" ~ routine.id
        ~ "\",\n  \"run_id\": \"" ~ id ~ "\",\n  \"scheduled_at\": \"" ~ iso(now)
        ~ "\",\n  \"status\": \"" ~ status ~ "\"\n}\n";
    write(buildPath(folder, id ~ ".json5"), body);
}

private void writeMachine(Options options, Presence presence, string[string] lastAction, SysTime now)
{
    auto folder = buildPath(options.ledger, "machines");
    mkdirRecurse(folder);
    string harnesses;
    foreach (id, online; presence.harnessOnline)
    {
        if (harnesses.length)
            harnesses ~= ",\n";
        harnesses ~= "      {\"id\": \"" ~ id ~ "\", \"state\": \""
            ~ (online ? "online" : "offline") ~ "\"}";
    }
    string waiting;
    foreach (routine, reason; lastAction)
    {
        if (waiting.length)
            waiting ~= ",\n";
        waiting ~= "    {\"routine\": \"" ~ routine ~ "\", \"run_id\": \"pending\", \"reason\": \""
            ~ reason ~ "\"}";
    }
    auto body = "{\n  \"schema\": \"routine-ledger/machine/1\",\n  \"id\": \"" ~ options.machine
        ~ "\",\n  \"os\": \"windows\",\n  \"scheduler\": \"task-scheduler\",\n  \"targets\": [],\n"
        ~ "  \"timers\": [],\n  \"presence\": {\n    \"host\": \""
        ~ (presence.hostOnline ? "online" : "offline") ~ "\",\n    \"host_since\": \"" ~ iso(now)
        ~ "\",\n    \"harnesses\": [\n" ~ harnesses ~ "\n    ]\n  },\n  \"waiting\": [\n"
        ~ waiting ~ "\n  ],\n  \"updated_at\": \"" ~ iso(now) ~ "\"\n}\n";
    write(buildPath(folder, options.machine ~ ".json5"), body);
}

private string iso(SysTime at)
{
    auto utc = at.toUTC();
    import std.format : format;
    return format("%04d-%02d-%02dT%02d:%02d:%02dZ", utc.year, cast(int) utc.month, utc.day,
            utc.hour, utc.minute, utc.second);
}

private string pad(int value)
{
    import std.format : format;
    return format("%02d", value);
}

private string exeName()
{
    return thisExePath();
}

unittest
{
    assert(usage().indexOf("serve") > 0);
    string error;
    string command;
    Options options;
    assert(parseArgs(["routine-timer", "version"], command, options, error));
    assert(command == "version");
    assert(parseArgs(["routine-timer", "--install", "apply", "--ledger", "L"], command, options, error));
    assert(options.install);
    assert(options.ledger == "L");
    assert(command == "apply");
}
