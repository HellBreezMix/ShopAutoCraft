-- /home/discord.lua
-- Простой клиент для отправки текстовых уведомлений в Discord через Webhook.
-- Не требует своего сервера/БД — только Internet Card и бесплатную ссылку вебхука.

local internet = require("internet")
local json = require("json")
local config = require("config")

local discord = {}

local function safeClose(handle)
    if not handle then return end
    pcall(function() handle:close() end)
    pcall(function() if handle.close then handle.close(handle) end end)
end

-- discord.send(text) — отправляет одно сообщение в канал, привязанный к вебхуку.
-- Полностью безопасна: любые сетевые ошибки гасятся внутри через pcall,
-- крафтер не упадёт, даже если Discord временно недоступен.
function discord.send(text)
    local url = config.discord_webhook_url
    if not url or url == "" then return false, "discord_webhook_url не настроен в config.lua/secret.lua" end
    if not text or text == "" then return false, "пустое сообщение" end

    -- Discord ограничивает длину content 2000 символами — на всякий случай обрезаем
    if #text > 1900 then text = text:sub(1, 1900) .. "... (обрезано)" end

    local body = json.encode({ content = text })
    local headers = { ["Content-Type"] = "application/json" }

    local handle
    local ok, err = pcall(function()
        handle = internet.request(url, body, headers, "POST")
        for _ in handle do end -- вычитываем ответ до конца, чтобы соединение закрылось штатно
    end)
    safeClose(handle); handle = nil
    if not ok then return false, tostring(err) end
    return true
end

return discord
