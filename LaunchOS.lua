local component = require("component")
local term = require("term")
local io = require("io")
local event = require("event")
local fs = require("filesystem")
local os = require("os")

local langFilePath = "/lib/RocketOS/lang.txt"
local passFilePath = "/lib/RocketOS/pass.txt"

-- Инициализация языка по умолчанию
if not fs.exists(langFilePath) then
  fs.makeDirectory("/lib/RocketOS")
  local f = io.open(langFilePath, "w")
  f:write("en")
  f:close()
end

-- Загрузка текущего языка
local function getLang()
  local f = io.open(langFilePath, "r")
  local lang = f:read("*l")
  f:close()
  return lang
end

local function setLang(lang)
  local f = io.open(langFilePath, "w")
  f:write(lang)
  f:close()
end

local lang = getLang()

-- Таблица перевода
local T = {
  ["main_menu"] = { ru = "=== Главное меню ===", en = "=== Main Menu ===" },
  ["launch_menu"] = { ru = "Меню запусков", en = "Launch Menu" },
  ["pad_connected"] = { ru = "подключена", en = "connected" },
  ["pad_disconnected"] = { ru = "не подключена", en = "not connected" },
  ["pad_ready"] = { ru = "Готов к запуску", en = "Ready to launch" },
  ["pad_not_ready"] = { ru = "Не готова", en = "Not ready" },
  ["rocket_tier"] = { ru = "Тир ракеты", en = "Rocket Tier" },
  ["coords"] = { ru = "Координаты", en = "Target Coordinates" },
  ["not_set"] = { ru = "не установлены", en = "not set" },
  ["enter"] = { ru = "Нажмите Enter для возврата в меню...", en = "Press Enter to return to menu..." },
  ["set_target"] = { ru = "Задать цель", en = "Set Target" },
  ["launch_menu_btn"] = { ru = "Меню запусков", en = "Launch Menu" },
  ["settings"] = { ru = "Настройки", en = "Settings" },
  ["exit"] = { ru = "Выход", en = "Exit" },
  ["invalid_input"] = { ru = "Неверный ввод", en = "Invalid input" },
  ["select_pad"] = { ru = "Выберите площадку для задания цели:", en = "Select pad to assign target:" },
  ["enter_x"] = { ru = "Введите координату X цели: ", en = "Enter target X coordinate: " },
  ["enter_z"] = { ru = "Введите координату Z цели: ", en = "Enter target Z coordinate: " },
  ["target_set"] = { ru = "Цель установлена", en = "Target set" },
  ["launching"] = { ru = "Запуск через 10 секунд... Нажмите Enter для отмены.", en = "Launching in 10 seconds... Press Enter to cancel." },
  ["launch_cancelled"] = { ru = "Запуск отменён", en = "Launch cancelled" },
  ["launch_failed"] = { ru = "Ошибка запуска", en = "Launch failed" },
  ["rocket_launched"] = { ru = "Ракета запущена", en = "Rocket launched" },
  ["all_launch"] = { ru = "Массовый запуск через 10 секунд... Нажмите Enter для отмены.", en = "Mass launch in 10 seconds... Press Enter to cancel." },
  ["select_lang"] = { ru = "Выберите язык: 1 - Русский, 2 - English", en = "Select language: 1 - Russian, 2 - English" },
  ["lang_set"] = { ru = "Язык установлен", en = "Language set" },
}

local function tr(key)
  return T[key] and (T[key][lang] or T[key].en) or key
end

local function authenticate()
  if not component.isAvailable("data") then
    print("Error: No data card found.")
    os.exit()
  end

  local data = component.data

  if not fs.exists(passFilePath) then
    fs.makeDirectory("/lib/RocketOS")
    term.write("Create new password: ")
    local newPass = io.read()
    local hash = data.sha256(newPass)
    local f = io.open(passFilePath, "w")
    f:write(hash)
    f:close()
    print("Password set.")
    os.sleep(1.5)
  else
    term.write("Enter password: ")
    local input = io.read()
    local hash = data.sha256(input)
    local f = io.open(passFilePath, "r")
    local saved = f:read("*l")
    f:close()
    if hash ~= saved then
      print("Wrong password.")
      os.sleep(2)
      os.exit()
    else
      print("Access granted.")
      os.sleep(1)
    end
  end
end

local pads = {}
local coords = {}

for address, name in component.list("ntm_launch_pad") do
  if #pads < 4 then
    table.insert(pads, component.proxy(address))
  end
end

local function wait()
  term.write(tr("enter"))
  io.read()
end

