-- /lua/network.lua
-- ============================================================================
-- HTTP-клиент для PocketBase (заменяет старый Firebase Realtime DB клиент).
--
-- ВАЖНО: этот файл специально сохраняет старый внешний API (`net.get`,
-- `net.post`, `net.put`, `net.patch` с Firebase-style путями), чтобы НЕ
-- переписывать вызовы во всех OC-программах (shop/main.lua, crafter.lua,
-- casino/main.lua, me_snapshot.lua). Маппинг путей на PocketBase коллекции
-- происходит внутри этого файла.
--
-- ЛОКАЛЬНЫЙ РЕЖИМ: если в config.lua use_database = false, все функции
-- crafter.lua, которые сюда обращаются, просто не вызываются (см. проверки
-- config.use_database внутри crafter.lua) — этот файл нужен только потому,
-- что crafter.lua делает require("network") при старте.
--
-- Memory-safe (как и Firebase-версия):
--   - table.concat вместо `s = s..chunk` (избегаем O(n²) аллокаций)
--   - safeClose handle'а через pcall — нет утечки TCP в JVM-мосте
--   - nil-ing больших переменных после использования
-- ============================================================================

local internet = require("internet")
local config = require("config")
local json = require("json")

local net = {}

-- =====================================================================
-- НИЗКИЙ УРОВЕНЬ: HTTP-запрос с JWT-токеном
-- =====================================================================

local function safeClose(handle)
    if not handle then return end
    pcall(function() handle:close() end)
    pcall(function() if handle.close then handle.close(handle) end end)
end

