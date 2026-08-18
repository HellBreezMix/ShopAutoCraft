-- /home/crafter.lua
-- GUI-приложение автокрафта МЭ-склада (ЛОКАЛЬНЫЙ РЕЖИМ — без PocketBase).
-- - Раз в config.crafter_interval секунд читает /home/crafter_data.json и пытается
--   заказать крафт всех товаров, у которых stock <= порога.
-- - Показывает все активные заказы, статус, возраст, кнопку отмены.
-- - Кнопка [+ ДОБАВИТЬ ТОВАР] переключает на экран сканирования сундука —
--   кладёшь предмет в сундук рядом с Adapter'ом (с Inventory Controller
--   Upgrade), жмёшь [СКАНИРОВАТЬ], задаёшь название и количества кнопками,
--   [СОХРАНИТЬ] — запись сама уходит в crafter_data.json. [< НАЗАД] — обратно.
-- - На каждый тик шлёт сводку в Discord через вебхук (см. discord.lua).
-- Закрытие: [ВЫХОД] или Ctrl+Alt+C.

local component = require("component")
local event = require("event")
local unicode = require("unicode")
local os = require("os")
local io = require("io")
local fs = require("filesystem")
local computer = require("computer")
local sides = require("sides")
local config = require("config")
local network = require("network")
local json = require("json")
local gui = require("gui")
local discord = require("discord")
local commands = require("commands")

event.shouldInterrupt = function() return false end

-- ===== Настройки =====
local INTERVAL = tonumber(config.crafter_interval) or 300
local THRESHOLD = tonumber(config.crafter_threshold) or 0
local DEFAULT_AMOUNT = tonumber(config.crafter_amount) or 64
local ENABLED_AT_START = (config.crafter_enabled ~= false)
local maxConcurrent = tonumber(config.crafter_max_concurrent) or 6
if maxConcurrent < 1 then maxConcurrent = 1 end

-- ===== Состояние =====
local activeJobs = {}
local JOB_TTL_SEC = 3600
local TICKS_PER_GC = 10
local tickCounter = 0
local memWarnedLowOnce = false

local lastTickAt = -INTERVAL
local secondsToTick = 0
local paused = not ENABLED_AT_START
local meOk = true
local dbOk = false
local totalCompleted = 0
local totalFailed = 0
local dailyCompleted = 0
local dailyFailed = 0
local dailyItemCounts = {}  -- [name] = сколько скрафчено за текущие сутки

local PROGRESS_POLL = 30
local lastProgressAt = 0

local cachedItems = nil

local issues = {}
local cpuInfo = nil
local lastTickWallTime = nil

local STATUS_PUBLISH_INTERVAL = 60
local lastStatusAt = 0
local statusPublishedOnce = false

local HEARTBEAT_INTERVAL = 60
local lastHeartbeatAt = 0
local startedAt = nil

-- ===== Экраны =====
-- "main"     — основной экран со списком крафтов
-- "add_item" — экран сканирования сундука / добавления-редактирования товара
-- "items"    — список всех товаров с кнопками редактировать/удалить
local screen = "main"
local addItem = {
    scanned = false,
    label = nil, itemId = nil, damage = 0,
    name = "", craftAmount = 64, keepAmount = 64, enabled = true,
    activeField = nil,
    message = "",
    editing = false,       -- true если редактируем существующий товар, а не добавляем новый
    returnScreen = "main", -- куда вернуться по [< НАЗАД]: "main" или "items"
}
local itemsList = {}  -- кэш списка товаров для экрана "items"

local function resetAddItem()
    addItem.scanned = false
    addItem.label = nil; addItem.itemId = nil; addItem.damage = 0
    addItem.name = ""; addItem.craftAmount = 64; addItem.keepAmount = 64
    addItem.enabled = true
    addItem.activeField = nil
    addItem.message = ""
    addItem.editing = false
    addItem.returnScreen = "main"
end

-- =========================================================
-- УТИЛИТЫ
-- =========================================================
local function formatUnixTime(unix)
    local z = math.floor(unix / 86400) + 719468
    local era = math.floor((z >= 0 and z or (z - 146096)) / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365)
    local y = yoe + era * 400
    local doy = doe - math.floor((365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100)))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp + (mp < 10 and 3 or -9)
    y = y + (m <= 2 and 1 or 0)
    local h = math.floor((unix % 86400) / 3600)
    local min = math.floor((unix % 3600) / 60)
    local s = math.floor(unix % 60)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d", y, m, d, h, min, s)
end

local _rt_cached_ms = 0
local _rt_cache_at_uptime = 0

local function getRealTime()
    local tz = tonumber(config.timezone) or 0
    local now_up = computer.uptime()
    if _rt_cached_ms > 0 and (now_up - _rt_cache_at_uptime) < 5 then
        local interpMs = _rt_cached_ms + math.floor((now_up - _rt_cache_at_uptime) * 1000)
        return formatUnixTime(math.floor(interpMs / 1000) + tz * 3600)
    end
    local tmp_file = "/home/HostTime.tmp"
    local f = io.open(tmp_file, "w")
    if f then
        pcall(function() f:write("") end)
        pcall(function() f:close() end)
        local lm = fs.lastModified(tmp_file)
        pcall(function() fs.remove(tmp_file) end)
        if lm and lm > 0 then
            _rt_cached_ms = lm
            _rt_cache_at_uptime = now_up
            return formatUnixTime(math.floor(lm / 1000) + tz * 3600)
        end
    end
    return os.date("%Y-%m-%d %H:%M:%S") .. " (игр)"
end