local function setTarget()
  term.clear()

  local selectedPad = 1
  if #pads == 0 then
    print("No launch pads connected.")
    wait()
    return
  elseif #pads > 1 then
    print(tr("select_pad"))
    for i = 1, #pads do
      print(i .. " - Pad " .. i)
    end
    term.write("Number: ")
    local choice = tonumber(io.read())
    if not choice or choice < 1 or choice > #pads then
      print(tr("invalid_input"))
      wait()
      return
    end
    selectedPad = choice
  end

  term.write(tr("enter_x"))
  local x = tonumber(io.read())
  term.write(tr("enter_z"))
  local z = tonumber(io.read())

  if not x or not z then
    print(tr("invalid_input"))
    wait()
    return
  end

  coords[selectedPad] = {x, z}
  print(tr("target_set") .. ": X = " .. x .. ", Z = " .. z)
  wait()
end

local function countdownAndLaunch(padIndex)
  local pad = pads[padIndex]
  if not pad then return end
  if not pad.canLaunch() then
    print("Pad " .. padIndex .. " not ready.")
    return
  end
  local target = coords[padIndex]
  if not target then
    print("No target set for pad " .. padIndex)
    return
  end

  print(tr("launching"))
  for i = 10, 0, -1 do
    io.write("Time left: " .. i .. "s   \r")
    local _, _, _, key = event.pull(1, "key_down")
    if key == 28 then
      print("\n" .. tr("launch_cancelled"))
      return
    end
  end

  print("\n" .. tr("rocket_launched") .. " Pad " .. padIndex)
  local result = pad.launch(target[1], target[2])
  if result == false then
    print(tr("launch_failed"))
  end
end

local function launchControlMenu()
  while true do
    term.clear()
    print("=== " .. tr("launch_menu") .. " ===")
    for i = 1, #pads do
      print(i .. " - Pad " .. i)
    end
    if #pads > 0 then
      print("5 - Launch all pads")
    end
    print("0 - " .. tr("exit"))
    term.write("> ")
    local choice = tonumber(io.read())

    if choice == 0 then break
    elseif choice >= 1 and choice <= #pads then
      countdownAndLaunch(choice)
      wait()
    elseif choice == 5 then
      print(tr("all_launch"))
      for i = 10, 0, -1 do
        io.write("Time left: " .. i .. "s   \r")
        local _, _, _, key = event.pull(1, "key_down")
        if key == 28 then
          print("\n" .. tr("launch_cancelled"))
          wait()
          break
        end
        if i == 0 then
          for index, pad in ipairs(pads) do
            local target = coords[index]
            if pad and pad.canLaunch() and target then
              local result = pad.launch(target[1], target[2])
              if result ~= false then
                print("→ Pad " .. index .. " " .. tr("rocket_launched") .. ": X = " .. target[1] .. ", Z = " .. target[2])
              else
                print("→ Pad " .. index .. " " .. tr("launch_failed"))
              end
            else
              print("→ Pad " .. index .. ": " .. tr("pad_not_ready") .. " / " .. tr("not_set"))
            end
          end
          wait()
        end
      end
    else
      print(tr("invalid_input"))
      wait()
    end
  end
end

local function settingsMenu()
  while true do
    term.clear()
    print("=== " .. tr("settings") .. " ===")
    print("1 - " .. tr("select_lang"))
    print("0 - " .. tr("exit"))
    term.write("> ")
    local choice = io.read()
    if choice == "0" then break
    elseif choice == "1" then
      print(tr("select_lang"))
      local langChoice = io.read()
      if langChoice == "1" then
        setLang("ru")
        lang = "ru"
      elseif langChoice == "2" then
        setLang("en")
        lang = "en"
      else
        print(tr("invalid_input"))
      end
      print(tr("lang_set") .. ": " .. (lang == "ru" and "Русский" or "English"))
      os.sleep(1)
    else
      print(tr("invalid_input"))
      wait()
    end
  end
end

-- Запуск
authenticate()

while true do
  term.clear()
  print(tr("main_menu"))
  for i = 1, 4 do
    print("------------------------")
    print("Pad " .. i)
    local pad = pads[i]
    if pad then
      print("- " .. tr("pad_connected"))
      local tier = "Нет"
      local ok, result = pcall(pad.getTier)
      if ok and type(result) == "number" then tier = tostring(result) end
      print("- " .. tr("pad_ready") .. ": " .. (pad.canLaunch() and "Yes" or "No"))
      print("- " .. tr("rocket_tier") .. ": " .. tier)
      if coords[i] then
        print("- " .. tr("coords") .. ": X = " .. coords[i][1] .. ", Z = " .. coords[i][2])
      else
        print("- " .. tr("coords") .. ": " .. tr("not_set"))
      end
    else
      print("- " .. tr("pad_disconnected"))
    end
  end

  print("------------------------")
  print("1 - " .. tr("set_target"))
  print("2 - " .. tr("launch_menu_btn"))
  print("3 - " .. tr("settings"))
  print("0 - " .. tr("exit"))
  term.write("> ")
  local choice = io.read()
  if choice == "1" then
    setTarget()
  elseif choice == "2" then
    launchControlMenu()
  elseif choice == "3" then
    settingsMenu()
  elseif choice == "0" then
    break
  else
    print(tr("invalid_input"))
    wait()
  end
end
