module ledger.wake;

// A due job is handed to agent-bus. This module only builds that command.
// It never starts the harness process.

struct WakeTarget
{
    string app;
    string versionText;
    string operation;
    string chatId;
}

struct WakeCommand
{
    string bin;
    string[] args;
    string error;
}

WakeCommand agentBusSubmit(WakeTarget target, string bin, string profiles, string text,
        bool worstCase, bool iUnderstand, string db)
{
    WakeCommand command;
    command.bin = bin.length ? bin : "agent-bus";
    if (profiles.length == 0)
    {
        command.error = "Set --profiles or AGENT_BUS_PROFILES so the timer can call agent-bus.";
        return command;
    }
    if (target.app.length == 0 || target.versionText.length == 0
            || target.operation.length == 0 || target.chatId.length == 0)
    {
        command.error = "agent_bus target needs app, version, operation, and chat_id.";
        return command;
    }
    if (text.length == 0)
    {
        command.error = "Refusing to submit an empty prompt.";
        return command;
    }
    command.args = [
        "--profiles", profiles, "submit",
        "--app", target.app,
        "--version", target.versionText,
        "--operation", target.operation,
        "--chat-id", target.chatId,
        "--text", text,
    ];
    if (worstCase)
        command.args ~= "--worst-case";
    if (iUnderstand)
        command.args ~= "--i-understand";
    if (db.length)
        command.args ~= ["--db", db];
    return command;
}

unittest
{
    WakeTarget target;
    target.app = "cursor";
    target.versionText = "3.29.15";
    target.operation = "prompt-existing-desktop-chat";
    target.chatId = "composer-1";
    auto missing = agentBusSubmit(target, "agent-bus", "", "do the thing", false, false, "");
    assert(missing.error.length > 0);
    assert(missing.args.length == 0);

    auto command = agentBusSubmit(target, "agent-bus", "C:/profiles", "do the thing", false, false, "");
    assert(command.error.length == 0);
    assert(command.bin == "agent-bus");
    assert(command.args[0] == "--profiles");
    assert(command.args[2] == "submit");
    bool sawWorst;
    foreach (arg; command.args)
        if (arg == "--worst-case")
            sawWorst = true;
    assert(!sawWorst);
    assert(command.args[$ - 1] == "do the thing");
}
