-- /lua/gui.lua  (Crafter)
local component = require("component")
local term = require("term")
local unicode = require("unicode")
local gpu = component.gpu

local gui = {}
gui.buttons = {}

gui.COLORS = {
    bg        = 0x111111,
    panel     = 0x222222,
    accent    = 0x00AAFF,
    text      = 0xEEEEEE,
    label     = 0x999999,
    good      = 0x55FF55,
    bad       = 0xFF5555,
    warn      = 0xFFAA00,
    btn       = 0x444444,
    btnActive = 0x006699,
    inputBox  = 0x333333,
}

local function rect(x, y, w, h, col)
    gpu.setBackground(col); gpu.fill(x, y, w, h, " ")
end

local function txt(x, y, s, fg, bg)
    if bg then gpu.setBackground(bg) end
    gpu.setForeground(fg)
    gpu.set(x, y, s)
end

local function center(x, y, w, s, fg, bg)
    if bg then gpu.setBackground(bg) end
    gpu.fill(x, y, w, 1, " ")
    local px = x + math.floor((w - unicode.len(s)) / 2)
    if fg then gpu.setForeground(fg) end
    gpu.set(px, y, s)
end

local function fmtSec(sec)
    if sec < 0 then sec = 0 end
    local m = math.floor(sec / 60)
    local s = math.floor(sec % 60)
    return string.format("%d:%02d", m, s)
end

function gui.btn(id, x, y, w, h, label, bg, fg)
    rect(x, y, w, h, bg)
    center(x, y + math.floor(h / 2), w, label, fg or gui.COLORS.text, bg)
    gui.buttons[id] = { x = x, y = y, w = w, h = h }
end

