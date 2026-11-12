module ledger.model;

import std.file : dirEntries, exists, isFile, readText, SpanMode;
import std.json : JSONType, JSONValue;
import std.path : buildPath;
import std.string : endsWith;

import ledger.json5 : parseJson5;

struct Routine
{
    string id;
    string owner;
    string kind;
    string triggerType;
    string cron;
    string tz;
    string every;
    string eventName;
    string at;
    string prompt;
    string[] requires;
    string[] preferred;
    string lease;
    string catchUp;
    string status;
    string createdAt;
}

struct Target
{
    string id;
    string kind;
    string[] capabilities;
    string[] machines;
    string program;
    string[] args;
    string app;
    string versionText;
    string operation;
    string chatId;
    string launch;
    string process;
    bool assumeRunning;
    string launchProgram;
    string[] launchArgs;
}

struct RunRecord
{
    string routine;
    string runId;
    string status;
    string scheduledAt;
}

struct MachineFile
{
    string id;
    bool hostOnline;
    bool hasHost;
    string hostSince;
    string updatedAt;
    bool[string] harnessOnline;
    string[string] lastAction;
}

struct Ledger
{
    Routine[] routines;
    Target[] targets;
    RunRecord[] runs;
    MachineFile[] machines;
    string[] errors;
}

private string[] strings(JSONValue value)
{
    string[] items;
    if (value.type != JSONType.array)
        return items;
    foreach (item; value.array)
        if (item.type == JSONType.string)
            items ~= item.str;
    return items;
}

private string field(JSONValue value, string key)
{
    if (key !in value)
        return "";
    auto item = value[key];
    if (item.type == JSONType.string)
        return item.str;
    return "";
}

string[] validateRoutine(JSONValue value)
{
    string[] errors;
    if (field(value, "schema") != "routine-ledger/routine/1")
        errors ~= "schema must be routine-ledger/routine/1";
    if (field(value, "id").length == 0)
        errors ~= "id is required";
    if (field(value, "prompt").length == 0)
        errors ~= "prompt is required";
    auto trigger = "trigger" in value ? value["trigger"] : JSONValue(null);
    if (trigger.type != JSONType.object || field(trigger, "type").length == 0)
        errors ~= "trigger.type is required";
    auto kind = field(value, "kind");
    if (kind == "watch" && ("watch" !in value || value["watch"].type != JSONType.object))
        errors ~= "watch routines need a watch block";
    return errors;
}

string[] validateTarget(JSONValue value)
{
    string[] errors;
    if (field(value, "schema") != "routine-ledger/target/1")
        errors ~= "schema must be routine-ledger/target/1";
    auto kind = field(value, "kind");
    if (kind != "http" && kind != "command" && kind != "github_dispatch" && kind != "agent_bus")
        errors ~= "kind must be http, command, github_dispatch, or agent_bus";
    if (kind == "agent_bus")
    {
        if (field(value, "app").length == 0)
            errors ~= "app is required";
        if (field(value, "version").length == 0)
            errors ~= "version is required";
        if (field(value, "operation").length == 0)
            errors ~= "operation is required";
        if (field(value, "chat_id").length == 0)
            errors ~= "chat_id is required";
    }
    auto launch = field(value, "launch");
    if (launch.length && launch != "wait" && launch != "launch")
        errors ~= "launch must be wait or launch";
    return errors;
}

private Routine routineFrom(JSONValue value)
{
    Routine routine;
    routine.id = field(value, "id");
    routine.owner = field(value, "owner");
    routine.kind = field(value, "kind");
    routine.prompt = field(value, "prompt");
    if ("requires" in value)
        routine.requires = strings(value["requires"]);
    if ("preferred_targets" in value)
        routine.preferred = strings(value["preferred_targets"]);
    routine.lease = field(value, "lease");
    routine.catchUp = field(value, "catch_up");
    routine.status = field(value, "status");
    if (routine.status.length == 0)
        routine.status = "active";
    routine.createdAt = field(value, "created_at");
    if ("trigger" in value && value["trigger"].type == JSONType.object)
    {
        auto trigger = value["trigger"];
        routine.triggerType = field(trigger, "type");
        routine.cron = field(trigger, "cron");
        routine.tz = field(trigger, "tz");
        routine.every = field(trigger, "every");
        routine.eventName = field(trigger, "event");
        routine.at = field(trigger, "at");
    }
    return routine;
}

private Target targetFrom(JSONValue value)
{
    Target target;
    target.id = field(value, "id");
    target.kind = field(value, "kind");
    if ("capabilities" in value)
        target.capabilities = strings(value["capabilities"]);
    if ("machines" in value)
        target.machines = strings(value["machines"]);
    target.program = field(value, "program");
    if ("args" in value)
        target.args = strings(value["args"]);
    target.app = field(value, "app");
    target.versionText = field(value, "version");
    target.operation = field(value, "operation");
    target.chatId = field(value, "chat_id");
    target.launch = field(value, "launch");
    if (target.launch.length == 0)
        target.launch = "wait";
    if ("presence" in value && value["presence"].type == JSONType.object)
    {
        target.process = field(value["presence"], "process");
        target.assumeRunning = field(value["presence"], "assume") == "running";
    }
    target.launchProgram = field(value, "launch_program");
    if ("launch_args" in value)
        target.launchArgs = strings(value["launch_args"]);
    return target;
}

