-- /home/crafter.lua
-- GUI-приложение автокрафта МЭ-склада (ЛОКАЛЬНЫЙ РЕЖИМ — без PocketBase).
-- - Раз в config.crafter_interval секунд читает /home/crafter_data.json и пытается
--   заказать крафт всех товаров, у которых stock <= порога.
-- - Показывает все активные заказы, статус, возраст, кнопку отмены.
-- - Кнопки: тик сейчас, пауза/авто, отменить всё, выход.
-- - На каждый тик шлёт сводку в Discord через вебхук (см. discord.lua).
-- Закрытие: [ВЫХОД] или Ctrl+Alt+C.

local component = require("component")
local event = require("event")
local os = require("os")
local io = require("io")
local fs = require("filesystem")
local computer = require("computer")
local config = require("config")
local network = require("network")
local json = require("json")
local gui = require("gui")
local discord = require("discord")

event.shouldInterrupt = function() return false end

-- ===== Настройки =====
local INTERVAL = tonumber(config.crafter_interval) or 300
local THRESHOLD = tonumber(config.crafter_threshold) or 0
local DEFAULT_AMOUNT = tonumber(config.crafter_amount) or 64
local ENABLED_AT_START = (config.crafter_enabled ~= false)
local maxConcurrent = tonumber(config.crafter_max_concurrent) or 6
if maxConcurrent < 1 then maxConcurrent = 1 end

-- ===== Состояние =====
local activeJobs = {}  -- [key] = {job, name, amount, started_at, key, id, damage, start_stock, produced}
local JOB_TTL_SEC = 3600       -- max возраст job в activeJobs — иначе принудительно убираем (1 час)
local TICKS_PER_GC = 10        -- диагностика памяти каждые N итераций event-loop'а
local tickCounter = 0
local memWarnedLowOnce = false

local lastTickAt = -INTERVAL  -- чтобы первый тик случился сразу
local secondsToTick = 0
local paused = not ENABLED_AT_START
local meOk = true
local dbOk = false
local totalCompleted = 0
local totalFailed = 0

-- Опрос стоков для прогресса (раз в N секунд) — увеличено для экономии RAM
local PROGRESS_POLL = 30
local lastProgressAt = 0

-- Кэш последнего загруженного списка товаров (для добивания очереди между тиками)
local cachedItems = nil

-- Проблемы для отчёта (issues) — что мешает работе. Обновляются в tick().
local issues = {}
local cpuInfo = nil   -- { total, busy, free }
local lastTickWallTime = nil

-- Публикация статуса в БД (раз в N секунд) — реже = меньше JSON-аллокаций
local STATUS_PUBLISH_INTERVAL = 60
local lastStatusAt = 0
local statusPublishedOnce = false

-- Heartbeat для дашборда: маленький snapshot со временем последней активности
local HEARTBEAT_INTERVAL = 60
local lastHeartbeatAt = 0
local startedAt = nil  -- инициализируем при первом heartbeat'е

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

-- Кеш реального времени: io.open + fs.remove каждый вызов = JVM-мост, утечка.
-- Обновляем не чаще раза в 5 сек, между ними интерполируем uptime.
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

-- Логирование: в PocketBase (если use_database=true) И/ИЛИ в Discord (если
-- настроен discord_webhook_url в config.lua/secret.lua). В локальном режиме
-- (use_database=false) работает только вторая ветка.
-- Штатные события крафта (ЗАКАЗАН, ЗАВЕРШЁН, ОТМЕНЁН) — это шум. При
-- maxConcurrent=6 и активной игре они генерируют много сообщений в час.
-- Эти события идут в лог/Discord ТОЛЬКО если в config.lua явно включить
-- `crafter_log_jobs = true`. Ошибки/таймауты/тики (редкие) идут всегда.
local LOG_JOBS = config.crafter_log_jobs == true
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
        pcall(function()
            discord.send(string.format("**[%s]** %s\n%s", action, getRealTime(), details or ""))
        end)
    end
