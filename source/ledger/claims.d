module ledger.claims;

import std.datetime : SysTime;

struct Note
{
    string kind;
    string harness;
    string sessionId;
    string[] capabilities;
    SysTime at;
    SysTime leaseExpires;
    bool hasLease;
    bool trusted = true;
}

struct Lock
{
    bool held;
    string harness;
    string sessionId;
    SysTime leaseExpires;
}

bool covers(const string[] have, const string[] need)
{
    foreach (required; need)
    {
        bool found;
        foreach (capability; have)
            if (capability == required)
                found = true;
        if (!found)
            return false;
    }
    return true;
}

Lock judge(const Note[] notes, const string[] requires, SysTime now)
{
    Lock current;
    bool reserved;
    foreach (note; notes)
    {
        if (!note.trusted)
            continue;
        if (note.kind == "claim")
        {
            if (!note.hasLease || !covers(note.capabilities, requires))
                continue;
            if (reserved && now < current.leaseExpires)
                continue;
            current.harness = note.harness;
            current.sessionId = note.sessionId;
            current.leaseExpires = note.leaseExpires;
            reserved = true;
            current.held = now < note.leaseExpires;
        }
        else if (note.kind == "start" || note.kind == "heartbeat")
        {
            if (!reserved || note.harness != current.harness || !note.hasLease)
                continue;
            current.leaseExpires = note.leaseExpires;
            current.held = now < note.leaseExpires;
        }
        else if (note.kind == "finish" || note.kind == "release")
        {
            if (reserved && note.harness == current.harness)
            {
                reserved = false;
                current.held = false;
            }
        }
    }
    if (reserved && now >= current.leaseExpires)
        current.held = false;
    return current;
}

unittest
{
    import std.datetime : Clock, UTC, minutes;

    auto now = Clock.currTime(UTC());
    Note first;
    first.kind = "claim";
    first.harness = "cursor-desktop";
    first.sessionId = "a";
    first.capabilities = ["shell", "gh"];
    first.hasLease = true;
    first.leaseExpires = now + 30.minutes;
    first.at = now;
    Note second = first;
    second.harness = "grok-bot";
    second.sessionId = "b";
    second.at = now + 1.minutes;
    auto lock = judge([first, second], ["shell"], now + 1.minutes);
    assert(lock.held);
    assert(lock.harness == "cursor-desktop");

    first.leaseExpires = now - 1.minutes;
    auto expired = judge([first], ["shell"], now);
    assert(!expired.held);

    Note weak = first;
    weak.leaseExpires = now + 30.minutes;
    weak.capabilities = ["shell"];
    auto denied = judge([weak], ["shell", "gh"], now);
    assert(!denied.held);
}
