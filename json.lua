-- /lua/json.lua
-- Memory-safe JSON для OpenComputers.
--
-- Старая версия имела O(n^2) аллокаций на каждую строку JSON
-- (res = res .. char в цикле) — на больших ответах это давало
-- мегабайты временного мусора в Lua-heap.
--
-- Новая версия:
--   * Строки парсятся через string.find (одна нативная операция вместо посимвольного цикла).
--   * Escape-последовательности декодируются одним string.gsub.
--   * Пропуск whitespace через string.find('[^...]', i) вместо посимвольной проверки.
--   * Кодирование использовало table.concat изначально — оставлено как есть.

local json = {}

-- =====================================================================
-- КОДИРОВАНИЕ (Lua -> JSON)
-- =====================================================================
local ENCODE_ESCAPE = {
    ['\\'] = '\\\\', ['"'] = '\\"',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
    ['\b'] = '\\b', ['\f'] = '\\f',
}

local function escape_str(s)
    return (s:gsub('[\\"\n\r\t\b\f]', ENCODE_ESCAPE))
end

function json.encode(v)
    local vtype = type(v)
    if vtype == "string" then
        return '"' .. escape_str(v) .. '"'
    elseif vtype == "number" or vtype == "boolean" then
        return tostring(v)
    elseif vtype == "table" then
        local is_array = true
        local max = 0
        for k, _ in pairs(v) do
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > max then max = k end
        end

        local parts = {}
        if is_array then
            for i = 1, max do
                parts[i] = json.encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local n = 0
            for k, val in pairs(v) do
                n = n + 1
                parts[n] = '"' .. escape_str(tostring(k)) .. '":' .. json.encode(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return "null"
    end
end

-- =====================================================================
-- ДЕКОДИРОВАНИЕ (JSON -> Lua)
-- =====================================================================

local DECODE_ESCAPE = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    ['b'] = '\b', ['f'] = '\f', ['n'] = '\n',
    ['r'] = '\r', ['t'] = '\t',
}

-- Пропустить whitespace, вернуть новую позицию (или #str+1 если конец)
local function skip_ws(str, pos)
    local _, e = str:find('^[ \t\r\n]+', pos)
    if e then return e + 1 end
    return pos
end

-- Декодировать escape-последовательности в строке.
local function unescape(s)
    s = s:gsub('\\u(%x%x%x%x)', function(hex)
        local cp = tonumber(hex, 16)
        if cp < 0x80 then
            return string.char(cp)
        elseif cp < 0x800 then
            return string.char(
                0xC0 + math.floor(cp / 0x40),
                0x80 + cp % 0x40)
        else
            return string.char(
                0xE0 + math.floor(cp / 0x1000),
                0x80 + math.floor(cp / 0x40) % 0x40,
                0x80 + cp % 0x40)
        end
    end)
    return (s:gsub('\\(.)', function(c)
        return DECODE_ESCAPE[c] or c
    end))
end

local parse  -- forward

local function parse_string(str, pos)
    local i = pos + 1
    while true do
        local nq = str:find('"', i, true)
        if not nq then error("Незакрытая строка на позиции " .. pos) end
        local bs = 0
        local j = nq - 1
        while j >= pos + 1 and str:byte(j) == 92 do  -- 92 = '\\'
            bs = bs + 1
            j = j - 1
        end
        if bs % 2 == 0 then
            local raw = str:sub(pos + 1, nq - 1)
            if raw:find('\\', 1, true) then
                raw = unescape(raw)
            end
            return raw, nq + 1
        end
        i = nq + 1
    end
end

local function parse_number_or_keyword(str, pos)
    local _, e = str:find('^[^ \t\r\n%]},]+', pos)
    if not e then error("Неожиданный конец JSON на позиции " .. pos) end
    local val_str = str:sub(pos, e)
    if val_str == "true" then return true, e + 1
    elseif val_str == "false" then return false, e + 1
    elseif val_str == "null" then return nil, e + 1
    end
    local num = tonumber(val_str)
    if num then return num, e + 1 end
    error("Неверное значение '" .. val_str .. "' на позиции " .. pos)
end

local function parse_array(str, pos)
    local res = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == "]" then return res, pos + 1 end
    local n = 0
    while true do
        local val
        val, pos = parse(str, pos)
        n = n + 1
        res[n] = val
        pos = skip_ws(str, pos)
        local nc = str:sub(pos, pos)
        if nc == "]" then return res, pos + 1 end
        if nc ~= "," then error("Ожидалась ',' или ']' на позиции " .. pos) end
        pos = pos + 1
    end
end

local function parse_object(str, pos)
    local res = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == "}" then return res, pos + 1 end
    while true do
        if str:sub(pos, pos) ~= '"' then error("Ожидался строковый ключ на позиции " .. pos) end
        local key
        key, pos = parse_string(str, pos)
        pos = skip_ws(str, pos)
        if str:sub(pos, pos) ~= ":" then error("Ожидалось ':' на позиции " .. pos) end
        pos = skip_ws(str, pos + 1)
        local val
        val, pos = parse(str, pos)
        res[key] = val
        pos = skip_ws(str, pos)
        local nc = str:sub(pos, pos)
        if nc == "}" then return res, pos + 1 end
        if nc ~= "," then error("Ожидалась ',' или '}' на позиции " .. pos) end
        pos = skip_ws(str, pos + 1)
    end
end

parse = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == '"' then return parse_string(str, pos)
    elseif c == "[" then return parse_array(str, pos)
    elseif c == "{" then return parse_object(str, pos)
    else return parse_number_or_keyword(str, pos) end
end

function json.decode(str)
    if type(str) ~= "string" or str == "" then return nil end
    local ok, res = pcall(parse, str, 1)
    if ok then return res else return nil, res end
end

return json