local LOG_JOBS = config.crafter_log_jobs == true
local NOTIFY_EVERY_TICK = config.crafter_notify_every_tick ~= false  -- по умолчанию true
local discordOk = nil          -- nil = ещё не пробовали, true/false — результат последней попытки
local lastDiscordError = ""
local function log(action, details)
    if config.use_database then
        pcall(function()
            network.request("POST", "/logs", json.encode({
                time = getRealTime(),
                action = action,
                user = "crafter",
                details = details or "",
            }))
        end)
    end
    if config.discord_webhook_url and config.discord_webhook_url ~= "" then
        local ok, sendOk, sendErr = pcall(function()
            return discord.send(string.format("**[%s]** %s\n%s", action, getRealTime(), details or ""))
        end)
        if ok then
            discordOk = sendOk and true or false
            if not sendOk then lastDiscordError = tostring(sendErr or "неизвестная ошибка") end
        else
            discordOk = false
            lastDiscordError = tostring(sendOk)  -- при pcall-ошибке результат ошибки лежит во втором значении
        end
    end
end
local function logJob(action, details)
    if not LOG_JOBS then return end
    log(action, details)
end

-- =========================================================
-- ИСТОЧНИК ТОВАРОВ
-- =========================================================
local function loadCrafterItems()
    if config.use_database then
        if not component.isAvailable("internet") then
            log("ОШИБКА", "Internet Card не найдена")
            return nil
        end
        if not config.pocketbase_url or config.pocketbase_url == ""  then
            log("ОШИБКА", "pocketbase_url не настроен в /home/config.lua")
            return nil
        end
        local ok, res = network.get("/crafter")
        if not ok then log("ОШИБКА", "Запрос /crafter провалился: " .. tostring(res)); return nil end
        if not res or res == "null" then
            log("ИНФО", "В БД нет /crafter — добавь предметы через вкладку Автокрафт")
            return {}
        end
        local parsed = json.decode(res)
        res = nil
        if not parsed then log("ОШИБКА", "Невалидный JSON в /crafter"); return nil end
        if not parsed.items then parsed = nil; return {} end
        local arr = {}
        if type(parsed.items) == "table" then
            if #parsed.items > 0 then arr = parsed.items
            else for _, v in pairs(parsed.items) do table.insert(arr, v) end end
        end
        parsed = nil
        return arr
    end
    local f = io.open("/home/crafter_data.json", "r")
    if f then
        local data = f:read("*a"); f:close()
        if data and data ~= "" then
            local parsed = json.decode(data)
            if parsed and parsed.items then return parsed.items end
        end
    end
    return nil
end

-- =========================================================
-- МЭ-СЕТЬ
-- =========================================================
local function getStocks()
    local stocks = {}
    for addr in component.list("me_interface") do
        local proxy = component.proxy(addr)
        local ok, items = pcall(function() return proxy.getItemsInNetwork() end)
        if ok and items then
            for _, it in ipairs(items) do
                local key = (it.name or "") .. "|" .. math.floor(it.damage or 0)
                stocks[key] = (stocks[key] or 0) + (it.size or 0)
            end
            return stocks, true
        end
    end
    return stocks, false
end

local function requestCraft(id, damage, amount)
    for addr in component.list("me_interface") do
        local proxy = component.proxy(addr)
        local ok, list = pcall(function() return proxy.getCraftables({ name = id, damage = damage }) end)
        if ok and list and #list > 0 then
            local craft = list[1]
            local ok_r, job = pcall(function() return craft.request(amount) end)
            if ok_r and job then return job end
        end
    end
    return nil
end

-- =========================================================
-- СКАНИРОВАНИЕ СУНДУКА (для экрана "Добавить товар")
--
-- В этой сборке Adapter даёт прямой компонент "chest" (без параметра
-- стороны — он и так привязан к одному конкретному сундуку). Поля таблицы
-- предмета в этом драйвере называются id / dmg / display_name (не
-- name / damage / label, как в "обычном" inventory_controller).
--
-- На случай другого железа (обычный inventory_controller через Adapter)
-- оставлен запасной путь ниже.
-- =========================================================
local function scanChest()
    -- ===== Путь 1: прямой компонент "chest" (то, что есть у тебя) =====
    if component.isAvailable("chest") then
        local chest = component.chest
        local ok, size = pcall(function() return chest.getInventorySize() end)
        if not ok or not size then
            addItem.message = "Ошибка: не удалось получить размер сундука"
            return
        end
        local stack = nil
        for slot = 1, size do
            local ok2, s = pcall(function() return chest.getStackInSlot(slot) end)
            if ok2 and s then stack = s; break end
        end
        if not stack then
            addItem.message = "Сундук пуст — положи предмет"
            return
        end
        addItem.scanned = true
        addItem.itemId = stack.id or "?"
        addItem.damage = math.floor(stack.dmg or 0)
        addItem.label = stack.display_name or stack.name or addItem.itemId
        addItem.name = addItem.label
        addItem.message = "Найдено: " .. addItem.label
        return
    end

    -- ===== Путь 2: запасной вариант через inventory_controller =====
    if component.isAvailable("inventory_controller") then
        local ic = component.inventory_controller
        local foundSide, size = nil, nil
        for _, side in pairs(sides) do
            local ok, sz = pcall(function() return ic.getInventorySize(side) end)
            if ok and sz and sz > 0 then foundSide = side; size = sz; break end
        end
        if not foundSide then
            addItem.message = "Ошибка: сундук не найден рядом с Adapter'ом"
            return
        end
        local stack = nil
        for slot = 1, size do
            local ok, s = pcall(function() return ic.getStackInSlot(foundSide, slot) end)
            if ok and s then stack = s; break end
        end
        if not stack then
            addItem.message = "Сундук пуст — положи предмет"
            return
        end
        addItem.scanned = true
        addItem.label = stack.label or stack.name or "?"
        addItem.itemId = stack.name or "?"
        addItem.damage = math.floor(stack.damage or 0)
        addItem.name = addItem.label
        addItem.message = "Найдено: " .. addItem.label
        return
    end

    addItem.message = "Ошибка: не найден ни chest, ни Inventory Controller"