end
-- Шорткат для штатных job-логов: пишет только если LOG_JOBS включён.
-- (А ТИК/ОШИБКА/ПРОВАЛ/ТАЙМАУТ/СТАРТ/СТОП пишут всегда через обычный log)
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
        res = nil  -- освобождаем строку ответа, она может быть большой
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
            logJob("ЗАВЕРШЁН", j.name .. " x" .. j.amount)
            activeJobs[key] = nil
        elseif s == "отменён" then
            logJob("ОТМЕНЁН", j.name .. " x" .. j.amount)
            activeJobs[key] = nil
        elseif s == "провален" then
            totalFailed = totalFailed + 1
            log("ПРОВАЛ", j.name .. " x" .. j.amount)
            activeJobs[key] = nil
        else
            -- TTL: если job висит дольше JOB_TTL_SEC, считаем зависшим и убираем
            -- (попытаемся cancel'нуть; не страшно если не получится)
            if (now - (j.started_at or now)) > JOB_TTL_SEC then
                totalFailed = totalFailed + 1
                log("ТАЙМАУТ", j.name .. " x" .. j.amount .. " (висел " .. JOB_TTL_SEC .. "с)")
                pcall(function() j.job.cancel() end)
                pcall(function() j.job.Cancel() end)
                activeJobs[key] = nil
            end
        end
    end
end

-- =========================================================
-- ПРОГРЕСС ВЫПОЛНЕНИЯ
-- Снимаем актуальные стоки из МЭ и считаем produced = current - start_stock.
-- Если игрок забрал что-то — produced не уменьшаем (берём max со старым значением).
-- Если produced >= amount → крафт считаем готовым и удаляем из activeJobs.
-- =========================================================
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
            logJob("ЗАВЕРШЁН", j.name .. " x" .. j.amount .. " (по стоку)")
            pcall(function() j.job.cancel() end)
            activeJobs[key] = nil
        end
    end
    return stocks  -- возвращаем стоки, чтобы tryFillSlots их переиспользовала
end

local function cancelJob(j)
    if not j or not j.job then return false end
    local ok = pcall(function() j.job.cancel() end)
    if not ok then pcall(function() j.job.Cancel() end) end
    return true
end

-- =========================================================
-- ИНФА О CRAFTING CPU В AE-СЕТИ
-- =========================================================
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

-- =========================================================
-- ПОДСЧЁТ АКТИВНЫХ (должна быть выше всех, кто её зовёт — sendHeartbeat/publishStatus/tryFillSlots/tick)
-- =========================================================
local function countActive()
    local n = 0
    for _ in pairs(activeJobs) do n = n + 1 end
    return n
end

-- Возвращает unix-timestamp в миллисекундах (UTC). Использует тот же кеш,
-- что getRealTime, чтобы не делать второй io.open за один тик.
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

-- =========================================================
-- ПУБЛИКАЦИЯ СТАТУСА (только если use_database=true; в локальном режиме — no-op)
-- =========================================================
local function sendHeartbeat(force)
    if not config.use_database then return end
    if not config.pocketbase_url or config.pocketbase_url == ""  then return end
    if not component.isAvailable("internet") then return end
    local now = computer.uptime()
    if not force and (now - lastHeartbeatAt) < HEARTBEAT_INTERVAL then return end
    lastHeartbeatAt = now
    if not startedAt then startedAt = getRealTime() end
    local payload = {
        name = "Автокрафтер",
        type = "crafter",
        last_seen = getRealTime(),
        last_seen_ms = getRealTimeMs(),
        started_at = startedAt,
        paused = paused,
        active_count = countActive(),
        max_concurrent = maxConcurrent,
        me_ok = meOk,
        db_ok = dbOk,
        total_completed = totalCompleted,
        total_failed = totalFailed,
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

    -- собираем активные крафты в сериализуемом виде (ограничиваем 20 чтобы JSON не разбух)
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
            id = j.id, damage = j.damage,
            name = j.name, amount = j.amount,
            produced = j.produced or 0,
            age_sec = math.floor(now - (j.started_at or now)),
            status = stat,
        })
    end

    local snapshot = {
        updated_at = getRealTime(),
        last_tick_at = lastTickWallTime,
        me_ok = meOk,
        db_ok = dbOk,
        paused = paused,
        max_concurrent = maxConcurrent,
        active_count = #arr,
        cpu_info = cpuInfo,
        issues = issues,
        active_jobs = jobsArr,
        total_completed = totalCompleted,
        total_failed = totalFailed,
    }
    local body = json.encode(snapshot)
    local ok, res = network.put("/crafter_status", body)
    if not ok then
        log("STATUS_ERR", "network.put провалился: " .. tostring(res))
    elseif type(res) == "string" and (res:find("error", 1, true) or res:find("Permission", 1, true)) then
        log("STATUS_ERR", "PocketBase ответил: " .. tostring(res):sub(1, 200))
    else
        -- первая успешная публикация → одна запись в лог, чтобы было видно что работает
        if not statusPublishedOnce then
            statusPublishedOnce = true
            log("СТАТУС", "опубликован в /crafter_status (" .. #body .. " байт)")
        end
    end
end

local function pushIssue(msg)
    table.insert(issues, msg)
end

-- =========================================================
-- ДОБИВАНИЕ ОЧЕРЕДИ
-- Использует кэшированный список товаров и переданные/свежие стоки.
-- Запускает столько новых крафтов, чтобы countActive() достигло maxConcurrent.
-- Вызывается между основными тиками — даёт быструю реакцию на завершение крафта.
-- =========================================================
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

    local started = 0
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
                    started = started + 1
                    logJob("ЗАКАЗАН", (it.name or it.id) .. " x" .. target
                        .. " (из очереди, stock=" .. stock .. "/" .. keep .. ")")
                end
            end
        end
    end
end

-- =========================================================
-- ОСНОВНОЙ ТИК
-- Загружает список товаров, обновляет cachedItems, заполняет слоты до maxConcurrent,
-- и шлёт сводку в Discord (если настроен вебхук).
-- =========================================================
local function tick()
    pruneFinishedJobs()

    -- собираем issues заново каждый тик
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
    cachedItems = items  -- запоминаем для tryFillSlots между тиками

    local requested = 0
    local already = 0
    local capped = 0
    local skipped = 0
    local disabled = 0
    local noPattern = {}  -- предметы без паттерна, для подробного отчёта
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
                    capped = capped + 1   -- товар в очереди, ждёт свободного слота
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
    -- агрегируем проблему "нет паттерна" в одну запись
    if #noPattern > 0 then
        local shown = {}
        for i = 1, math.min(5, #noPattern) do table.insert(shown, noPattern[i]) end
        local msg = "Нет паттерна для: " .. table.concat(shown, ", ")
        if #noPattern > 5 then msg = msg .. " и ещё " .. (#noPattern - 5) end
        pushIssue(msg)
    end

    -- ТИК: сводка всегда шлётся (эта запись и есть уведомление "каждый тик" в Discord)
    log("ТИК", string.format(
        "заказано=%d, уже_крафтится=%d, в_очереди=%d, не_craftable=%d, выкл=%d, всего=%d, лимит=%d",
        requested, already, capped, skipped, disabled, #items, maxConcurrent))

    -- сразу пересчитываем прогресс по уже полученным стокам (без двойного запроса в ME)
    updateProgress(stocks)

    publishStatus(true)
end

-- =========================================================
-- РЕНДЕР
-- =========================================================
local function buildState()
    -- сортируем jobs по времени создания (новые сверху)
    local arr = {}
    for _, j in pairs(activeJobs) do table.insert(arr, j) end
    table.sort(arr, function(a, b) return (a.started_at or 0) > (b.started_at or 0) end)
    local out = {}
    local now = computer.uptime()
    for _, j in ipairs(arr) do
        table.insert(out, {
            key = j.key, name = j.name, amount = j.amount,
            produced = j.produced or 0,
            status = jobStatus(j),
            age_sec = math.floor(now - (j.started_at or now)),
        })
    end
    return {
        jobs = out,
        recentLog = {},   -- не используется в GUI (логи теперь в Discord), оставлено для совместимости
        secondsToTick = secondsToTick,
        totalCompleted = totalCompleted,
        totalFailed = totalFailed,
        meOk = meOk,
        dbOk = dbOk,
        paused = paused,
        maxConcurrent = maxConcurrent,
        activeCount = countActive(),
    }
end

local function redraw()
    pcall(function() gui.draw(buildState()) end)
end

-- =========================================================
-- ОБРАБОТКА КНОПОК
-- =========================================================
local function handleClick(id)
    if id == "force_tick" then
        lastTickAt = -INTERVAL  -- следующий тик сразу
        log("СОБЫТИЕ", "Принудительный тик")
    elseif id == "pause" then
        paused = not paused
        log("СОБЫТИЕ", paused and "Автокрафт приостановлен" or "Автокрафт включён")
    elseif id == "cancel_all" then
        local n = 0
        for _, j in pairs(activeJobs) do
            cancelJob(j); n = n + 1
        end
        log("СОБЫТИЕ", "Отменены все крафты (" .. n .. ")")
    elseif id == "limit_dec" then
        if maxConcurrent > 1 then
            maxConcurrent = maxConcurrent - 1
            log("СОБЫТИЕ", "Лимит одновременных крафтов: " .. maxConcurrent)
        end
    elseif id == "limit_inc" then
        maxConcurrent = maxConcurrent + 1
        log("СОБЫТИЕ", "Лимит одновременных крафтов: " .. maxConcurrent)
        -- при увеличении лимита сразу добиваем очередь
        local stocks = updateProgress()
        if stocks then tryFillSlots(stocks) else tryFillSlots() end
    elseif id == "quit" then
        log("СТОП", "Выход по кнопке")
        gpu = component.gpu
        gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
        require("term").clear()
        os.exit()
    elseif id and id:match("^cancel_%d+$") then
        local idx = tonumber(id:match("%d+"))
        -- собираем активные в том же порядке, что в buildState
        local arr = {}
        for _, j in pairs(activeJobs) do table.insert(arr, j) end
        table.sort(arr, function(a, b) return (a.started_at or 0) > (b.started_at or 0) end)
        local j = arr[idx]
        if j then
            cancelJob(j)
            log("ОТМЕНА", "Запрошена отмена: " .. j.name)
            -- статус обновится на следующем pruneFinishedJobs
        end
    end
end

-- =========================================================
-- ОСНОВНОЙ ЦИКЛ
-- =========================================================
-- Удаляем осколки от прошлых версий программы
pcall(function() if fs.exists("/home/crafter.log") then fs.remove("/home/crafter.log") end end)
pcall(function() if fs.exists("/home/HostTime.tmp") then fs.remove("/home/HostTime.tmp") end end)

log("СТАРТ", string.format("interval=%ds, default_amount=%d, max_concurrent=%d",
    INTERVAL, DEFAULT_AMOUNT, maxConcurrent))

local function loop()
    redraw()
    while true do
        local sinceLast = computer.uptime() - lastTickAt
        secondsToTick = math.max(0, INTERVAL - math.floor(sinceLast))

        -- Запускаем тик, если пора и не на паузе
        if not paused and sinceLast >= INTERVAL then
            local ok, err = pcall(tick)
            if not ok then log("FATAL_TICK", tostring(err)) end
            lastTickAt = computer.uptime()
            redraw()
        end

        -- Подтягиваем статусы и прогресс, при свободных слотах сразу добиваем очередь
        pruneFinishedJobs()
        local stocks = updateProgress()
        if stocks then tryFillSlots(stocks) end
        stocks = nil  -- освобождаем ссылку чтобы GC мог собрать большую таблицу
        publishStatus()  -- rate-limited, no-op в локальном режиме
        sendHeartbeat()  -- rate-limited, no-op в локальном режиме

        -- Диагностика RAM: warning при 70%, авто-сброс кешей при 82%, авто-reboot при 92%
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
                        "Оперативка OC-компьютера занята на %d%% (%d/%d KB). " ..
                        "Поставь больше RAM-плашек в Computer Case или подними интервалы в config.lua.",
                        usedPct, math.floor((total-free)/1024), math.floor(total/1024)))
                end
                if usedPct < 55 then memWarnedLowOnce = false end

                if usedPct >= 92 then
                    log("🆘 RAM ПРЕДЕЛ", string.format(
                        "RAM = %d%% — экстренный ребут. После reboot — автостарт из .shrc.", usedPct))
                    os.sleep(3)
                    computer.shutdown(true)
                end

                if usedPct >= 82 then
                    log("⚠ RAM КРИТИЧНО", string.format(
                        "RAM %d%%, очищаю кеши: cachedItems, issues, завершённые jobs. Sleep 2s.", usedPct))
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
                            "После сброса кешей RAM = %d%% (всё ещё критично). Reboot через 5 сек.", usedPct2))
                        os.sleep(5)
                        computer.shutdown(true)
                    elseif usedPct2 < 65 then
                        log("✓ RAM ВОССТАНОВЛЕНА", string.format(
                            "Сброс помог: было %d%%, стало %d%%", usedPct, usedPct2))
                    else
                        log("⚠ RAM ЧАСТИЧНО", string.format(
                            "Сброс уменьшил RAM с %d%% до %d%%, но ещё высоко.", usedPct, usedPct2))
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
            local code = ev[3]
            if code == 33 then handleClick("force_tick"); redraw()      -- F
            elseif code == 18 then handleClick("quit")                   -- E
            elseif code == 25 then handleClick("pause"); redraw() end    -- P
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
