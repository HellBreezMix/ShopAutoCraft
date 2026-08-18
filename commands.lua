-- /home/commands.lua
-- Опрос Cloudflare Worker на новые команды из Discord-канала.
-- Работает через тот же Worker, что и уведомления (discord_webhook_url) —
-- используем его как базовый адрес и стучимся в /poll.
-- Состояние (id последнего обработанного сообщения) хранится локально в
-- файле, поэтому переживает перезагрузку компьютера и не требует KV на Worker'е.

local internet = require("internet")
local json = require("json")
local fs = require("filesystem")
local config = require("config")

local commands = {}

local STATE_FILE = "/home/last_cmd_id.txt"

local function loadLastId()
    if fs.exists(STATE_FILE) then
        local f = io.open(STATE_FILE, "r")
        if f then
            local id = f:read("*a"); f:close()
            id = id and id:gsub("%s+", "") or ""
            if id ~= "" then return id end
        end
    end
    return "0"
end

local function saveLastId(id)
    local f = io.open(STATE_FILE, "w")
    if f then f:write(tostring(id)); f:close() end
end

local function safeClose(handle)
    if not handle then return end
    pcall(function() handle:close() end)
    pcall(function() if handle.close then handle.close(handle) end end)
end

-- commands.poll() -> массив { id, content, author } новых команд (может быть пустым).
-- Никогда не бросает исключение наружу — любая сетевая ошибка гасится молча,
-- просто вернётся пустой список (следующая попытка через POLL_INTERVAL).
function commands.poll()
    local base = config.discord_webhook_url
    if not base or base == "" then return {} end
    local lastId = loadLastId()
    local pollUrl = base .. "/poll?after=" .. lastId

    local handle
    local ok, result = pcall(function()
        handle = internet.request(pollUrl)
        local parts = {}
        for chunk in handle do parts[#parts + 1] = chunk end
        return table.concat(parts)
    end)
    safeClose(handle); handle = nil
    if not ok then return {} end

    local parsed = json.decode(result)
    if not parsed then return {} end
    if parsed.lastId then saveLastId(parsed.lastId) end
    return parsed.commands or {}
end

return commands