end

-- =========================================================
-- СОХРАНЕНИЕ ТОВАРА В crafter_data.json
-- =========================================================
local function saveAddItem()
    if not addItem.scanned then
        addItem.message = "Сначала отсканируй предмет"
        return
    end
    local craft = tonumber(addItem.craftAmount) or 64
    local keep = tonumber(addItem.keepAmount) or 64
    local finalName = (addItem.name ~= "" and addItem.name) or addItem.label

    local newEntry = {
        id = addItem.itemId, damage = addItem.damage,
        name = finalName, craft_amount = craft, keep_amount = keep,
        enabled = (addItem.enabled ~= false),
    }

    local path = "/home/crafter_data.json"
    local items = {}
    if fs.exists(path) then
        local f = io.open(path, "r")
        if f then
            local data = f:read("*a"); f:close()
            local parsed = json.decode(data)
            if parsed and parsed.items then items = parsed.items end
        end
    end

    local replaced = false
    for i, it in ipairs(items) do
        if it.id == newEntry.id and math.floor(tonumber(it.damage) or 0) == newEntry.damage then
            items[i] = newEntry; replaced = true; break
        end
    end
    if not replaced then table.insert(items, newEntry) end

    local f = io.open(path, "w")
    if f then
        f:write(json.encode({ items = items }))
        f:close()
        addItem.message = (replaced and "Обновлено: " or "Добавлено: ") .. finalName
        log("СОБЫТИЕ", (replaced and "Обновлён товар: " or "Добавлен товар: ") .. finalName ..
            " (крафтить=" .. craft .. ", порог=" .. keep .. ")")
        cachedItems = nil  -- следующий тик перечитает список с диска
    else
        addItem.message = "Ошибка: не удалось записать файл"
    end
end

-- =========================================================
-- ЭКРАН "ТОВАРЫ" — список / редактирование / удаление
-- =========================================================
local function refreshItemsList()
    local path = "/home/crafter_data.json"
    itemsList = {}
    if fs.exists(path) then
        local f = io.open(path, "r")
        if f then
            local data = f:read("*a"); f:close()
            local parsed = json.decode(data)
            if parsed and parsed.items then itemsList = parsed.items end
        end
    end
end

-- Открывает экран "Добавить/редактировать товар" уже заполненным данными
-- существующего товара — без необходимости заново сканировать сундук.
local function openEditItem(it)
    addItem.scanned = true
    addItem.editing = true
    addItem.itemId = it.id
    addItem.damage = math.floor(tonumber(it.damage) or 0)
    addItem.label = it.name or it.id or "?"
    addItem.name = it.name or it.id or "?"
    addItem.craftAmount = tonumber(it.craft_amount) or 64
    addItem.keepAmount = tonumber(it.keep_amount) or 64
    addItem.enabled = (it.enabled ~= false)
    addItem.activeField = nil
    addItem.message = "Редактирование: " .. addItem.name
    addItem.returnScreen = "items"
    screen = "add_item"
end

-- Удаляет товар по индексу в itemsList и сразу перезаписывает crafter_data.json
local function deleteItemAt(idx)
    local it = itemsList[idx]
    if not it then return end
    table.remove(itemsList, idx)
    local path = "/home/crafter_data.json"
    local f = io.open(path, "w")
    if f then
        f:write(json.encode({ items = itemsList }))
        f:close()
        log("СОБЫТИЕ", "Удалён товар: " .. (it.name or it.id or "?"))
        cachedItems = nil
    end
end

-- =========================================================
-- УПРАВЛЕНИЕ JOB-АМИ
-- =========================================================
local function jobStatus(j)
    local ok_d, done = pcall(function() return j.job.isDone() end)
    local ok_c, cancel = pcall(function() return j.job.isCanceled() end)
    local ok_f, failed = pcall(function() return j.job.hasFailed() end)
    if ok_d and done then return "готов" end
    if ok_c and cancel then return "отменён" end
    if ok_f and failed then return "провален" end
    return "идёт"
end

local function pruneFinishedJobs()
    local now = computer.uptime()
    for key, j in pairs(activeJobs) do
        local s = jobStatus(j)
        if s == "готов" then
            totalCompleted = totalCompleted + 1
            dailyCompleted = dailyCompleted + 1
            dailyItemCounts[j.name] = (dailyItemCounts[j.name] or 0) + (j.amount or 0)
            logJob("ЗАВЕРШЁН", j.name .. " x" .. j.amount)
            activeJobs[key] = nil
        elseif s == "отменён" then
            logJob("ОТМЕНЁН", j.name .. " x" .. j.amount)
            activeJobs[key] = nil
        elseif s == "провален" then
            totalFailed = totalFailed + 1
            dailyFailed = dailyFailed + 1
            log("ПРОВАЛ", j.name .. " x" .. j.amount)
            activeJobs[key] = nil
        else
            if (now - (j.started_at or now)) > JOB_TTL_SEC then
                totalFailed = totalFailed + 1
                dailyFailed = dailyFailed + 1
                log("ТАЙМАУТ", j.name .. " x" .. j.amount .. " (висел " .. JOB_TTL_SEC .. "с)")
                pcall(function() j.job.cancel() end)
                pcall(function() j.job.Cancel() end)
                activeJobs[key] = nil
            end
        end
    end