local function pbRequest(method, urlPath, bodyJson)
    if not config.pocketbase_url or config.pocketbase_url == "" then
        return false, "pocketbase_url не настроен в config.lua"
    end

    local url = config.pocketbase_url .. urlPath
    local headers = { ["Content-Type"] = "application/json" }
    if config.pocketbase_token and config.pocketbase_token ~= "" then
        headers["Authorization"] = config.pocketbase_token
    end

    -- OC Internet Card умеет только GET/POST. Для PATCH/PUT/DELETE шлём
    -- POST + X-HTTP-Method-Override — Caddy на сервере подменит method.
    local actualMethod = method
    if method == "PATCH" or method == "PUT" or method == "DELETE" then
        actualMethod = "POST"
        headers["X-HTTP-Method-Override"] = method
    end

    local handle
    local ok, errOrResult = pcall(function()
        handle = internet.request(url, bodyJson, headers, actualMethod)
        local parts = {}
        for chunk in handle do parts[#parts + 1] = chunk end
        local result = table.concat(parts)
        parts = nil
        return result
    end)
    safeClose(handle); handle = nil; headers = nil; url = nil
    if ok then return true, errOrResult end
    return false, "Сеть: " .. tostring(errOrResult)
end

-- URL-encode для query параметров (PB filter содержит '(' ')' "'" — браузер
-- кодирует их автоматически, но OC internet.request — нет, и PB не находит запись.
local function urlEncode(s)
    return (s:gsub("[^A-Za-z0-9_.~%-]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function pbFind(collection, filter, perPage, sort)
    local q = "perPage=" .. (perPage or 1)
    if filter then q = q .. "&filter=" .. urlEncode(filter) end
    if sort   then q = q .. "&sort="   .. urlEncode(sort)   end
    local ok, body = pbRequest("GET", "/api/collections/" .. collection .. "/records?" .. q)
    if not ok then return nil, body end
    local parsed = json.decode(body); body = nil
    return parsed, nil
end

local function pbCreate(collection, payload)
    return pbRequest("POST", "/api/collections/" .. collection .. "/records",
        json.encode(payload))
end

local function pbUpdate(collection, id, payload)
    return pbRequest("PATCH", "/api/collections/" .. collection .. "/records/" .. id,
        json.encode(payload))
end

-- Upsert single-record-коллекции (shop_config, me_snapshot, crafter_status, casino_config)
local function pbUpsertSingle(collection, payload)
    local r = pbFind(collection, nil, 1)
    if r and r.items and r.items[1] then
        return pbUpdate(collection, r.items[1].id, payload)
    end
    return pbCreate(collection, payload)
end

-- Найти/создать heartbeat (уникальный program_id)
local function pbUpsertHeartbeat(programId, payload)
    local r = pbFind("heartbeats", "(program_id='" .. programId .. "')", 1)
    if r and r.items and r.items[1] then
        return pbUpdate("heartbeats", r.items[1].id, payload)
    end
    payload.program_id = programId
    return pbCreate("heartbeats", payload)
end

-- =====================================================================
-- ВЫСОКИЙ УРОВЕНЬ: эмуляция Firebase-style путей
-- =====================================================================

-- --- /shop --------------------------------------------------------------
local function getShop()
    local cfg   = pbFind("shop_config",     nil, 1)
    local cats  = pbFind("shop_categories", nil, 200, "order")
    local items = pbFind("shop_items",      nil, 2000)
    local buy   = pbFind("shop_buyback",    nil, 500)

    local shop = {}
    if cfg and cfg.items and cfg.items[1] then
        shop.shop_name = cfg.items[1].shop_name
    end
    -- Маппинг id→name для перевода relation в строку (shop main.lua сравнивает
    -- s_item.category с active_category по ИМЕНИ, не по PB-relation-ID).
    local cat_id_to_name = {}
    shop.categories = {}
    if cats and cats.items then
        for _, c in ipairs(cats.items) do
            shop.categories[#shop.categories+1] = c.name
            cat_id_to_name[c.id] = c.name
        end
    end
    shop.items = {}
    if items and items.items then
        for _, it in ipairs(items.items) do
            shop.items[#shop.items+1] = {
                id          = it.item_id,
                name        = it.name,
                price       = it.price,
                damage      = it.damage,
                category    = cat_id_to_name[it.category] or it.category,
                icon        = it.icon,
                icon_render = it.icon_render,
                enabled     = it.enabled,
            }
        end
    end
    shop.buyback = {}
    if buy and buy.items then
        for _, b in ipairs(buy.items) do
            shop.buyback[#shop.buyback+1] = {
                id      = b.item_id,
                name    = b.name,
                price   = b.price,
                damage  = b.damage,
                enabled = b.enabled,
            }
        end
    end
    return true, json.encode(shop)
end

-- --- /users -------------------------------------------------------------
local function getAllUsers()
    local resp = pbFind("users", nil, 500)
    local out = {}
    if resp and resp.items then
        for _, u in ipairs(resp.items) do
            out[u.username] = {
                balance = u.balance or 0,
                spent   = u.spent or 0,
                isAdmin = u.is_admin and true or false,
            }
        end
    end
    return true, json.encode(out)
end

local function getUser(username)
    local resp = pbFind("users", "(username='" .. username .. "')", 1)
    if resp and resp.items and resp.items[1] then
        local u = resp.items[1]
        return true, json.encode({
            balance = u.balance or 0,
            spent   = u.spent or 0,
            isAdmin = u.is_admin and true or false,
        })
    end
    return true, "null"
end

local function patchUser(username, bodyJson)
    local data = json.decode(bodyJson)
    if not data then return false, "Bad JSON" end
    local payload = {}
    if data.balance ~= nil then payload.balance  = data.balance end
    if data.spent   ~= nil then payload.spent    = data.spent end
    if data.isAdmin ~= nil then payload.is_admin = data.isAdmin and true or false end
    local resp = pbFind("users", "(username='" .. username .. "')", 1)
    if resp and resp.items and resp.items[1] then
        return pbUpdate("users", resp.items[1].id, payload)
    end
    -- юзера ещё нет — создаём (с placeholder-паролем)
    payload.username        = username
    payload.password        = "OCBOT_" .. tostring(math.random(1e9))
    payload.passwordConfirm = payload.password
    return pbCreate("users", payload)
end

-- === КАЗИНО: отдельная коллекция casino_users со своими балансами ===
local function getAllCasinoUsers()
    local resp = pbFind("casino_users", nil, 500)
    local out = {}
    if resp and resp.items then
        for _, u in ipairs(resp.items) do
            out[u.username] = {
                balance = u.balance or 0,
                spent   = u.spent or 0,
            }
        end
    end
    return true, json.encode(out)
end

local function getCasinoUser(username)
    local resp = pbFind("casino_users", "(username='" .. username .. "')", 1)
    if resp and resp.items and resp.items[1] then
        local u = resp.items[1]
        return true, json.encode({
            balance = u.balance or 0,
            spent   = u.spent or 0,
        })
    end
    return true, "null"
end

local function patchCasinoUser(username, bodyJson)
    local data = json.decode(bodyJson)
    if not data then return false, "Bad JSON" end
    local payload = {}
    if data.balance ~= nil then payload.balance = data.balance end
    if data.spent   ~= nil then payload.spent   = data.spent end
    local resp = pbFind("casino_users", "(username='" .. username .. "')", 1)
    if resp and resp.items and resp.items[1] then
        return pbUpdate("casino_users", resp.items[1].id, payload)
    end
    payload.username = username
    return pbCreate("casino_users", payload)
end

-- --- /logs --------------------------------------------------------------
local function postLog(bodyJson)
    local d = json.decode(bodyJson)
    if not d then return false, "Bad JSON" end
    local timeStr = d.time
    if timeStr and not timeStr:find("T") then
        timeStr = timeStr:gsub(" ", "T") .. ".000Z"
    end
    return pbCreate("logs", {
        time    = timeStr or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        user    = d.user or "",
        action  = d.action or "",
        details = d.details or "",
        source  = d.source or (config.log_source or "shop"),
    })
end

local function postCasinoLog(bodyJson)
    local d = json.decode(bodyJson)
    if not d then return false, "Bad JSON" end
    local timeStr = d.time
    if timeStr and not timeStr:find("T") then
        timeStr = timeStr:gsub(" ", "T") .. ".000Z"
    end
    return pbCreate("casino_logs", {
        time      = timeStr or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        user      = d.user or "",
        action    = d.action or "",
        details   = d.details or "",
        source    = "casino",
        bet       = d.bet or 0,
        win       = d.win or 0,
        case_name = d.case or d.case_name or "",
    })
end

-- --- /heartbeats --------------------------------------------------------
local function putHeartbeat(programId, bodyJson)
    local d = json.decode(bodyJson)
    if not d then return false, "Bad JSON" end
    local lastSeen = d.last_seen
    if lastSeen and not lastSeen:find("T") then
        lastSeen = lastSeen:gsub(" ", "T") .. ".000Z"
    end
    local startedAt = d.started_at
    if startedAt and not startedAt:find("T") then
        startedAt = startedAt:gsub(" ", "T") .. ".000Z"
    end
    local extra = {}
    for k, v in pairs(d) do
        if k ~= "name" and k ~= "type" and k ~= "last_seen"
           and k ~= "last_seen_ms" and k ~= "started_at" and k ~= "stopped" then
            extra[k] = v
        end
    end
    return pbUpsertHeartbeat(programId, {
        name         = d.name or programId,
        type         = d.type or programId,
        last_seen    = lastSeen or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        last_seen_ms = d.last_seen_ms or 0,
        started_at   = startedAt,
        stopped      = d.stopped and true or false,
        extra        = extra,
    })
end

-- --- /me_snapshot, /crafter_status, /casino -----------------------------
local function putMeSnapshot(bodyJson)
    local d = json.decode(bodyJson)
    if not d then return false, "Bad JSON" end
    local upd = d.updated_at
    if upd and not upd:find("T") then upd = upd:gsub(" ", "T") .. ".000Z" end
    return pbUpsertSingle("me_snapshot", {
        updated_at   = upd or os.date("!%Y-%m-%dT%H:%M:%SZ"),
        unique_count = d.unique_count or 0,
        total_size   = d.total_size or 0,
        truncated    = type(d.truncated) == "number" and d.truncated or 0,
        items        = d.items or {},
    })
end

local function putCrafterStatus(bodyJson)
    local d = json.decode(bodyJson)
    if not d then return false, "Bad JSON" end
    return pbUpsertSingle("crafter_status", {
        paused          = d.paused and true or false,
        me_ok           = (d.meOk or d.me_ok) and true or false,
        db_ok           = (d.dbOk or d.db_ok) and true or false,
        max_concurrent  = d.maxConcurrent or d.max_concurrent or 0,
        total_completed = d.totalCompleted or d.total_completed or 0,
        total_failed    = d.totalFailed or d.total_failed or 0,
        active_jobs     = d.jobs or d.active_jobs or {},
        cpu_info        = d.cpuInfo or d.cpu_info or nil,
        issues          = d.issues or {},
        updated_at      = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    })
end

local function getCasinoData()
    local cfg = pbFind("casino_config", nil, 1)
    local cases = pbFind("casino_cases", nil, 100)
    local items = pbFind("casino_items", nil, 1000)
    local out = {}
    if cfg and cfg.items and cfg.items[1] then
        for k, v in pairs(cfg.items[1]) do
            if k ~= "id" and k ~= "collectionId" and k ~= "collectionName"
               and k ~= "created" and k ~= "updated" then
                out[k] = v
            end
        end
    end
    out.cases = {}
    if cases and cases.items then
        for _, c in ipairs(cases.items) do
            out.cases[#out.cases+1] = {
                _id     = c.id,
                name    = c.name,
                price   = c.price,
                image   = c.image,
                enabled = c.enabled,
                items   = {},
            }
        end
    end
    if items and items.items then
        for _, it in ipairs(items.items) do
            for _, cs in ipairs(out.cases) do
                if cs._id == it["case"] then
                    cs.items[#cs.items+1] = {
                        id     = it.item_id,
                        name   = it.name,
                        damage = tonumber(it.damage) or 0,
                        chance = tonumber(it.chance) or 0,
                        price  = tonumber(it.price) or 0,
                        qty    = tonumber(it.qty) or 1,
                    }
                    break
                end
            end
        end
    end
    return true, json.encode(out)
end

local function putCasinoData(bodyJson)
    local d = json.decode(bodyJson)
    if not d then return false, "Bad JSON" end
    pbUpsertSingle("casino_config", {
        roulette_speed = d.roulette_speed or 100,
        min_bet        = d.min_bet or 1,
        max_bet        = d.max_bet or 1000,
    })
    return true, "ok"
end

-- =====================================================================
-- ПУБЛИЧНЫЙ API (совместимый со старым Firebase-клиентом)
-- =====================================================================

local function getCrafterItems()
    local r = pbFind("crafter_items", nil, 500, "order")
    local arr = {}
    if r and r.items then
        for _, it in ipairs(r.items) do
            arr[#arr+1] = {
                id           = it.item_id,
                name         = it.name,
                damage       = it.damage,
                craft_amount = it.craft_amount,
                keep_amount  = it.keep_amount,
                enabled      = it.enabled,
                icon         = it.icon,
                numeric_id   = it.numeric_id,
            }
        end
    end
    return true, json.encode({ items = arr })
end

function net.get(path)
    if path == "/shop"    then return getShop() end
    if path == "/crafter" then return getCrafterItems() end
    if path == "/users"   then return getAllUsers() end
    if path == "/casino/users" then return getAllCasinoUsers() end
    local cu = path:match("^/casino/users/(.+)")
    if cu then return getCasinoUser(cu) end
    local u = path:match("^/users/(.+)")
    if u then return getUser(u) end
    if path == "/casino" or path == "/casino/data" or path == "/data" then
        return getCasinoData()
    end
    return true, "null"
end

function net.post(path, data)
    if path == "/logs"        then return postLog(data) end
    if path == "/casino/logs" then return postCasinoLog(data) end
    return false, "POST unsupported: " .. path
end

function net.put(path, data)
    local hb = path:match("^/heartbeats/(.+)")
    if hb then return putHeartbeat(hb, data) end
    if path == "/me_snapshot"    then return putMeSnapshot(data) end
    if path == "/crafter_status" then return putCrafterStatus(data) end
    if path == "/data" or path == "/casino/data" then return putCasinoData(data) end
    local cu = path:match("^/casino/users/(.+)")
    if cu then return patchCasinoUser(cu, data) end
    local u = path:match("^/users/(.+)")
    if u then return patchUser(u, data) end
    if path == "/shop" then
        local d = json.decode(data)
        if d and d.shop_name then
            return pbUpsertSingle("shop_config", { shop_name = d.shop_name, currency = "ЭМ" })
        end
        return true, "ok"
    end
    return false, "PUT unsupported: " .. path
end

function net.patch(path, data)
    local cu = path:match("^/casino/users/(.+)")
    if cu then return patchCasinoUser(cu, data) end
    local u = path:match("^/users/(.+)")
    if u then return patchUser(u, data) end
    return false, "PATCH unsupported: " .. path
end

function net.request(method, path, data)
    if method == "GET"   then return net.get(path) end
    if method == "POST"  then return net.post(path, data) end
    if method == "PUT"   then return net.put(path, data) end
    if method == "PATCH" then return net.patch(path, data) end
    return false, "Method unsupported: " .. tostring(method)
end

return net
