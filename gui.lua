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
-- state = {
--   jobs        = массив {key, name, amount, status, age_sec}
--   recentLog   = массив строк (не используется, логи теперь в Discord)
--   secondsToTick = число (до следующего тика)
--   totalCompleted = сколько завершилось успешно
--   totalFailed   = сколько провалилось/отменено
--   meOk          = bool (есть ли связь с me_interface)
--   dbOk          = bool (последний tick подтянул список товаров)
--   paused        = bool (приостановлен ли автокрафт)
-- }
-- =====================================================================
function gui.draw(state)
    gui.buttons = {}
    local W, H = gpu.getResolution()

    gpu.setBackground(gui.COLORS.bg); term.clear()

    -- ===== Шапка =====
    rect(1, 1, W, 1, gui.COLORS.panel)
    local headerStr = "АВТОКРАФТ МАГАЗИНА"
    center(1, 1, W, headerStr, gui.COLORS.accent, gui.COLORS.panel)

    -- ===== Статусная строка =====
    local meStr = state.meOk and "ME: OK" or "ME: NO LINK"
    local meCol = state.meOk and gui.COLORS.good or gui.COLORS.bad
    local dbStr = state.dbOk and "СПИСОК: OK" or "СПИСОК: ERR"
    local dbCol = state.dbOk and gui.COLORS.good or gui.COLORS.bad
    local pausedStr = state.paused and "[ПАУЗА]" or "[АВТО]"
    local pausedCol = state.paused and gui.COLORS.warn or gui.COLORS.good

    rect(1, 2, W, 1, gui.COLORS.bg)
    txt(2,  2, meStr,     meCol,     gui.COLORS.bg)
    txt(12, 2, dbStr,     dbCol,     gui.COLORS.bg)
    txt(22, 2, pausedStr, pausedCol, gui.COLORS.bg)
    txt(32, 2,
        string.format("Активных: %d/%d  Завершено: %-4d  Провалено: %-3d  До тика: %s",
            state.activeCount or #state.jobs, state.maxConcurrent or 2,
            state.totalCompleted or 0, state.totalFailed or 0,
            fmtSec(state.secondsToTick or 0)),
        gui.COLORS.label, gui.COLORS.bg)

    -- ===== Кнопки управления =====
    rect(1, 3, W, 1, gui.COLORS.bg)
    gui.btn("force_tick", 2, 3, 18, 1, "[ТИК СЕЙЧАС]", gui.COLORS.btnActive)
    gui.btn("pause", 21, 3, 14, 1, state.paused and "[ВКЛ. АВТО]" or "[ПАУЗА]",
        state.paused and gui.COLORS.good or gui.COLORS.warn)
    gui.btn("cancel_all", 36, 3, 18, 1, "[ОТМЕНИТЬ ВСЕ]", gui.COLORS.bad)
    -- управление лимитом параллельных крафтов
    gui.btn("limit_dec", 56, 3, 4, 1, "[-]", gui.COLORS.btn)
    txt(61, 3, "Лимит: " .. tostring(state.maxConcurrent or 2), gui.COLORS.text, gui.COLORS.bg)
    gui.btn("limit_inc", 72, 3, 4, 1, "[+]", gui.COLORS.btn)
    gui.btn("quit", W - 11, 3, 10, 1, "[ВЫХОД]", gui.COLORS.bad)

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

function gui.checkClick(x, y)
    for id, b in pairs(gui.buttons) do
        if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return id end
    end
    return nil
end

return gui
