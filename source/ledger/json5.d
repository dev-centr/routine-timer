module ledger.json5;

import std.ascii : isDigit, isHexDigit, isWhite;
import std.conv : to;
import std.json : JSONType, JSONValue;

class Json5Error : Exception
{
    this(string message, string file = __FILE__, size_t line = __LINE__)
    {
        super(message, file, line);
    }
}

JSONValue parseJson5(string text)
{
    Parser parser;
    parser.s = text;
    parser.skip();
    if (parser.i >= parser.s.length)
        throw new Json5Error("Empty JSON5.");
    auto value = parser.parseValue();
    parser.skip();
    if (parser.i != parser.s.length)
        throw new Json5Error("Trailing data in JSON5.");
    return value;
}

private struct Parser
{
    string s;
    size_t i;

    void skip()
    {
        while (i < s.length)
        {
            char c = s[i];
            if (isWhite(c))
            {
                i++;
                continue;
            }
            if (c == '/' && i + 1 < s.length && s[i + 1] == '/')
            {
                i += 2;
                while (i < s.length && s[i] != '\n')
                    i++;
                continue;
            }
            if (c == '/' && i + 1 < s.length && s[i + 1] == '*')
            {
                i += 2;
                while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/'))
                    i++;
                if (i + 1 >= s.length)
                    throw new Json5Error("Unterminated comment.");
                i += 2;
                continue;
            }
            break;
        }
    }

    JSONValue parseValue()
    {
        skip();
        if (i >= s.length)
            throw new Json5Error("Unexpected end of JSON5.");
        char c = s[i];
        if (c == '{')
            return parseObject();
        if (c == '[')
            return parseArray();
        if (c == '"' || c == '\'')
            return JSONValue(parseString());
        if (c == '-' || isDigit(c))
            return parseNumber();
        if (starts("true"))
        {
            i += 4;
            return JSONValue(true);
        }
        if (starts("false"))
        {
            i += 5;
            return JSONValue(false);
        }
        if (starts("null"))
        {
            i += 4;
            return JSONValue(null);
        }
        throw new Json5Error("Unexpected character in JSON5.");
    }

    JSONValue parseObject()
    {
        expect('{');
        JSONValue[string] obj;
        skip();
        if (peek('}'))
        {
            i++;
            return JSONValue(obj);
        }
        while (true)
        {
            skip();
            string key = parseKey();
            skip();
            expect(':');
            obj[key] = parseValue();
            skip();
            if (peek('}'))
            {
                i++;
                break;
            }
            expect(',');
            skip();
            if (peek('}'))
            {
                i++;
                break;
            }
        }
        return JSONValue(obj);
    }

    JSONValue parseArray()
    {
        expect('[');
        JSONValue[] items;
        skip();
        if (peek(']'))
        {
            i++;
            return JSONValue(items);
        }
        while (true)
        {
            items ~= parseValue();
            skip();
            if (peek(']'))
            {
                i++;
                break;
            }
            expect(',');
            skip();
            if (peek(']'))
            {
                i++;
                break;
            }
        }
        return JSONValue(items);
    }

    string parseKey()
    {
        skip();
        if (i < s.length && (s[i] == '"' || s[i] == '\''))
            return parseString();
        return parseIdent();
    }

    string parseIdent()
    {
        if (i >= s.length || !isIdentStart(s[i]))
            throw new Json5Error("Expected a key.");
        size_t start = i;
        i++;
        while (i < s.length && isIdent(s[i]))
            i++;
        return s[start .. i];
    }

    string parseString()
    {
        char quote = s[i];
        i++;
        string value;
        while (i < s.length)
        {
            char c = s[i];
            if (c == quote)
            {
                i++;
                return value;
            }
            if (c == '\\')
            {
                i++;
                if (i >= s.length)
                    throw new Json5Error("Bad escape.");
                char e = s[i];
                i++;
                switch (e)
                {
                case '"':
                case '\'':
                case '\\':
                case '/':
                    value ~= e;
                    break;
                case 'b':
                    value ~= '\b';
                    break;
                case 'f':
                    value ~= '\f';
                    break;
                case 'n':
                    value ~= '\n';
                    break;
                case 'r':
                    value ~= '\r';
                    break;
                case 't':
                    value ~= '\t';
                    break;
                case 'u':
                    if (i + 4 > s.length)
                        throw new Json5Error("Bad unicode escape.");
                    dchar ch = cast(dchar) to!int(s[i .. i + 4], 16);
                    i += 4;
                    import std.utf : encode;
                    char[4] buf;
                    value ~= buf[0 .. encode(buf, ch)];
                    break;
                default:
                    throw new Json5Error("Bad escape.");
                }
                continue;
            }
            value ~= c;
            i++;
        }
        throw new Json5Error("Unterminated string.");
    }

    JSONValue parseNumber()
    {
        size_t start = i;
        if (s[i] == '-')
            i++;
        while (i < s.length && isDigit(s[i]))
            i++;
        bool fractional = false;
        if (i < s.length && s[i] == '.')
        {
            fractional = true;
            i++;
            while (i < s.length && isDigit(s[i]))
                i++;
        }
        if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
        {
            fractional = true;
            i++;
            if (i < s.length && (s[i] == '+' || s[i] == '-'))
                i++;
            while (i < s.length && isDigit(s[i]))
                i++;
        }
        string token = s[start .. i];
        if (fractional)
            return JSONValue(to!double(token));
        return JSONValue(to!long(token));
    }

    bool starts(string word)
    {
        return i + word.length <= s.length && s[i .. i + word.length] == word;
    }

    bool peek(char c)
    {
        return i < s.length && s[i] == c;
    }

    void expect(char c)
    {
        skip();
        if (i >= s.length || s[i] != c)
            throw new Json5Error("Expected '" ~ c ~ "'.");
        i++;
    }
}

private bool isIdentStart(char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '$';
}

private bool isIdent(char c)
{
    return isIdentStart(c) || isDigit(c);
}

unittest
{
    auto value = parseJson5(`// note
    {
      schema: "routine-ledger/routine/1",
      n: 1,
      ok: true,
      tags: ["shell",],
      empty: null,
    }`);
    assert(value["schema"].str == "routine-ledger/routine/1");
    assert(value["n"].integer == 1);
    assert(value["ok"].type == JSONType.true_);
    assert(value["tags"].array.length == 1);
    assert(value["empty"].type == JSONType.null_);
}