end

local function updateProgress(stocksFromTick)
    local now = computer.uptime()
    if not stocksFromTick and (now - lastProgressAt) < PROGRESS_POLL then return nil end

    local stocks
    if stocksFromTick then
        stocks = stocksFromTick
    else
        local ok
        stocks, ok = getStocks()
        meOk = ok
        if not ok then return nil end
    end
    lastProgressAt = now

    for key, j in pairs(activeJobs) do
        local cur = stocks[key] or 0
        local delta = cur - (j.start_stock or 0)
        if delta > (j.produced or 0) then
            j.produced = math.min(delta, j.amount)
        end
        if (j.produced or 0) >= j.amount then
            totalCompleted = totalCompleted + 1
            dailyCompleted = dailyCompleted + 1
            dailyItemCounts[j.name] = (dailyItemCounts[j.name] or 0) + (j.amount or 0)
            logJob("ЗАВЕРШЁН", j.name .. " x" .. j.amount .. " (по стоку)")
            pcall(function() j.job.cancel() end)
            activeJobs[key] = nil
        end
    end
    return stocks
end

local function cancelJob(j)
    if not j or not j.job then return false end
    local ok = pcall(function() j.job.cancel() end)
    if not ok then pcall(function() j.job.Cancel() end) end
    return true
end

local function getCpuInfo()
    for addr in component.list("me_interface") do
        local proxy = component.proxy(addr)
        local ok, cpus = pcall(function() return proxy.getCpus() end)
        if ok and cpus then
            local total, busy = 0, 0
            for _, c in ipairs(cpus) do
                total = total + 1
                if c.busy then busy = busy + 1 end
            end
            return { total = total, busy = busy, free = total - busy }
        end
    end
    return nil
end

local function countActive()
    local n = 0
    for _ in pairs(activeJobs) do n = n + 1 end
    return n
end

-- =========================================================
-- УДАЛЁННОЕ УПРАВЛЕНИЕ ИЗ DISCORD
-- Опрашиваем Worker раз в COMMANDS_POLL_INTERVAL секунд, выполняем команды,
-- отвечаем подтверждением в тот же канал.
-- =========================================================
local COMMANDS_POLL_INTERVAL = 15
local lastCommandsPollAt = -COMMANDS_POLL_INTERVAL  -- первый опрос сразу

local function handleCommand(text, author)
    local cmd = tostring(text or ""):lower()
    author = author or "?"

    if cmd == "!пауза" or cmd == "!pause" then
        paused = true
        log("КОМАНДА", author .. ": пауза")
        discord.send("⏸ Автокрафт приостановлен по команде от " .. author)
    elseif cmd == "!авто" or cmd == "!resume" or cmd == "!продолжить" then
        paused = false
        log("КОМАНДА", author .. ": авто")
        discord.send("▶ Автокрафт возобновлён по команде от " .. author)
    elseif cmd == "!тик" or cmd == "!tick" then
        lastTickAt = -INTERVAL
        log("КОМАНДА", author .. ": тик")
        discord.send("🔄 Принудительный тик запрошен (" .. author .. ")")
    elseif cmd == "!статус" or cmd == "!status" then
        discord.send(string.format(
            "📊 Статус: %s | активно=%d/%d | завершено=%d | провалено=%d | ME=%s",
            paused and "ПАУЗА" or "АВТО", countActive(), maxConcurrent,
            totalCompleted, totalFailed, meOk and "OK" or "НЕТ СВЯЗИ"))
    else
        local n = cmd:match("^!лимит%s+(%d+)$") or cmd:match("^!limit%s+(%d+)$")
        if n then
            local newLimit = tonumber(n)
            if newLimit and newLimit >= 1 then
                maxConcurrent = newLimit
                log("КОМАНДА", author .. ": лимит=" .. newLimit)
                discord.send("⚙ Лимит одновременных крафтов изменён на " .. newLimit .. " (" .. author .. ")")
            end
        elseif cmd == "!help" or cmd == "!помощь" then
            discord.send(
                "📖 **Доступные команды:**\n" ..
                "`!статус` — текущее состояние крафтера\n" ..
                "`!пауза` / `!авто` — приостановить / возобновить автокрафт\n" ..
                "`!тик` — принудительный тик прямо сейчас\n" ..
                "`!лимит N` — сменить лимит одновременных крафтов (например `!лимит 4`)\n" ..
                "`!help` — этот список")
        end
        -- прочие неизвестные команды (или обычные сообщения без "!") молча игнорируются
    end
end

local function processCommands()
    local now = computer.uptime()
    if (now - lastCommandsPollAt) < COMMANDS_POLL_INTERVAL then return end
    lastCommandsPollAt = now
    if not component.isAvailable("internet") then return end

    local ok, cmds = pcall(commands.poll)
    if not ok or not cmds then return end
    for _, c in ipairs(cmds) do
        pcall(handleCommand, c.content, c.author)
    end
end

-- =========================================================
-- ЕЖЕДНЕВНАЯ СВОДКА
-- Раз в DAILY_SUMMARY_INTERVAL секунд (по умолчанию сутки) шлёт в Discord
-- итог за период: сколько скрафчено/провалено, топ-3 товара — и обнуляет
-- суточные счётчики. Не заменяет уведомления по тику (их можно отключить
-- отдельно через config.crafter_notify_every_tick = false).
-- =========================================================
local DAILY_SUMMARY_INTERVAL = tonumber(config.crafter_daily_summary_interval) or 86400
local lastDailySummaryAt = computer.uptime()

