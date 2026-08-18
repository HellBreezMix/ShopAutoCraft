-- /home/installer.lua  (локальный автокрафт, без PocketBase)
local internet = require("internet")
local fs = require("filesystem")

-- ССЫЛКА НА ПАПКУ С ФАЙЛАМИ В РЕПОЗИТОРИИ НА GITHUB (со слешем на конце)
-- ЗАМЕНИ на свою: https://raw.githubusercontent.com/ТВОЙ_НИК/РЕПОЗИТОРИЙ/main/
local repo = "https://raw.githubusercontent.com/HellBreezMix/ShopAutoCraft/main/"

local files = {
    "config.lua",
    "network.lua",
    "json.lua",
    "gui.lua",
    "crafter.lua",
    "discord.lua",
    "commands.lua",
    "secret.lua",
    "crafter_data.json",
}

print("=== УСТАНОВКА АВТОКРАФТЕРА (локальный режим) ===")
print("Подключение к GitHub...\n")

local function download(url)
    local ok, err_or_content = pcall(function()
        local handle = internet.request(url)
        local parts = {}
        for chunk in handle do parts[#parts + 1] = chunk end
        return table.concat(parts)
    end)
    if ok then return err_or_content end
    return nil, tostring(err_or_content)
end

for _, file in ipairs(files) do
    io.write("Скачивание " .. file .. " ... ")
    local content, err = download(repo .. file)
    if not content then
        print("[ОШИБКА СЕТИ: " .. tostring(err) .. "]")
    elseif content:match("404: Not Found") then
        print("[ОШИБКА: файл не найден на GitHub]")
    else
        -- Защищаем существующие config.lua, secret.lua и crafter_data.json от
        -- перезаписи — там могут лежать локальные настройки, вебхук и твой
        -- реальный список товаров.
        local target = "/home/" .. file
        if (file == "config.lua" or file == "secret.lua" or file == "crafter_data.json")
            and fs.exists(target) then
            print("[SKIP — уже есть на компе]")
        else
            local f = io.open(target, "w")
            if f then
                f:write(content)
                f:close()
                print("[OK]")
            else
                print("[ОШИБКА: не удалось записать файл]")
            end
        end
    end
end

print("\n=== ГОТОВО ===")
print("Если это первая установка — открой /home/secret.lua командой:")
print("  edit /home/secret.lua")
print("и впиши свою настоящую ссылку Discord Webhook.")
print("Затем проверь /home/crafter_data.json — впиши свои товары.")
print("Запуск: crafter")
