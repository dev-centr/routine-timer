module ledger.schedule;

import std.algorithm : canFind;
import std.conv : to;
import std.datetime : DateTime, Duration, SysTime, UTC, days, hours, minutes, seconds;
import std.datetime.timezone : PosixTimeZone, TimeZone;
import std.string : indexOf, split;

struct Due
{
    bool found;
    SysTime at;
    string error;
}

Duration parseDuration(string text, out string error)
{
    if (text.length < 2)
    {
        error = "Bad duration '" ~ text ~ "'.";
        return Duration.zero;
    }
    char unit = text[$ - 1];
    int count;
    try
        count = to!int(text[0 .. $ - 1]);
    catch (Exception)
    {
        error = "Bad duration '" ~ text ~ "'.";
        return Duration.zero;
    }
    if (count < 0)
    {
        error = "Bad duration '" ~ text ~ "'.";
        return Duration.zero;
    }
    if (unit == 's')
        return count.seconds;
    if (unit == 'm')
        return count.minutes;
    if (unit == 'h')
        return count.hours;
    if (unit == 'd')
        return count.days;
    error = "Bad duration '" ~ text ~ "'.";
    return Duration.zero;
}

SysTime parseTimestamp(string text, out string error)
{
    if (text.length < 20 || text[4] != '-' || text[10] != 'T')
    {
        error = "Bad timestamp '" ~ text ~ "'.";
        return SysTime(DateTime(1970, 1, 1), UTC());
    }
    try
    {
        int year = to!int(text[0 .. 4]);
        int month = to!int(text[5 .. 7]);
        int day = to!int(text[8 .. 10]);
        int hour = to!int(text[11 .. 13]);
        int minute = to!int(text[14 .. 16]);
        int second = text.length >= 19 ? to!int(text[17 .. 19]) : 0;
        return SysTime(DateTime(year, month, day, hour, minute, second), UTC());
    }
    catch (Exception)
    {
        error = "Bad timestamp '" ~ text ~ "'.";
        return SysTime(DateTime(1970, 1, 1), UTC());
    }
}

string runId(SysTime at)
{
    auto utc = at.toUTC();
    import std.format : format;
    return format("%04d%02d%02dT%02d%02dZ", utc.year, cast(int) utc.month, utc.day, utc.hour, utc.minute);
}

private immutable(TimeZone) loadZone(string name, out string error)
{
    if (name.length == 0 || name == "UTC" || name == "Etc/UTC" || name == "Z")
        return UTC();
    try
        return PosixTimeZone.getTimeZone(name);
    catch (Exception)
    {
    }
    static immutable string[string] windowsNames = [
        "America/Chicago": "Central Standard Time",
        "America/New_York": "Eastern Standard Time",
        "America/Denver": "Mountain Standard Time",
        "America/Los_Angeles": "Pacific Standard Time",
        "UTC": "UTC",
    ];
    string windows = name;
    if (auto mapped = name in windowsNames)
        windows = *mapped;
    version (Windows)
    {
        import std.datetime.timezone : WindowsTimeZone;
        try
            return WindowsTimeZone.getTimeZone(windows);
        catch (Exception)
        {
        }
    }
    error = "Unknown time zone '" ~ name ~ "'. The timer will not guess the hour.";
    return UTC();
}

private bool fieldMatches(string field, int value, int origin)
{
    if (field == "*")
        return true;
    if (field.length >= 3 && field[0 .. 2] == "*/")
    {
        int step = to!int(field[2 .. $]);
        return step > 0 && (value - origin) % step == 0;
    }
    if (field.indexOf(',') >= 0)
    {
        foreach (part; field.split(','))
            if (fieldMatches(part, value, origin))
                return true;
        return false;
    }
    return to!int(field) == value;
}