-- =====================================================================
-- ОСНОВНОЕ ОКНО
-- =====================================================================
function gui.draw(state)
    gui.buttons = {}
    local W, H = gpu.getResolution()

    gpu.setBackground(gui.COLORS.bg); term.clear()

    -- ===== Шапка =====
    rect(1, 1, W, 1, gui.COLORS.panel)
    center(1, 1, W, "АВТОКРАФТ МАГАЗИНА", gui.COLORS.accent, gui.COLORS.panel)

    -- ===== Статусная строка =====
    local meStr = state.meOk and "ME: OK" or "ME: NO LINK"
    local meCol = state.meOk and gui.COLORS.good or gui.COLORS.bad
    local dbStr = state.dbOk and "СПИСОК: OK" or "СПИСОК: ERR"
    local dbCol = state.dbOk and gui.COLORS.good or gui.COLORS.bad
    local pausedStr = state.paused and "[ПАУЗА]" or "[АВТО]"
    local pausedCol = state.paused and gui.COLORS.warn or gui.COLORS.good

    local dcStr, dcCol
    if state.discordOk == nil then
        dcStr, dcCol = "DC: -", gui.COLORS.label
    elseif state.discordOk then
        dcStr, dcCol = "DC: OK", gui.COLORS.good
    else
        dcStr, dcCol = "DC: ERR", gui.COLORS.bad
    end

    rect(1, 2, W, 1, gui.COLORS.bg)
    txt(2,  2, meStr,     meCol,     gui.COLORS.bg)
    txt(12, 2, dbStr,     dbCol,     gui.COLORS.bg)
    txt(22, 2, pausedStr, pausedCol, gui.COLORS.bg)
    txt(31, 2, dcStr,     dcCol,     gui.COLORS.bg)
    txt(41, 2,
        string.format("Активных: %d/%d  Завершено: %-4d  Провалено: %-3d  До тика: %s",
            state.activeCount or #state.jobs, state.maxConcurrent or 2,
            state.totalCompleted or 0, state.totalFailed or 0,
            fmtSec(state.secondsToTick or 0)),
        gui.COLORS.label, gui.COLORS.bg)

    -- ===== Строка с ошибкой Discord (если есть) =====
    if state.discordOk == false and state.lastDiscordError and state.lastDiscordError ~= "" then
        rect(1, H, W, 1, gui.COLORS.bg)
        txt(2, H, "Discord ошибка: " .. unicode.sub(tostring(state.lastDiscordError), 1, W - 20),
            gui.COLORS.bad, gui.COLORS.bg)
    end

    -- ===== Кнопки управления =====
    rect(1, 3, W, 1, gui.COLORS.bg)
    gui.btn("force_tick", 2, 3, 18, 1, "[ТИК СЕЙЧАС]", gui.COLORS.btnActive)
    gui.btn("pause", 21, 3, 14, 1, state.paused and "[ВКЛ. АВТО]" or "[ПАУЗА]",
        state.paused and gui.COLORS.good or gui.COLORS.warn)
    gui.btn("cancel_all", 36, 3, 18, 1, "[ОТМЕНИТЬ ВСЕ]", gui.COLORS.bad)
    gui.btn("limit_dec", 56, 3, 4, 1, "[-]", gui.COLORS.btn)
    txt(61, 3, "Лимит: " .. tostring(state.maxConcurrent or 2), gui.COLORS.text, gui.COLORS.bg)
    gui.btn("limit_inc", 72, 3, 4, 1, "[+]", gui.COLORS.btn)
    gui.btn("quit", W - 11, 3, 10, 1, "[ВЫХОД]", gui.COLORS.bad)

    -- ===== Кнопки перехода в режим добавления/списка товаров =====
    rect(1, 4, W, 1, gui.COLORS.bg)
    gui.btn("add_item_btn", 2, 4, 22, 1, "[+ ДОБАВИТЬ ТОВАР]", gui.COLORS.btnActive)
    gui.btn("items_btn", 25, 4, 14, 1, "[ТОВАРЫ]", gui.COLORS.btn)

    -- ===== Заголовки колонок =====
    rect(1, 5, W, 1, gui.COLORS.panel)
    txt(2,       5, "#",        gui.COLORS.label, gui.COLORS.panel)
    txt(5,       5, "Название", gui.COLORS.label, gui.COLORS.panel)
    txt(W - 44,  5, "Прогресс", gui.COLORS.label, gui.COLORS.panel)
    txt(W - 30,  5, "Возраст",  gui.COLORS.label, gui.COLORS.panel)
    txt(W - 20,  5, "Статус",   gui.COLORS.label, gui.COLORS.panel)
    txt(W - 10,  5, "Действ.",  gui.COLORS.label, gui.COLORS.panel)

    -- ===== Список крафтов =====
    local listTop = 6
    local listBottom = H - 1
    local maxRows = listBottom - listTop + 1

    if #state.jobs == 0 then
        center(1, listTop + math.floor(maxRows / 2),
            W, "Нет активных крафтов", gui.COLORS.label, gui.COLORS.bg)
    else
        for i = 1, math.min(maxRows, #state.jobs) do
            local j = state.jobs[i]
            local y = listTop + (i - 1)

            local statusCol = gui.COLORS.text
            if j.status == "идёт"     then statusCol = gui.COLORS.good
            elseif j.status == "ожидает" then statusCol = gui.COLORS.warn
            elseif j.status == "провален" then statusCol = gui.COLORS.bad
            elseif j.status == "отменён"  then statusCol = gui.COLORS.bad
            elseif j.status == "готов"    then statusCol = gui.COLORS.good end

            local nameW = (W - 44) - 6
            local nm = unicode.sub(j.name or "?", 1, nameW)

            local produced = j.produced or 0
            local amount = j.amount or 0
            local progressStr = produced .. "/" .. amount
            local progCol = gui.COLORS.label
            if amount > 0 then
                local frac = produced / amount
                if frac >= 1 then progCol = gui.COLORS.good
                elseif frac > 0 then progCol = gui.COLORS.warn end
            end

            txt(2,      y, tostring(i),         gui.COLORS.label, gui.COLORS.bg)
            txt(5,      y, nm,                  gui.COLORS.text,  gui.COLORS.bg)
            txt(W - 44, y, progressStr,         progCol,          gui.COLORS.bg)
            txt(W - 30, y, fmtSec(j.age_sec or 0), gui.COLORS.label, gui.COLORS.bg)
            txt(W - 20, y, j.status or "?",     statusCol,        gui.COLORS.bg)
            gui.btn("cancel_" .. i, W - 10, y, 8, 1, "[X]", gui.COLORS.bad)
        end
        if #state.jobs > maxRows then
            txt(2, listBottom, "(...показано " .. maxRows .. " из " .. #state.jobs .. ")",
                gui.COLORS.label, gui.COLORS.bg)
        end
    end
end

-- =====================================================================
-- ЭКРАН "ДОБАВИТЬ ТОВАР"
-- state = {
--   scanned, label, itemId, damage,   -- результат сканирования сундука
--   name, craftAmount, keepAmount,    -- редактируемые поля
--   activeField,                      -- nil | "name"  (какое поле сейчас редактируется)
--   message,                          -- строка статуса/ошибки внизу
-- }
-- =====================================================================
function gui.drawAddItem(state)
    gui.buttons = {}
    local W, H = gpu.getResolution()

    gpu.setBackground(gui.COLORS.bg); term.clear()

    -- ===== Шапка =====
    rect(1, 1, W, 1, gui.COLORS.panel)
    center(1, 1, W, state.editing and "РЕДАКТИРОВАТЬ ТОВАР" or "ДОБАВИТЬ ТОВАР В АВТОКРАФТ",
        gui.COLORS.accent, gui.COLORS.panel)

    gui.btn("back", 2, 3, 14, 1, "[< НАЗАД]", gui.COLORS.bad)
    gui.btn("scan", 18, 3, 26, 1, "[СКАНИРОВАТЬ СУНДУК]", gui.COLORS.btnActive)

    -- ===== Инфо о найденном предмете =====
    rect(1, 5, W, 1, gui.COLORS.bg)
    if state.scanned then
        txt(2, 5, string.format("%s: %s   id=%s   damage=%d",
            state.editing and "Товар" or "Найдено",
            state.label or "?", state.itemId or "?", state.damage or 0),
            gui.COLORS.good, gui.COLORS.bg)
    else
        txt(2, 5, "Положи ОДИН предмет в сундук рядом с Adapter'ом и нажми [СКАНИРОВАТЬ СУНДУК]",
            gui.COLORS.label, gui.COLORS.bg)
    end

    -- ===== Поле "Название" =====
    txt(2, 7, "Название:", gui.COLORS.label, gui.COLORS.bg)
    local nameBoxCol = (state.activeField == "name") and gui.COLORS.accent or gui.COLORS.inputBox
    rect(14, 7, 40, 1, nameBoxCol)
    local nameShown = (state.name or "") .. ((state.activeField == "name") and "_" or "")
    txt(15, 7, unicode.sub(nameShown, 1, 38), gui.COLORS.text, nameBoxCol)
    gui.buttons["field_name"] = { x = 14, y = 7, w = 40, h = 1 }

    -- ===== Поле "Крафтить за раз" со степпером =====
    txt(2, 9, "Крафтить за раз:", gui.COLORS.label, gui.COLORS.bg)
    gui.btn("craft_dec10000", 20, 9, 7, 1, "-10000", gui.COLORS.btn)
    gui.btn("craft_dec1000",  28, 9, 6, 1, "-1000",  gui.COLORS.btn)
    gui.btn("craft_dec100",   35, 9, 5, 1, "-100",   gui.COLORS.btn)
    gui.btn("craft_dec10",    41, 9, 4, 1, "-10",    gui.COLORS.btn)
    gui.btn("craft_dec",      46, 9, 3, 1, "-1",     gui.COLORS.btn)
    rect(50, 9, 9, 1, gui.COLORS.inputBox)
    center(50, 9, 9, tostring(state.craftAmount or 64), gui.COLORS.text, gui.COLORS.inputBox)
    gui.btn("craft_inc",      60, 9, 3, 1, "+1",     gui.COLORS.btn)
    gui.btn("craft_inc10",    64, 9, 4, 1, "+10",    gui.COLORS.btn)
    gui.btn("craft_inc100",   69, 9, 5, 1, "+100",   gui.COLORS.btn)
    gui.btn("craft_inc1000",  75, 9, 6, 1, "+1000",  gui.COLORS.btn)
    gui.btn("craft_inc10000", 82, 9, 7, 1, "+10000", gui.COLORS.btn)

    -- ===== Поле "Порог (держать на складе)" со степпером =====
    txt(2, 11, "Порог (держать):", gui.COLORS.label, gui.COLORS.bg)
    gui.btn("keep_dec10000", 20, 11, 7, 1, "-10000", gui.COLORS.btn)
    gui.btn("keep_dec1000",  28, 11, 6, 1, "-1000",  gui.COLORS.btn)
    gui.btn("keep_dec100",   35, 11, 5, 1, "-100",   gui.COLORS.btn)
    gui.btn("keep_dec10",    41, 11, 4, 1, "-10",    gui.COLORS.btn)
    gui.btn("keep_dec",      46, 11, 3, 1, "-1",     gui.COLORS.btn)
    rect(50, 11, 9, 1, gui.COLORS.inputBox)
    center(50, 11, 9, tostring(state.keepAmount or 64), gui.COLORS.text, gui.COLORS.inputBox)
    gui.btn("keep_inc",      60, 11, 3, 1, "+1",     gui.COLORS.btn)
    gui.btn("keep_inc10",    64, 11, 4, 1, "+10",    gui.COLORS.btn)
    gui.btn("keep_inc100",   69, 11, 5, 1, "+100",   gui.COLORS.btn)
    gui.btn("keep_inc1000",  75, 11, 6, 1, "+1000",  gui.COLORS.btn)
    gui.btn("keep_inc10000", 82, 11, 7, 1, "+10000", gui.COLORS.btn)

    -- ===== Переключатель "Включён" =====
    txt(2, 13, "Статус:", gui.COLORS.label, gui.COLORS.bg)
    local enabled = (state.enabled ~= false)
    gui.btn("toggle_enabled", 20, 13, 16, 1,
        enabled and "[ВКЛЮЧЁН]" or "[ВЫКЛЮЧЕН]",
        enabled and gui.COLORS.good or gui.COLORS.bad)

    -- ===== Кнопка сохранения =====
    gui.btn("save", 2, 15, 20, 1, "[СОХРАНИТЬ]", gui.COLORS.good)

    -- ===== Сообщение/статус =====
    rect(1, 17, W, 1, gui.COLORS.bg)
    if state.message and state.message ~= "" then
        local msgCol = gui.COLORS.label
        local low = state.message:lower()
        if low:find("ошибка") or low:find("не найден") or low:find("пуст") then
            msgCol = gui.COLORS.bad
        elseif low:find("добавлено") or low:find("обновлено") or low:find("найдено") then
            msgCol = gui.COLORS.good
        end
        txt(2, 17, state.message, msgCol, gui.COLORS.bg)
    end

    txt(2, 19, "Подсказка: тапни по полю \"Название\", чтобы переименовать, " ..
        "печатай на клавиатуре, Enter — подтвердить.", gui.COLORS.label, gui.COLORS.bg)
end

-- =====================================================================
-- ЭКРАН "ТОВАРЫ" — список всех товаров с кнопками редактировать/удалить
-- items = массив { id, damage, name, craft_amount, keep_amount, enabled }
-- =====================================================================
function gui.drawItemsList(items)
    gui.buttons = {}
    local W, H = gpu.getResolution()

    gpu.setBackground(gui.COLORS.bg); term.clear()

    rect(1, 1, W, 1, gui.COLORS.panel)
    center(1, 1, W, "ТОВАРЫ В АВТОКРАФТЕ", gui.COLORS.accent, gui.COLORS.panel)

    gui.btn("items_back", 2, 3, 14, 1, "[< НАЗАД]", gui.COLORS.bad)
    gui.btn("items_add", 18, 3, 18, 1, "[+ ДОБАВИТЬ]", gui.COLORS.btnActive)
    txt(38, 3, "Всего товаров: " .. tostring(#items), gui.COLORS.label, gui.COLORS.bg)

    rect(1, 5, W, 1, gui.COLORS.panel)
    txt(2,      5, "#",        gui.COLORS.label, gui.COLORS.panel)
    txt(5,      5, "Название", gui.COLORS.label, gui.COLORS.panel)
    txt(W - 46, 5, "id:damage", gui.COLORS.label, gui.COLORS.panel)
    txt(W - 26, 5, "Крафт/Порог", gui.COLORS.label, gui.COLORS.panel)
    txt(W - 12, 5, "Вкл",      gui.COLORS.label, gui.COLORS.panel)
    txt(W - 8,  5, "Действ.",  gui.COLORS.label, gui.COLORS.panel)

    local listTop = 6
    local listBottom = H - 1
    local maxRows = listBottom - listTop + 1

    if #items == 0 then
        center(1, listTop + math.floor(maxRows / 2),
            W, "Список пуст — нажми [+ ДОБАВИТЬ]", gui.COLORS.label, gui.COLORS.bg)
    else
        for i = 1, math.min(maxRows, #items) do
            local it = items[i]
            local y = listTop + (i - 1)
            local enabled = (it.enabled ~= false)

            local nameW = (W - 46) - 6
            local nm = unicode.sub(tostring(it.name or it.id or "?"), 1, nameW)
            local idDmg = unicode.sub(tostring(it.id or "?") .. ":" .. tostring(math.floor(tonumber(it.damage) or 0)), 1, 18)
            local craftKeep = tostring(it.craft_amount or "?") .. "/" .. tostring(it.keep_amount or "?")

            txt(2,       y, tostring(i), gui.COLORS.label, gui.COLORS.bg)
            txt(5,       y, nm,          gui.COLORS.text,  gui.COLORS.bg)
            txt(W - 46,  y, idDmg,       gui.COLORS.label, gui.COLORS.bg)
            txt(W - 26,  y, craftKeep,   gui.COLORS.text,  gui.COLORS.bg)
            txt(W - 12,  y, enabled and "ВКЛ" or "ВЫКЛ",
                enabled and gui.COLORS.good or gui.COLORS.bad, gui.COLORS.bg)
            gui.btn("edit_" .. i,   W - 8, y, 4, 1, "РЕД", gui.COLORS.btnActive)
            gui.btn("delete_" .. i, W - 4, y, 4, 1, "X", gui.COLORS.bad)
        end
        if #items > maxRows then
            txt(2, listBottom, "(...показано " .. maxRows .. " из " .. #items .. ")",
                gui.COLORS.label, gui.COLORS.bg)
        end
    end
end

function gui.checkClick(x, y)
    for id, b in pairs(gui.buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return id end
    end
    return nil
end

return gui
