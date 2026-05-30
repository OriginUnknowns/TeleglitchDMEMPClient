-- Minimal JSON encoder/decoder for the MP wire protocol.
-- Schema: numbers, strings, booleans, null, arrays, objects. No nested escapes beyond \" \\ \n.
-- Designed to round-trip with Node.js JSON.parse/stringify.

local json = {}

-- ============ ENCODE ============
local function escape_str(s)
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "\r", "\\r")
    s = string.gsub(s, "\t", "\\t")
    return s
end

local function encode(v)
    local t = type(v)
    if t == "nil" or v == json.null then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return string.format("%.4f", v):gsub("%.?0+$", "")
    elseif t == "string" then return "\"" .. escape_str(v) .. "\""
    elseif t == "table" then
        -- Detect array vs object: integer keys 1..N → array
        local is_array = true
        local n = 0
        for k, _ in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then is_array = false; break end
        end
        if is_array and n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        elseif n == 0 then
            return "[]"  -- empty table treated as array; safer for snapshots
        else
            local parts = {}
            for k, val in pairs(v) do
                table.insert(parts, "\"" .. escape_str(tostring(k)) .. "\":" .. encode(val))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

json.encode = encode
json.null = {}  -- sentinel

-- ============ DECODE ============
-- Simple recursive descent parser. Handles our schema.
local pos
local s_

local function skip_ws()
    while pos <= #s_ do
        local c = string.sub(s_, pos, pos)
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then break end
        pos = pos + 1
    end
end

local parse_value

local function parse_string()
    pos = pos + 1  -- skip opening quote
    local start = pos
    local parts = {}
    while pos <= #s_ do
        local c = string.sub(s_, pos, pos)
        if c == "\"" then
            table.insert(parts, string.sub(s_, start, pos - 1))
            pos = pos + 1
            return table.concat(parts)
        elseif c == "\\" then
            table.insert(parts, string.sub(s_, start, pos - 1))
            local n = string.sub(s_, pos + 1, pos + 1)
            if n == "n" then table.insert(parts, "\n")
            elseif n == "t" then table.insert(parts, "\t")
            elseif n == "r" then table.insert(parts, "\r")
            elseif n == "\"" then table.insert(parts, "\"")
            elseif n == "\\" then table.insert(parts, "\\")
            elseif n == "/" then table.insert(parts, "/")
            else table.insert(parts, n) end
            pos = pos + 2
            start = pos
        else
            pos = pos + 1
        end
    end
    error("unterminated string at " .. start)
end

local function parse_number()
    local start = pos
    while pos <= #s_ do
        local c = string.sub(s_, pos, pos)
        if not c:match("[0-9eE%.%-%+]") then break end
        pos = pos + 1
    end
    return tonumber(string.sub(s_, start, pos - 1))
end

local function parse_array()
    pos = pos + 1  -- skip [
    local arr = {}
    skip_ws()
    if string.sub(s_, pos, pos) == "]" then pos = pos + 1; return arr end
    while true do
        skip_ws()
        table.insert(arr, parse_value())
        skip_ws()
        local c = string.sub(s_, pos, pos)
        if c == "]" then pos = pos + 1; return arr end
        if c == "," then pos = pos + 1
        else error("expected , or ] at " .. pos) end
    end
end

local function parse_object()
    pos = pos + 1  -- skip {
    local obj = {}
    skip_ws()
    if string.sub(s_, pos, pos) == "}" then pos = pos + 1; return obj end
    while true do
        skip_ws()
        if string.sub(s_, pos, pos) ~= "\"" then error("expected string key at " .. pos) end
        local key = parse_string()
        skip_ws()
        if string.sub(s_, pos, pos) ~= ":" then error("expected : at " .. pos) end
        pos = pos + 1
        skip_ws()
        obj[key] = parse_value()
        skip_ws()
        local c = string.sub(s_, pos, pos)
        if c == "}" then pos = pos + 1; return obj end
        if c == "," then pos = pos + 1
        else error("expected , or } at " .. pos) end
    end
end

parse_value = function()
    skip_ws()
    local c = string.sub(s_, pos, pos)
    if c == "\"" then return parse_string()
    elseif c == "{" then return parse_object()
    elseif c == "[" then return parse_array()
    elseif c == "t" and string.sub(s_, pos, pos+3) == "true" then pos = pos + 4; return true
    elseif c == "f" and string.sub(s_, pos, pos+4) == "false" then pos = pos + 5; return false
    elseif c == "n" and string.sub(s_, pos, pos+3) == "null" then pos = pos + 4; return json.null
    elseif c:match("[%-0-9]") then return parse_number()
    else error("unexpected char '" .. c .. "' at " .. pos) end
end

function json.decode(str)
    s_ = str; pos = 1
    return parse_value()
end

return json