private bool cronMatches(string expr, SysTime local)
{
    auto parts = expr.split(' ');
    string[] fields;
    foreach (part; parts)
        if (part.length)
            fields ~= part;
    if (fields.length != 5)
        return false;
    int dow = cast(int) local.dayOfWeek;
    bool dowField = fields[4] != "*";
    bool domField = fields[2] != "*";
    bool minute = fieldMatches(fields[0], local.minute, 0);
    bool hour = fieldMatches(fields[1], local.hour, 0);
    bool month = fieldMatches(fields[3], cast(int) local.month, 1);
    if (!minute || !hour || !month)
        return false;
    bool dom = fieldMatches(fields[2], local.day, 1);
    bool dowOk = fieldMatches(fields[4], dow, 0) || (fields[4] == "7" && dow == 0);
    if (domField && dowField)
        return dom || dowOk;
    return dom && dowOk;
}

Due latestDue(string triggerType, string cron, string tz, string every, string atText,
        string createdAt, SysTime now)
{
    Due due;
    string createdError;
    bool hasCreated = createdAt.length > 0;
    SysTime created = hasCreated ? parseTimestamp(createdAt, createdError) : SysTime.init;
    if (hasCreated && createdError.length)
    {
        due.error = createdError;
        return due;
    }
    if (triggerType == "event")
        return due;
    if (triggerType == "once")
    {
        string error;
        auto at = parseTimestamp(atText, error);
        if (error.length)
        {
            due.error = error;
            return due;
        }
        if (at <= now && (!hasCreated || at >= created))
        {
            due.found = true;
            due.at = at;
        }
        return due;
    }
    if (triggerType == "interval")
    {
        string error;
        auto step = parseDuration(every, error);
        if (error.length || step <= Duration.zero)
        {
            due.error = error.length ? error : "Interval must be positive.";
            return due;
        }
        auto origin = hasCreated ? created : SysTime(DateTime(1970, 1, 1), UTC());
        if (now < origin)
            return due;
        long span = (now - origin).total!"hnsecs";
        long width = step.total!"hnsecs";
        long steps = span / width;
        due.at = origin + step * steps;
        due.found = due.at <= now;
        return due;
    }
    if (triggerType != "cron")
    {
        due.error = "Unknown trigger '" ~ triggerType ~ "'.";
        return due;
    }
    string zoneError;
    auto zone = loadZone(tz.length ? tz : "UTC", zoneError);
    if (zoneError.length)
    {
        due.error = zoneError;
        return due;
    }
    auto cursor = now.toUTC();
    cursor.fracSecs = Duration.zero;
    cursor.second = 0;
    enum limit = 366 * 24 * 60;
    for (int i = 0; i < limit; i++)
    {
        auto local = SysTime(cursor.stdTime, zone);
        if (cronMatches(cron, local) && cursor <= now && (!hasCreated || cursor >= created.toUTC()))
        {
            due.found = true;
            due.at = cursor.toUTC();
            return due;
        }
        cursor -= 1.minutes;
    }
    return due;
}

unittest
{
    string error;
    assert(parseDuration("30m", error) == 30.minutes);
    assert(error.length == 0);
    auto stamp = parseTimestamp("2026-11-09T15:00:00Z", error);
    assert(error.length == 0);
    assert(runId(stamp) == "20261109T1500Z");

    auto now = SysTime(DateTime(2026, 11, 9, 15, 30, 0), UTC());
    auto due = latestDue("cron", "0 9 * * *", "UTC", "", "", "2026-11-01T00:00:00Z", now);
    assert(due.error.length == 0);
    assert(due.found);
    assert(due.at.hour == 9);
    assert(due.at.day == 9);

    auto interval = latestDue("interval", "", "UTC", "30m", "", "2026-11-09T15:00:00Z", now);
    assert(interval.found);
    assert(interval.at == SysTime(DateTime(2026, 11, 9, 15, 30, 0), UTC()));

    auto unknown = latestDue("cron", "0 9 * * *", "Not/AZone", "", "", "", now);
    assert(unknown.error.length > 0);
    assert(!unknown.found);
}
