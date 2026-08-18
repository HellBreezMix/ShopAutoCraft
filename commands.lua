-- /home/commands.lua
-- Опрос Cloudflare Worker на новые команды из Discord-канала.
-- ВАЖНО: используем тот же корневой адрес ("/"), что и уведомления в
-- discord.lua — отдельный путь "/poll" у Cloudflare почему-то ловил 403,
-- хотя корневой путь работает стабильно. Worker сам различает "это опрос
-- команд или обычное уведомление" по наличию поля "after" в теле JSON.
-- Состояние (id последнего обработанного сообщения) хранится локально в
-- файле, поэтому переживает перезагрузку компьютера.

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
-- Никогда не бросает исключение наружу.
function commands.poll()
    local base = config.discord_webhook_url
    if not base or base == "" then return {} end
    local lastId = loadLastId()
    local body = json.encode({ after = lastId })
    local headers = { ["Content-Type"] = "application/json" }

    local handle
    local ok, result = pcall(function()
        handle = internet.request(base, body, headers, "POST")
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