local function padRight(s, width)
    local len = unicode.len(s)
    if len >= width then return s end  -- длинное название показываем целиком, без обрезки
    return s .. string.rep(" ", width - len)
end

local function sendDailySummary()
    local sorted = {}
    for name, cnt in pairs(dailyItemCounts) do
        table.insert(sorted, { name = name, cnt = cnt })
    end
    table.sort(sorted, function(a, b) return a.cnt > b.cnt end)

    local MAX_LINES = 30  -- защита от слишком длинного сообщения при большом ассортименте
    local lines = { padRight("Товар", 22) .. " Кол-во", string.rep("-", 30) }
    for i = 1, math.min(MAX_LINES, #sorted) do
        table.insert(lines, padRight(sorted[i].name, 22) .. " " .. string.format("%6d", sorted[i].cnt))
    end
    if #sorted > MAX_LINES then
        table.insert(lines, "... и ещё " .. (#sorted - MAX_LINES) .. " вид(ов)")
    end
    local tableStr = (#sorted > 0) and table.concat(lines, "\n") or "(ничего не крафтилось)"

    discord.send(string.format(
        "📅 **Суточная сводка**\n```\n%s\n```\nВсего скрафчено: %d | Провалено: %d\nАктивно сейчас: %d/%d | ME=%s",
        tableStr, dailyCompleted, dailyFailed, countActive(), maxConcurrent,
        meOk and "OK" or "НЕТ СВЯЗИ"))

    dailyCompleted = 0
    dailyFailed = 0
    dailyItemCounts = {}
end

local function checkDailySummary()
    local now = computer.uptime()
    if (now - lastDailySummaryAt) < DAILY_SUMMARY_INTERVAL then return end
    lastDailySummaryAt = now
    pcall(sendDailySummary)
end

local function getRealTimeMs()
    local now_up = computer.uptime()
    if _rt_cached_ms > 0 and (now_up - _rt_cache_at_uptime) < 5 then
        return _rt_cached_ms + math.floor((now_up - _rt_cache_at_uptime) * 1000)
    end
    local tmp = "/home/HostTime.tmp"
    local f = io.open(tmp, "w")
    if not f then return nil end
    pcall(function() f:write("") end)
    pcall(function() f:close() end)
    local lm = fs.lastModified(tmp)
    pcall(function() fs.remove(tmp) end)
    if lm and lm > 0 then
        _rt_cached_ms = lm
        _rt_cache_at_uptime = now_up
        return lm
    end
    return nil
end

local function sendHeartbeat(force)
    if not config.use_database then return end
    if not config.pocketbase_url or config.pocketbase_url == ""  then return end
    if not component.isAvailable("internet") then return end
    local now = computer.uptime()
    if not force and (now - lastHeartbeatAt) < HEARTBEAT_INTERVAL then return end
    lastHeartbeatAt = now
    if not startedAt then startedAt = getRealTime() end
    local payload = {
        name = "Автокрафтер", type = "crafter",
        last_seen = getRealTime(), last_seen_ms = getRealTimeMs(),
        started_at = startedAt, paused = paused,
        active_count = countActive(), max_concurrent = maxConcurrent,
        me_ok = meOk, db_ok = dbOk,
        total_completed = totalCompleted, total_failed = totalFailed,
    }
    pcall(function() network.put("/heartbeats/crafter", json.encode(payload)) end)
end

local function publishStatus(force)
    if not config.use_database then return end
    if not config.pocketbase_url or config.pocketbase_url == ""  then return end
    if not component.isAvailable("internet") then return end
    local now = computer.uptime()
    if not force and (now - lastStatusAt) < STATUS_PUBLISH_INTERVAL then return end
    lastStatusAt = now

    local jobsArr = {}
    local arr = {}
    for _, j in pairs(activeJobs) do table.insert(arr, j) end
    table.sort(arr, function(a, b) return (a.started_at or 0) > (b.started_at or 0) end)
    local MAX_JOBS_IN_STATUS = 20
    for i = 1, math.min(#arr, MAX_JOBS_IN_STATUS) do
        local j = arr[i]
        local ok_d, done = pcall(function() return j.job.isDone() end)
        local ok_c, cancel = pcall(function() return j.job.isCanceled() end)
        local ok_f, failed = pcall(function() return j.job.hasFailed() end)
        local stat = "идёт"
        if ok_d and done then stat = "готов"
        elseif ok_c and cancel then stat = "отменён"
        elseif ok_f and failed then stat = "провален" end
        table.insert(jobsArr, {
            id = j.id, damage = j.damage, name = j.name, amount = j.amount,
            produced = j.produced or 0, age_sec = math.floor(now - (j.started_at or now)),
            status = stat,
        })
    end

    local snapshot = {
        updated_at = getRealTime(), last_tick_at = lastTickWallTime,
        me_ok = meOk, db_ok = dbOk, paused = paused, max_concurrent = maxConcurrent,
        active_count = #arr, cpu_info = cpuInfo, issues = issues, active_jobs = jobsArr,
        total_completed = totalCompleted, total_failed = totalFailed,
    }
    local body = json.encode(snapshot)
    local ok, res = network.put("/crafter_status", body)
    if not ok then
        log("STATUS_ERR", "network.put провалился: " .. tostring(res))
    elseif type(res) == "string" and (res:find("error", 1, true) or res:find("Permission", 1, true)) then
        log("STATUS_ERR", "PocketBase ответил: " .. tostring(res):sub(1, 200))
    else
        if not statusPublishedOnce then
            statusPublishedOnce = true
            log("СТАТУС", "опубликован в /crafter_status (" .. #body .. " байт)")
        end
    end
end

local function pushIssue(msg)
    table.insert(issues, msg)
end

local function tryFillSlots(stocks)
    if paused then return end
    if not cachedItems then return end
    if countActive() >= maxConcurrent then return end

    if not stocks then
        local ok
        stocks, ok = getStocks()
        meOk = ok
        if not ok then return end
    end

    for _, it in ipairs(cachedItems) do
        if countActive() >= maxConcurrent then break end
        if it.id and it.id ~= "" and it.enabled ~= false then
            local dmg = math.floor(tonumber(it.damage) or 0)
            local key = it.id .. "|" .. dmg
            local stock = stocks[key] or 0
            local keep = tonumber(it.keep_amount) or 1
            if stock < keep and not activeJobs[key] then
                local target = tonumber(it.craft_amount) or DEFAULT_AMOUNT
                local job = requestCraft(it.id, dmg, target)
                if job then
                    activeJobs[key] = {
                        job = job, name = it.name or it.id,
                        amount = target, started_at = computer.uptime(),
                        key = key, id = it.id, damage = dmg,
                        start_stock = stock, produced = 0,
                    }
                    logJob("ЗАКАЗАН", (it.name or it.id) .. " x" .. target
                        .. " (из очереди, stock=" .. stock .. "/" .. keep .. ")")
                end
            end
        end
    end
end

-- =========================================================
-- ОСНОВНОЙ ТИК
-- =========================================================
local function tick()
    pruneFinishedJobs()

    issues = {}
    cpuInfo = getCpuInfo()
    lastTickWallTime = getRealTime()

    local stocks, gotStocks = getStocks()
    meOk = gotStocks
    if not gotStocks then
        pushIssue("Нет связи с me_interface — Adapter и ME Interface должны быть рядом")
        log("ОШИБКА", "Нет связи с me_interface")
        publishStatus(true)
        return
    end

    if not cpuInfo then
        pushIssue("Не удалось получить список Crafting CPU")
    elseif cpuInfo.total == 0 then
        pushIssue("В AE-сети НЕТ Crafting CPU. Поставь Crafting Storage + Co-Processor.")
    elseif cpuInfo.free == 0 then
        pushIssue("Все " .. cpuInfo.total .. " Crafting CPU заняты — новые крафты в очереди")
    end

    local items = loadCrafterItems()
    dbOk = (items ~= nil)
    if not items then
        pushIssue("Не удалось загрузить список товаров (проверь /home/crafter_data.json)")
        publishStatus(true)
        return
    end
    cachedItems = items

    local requested, already, capped, skipped, disabled = 0, 0, 0, 0, 0
    local noPattern = {}
    for _, it in ipairs(items) do
        if it.enabled == false then
            disabled = disabled + 1
        elseif it.id and it.id ~= "" then
            local dmg = math.floor(tonumber(it.damage) or 0)
            local key = it.id .. "|" .. dmg
            local stock = stocks[key] or 0
            local keep = tonumber(it.keep_amount) or 1
            local target = tonumber(it.craft_amount) or DEFAULT_AMOUNT

            if stock < keep then
                if activeJobs[key] then
                    already = already + 1
                elseif countActive() >= maxConcurrent then
                    capped = capped + 1
                else
                    local job = requestCraft(it.id, dmg, target)
                    if job then
                        activeJobs[key] = {
                            job = job, name = it.name or it.id,
                            amount = target, started_at = computer.uptime(),
                            key = key, id = it.id, damage = dmg,
                            start_stock = stock, produced = 0,
                        }
                        requested = requested + 1
                        logJob("ЗАКАЗАН", (it.name or it.id) .. " x" .. target
                            .. " (stock=" .. stock .. "/" .. keep .. ")")
                    else
                        skipped = skipped + 1
                        table.insert(noPattern, (it.name or it.id) .. " (" .. it.id .. ":" .. dmg .. ")")
                    end
                end
            end
        end
    end
    if #noPattern > 0 then
        local shown = {}
        for i = 1, math.min(5, #noPattern) do table.insert(shown, noPattern[i]) end
        local msg = "Нет паттерна для: " .. table.concat(shown, ", ")
        if #noPattern > 5 then msg = msg .. " и ещё " .. (#noPattern - 5) end
        pushIssue(msg)
    end

    if NOTIFY_EVERY_TICK then
        log("ТИК", string.format(
            "заказано=%d, уже_крафтится=%d, в_очереди=%d, не_craftable=%d, выкл=%d, всего=%d, лимит=%d",
            requested, already, capped, skipped, disabled, #items, maxConcurrent))
    end

    updateProgress(stocks)
    publishStatus(true)
end

-- =========================================================
-- РЕНДЕР
-- =========================================================
local function buildState()
    local arr = {}
    for _, j in pairs(activeJobs) do table.insert(arr, j) end
    table.sort(arr, function(a, b) return (a.started_at or 0) > (b.started_at or 0) end)
    local out = {}
    local now = computer.uptime()
    for _, j in ipairs(arr) do
        table.insert(out, {
            key = j.key, name = j.name, amount = j.amount,
            produced = j.produced or 0, status = jobStatus(j),
            age_sec = math.floor(now - (j.started_at or now)),
        })
    end
    return {
        jobs = out, recentLog = {}, secondsToTick = secondsToTick,
        totalCompleted = totalCompleted, totalFailed = totalFailed,
        meOk = meOk, dbOk = dbOk, paused = paused,
        maxConcurrent = maxConcurrent, activeCount = countActive(),
        discordOk = discordOk, lastDiscordError = lastDiscordError,
    }
end

local function redraw()
    if screen == "add_item" then
        pcall(function() gui.drawAddItem(addItem) end)
    elseif screen == "items" then
        pcall(function() gui.drawItemsList(itemsList) end)
    else
        pcall(function() gui.draw(buildState()) end)
    end
end

-- =========================================================
-- ОБРАБОТКА КНОПОК
-- =========================================================
local function handleClick(id)
    if screen == "add_item" then
        if id == "back" then
            local dest = addItem.returnScreen or "main"
            resetAddItem()
            if dest == "items" then refreshItemsList() end
            screen = dest
        elseif id == "scan" then
            scanChest()
        elseif id == "field_name" then
            addItem.activeField = "name"
        elseif id == "toggle_enabled" then
            addItem.enabled = not addItem.enabled
        elseif id == "craft_dec" then
            addItem.craftAmount = math.max(1, (addItem.craftAmount or 64) - 1)
        elseif id == "craft_dec10" then
            addItem.craftAmount = math.max(1, (addItem.craftAmount or 64) - 10)
        elseif id == "craft_dec100" then
            addItem.craftAmount = math.max(1, (addItem.craftAmount or 64) - 100)
        elseif id == "craft_dec1000" then
            addItem.craftAmount = math.max(1, (addItem.craftAmount or 64) - 1000)
        elseif id == "craft_dec10000" then
            addItem.craftAmount = math.max(1, (addItem.craftAmount or 64) - 10000)
        elseif id == "craft_inc" then
            addItem.craftAmount = (addItem.craftAmount or 64) + 1
        elseif id == "craft_inc10" then
            addItem.craftAmount = (addItem.craftAmount or 64) + 10
        elseif id == "craft_inc100" then
            addItem.craftAmount = (addItem.craftAmount or 64) + 100
        elseif id == "craft_inc1000" then
            addItem.craftAmount = (addItem.craftAmount or 64) + 1000
        elseif id == "craft_inc10000" then
            addItem.craftAmount = (addItem.craftAmount or 64) + 10000
        elseif id == "keep_dec" then
            addItem.keepAmount = math.max(1, (addItem.keepAmount or 64) - 1)
        elseif id == "keep_dec10" then
            addItem.keepAmount = math.max(1, (addItem.keepAmount or 64) - 10)
        elseif id == "keep_dec100" then
            addItem.keepAmount = math.max(1, (addItem.keepAmount or 64) - 100)
        elseif id == "keep_dec1000" then
            addItem.keepAmount = math.max(1, (addItem.keepAmount or 64) - 1000)
        elseif id == "keep_dec10000" then
            addItem.keepAmount = math.max(1, (addItem.keepAmount or 64) - 10000)
        elseif id == "keep_inc" then
            addItem.keepAmount = (addItem.keepAmount or 64) + 1
        elseif id == "keep_inc10" then
            addItem.keepAmount = (addItem.keepAmount or 64) + 10
        elseif id == "keep_inc100" then
            addItem.keepAmount = (addItem.keepAmount or 64) + 100
        elseif id == "keep_inc1000" then
            addItem.keepAmount = (addItem.keepAmount or 64) + 1000
        elseif id == "keep_inc10000" then
            addItem.keepAmount = (addItem.keepAmount or 64) + 10000
        elseif id == "save" then
            saveAddItem()
        end
        return
    end

    if screen == "items" then
        if id == "items_back" then
            screen = "main"
        elseif id == "items_add" then
            resetAddItem()
            addItem.returnScreen = "items"
            screen = "add_item"
        elseif id and id:match("^edit_%d+$") then
            local idx = tonumber(id:match("%d+"))
            local it = itemsList[idx]
            if it then openEditItem(it) end
        elseif id and id:match("^delete_%d+$") then
            local idx = tonumber(id:match("%d+"))
            deleteItemAt(idx)
        end
        return
    end

    -- ===== главный экран =====
    if id == "add_item_btn" then
        resetAddItem()
        addItem.returnScreen = "main"
        screen = "add_item"
    elseif id == "items_btn" then
        refreshItemsList()
        screen = "items"
    elseif id == "force_tick" then
        lastTickAt = -INTERVAL
        log("СОБЫТИЕ", "Принудительный тик")
    elseif id == "pause" then
        paused = not paused
        log("СОБЫТИЕ", paused and "Автокрафт приостановлен" or "Автокрафт включён")
    elseif id == "cancel_all" then
        local n = 0
        for _, j in pairs(activeJobs) do cancelJob(j); n = n + 1 end
        log("СОБЫТИЕ", "Отменены все крафты (" .. n .. ")")
    elseif id == "limit_dec" then
        if maxConcurrent > 1 then
            maxConcurrent = maxConcurrent - 1
            log("СОБЫТИЕ", "Лимит одновременных крафтов: " .. maxConcurrent)
        end
    elseif id == "limit_inc" then
        maxConcurrent = maxConcurrent + 1
        log("СОБЫТИЕ", "Лимит одновременных крафтов: " .. maxConcurrent)
        local stocks = updateProgress()
        if stocks then tryFillSlots(stocks) else tryFillSlots() end
    elseif id == "quit" then
        log("СТОП", "Выход по кнопке")
        local gpu = component.gpu
        gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
        require("term").clear()
        os.exit()
    elseif id and id:match("^cancel_%d+$") then
        local idx = tonumber(id:match("%d+"))
        local arr = {}
        for _, j in pairs(activeJobs) do table.insert(arr, j) end
        table.sort(arr, function(a, b) return (a.started_at or 0) > (b.started_at or 0) end)
        local j = arr[idx]
        if j then
            cancelJob(j)
            log("ОТМЕНА", "Запрошена отмена: " .. j.name)
        end
    end
end

-- =========================================================
-- ОСНОВНОЙ ЦИКЛ
-- =========================================================
pcall(function() if fs.exists("/home/crafter.log") then fs.remove("/home/crafter.log") end end)
pcall(function() if fs.exists("/home/HostTime.tmp") then fs.remove("/home/HostTime.tmp") end end)

log("СТАРТ", string.format("interval=%ds, default_amount=%d, max_concurrent=%d",
    INTERVAL, DEFAULT_AMOUNT, maxConcurrent))

local function loop()
    redraw()
    while true do
        local sinceLast = computer.uptime() - lastTickAt
        secondsToTick = math.max(0, INTERVAL - math.floor(sinceLast))

        if not paused and sinceLast >= INTERVAL then
            local ok, err = pcall(tick)
            if not ok then log("FATAL_TICK", tostring(err)) end
            lastTickAt = computer.uptime()
            redraw()
        end

        pruneFinishedJobs()
        local stocks = updateProgress()
        if stocks then tryFillSlots(stocks) end
        stocks = nil
        publishStatus()
        sendHeartbeat()
        processCommands()  -- rate-limited внутри (раз в COMMANDS_POLL_INTERVAL сек)
        checkDailySummary()  -- rate-limited внутри (раз в DAILY_SUMMARY_INTERVAL сек)

        tickCounter = tickCounter + 1
        if tickCounter >= TICKS_PER_GC then
            tickCounter = 0
            local total = computer.totalMemory()
            local free = computer.freeMemory()
            if total and total > 0 then
                local usedPct = math.floor((total - free) * 100 / total)

                if usedPct >= 70 and not memWarnedLowOnce then
                    memWarnedLowOnce = true
                    log("⚠ RAM ПЕРЕПОЛНЕНА", string.format(
                        "Оперативка занята на %d%% (%d/%d KB). Поставь больше RAM или подними интервалы.",
                        usedPct, math.floor((total-free)/1024), math.floor(total/1024)))
                end
                if usedPct < 55 then memWarnedLowOnce = false end

                if usedPct >= 92 then
                    log("🆘 RAM ПРЕДЕЛ", string.format("RAM = %d%% — экстренный ребут.", usedPct))
                    os.sleep(3)
                    computer.shutdown(true)
                end

                if usedPct >= 82 then
                    log("⚠ RAM КРИТИЧНО", string.format("RAM %d%%, очищаю кеши. Sleep 2s.", usedPct))
                    cachedItems = nil
                    issues = {}
                    cpuInfo = nil
                    for k, j in pairs(activeJobs) do
                        local ok, done = pcall(function() return j.job.isDone() end)
                        if ok and done then activeJobs[k] = nil end
                    end
                    os.sleep(2)

                    local free2 = computer.freeMemory()
                    local usedPct2 = math.floor((total - free2) * 100 / total)
                    if usedPct2 >= 80 then
                        log("⚠ АВАРИЙНЫЙ ПЕРЕЗАГРУЗ", string.format(
                            "После сброса RAM = %d%%. Reboot через 5 сек.", usedPct2))
                        os.sleep(5)
                        computer.shutdown(true)
                    elseif usedPct2 < 65 then
                        log("✓ RAM ВОССТАНОВЛЕНА", string.format(
                            "Было %d%%, стало %d%%", usedPct, usedPct2))
                    else
                        log("⚠ RAM ЧАСТИЧНО", string.format(
                            "Уменьшилось с %d%% до %d%%, но ещё высоко.", usedPct, usedPct2))
                    end
                end
            end
        end

        local ev = { event.pull(1) }
        local name = ev[1]
        if name == "touch" then
            local x, y = ev[3], ev[4]
            local id = gui.checkClick(x, y)
            if id then
                pcall(computer.beep, 1000, 0.05)
                handleClick(id)
                redraw()
            end
        elseif name == "key_down" then
            -- Порядок подтверждён диагностикой (diag_keys.lua): ev[3] = символ
            -- (unicode-код, поддерживает кириллицу), ev[4] = код клавиши (scancode).
            local a, b = ev[3], ev[4]
            if screen == "add_item" and addItem.activeField == "name" then
                -- Подтверждено диагностикой: символ приходит в ev[3] (a), код
                -- клавиши — в ev[4] (b).
                local char, code = a, b
                if code == 28 then
                    addItem.activeField = nil
                elseif code == 14 then
                    -- Backspace: убираем последний СИМВОЛ (а не байт — кириллица
                    -- занимает 2 байта в UTF-8, string.sub(-2) её бы поломал)
                    local len = unicode.len(addItem.name)
                    if len > 0 then
                        addItem.name = unicode.sub(addItem.name, 1, len - 1)
                    end
                elseif char and char >= 32 and char ~= 127 then
                    -- unicode.char вместо string.char — иначе кириллица и другие
                    -- многобайтовые символы (codepoint > 255) ломают строку
                    local ok, ch = pcall(unicode.char, char)
                    if ok and ch then addItem.name = addItem.name .. ch end
                end
                redraw()
            elseif screen == "main" then
                -- Подтверждено диагностикой: код клавиши в ev[4] (b), не ev[3].
                local code = b
                if code == 33 then handleClick("force_tick"); redraw()
                elseif code == 18 then handleClick("quit")
                elseif code == 25 then handleClick("pause"); redraw() end
            end
        elseif name == "interrupted" then
            handleClick("quit")
        elseif not name then
            redraw()
        end
    end
end

local ok, err = pcall(loop)
if not ok then
    log("CRASH", tostring(err))
    component.gpu.setBackground(0x000000)
    component.gpu.setForeground(0xFF5555)
    require("term").clear()
    print("Программа упала: " .. tostring(err))
end