Ledger loadLedger(string root)
{
    Ledger ledger;
    auto routines = buildPath(root, "routines");
    if (exists(routines))
    {
        foreach (entry; dirEntries(routines, SpanMode.shallow))
        {
            if (!entry.isFile || !entry.name.endsWith(".json5"))
                continue;
            try
            {
                auto value = parseJson5(readText(entry.name));
                ledger.errors ~= validateRoutine(value);
                ledger.routines ~= routineFrom(value);
            }
            catch (Exception exc)
            {
                ledger.errors ~= entry.name ~ ": " ~ exc.msg;
            }
        }
    }
    auto targets = buildPath(root, "targets");
    if (exists(targets))
    {
        foreach (entry; dirEntries(targets, SpanMode.shallow))
        {
            if (!entry.isFile || !entry.name.endsWith(".json5"))
                continue;
            try
            {
                auto value = parseJson5(readText(entry.name));
                ledger.errors ~= validateTarget(value);
                ledger.targets ~= targetFrom(value);
            }
            catch (Exception exc)
            {
                ledger.errors ~= entry.name ~ ": " ~ exc.msg;
            }
        }
    }
    auto runs = buildPath(root, "runs");
    if (exists(runs))
    {
        foreach (entry; dirEntries(runs, SpanMode.depth))
        {
            if (!entry.isFile || !entry.name.endsWith(".json5"))
                continue;
            auto value = parseJson5(readText(entry.name));
            RunRecord record;
            record.routine = field(value, "routine");
            record.runId = field(value, "run_id");
            record.status = field(value, "status");
            record.scheduledAt = field(value, "scheduled_at");
            ledger.runs ~= record;
        }
    }
    auto machines = buildPath(root, "machines");
    if (exists(machines))
    {
        foreach (entry; dirEntries(machines, SpanMode.shallow))
        {
            if (!entry.isFile || !entry.name.endsWith(".json5"))
                continue;
            ledger.machines ~= machineFrom(parseJson5(readText(entry.name)));
        }
    }
    return ledger;
}

MachineFile machineFrom(JSONValue value)
{
    MachineFile machine;
    machine.id = field(value, "id");
    machine.updatedAt = field(value, "updated_at");
    if ("presence" in value && value["presence"].type == JSONType.object)
    {
        auto presence = value["presence"];
        machine.hasHost = true;
        machine.hostOnline = field(presence, "host") == "online";
        machine.hostSince = field(presence, "host_since");
        if ("harnesses" in presence && presence["harnesses"].type == JSONType.array)
        {
            foreach (item; presence["harnesses"].array)
            {
                auto id = field(item, "id");
                if (id.length)
                    machine.harnessOnline[id] = field(item, "state") == "online";
            }
        }
    }
    if ("waiting" in value && value["waiting"].type == JSONType.array)
    {
        foreach (item; value["waiting"].array)
        {
            auto routine = field(item, "routine");
            if (routine.length)
                machine.lastAction[routine] = field(item, "reason");
        }
    }
    return machine;
}

bool terminalRun(string status)
{
    return status == "done" || status == "skipped" || status == "failed";
}

bool runHandled(const Ledger ledger, string routine, string runId)
{
    foreach (record; ledger.runs)
        if (record.routine == routine && record.runId == runId && record.status != "scheduled")
            return true;
    return false;
}

bool findTarget(Ledger ledger, Routine routine, string machine, out Target found)
{
    bool capable(Target target)
    {
        foreach (need; routine.requires)
        {
            bool have;
            foreach (name; target.capabilities)
                if (name == need)
                    have = true;
            if (!have)
                return false;
        }
        return true;
    }
    bool onMachine(Target target)
    {
        if (target.machines.length == 0)
            return true;
        foreach (name; target.machines)
            if (name == machine)
                return true;
        return false;
    }
    foreach (preferred; routine.preferred)
    {
        foreach (target; ledger.targets)
            if (target.id == preferred && capable(target) && onMachine(target))
            {
                found = target;
                return true;
            }
    }
    foreach (target; ledger.targets)
    {
        if (capable(target) && onMachine(target))
        {
            found = target;
            return true;
        }
    }
    return false;
}

unittest
{
    auto routine = parseJson5(`{
      schema: "routine-ledger/routine/1",
      id: "watch-git-ai-2399",
      kind: "watch",
      trigger: { type: "cron", cron: "0 9 * * *", tz: "UTC" },
      prompt: "Check the issue.",
      requires: ["shell"],
      lease: "45m",
      catch_up: "run-once",
      watch: { urls: ["https://example.invalid/x"] },
    }`);
    assert(validateRoutine(routine).length == 0);
    assert(routineFrom(routine).tz == "UTC");

    auto target = parseJson5(`{
      schema: "routine-ledger/target/1",
      id: "cursor-desktop",
      kind: "agent_bus",
      capabilities: ["shell"],
      app: "cursor",
      version: "3.29.15",
      operation: "prompt-existing-desktop-chat",
      chat_id: "composer-1",
      presence: { process: "Cursor.exe" },
    }`);
    assert(validateTarget(target).length == 0);
    auto parsed = targetFrom(target);
    assert(parsed.launch == "wait");
    assert(parsed.process == "Cursor.exe");
    assert(!parsed.assumeRunning);
}
