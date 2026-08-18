-- /home/config.lua  (локальный режим, без PocketBase)
--
-- Токен/секреты НЕ хранятся в этом файле — они лежат в /home/secret.lua
-- (который не стоит куда-либо выкладывать публично, там ссылка вебхука).

local fs = require("filesystem")
local secret = {}
if fs.exists("/home/secret.lua") then
    local ok, loaded = pcall(dofile, "/home/secret.lua")
    if ok and type(loaded) == "table" then secret = loaded end
end

return {
    use_database = false,  -- ГЛАВНОЕ: работаем полностью локально, без внешнего сервера

    -- Ссылка Discord Webhook — уведомления вместо веб-панели.
    -- Хранится в secret.lua, сюда попадает автоматически.
    discord_webhook_url = secret.discord_webhook_url or "",

    log_source = "crafter",
    timezone   = 3,

    crafter_interval        = 300,   -- раз в 300 сек (5 мин) — полный тик + уведомление в Discord
    crafter_max_concurrent  = 6,     -- сколько крафтов делать одновременно
    crafter_amount          = 64,    -- сколько крафтить за раз по умолчанию
    crafter_log_jobs        = false, -- true — уведомление на КАЖДЫЙ отдельный крафт (может быть много сообщений)
}
