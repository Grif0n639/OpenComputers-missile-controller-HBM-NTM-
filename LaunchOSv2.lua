-------------------------------------------------
-- === Базовые модули ===
-------------------------------------------------
local component = require("component")
local term      = require("term")
local io        = require("io")
local event     = require("event")
local fs        = require("filesystem")
local os        = require("os")
local shell     = require("shell")
local computer  = require("computer")

-------------------------------------------------
-- === Пути и константы ===
-------------------------------------------------
local langFilePath     = "/lib/RocketOS/lang.txt"
local AUTH_STATE_PATH  = "/lib/RocketOS/auth.cfg"
local KEY_DISK_LABEL   = "ROCKETOS-KEY"
local KEY_FILE_REL     = "/RocketOS/pass.key"

-- Рабочая директория и файлы рядом со скриптом
local workDir     = shell and shell.getWorkingDirectory() or "/home"
local dataDir     = workDir .. "/RocketOS_Data"
local managerFile = dataDir .. "/managerStarts.txt"
local settingsFile = dataDir .. "/settings.txt"   -- файл настроек рядом с менеджером

-- Версия приложения (показывается в правом нижнем углу главного меню)
local VERSION = "v2.0.1"

-------------------------------------------------
-- === Сеть RocketOSNet (клиент) ===
-------------------------------------------------
local NET_PORT        = 42666
local NET_PROTO       = "RocketOSNet|v1"
local NET_DISCOVER    = "DISCOVER"
local NET_SERVER      = "SERVER"
local NET_HELLO       = "HELLO"
local NET_OK          = "OK"
local NET_INFO        = "INFO"    -- инфопакет от сервера
local NET_BYE         = "BYE"     -- добровольное отключение клиента

-- Радар-сервис
local NET_RADAR_POLL  = "RADAR_POLL"
local NET_RADAR_STATE = "RADAR_STATE"
local NET_RADAR_SUB   = "RADAR_SUB"
local NET_RADAR_UNSUB = "RADAR_UNSUB"

-- Автоперехват (сервер управляет)
local NET_AI_TOGGLE   = "AI_TOGGLE"   -- клиент -> сервер: переключить AI
local NET_AI_STATE    = "AI_STATE"    -- сервер -> клиент: 0/1 текущее состояние
local NET_AI_FIRE     = "AI_FIRE"     -- сервер -> клиент: запустить N перехватчиков

-- Текущая привязка к серверу
local SERVER_ADDR      = nil     -- адрес модема сервера (string)
local SERVER_CONNECTED = false   -- успешный handshake?
local SERVER_LAST_INFO = nil     -- последняя INFO от сервера (таблица)


-------------------------------------------------
-- === Цвета ===
-------------------------------------------------
local colors = {
  gray       = 0xAAAAAA,
  red        = 0xFF0000,
  orange     = 0xFFA500,
  lightgreen = 0xADFF2F,
  green      = 0x00FF00,
  white      = 0xFFFFFF,
  toxic      = 0xCCFF00,  -- ядовито-жёлтый (ядерный алерт)
}

-------------------------------------------------
-- === Отрисовка бейджа версии (правый нижний угол) ===
-------------------------------------------------
local function drawVersionBadge()
  if not component.isAvailable("gpu") then return end
  local gpu = component.gpu
  local w, h = gpu.getResolution()

  local s = VERSION
  local cx, cy = term.getCursor()   -- запомним позицию курсора
  local prev   = gpu.getForeground()

  gpu.setForeground(colors.gray)    -- нейтральный цвет
  term.setCursor(math.max(1, w - #s + 1), h)
  io.write(s)

  gpu.setForeground(prev)
  term.setCursor(cx, cy)            -- вернули курсор обратно к приглашению
end

-------------------------------------------------
-- === Инициализация директорий/файлов ===
-------------------------------------------------
if not fs.exists(dataDir) then fs.makeDirectory(dataDir) end
if not fs.exists(managerFile) then local f=io.open(managerFile,"w"); if f then f:close() end end

-- язык по умолчанию (создаём файл, если нет)
if not fs.exists(langFilePath) then
  fs.makeDirectory("/lib/RocketOS")
  local f = io.open(langFilePath, "w"); if f then f:write("ru"); f:close() end
end

-------------------------------------------------
-- === Сохранение/загрузка настроек (режим ПРО) ===
-------------------------------------------------
-- Глобальные флаги
local PRO_MODE = false
local AUTO_INTERCEPT = false

local function saveSettings()
  local f = io.open(settingsFile, "w")
  if f then
    f:write("PRO_MODE=",         PRO_MODE         and "1" or "0", "\n")
    f:write("AUTO_INTERCEPT=",   AUTO_INTERCEPT   and "1" or "0", "\n")
    f:write("SERVER_CONNECTED=", SERVER_CONNECTED and "1" or "0", "\n")
    f:write("SERVER_ADDR=",      SERVER_ADDR or "", "\n")
    f:close()
  end
end

local function loadSettings()
  PRO_MODE         = false
  AUTO_INTERCEPT   = false
  SERVER_CONNECTED = false
  SERVER_ADDR      = nil

  local f = io.open(settingsFile, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k then
        if     k == "PRO_MODE"         then PRO_MODE         = (v=="1" or v=="true" or v=="on" or v=="yes")
        elseif k == "AUTO_INTERCEPT"   then AUTO_INTERCEPT   = (v=="1" or v=="true" or v=="on" or v=="yes")
        elseif k == "SERVER_CONNECTED" then SERVER_CONNECTED = (v=="1" or v=="true" or v=="on" or v=="yes")
        elseif k == "SERVER_ADDR"      then SERVER_ADDR      = (v ~= "" and v or nil)
        end
      end
    end
    f:close()
  end
end

-- Подхватываем настройки сразу после объявления функций
loadSettings()


-------------------------------------------------
-- === Управление языком ===
-------------------------------------------------
local function getLang()
  local f = io.open(langFilePath, "r"); local lang = f and f:read("*l") or "ru"; if f then f:close() end; return lang
end
local function setLang(lang)
  local f = io.open(langFilePath, "w"); if f then f:write(lang); f:close() end
end
local lang = getLang()

-------------------------------------------------
-- === Таблица перевода ===
-------------------------------------------------
local T = {
  -- Базовые
  main_menu        = {ru="=== Главное меню ===",         en="=== Main Menu ==="},
  launch_menu      = {ru="Меню запусков",                en="Launch Menu"},
  pad_connected    = {ru="подключена",                   en="connected"},
  pad_disconnected = {ru="не подключена",                en="not connected"},
  pad_ready        = {ru="Готова",                        en="Ready"},
  pad_not_ready    = {ru="Не готова",                    en="Not ready"},
  rocket_tier      = {ru="Тир ракеты",                   en="Rocket Tier"},
  coords           = {ru="Координаты",                   en="Coordinates"},
  not_set          = {ru="не установлены",               en="not set"},
  fuel             = {ru="Топливо",                      en="Fuel"},
  energy           = {ru="Энергия",                      en="Energy"},
  no_data          = {ru="нет данных",                   en="no data"},
  enter            = {ru="Нажмите Enter для возврата...",en="Press Enter to return..."},
  set_target       = {ru="Задать цель",                  en="Set Target"},
  launch_menu_btn  = {ru="Меню запусков",                en="Launch Menu"},
  settings         = {ru="Настройки",                    en="Settings"},
  exit             = {ru="Выход",                        en="Exit"},
  invalid_input    = {ru="Неверный ввод",                en="Invalid input"},
  select_pad       = {ru="Выберите площадку:",           en="Select pad:"},
  enter_x          = {ru="Введите X: ",                  en="Enter X: "},
  enter_z          = {ru="Введите Z: ",                  en="Enter Z: "},
  target_set       = {ru="Цель установлена",             en="Target set"},
  launching        = {ru="Запуск через 10 секунд... Enter = отмена", en="Launching in 10 sec... Enter = cancel"},
  launch_cancelled = {ru="Запуск отменён",               en="Launch cancelled"},
  launch_failed    = {ru="Ошибка запуска",               en="Launch failed"},
  rocket_launched  = {ru="Ракета запущена",              en="Rocket launched"},
  all_launch       = {ru="Массовый запуск через 10 секунд... Enter = отмена", en="Mass launch in 10 sec... Enter = cancel"},
  select_lang      = {ru="1 - Русский, 2 - English",     en="1 - Russian, 2 - English"},
  lang_set         = {ru="Язык установлен",              en="Language set"},
  open_manager     = {ru="Открыть менеджер запусков",    en="Open Launch Manager"},

  -- Менеджер записей
  manager_menu     = {ru="=== Менеджер запусков ===",    en="=== Launch Manager ==="},
  manager_create   = {ru="Создать запись",               en="Create entry"},
  manager_edit     = {ru="Изменить запись",              en="Edit entry"},
  manager_apply    = {ru="Применить запись",             en="Apply entry"},
  manager_delete   = {ru="Удалить запись",               en="Delete entry"},
  manager_back     = {ru="Вернуться",                    en="Back"},
  enter_name       = {ru="Введите название: ",           en="Enter name: "},
  record_saved     = {ru="Запись сохранена",             en="Record saved"},
  record_updated   = {ru="Запись обновлена",             en="Record updated"},
  record_deleted   = {ru="Запись удалена",               en="Record deleted"},
  no_records       = {ru="Нет записей",                  en="No records"},

  -- Аутентификация
  auth_insert_first  = {ru="Вставьте дискету (пустую или с ключом).",
                        en="Insert a floppy (empty or with key)."},
  auth_insert_bound  = {ru="Вставьте ПРИВЯЗАННУЮ дискету-ключ. Без неё запуск невозможен.",
                        en="Insert the BOUND key floppy. You cannot continue without it."},
  auth_waiting       = {ru="Ожидание ключа…",            en="Waiting for key…"},
  auth_wrong_disk    = {ru="Неверная дискета: адрес не совпадает с привязанным.",
                        en="Wrong floppy: address does not match the bound one."},
  auth_key_missing   = {ru="На дискете нет ключа, создаём новый.",
                        en="No key file found on floppy, creating a new one."},
  auth_key_created   = {ru="Файл ключа создан успешно.", en="Key file created successfully."},
  auth_key_corrupt   = {ru="Файл ключа повреждён или подменён.",
                        en="Key file is corrupted or tampered."},
  auth_password_prompt = {ru="Введите пароль: ",         en="Enter password: "},
  auth_new_password    = {ru="Создайте новый пароль: ",  en="Create new password: "},
  auth_denied          = {ru="Неверный пароль.",         en="Wrong password."},
  auth_granted         = {ru="Доступ разрешён.",         en="Access granted."},
  auth_bound_saved     = {ru="Ключ успешно привязан к этой системе.",
                          en="Key successfully bound to this system."},
  empty_floppy_init    = {ru="Найдена пустая дискета → назначаю метку ROCKETOS-KEY",
                          en="Empty floppy found → labeling as ROCKETOS-KEY"},
}
local function tr(k) return (T[k] and (T[k][lang] or T[k].en)) or k end

-------------------------------------------------
-- === Сеть: клиент ===
-------------------------------------------------
local function haveModem()
  return component.isAvailable("modem")
end

local function netOpen()
  if not haveModem() then return nil, "no_modem" end
  local m = component.modem
  if not m.isOpen(NET_PORT) then pcall(m.open, NET_PORT) end
  return m
end

-- Поиск серверов: возвращает массив { {addr="...", info=...}, ... }
local function discoverServers(timeout)
  timeout = timeout or 4
  local m = netOpen()
  if not m then return {}, "no_modem" end

  pcall(m.broadcast, NET_PORT, NET_PROTO, NET_DISCOVER)

  local found = {}
  local t0 = computer.uptime()
  while computer.uptime() - t0 < timeout do
    local left = timeout - (computer.uptime() - t0)
    local _, _, from, port, _, proto, kind, info =
      event.pull(left, "modem_message")
    if port == NET_PORT and proto == NET_PROTO and kind == NET_SERVER then
      table.insert(found, {addr = from, info = info})
    end
  end
  return found
end

-- Попытка рукопожатия с сервером по адресу (+ приём NET_INFO)
local function tryConnectServer(addr, timeout)
  timeout = timeout or 3
  local m = netOpen()
  if not m then return false, "Модем не найден" end

  pcall(m.send, addr, NET_PORT, NET_PROTO, NET_HELLO)

  SERVER_LAST_INFO = nil
  local t0 = computer.uptime()
  local gotOK = false

  while computer.uptime() - t0 < timeout do
    local left = timeout - (computer.uptime() - t0)
    local ev = {event.pull(left, "modem_message")}
    if ev[1] then
      local _, _, from, port, _, proto, kind, a,b,c,d,e,f = table.unpack(ev)
      if from == addr and port == NET_PORT and proto == NET_PROTO then
        if kind == NET_OK then
          SERVER_ADDR = addr
          SERVER_CONNECTED = true
          saveSettings()
          gotOK = true
          -- не выходим сразу: дадим шанс прилететь INFO
        elseif kind == NET_INFO then
          SERVER_LAST_INFO = {
            id      = tonumber(a),
            info    = tostring(b or ""),
            radar   = (c == true or c == 1 or c == "1"),
            subs    = tonumber(d) or 0,
            clients = tonumber(e) or 0,
            new     = (f == true or f == 1 or f == "1")
          }
        end
      end
    else
      break
    end
  end

  -- Короткое «окно» для догрузки INFO после OK
  if gotOK and not SERVER_LAST_INFO then
    local t_end = computer.uptime() + 0.5
    while computer.uptime() < t_end do
      local ev = {event.pull(t_end - computer.uptime(), "modem_message")}
      if not ev[1] then break end
      local _, _, from, port, _, proto, kind, a,b,c,d,e,f = table.unpack(ev)
      if from == addr and port == NET_PORT and proto == NET_PROTO and kind == NET_INFO then
        SERVER_LAST_INFO = {
          id      = tonumber(a),
          info    = tostring(b or ""),
          radar   = (c == true or c == 1 or c == "1"),
          subs    = tonumber(d) or 0,
          clients = tonumber(e) or 0,
          new     = (f == true or f == 1 or f == "1")
        }
        break
      end
    end
  end

  if gotOK then return true, nil, SERVER_LAST_INFO end
  return false, "Нет ответа от сервера"
end

local function radarSubscribe()
  local m = netOpen(); if not m then return end
  pcall(m.send, SERVER_ADDR, NET_PORT, NET_PROTO, NET_RADAR_SUB)
end

local function radarUnsubscribe()
  local m = netOpen(); if not m then return end
  pcall(m.send, SERVER_ADDR, NET_PORT, NET_PROTO, NET_RADAR_UNSUB)
end

-- НОВОЕ: добровольное отключение клиента
local function disconnectServer()
  if not SERVER_ADDR then
    SERVER_CONNECTED = false
    saveSettings()
    return false, "Адрес сервера не задан"
  end
  local m = netOpen()
  if m then pcall(m.send, SERVER_ADDR, NET_PORT, NET_PROTO, NET_BYE, "client_disconnect") end
  SERVER_CONNECTED = false
  saveSettings()
  return true
end

-- НОВОЕ: переподключение к сохранённому адресу
local function reconnectServer(timeout)
  if not SERVER_ADDR then return false, "Нет сохранённого адреса" end
  return tryConnectServer(SERVER_ADDR, timeout or 3)
end

-------------------------------------------------
-- === Хелперы пуска (учёт режима ПРО) ===
-------------------------------------------------
local function tryLaunchNoArgs(pad)
  local ok, r1 = pcall(function() return pad.launch() end)
  return ok and r1 ~= false
end

local function tryLaunchWithCoords(pad, x, z)
  local ok, r1 = pcall(function() return pad.launch(x, z) end)
  return ok and r1 ~= false
end

-- Универсальный пуск
local function launchPadUniversal(pad, target)
  if PRO_MODE then
    if tryLaunchNoArgs(pad)           then return true end
    if tryLaunchWithCoords(pad, 0, 0) then return true end
    if target then
      if tryLaunchWithCoords(pad, target[1], target[2]) then return true end
    end
    return false
  else
    if not target then return false end
    return tryLaunchWithCoords(pad, target[1], target[2])
  end
end

-------------------------------------------------
-- === Блок аутентификации (Floppy Key) ===
-------------------------------------------------
local function getMountPathByAddress(addr)
  for proxy, path in fs.mounts() do
    if proxy and proxy.address == addr then return path end
  end
  return nil
end

local function safeGetLabel(fsProxy)
  local ok, lbl = pcall(function() return fsProxy.getLabel() end)
  return ok and lbl or nil
end

-- Поиск дискеты-ключа; autoInit = true → пустую дискету помечаем ROCKETOS-KEY
local function findKeyDisk(autoInit)
  for addr in component.list("filesystem") do
    local proxy = component.proxy(addr)
    local label = safeGetLabel(proxy) or ""
    local mountPath = getMountPathByAddress(addr)
    if mountPath then
      if label == KEY_DISK_LABEL then
        return proxy, mountPath
      end
      if autoInit then
        local empty = true
        for _ in fs.list(mountPath) do empty = false; break end
        if empty then
          pcall(function() proxy.setLabel(KEY_DISK_LABEL) end)
          print(tr("empty_floppy_init"))
          return proxy, mountPath
        end
      end
    end
  end
  return nil, nil
end

local function composeToken(dataCard, passHash, fsAddress)
  return dataCard.sha256("RocketOS|v1|" .. tostring(passHash) .. "|" .. tostring(fsAddress))
end

local function readKeyFile(mountPath)
  local f = io.open(mountPath .. KEY_FILE_REL, "r")
  if not f then return nil, nil, "missing" end
  local passHash = (f:read("*l") or ""):gsub("%s+$","")
  local token    = (f:read("*l") or ""):gsub("%s+$","")
  f:close()
  if passHash == "" or token == "" then return nil, nil, "corrupt" end
  return passHash, token, nil
end

local function readBoundAddrHash()
  if not fs.exists(AUTH_STATE_PATH) then return nil end
  local f = io.open(AUTH_STATE_PATH, "r"); if not f then return nil end
  local s = (f:read("*l") or ""):gsub("%s+$",""); f:close()
  return s ~= "" and s or nil
end

local function writeBoundAddrHash(hash)
  fs.makeDirectory("/lib/RocketOS")
  local f = io.open(AUTH_STATE_PATH, "w"); assert(f, "cannot write auth state")
  f:write(hash, "\n"); f:close()
end

local function authenticate()
  if not component.isAvailable("data") then
    print("Error: No data card found."); os.exit()
  end
  local data = component.data
  local boundAddrHash = readBoundAddrHash()

  while true do
    local fsProxy, mountPath = findKeyDisk(true)  -- автоинициализация пустых
    if not fsProxy then
      print(boundAddrHash and tr("auth_insert_bound") or tr("auth_insert_first"))
      print(tr("auth_waiting")); os.sleep(1.0)
    else
      local thisAddrHash = data.sha256(fsProxy.address)
      if boundAddrHash and thisAddrHash ~= boundAddrHash then
        print(tr("auth_wrong_disk")); os.sleep(1.0)
      else
        local passHash, tokenOnDisk, err = readKeyFile(mountPath)
        if err == "missing" then
          print(tr("auth_key_missing"))
          term.write(tr("auth_new_password"))
          local newPass = io.read()
          local newPassHash = data.sha256(newPass)
          local newToken = composeToken(data, newPassHash, fsProxy.address)
          fs.makeDirectory(mountPath .. "/RocketOS")
          local f = io.open(mountPath .. KEY_FILE_REL, "w")
          f:write(newPassHash, "\n", newToken, "\n"); f:close()
          print(tr("auth_key_created")); os.sleep(0.6)
        elseif err == "corrupt" then
          print(tr("auth_key_corrupt")); os.sleep(1.0)
        else
          local expectedToken = composeToken(data, passHash, fsProxy.address)
          if tokenOnDisk ~= expectedToken then
            print(tr("auth_key_corrupt")); os.sleep(1.0)
          else
            if not boundAddrHash then
              writeBoundAddrHash(thisAddrHash)
              print(tr("auth_bound_saved")); os.sleep(0.6)
            end
            term.write(tr("auth_password_prompt"))
            local input = io.read()
            if data.sha256(input) ~= passHash then
              print(tr("auth_denied")); os.sleep(2); os.exit()
            else
              print(tr("auth_granted")); os.sleep(0.5); return true
            end
          end
        end
      end
    end
  end
end

-------------------------------------------------
-- === Основная логика управления площадками ===
-------------------------------------------------
local pads, coords = {}, {}
for address in component.list("ntm_launch_pad") do
  if #pads < 4 then table.insert(pads, component.proxy(address)) end
end

local function wait() term.write(tr("enter")); io.read() end

-- Безопасные чтения топлива/энергии (согласно API HBM NTM)
local function readFuelInfo(pad)
  local ok, a1, m1, n1, a2, m2, n2 = pcall(pad.getFluid)
  if not ok then return nil end
  return {
    t1 = {amount=a1, max=m1, name=n1},
    t2 = {amount=a2, max=m2, name=n2}
  }
end

local function readEnergyInfo(pad)
  local ok, stored, max = pcall(pad.getEnergyInfo)
  if not ok then return nil end
  return {stored=stored, max=max}
end

-------------------------------------------------
-- === Отрисовка информации о Pad (цветной UI) ===
-------------------------------------------------
local function drawPad(index, pad)
  local gpu = component.gpu
  gpu.setForeground(colors.white)
  print("Pad " .. index)
  print("------------------------")

  if not pad then
    gpu.setForeground(colors.gray)
    print("- " .. tr("pad_disconnected"))
    gpu.setForeground(colors.white)
    return
  end

  local tier = "?"
  local okTier, resultTier = pcall(pad.getTier)
  if okTier and type(resultTier) == "number" then tier = tostring(resultTier) end

  local canLaunch = false
  local okCL, resCL = pcall(pad.canLaunch)
  if okCL then canLaunch = resCL end

  local hasCoords = coords[index] ~= nil
  if PRO_MODE then hasCoords = true end

  if tier == "?" then
    gpu.setForeground(colors.red)
  elseif not canLaunch then
    gpu.setForeground(colors.orange)
  elseif canLaunch and not hasCoords then
    gpu.setForeground(colors.lightgreen)
  else
    gpu.setForeground(colors.green)
  end
  print("- " .. (canLaunch and tr("pad_ready") or tr("pad_not_ready")))
  gpu.setForeground(colors.white)

  print("- " .. tr("rocket_tier") .. ": " .. tier)

  local fi = readFuelInfo(pad)
  if fi then
    local line = "- " .. tr("fuel") .. ": "
    local p1 = (fi.t1.name or "?") .. " " .. tostring(fi.t1.amount or 0) .. "/" .. tostring(fi.t1.max or 0)
    if fi.t2.name and fi.t2.name ~= "" then
      local p2 = (fi.t2.name or "?") .. " " .. tostring(fi.t2.amount or 0) .. "/" .. tostring(fi.t2.max or 0)
      line = line .. p1 .. " | " .. p2
    else
      line = line .. p1
    end
    print(line)
  else
    print("- " .. tr("fuel") .. ": " .. tr("no_data"))
  end

  local ei = readEnergyInfo(pad)
  if ei then
    print("- " .. tr("energy") .. ": " .. tostring(ei.stored or 0) .. "/" .. tostring(ei.max or 0))
  else
    print("- " .. tr("energy") .. ": " .. tr("no_data"))
  end

  if coords[index] then
    print("- " .. tr("coords") .. ": X = " .. coords[index][1] .. ", Z = " .. coords[index][2])
  else
    print("- " .. tr("coords") .. ": " .. (PRO_MODE and "— (ПРО режим)" or tr("not_set")))
  end
  print("")
end

-------------------------------------------------
-- === Работа с файлами записей (менеджер) ===
-------------------------------------------------
local function loadRecords()
  local records = {}
  local f = io.open(managerFile, "r")
  if f then
    for line in f:lines() do
      local id, x, z, name = line:match("^(%d+);(-?%d+);(-?%d+);(.+)$")
      if id and x and z and name then
        table.insert(records, {id=tonumber(id), x=tonumber(x), z=tonumber(z), name=name})
      end
    end
    f:close()
  end
  table.sort(records, function(a,b) return a.id<b.id end)
  return records
end

local function saveRecords(records)
  local f = io.open(managerFile, "w")
  for _, r in ipairs(records) do
    f:write(r.id .. ";" .. r.x .. ";" .. r.z .. ";" .. r.name .. "\n")
  end
  f:close()
end

local function renumber(records)
  table.sort(records, function(a,b) return a.id<b.id end)
  for i,r in ipairs(records) do r.id = i end
end

-------------------------------------------------
-- === Подменю: Менеджер запусков ===
-------------------------------------------------
local function managerMenu()
  local function listRecords()
    local recs = loadRecords()
    if #recs==0 then print(tr("no_records")) else
      for _, r in ipairs(recs) do
        print(string.format("%2d - %s (X=%d, Z=%d)", r.id, r.name, r.x, r.z))
      end
    end
  end

  while true do
    term.clear()
    print(tr("manager_menu"))
    listRecords()
    print("------------------------")
    print("1 - " .. tr("manager_create"))
    print("2 - " .. tr("manager_edit"))
    print("3 - " .. tr("manager_apply"))
    print("4 - " .. tr("manager_delete"))
    print("5 - " .. tr("manager_back"))
    term.write("> ")
    local choice = io.read()

    if choice == "1" then
      local recs = loadRecords()
      if #recs >= 50 then print("Max 50"); wait()
      else
        term.write(tr("enter_x")); local x = tonumber(io.read())
        term.write(tr("enter_z")); local z = tonumber(io.read())
        term.write(tr("enter_name")); local name = io.read()
        table.insert(recs, {id=#recs+1, x=x or 0, z=z or 0, name=name ~= "" and name or ("Record "..(#recs+1))})
        saveRecords(recs)
        print(tr("record_saved")); wait()
      end

    elseif choice == "2" then
      local recs = loadRecords()
      term.write("ID: "); local id = tonumber(io.read())
      local rec
      for _,r in ipairs(recs) do if r.id==id then rec=r; break end end
      if not rec then print(tr("invalid_input")); wait()
      else
        term.write(tr("enter_x").."("..rec.x.."): "); local xs = io.read(); local nx = tonumber(xs) or rec.x
        term.write(tr("enter_z").."("..rec.z.."): "); local zs = io.read(); local nz = tonumber(zs) or rec.z
        term.write(tr("enter_name").."("..rec.name.."): "); local nm = io.read(); if nm=="" then nm=rec.name end
        rec.x,rec.z,rec.name = nx,nz,nm
        saveRecords(recs); print(tr("record_updated")); wait()
      end

    elseif choice == "3" then
      local recs = loadRecords()
      term.write("ID: "); local id = tonumber(io.read())
      local rec
      for _,r in ipairs(recs) do if r.id==id then rec=r; break end end
      if not rec then print(tr("invalid_input")); wait()
      else
        print(tr("select_pad"))
        for i=1,#pads do print(i.." - Pad "..i) end
        if #pads>1 then print("5 - All Pads") end
        term.write("> "); local sel = tonumber(io.read())
        if sel and sel>=1 and sel<=#pads then
          coords[sel] = {rec.x, rec.z}; print("Applied to Pad "..sel)
        elseif sel == 5 and #pads>1 then
          for i=1,#pads do coords[i]={rec.x,rec.z} end; print("Applied to ALL")
        else print(tr("invalid_input")) end
        wait()
      end

    elseif choice == "4" then
      local recs = loadRecords()
      term.write("ID: "); local id = tonumber(io.read())
      local idx = nil
      for i,r in ipairs(recs) do if r.id==id then idx=i; break end end
      if not idx then print(tr("invalid_input")); wait()
      else
        table.remove(recs, idx); renumber(recs); saveRecords(recs)
        print(tr("record_deleted")); wait()
      end

    elseif choice == "5" then
      break
    else
      print(tr("invalid_input")); wait()
    end
  end
end

-------------------------------------------------
-- === Установка цели ===
-------------------------------------------------
local function setTarget()
  term.clear()
  local selectedPad = 1
  if #pads == 0 then
    print("No launch pads connected."); wait(); return
  elseif #pads > 1 then
    print(tr("select_pad"))
    for i=1,#pads do print(i.." - Pad "..i) end
    print("6 - " .. tr("open_manager"))
    term.write("Number: ")
    local sel = io.read()
    if sel == "6" then managerMenu(); return end
    local choice = tonumber(sel)
    if not choice or choice < 1 or choice > #pads then
      print(tr("invalid_input")); wait(); return
    end
    selectedPad = choice
  end

  term.write(tr("enter_x")); local x = tonumber(io.read())
  term.write(tr("enter_z")); local z = tonumber(io.read())
  if not x or not z then print(tr("invalid_input")); wait(); return end

  coords[selectedPad] = {x, z}
  print(tr("target_set") .. ": X = " .. x .. ", Z = " .. z); wait()
end

-------------------------------------------------
-- === Запуск ракеты (обратный отсчёт отключается в ПРО) ===
-------------------------------------------------
local function countdownAndLaunch(padIndex)
  local pad = pads[padIndex]; if not pad then return end

  local okCL, canL = pcall(pad.canLaunch)
  if not okCL or not canL then
    print("Pad " .. padIndex .. " " .. tr("pad_not_ready"))
    return
  end

  local target = coords[padIndex]
  if (not PRO_MODE) and (not target) then
    print("No target set for pad " .. padIndex)
    return
  end

  if not PRO_MODE then
    print(tr("launching"))
    for i = 10, 0, -1 do
      io.write("Time left: " .. i .. "s   \r")
      local _, _, _, key = event.pull(1, "key_down")
      if key == 28 then
        print("\n" .. tr("launch_cancelled"))
        return
      end
    end
  end

  local okLaunch = launchPadUniversal(pad, target)
  if okLaunch then
    print((PRO_MODE and "" or "\n") .. tr("rocket_launched") .. " Pad " .. padIndex)
  else
    print((PRO_MODE and "" or "\n") .. tr("launch_failed"))
  end
end

-------------------------------------------------
-- === Меню управления запусками (без отсчёта в ПРО) ===
-------------------------------------------------
local function launchControlMenu()
  while true do
    term.clear()
    print("=== " .. tr("launch_menu") .. " ===")
    for i = 1, #pads do drawPad(i, pads[i]) end
    if #pads > 0 then print("5 - Launch all pads") end
    print("0 - " .. tr("exit"))
    term.write("> ")
    local choice = tonumber(io.read())

    if choice == 0 then
      break

    elseif choice and choice >= 1 and choice <= #pads then
      countdownAndLaunch(choice); wait()

    elseif choice == 5 and #pads > 0 then
      if not PRO_MODE then
        print(tr("all_launch"))
        for i = 10, 0, -1 do
          io.write("Time left: " .. i .. "s   \r")
          local _, _, _, key = event.pull(1, "key_down")
          if key == 28 then
            print("\n" .. tr("launch_cancelled")); wait(); break
          end
          if i == 0 then
            for idx, pad in ipairs(pads) do
              local okCL, canL = pcall(pad.canLaunch)
              if pad and okCL and canL then
                local target = coords[idx]
                local okL = launchPadUniversal(pad, target)
                if okL then
                  if target then
                    print("→ Pad " .. idx .. " " .. tr("rocket_launched") ..
                          " X=" .. (target[1] or 0) .. " Z=" .. (target[2] or 0))
                  else
                    print("→ Pad " .. idx .. " " .. tr("rocket_launched"))
                  end
                else
                  print("→ Pad " .. idx .. " " .. tr("launch_failed"))
                end
              else
                print("→ Pad " .. idx .. ": " .. tr("pad_not_ready"))
              end
            end
            wait()
          end
        end
      else
        for idx, pad in ipairs(pads) do
          local okCL, canL = pcall(pad.canLaunch)
          if pad and okCL and canL then
            local target = coords[idx] -- не обязателен в ПРО
            local okL = launchPadUniversal(pad, target)
            if okL then
              if target then
                print("→ Pad " .. idx .. " " .. tr("rocket_launched") ..
                      " X=" .. (target[1] or 0) .. " Z=" .. (target[2] or 0))
              else
                print("→ Pad " .. idx .. " " .. tr("rocket_launched"))
              end
            else
              print("→ Pad " .. idx .. " " .. tr("launch_failed"))
            end
          else
            print("→ Pad " .. idx .. ": " .. tr("pad_not_ready"))
          end
        end
        wait()
      end

    else
      print(tr("invalid_input")); wait()
    end
  end
end

-------------------------------------------------
-- === Подменю: Связь с сервером ===
-------------------------------------------------
local function serverSettingsMenu()
  while true do
    term.clear()
    print("=== Связь с сервером ===")
    print("- Состояние: " .. (SERVER_CONNECTED and ("подключен к " .. (SERVER_ADDR or "?")) or "не подключён"))
    if SERVER_LAST_INFO then
      print(string.format("- ID: %s, Радар: %s, Подписчиков радара: %d, Клиентов: %d",
        tostring(SERVER_LAST_INFO.id or "?"),
        SERVER_LAST_INFO.radar and "есть" or "нет",
        SERVER_LAST_INFO.subs or 0,
        SERVER_LAST_INFO.clients or 0))
      if SERVER_LAST_INFO.info and SERVER_LAST_INFO.info ~= "" then
        print("- Инфо сервера: " .. SERVER_LAST_INFO.info)
      end
    end
    print("- Порт: " .. tostring(NET_PORT))
    print("")
    print("1 - Найти сервер автоматически")
    print("2 - Ввести адрес вручную")
    print("3 - Отключиться от сервера" .. (SERVER_CONNECTED and "" or " (недоступно)"))
    print("4 - Переподключиться к последнему адресу" .. (SERVER_ADDR and "" or " (адрес не сохранён)"))
    print("0 - Назад")
    term.write("> ")
    local choice = io.read()

    if choice == "0" then
      break

    elseif choice == "1" then
      if not haveModem() then
        print("Модем не найден. Подключите модем к компьютеру."); os.sleep(1.4)
      else
        print("Идёт поиск серверов… (до 4с)")
        local list = discoverServers(4)
        if #list == 0 then
          print("Серверов не найдено."); os.sleep(1.2)
        elseif #list == 1 then
          print("Найден сервер: " .. list[1].addr .. ". Пытаюсь подключиться…")
          local ok, err, info = tryConnectServer(list[1].addr, 3)
          print(ok and "Подключено." or ("Ошибка: " .. (err or "unknown")))
          if ok and info then
            print(string.format("ID:%s, Радар:%s, Подписчиков:%d, Клиентов:%d",
              tostring(info.id or "?"), info.radar and "есть" or "нет",
              info.subs or 0, info.clients or 0))
          end
          os.sleep(1.6)
        else
          print("Найдено серверов: " .. #list)
          for i, s in ipairs(list) do
            print(string.format("%d) %s %s", i, s.addr, s.info and ("("..tostring(s.info)..")") or ""))
          end
          term.write("Номер сервера: "); local idx = tonumber(io.read())
          if idx and list[idx] then
            print("Пытаюсь подключиться к " .. list[idx].addr .. " …")
            local ok, err, info = tryConnectServer(list[idx].addr, 3)
            print(ok and "Подключено." or ("Ошибка: " .. (err or "unknown")))
            if ok and info then
              print(string.format("ID:%s, Радар:%s, Подписчиков:%d, Клиентов:%d",
                tostring(info.id or "?"), info.radar and "есть" or "нет",
                info.subs or 0, info.clients or 0))
            end
            os.sleep(1.6)
          else
            print(tr("invalid_input")); os.sleep(1.0)
          end
        end
      end

    elseif choice == "2" then
      if not haveModem() then
        print("Модем не найден. Подключите модем к компьютеру."); os.sleep(1.4)
      else
        term.write("Адрес сервера: "); local addr = io.read()
        if addr and addr ~= "" then
          print("Пытаюсь подключиться…")
          local ok, err, info = tryConnectServer(addr, 3)
          print(ok and "Подключено." or ("Ошибка: " .. (err or "unknown")))
          if ok and info then
            print(string.format("ID:%s, Радар:%s, Подписчиков:%d, Клиентов:%d",
              tostring(info.id or "?"), info.radar and "есть" or "нет",
              info.subs or 0, info.clients or 0))
          end
          os.sleep(1.6)
        else
          print("Адрес не введён."); os.sleep(1.0)
        end
      end

    elseif choice == "3" then
      if not SERVER_CONNECTED then
        print("Сейчас не подключен."); os.sleep(1.2)
      else
        local ok = disconnectServer()
        print(ok and "Отключено." or "Не удалось отключиться."); os.sleep(1.2)
      end

    elseif choice == "4" then
      if not SERVER_ADDR then
        print("Нет сохранённого адреса."); os.sleep(1.2)
      else
        print("Переподключение к " .. SERVER_ADDR .. " …")
        local ok, err, info = reconnectServer(3)
        print(ok and "Подключено." or ("Ошибка: " .. (err or "unknown")))
        if ok and info then
          print(string.format("ID:%s, Радар:%s, Подписчиков:%d, Клиентов:%d",
            tostring(info.id or "?"), info.radar and "есть" or "нет",
            info.subs or 0, info.clients or 0))
        end
        os.sleep(1.6)
      end

    else
      print(tr("invalid_input")); os.sleep(0.8)
    end
  end
end


-------------------------------------------------
-- === Меню настроек ===
-------------------------------------------------
local function settingsMenu()
  while true do
    term.clear()
    print("=== " .. tr("settings") .. " ===")
    print("Текущий режим ПРО: " .. (PRO_MODE and "ВКЛ" or "ВЫКЛ"))
    print("1 - " .. tr("select_lang"))
    print("2 - Активировать режим ПРО")
    print("3 - Отключить режим ПРО")
    print("4 - Связь с сервером")
    print("0 - " .. tr("exit"))
    term.write("> ")
    local choice = io.read()

    if choice == "0" then
      break

    elseif choice == "1" then
      print(tr("select_lang"))
      local langChoice = io.read()
      if     langChoice == "1" then setLang("ru"); lang = "ru"
      elseif langChoice == "2" then setLang("en"); lang = "en"
      else print(tr("invalid_input")) end
      print(tr("lang_set") .. ": " .. (lang == "ru" and "Русский" or "English")); os.sleep(1)

    elseif choice == "2" then
      PRO_MODE = true;  saveSettings()
      print("Режим ПРО: ВКЛ"); os.sleep(0.8)

    elseif choice == "3" then
      PRO_MODE = false; saveSettings()
      print("Режим ПРО: ВЫКЛ"); os.sleep(0.8)

    elseif choice == "4" then
      serverSettingsMenu()

    else
      print(tr("invalid_input")); os.sleep(0.8)
    end
  end
end



-------------------------------------------------
-- === Доступность радара и статус для меню ===
-------------------------------------------------
local function radarPresent()
  for _ in component.list("ntm_radar") do
    return true
  end
  return false
end

local function radarStatus()
  if radarPresent() then
    return "локальный"
  elseif SERVER_CONNECTED then
    return "через сервер"
  else
    return "недоступен"
  end
end


-------------------------------------------------
-- === Классификация отметок радара ===
-------------------------------------------------
local function isHostileMissile(blipType)
  return type(blipType) == "number" and blipType >= 0 and blipType <= 9
end

local function isNuke(blipType)
  return blipType == 4
end

-------------------------------------------------
-- === Меню: Настройка радара (скан + автоперехват + алерты) ===
-------------------------------------------------
local function radarMenu()
  local gpu = component.isAvailable("gpu") and component.gpu or nil
  local function setFg(c) if gpu then gpu.setForeground(c) end end
  local function warnBeep() pcall(computer.beep, 1000, 0.15); pcall(computer.beep, 800, 0.15) end

  -- локальный радар (если есть)
  local localRadar
  for addr in component.list("ntm_radar") do localRadar = component.proxy(addr); break end
  local useRemote = (not localRadar) and SERVER_CONNECTED

  if not localRadar and not useRemote then
    term.clear()
    print("=== Настройка радара ===\n")
    setFg(colors.gray); print("- Радар недоступен: ни локального, ни серверного."); setFg(colors.white)
    wait(); return
  end

  -- переменные состояния
  local hostile, stored, amount, nukeAlert = 0, 0, 0, false
  local insufficientWarn = false
  local lastLaunched = 0
  local interceptedSoFar = 0   -- сколько перехватчиков уже выпущено на текущую волну

  -- подписка на серверный поток (если выбираем удалённый режим)
  if useRemote then radarSubscribe() end

  local function drawHeader()
    term.clear()
    print("=== Настройка радара === " .. (useRemote and "(через сервер)" or "(локальный)"))
    print("")
  end

  local function drawBody(okPower)
    if useRemote then
      if not okPower then
        setFg(colors.red);       print("- Состояние радара: серверный радар обесточен/нет радара")
        setFg(colors.gray);      print("- Количество сигнатур: —")
        setFg(colors.white)
      elseif hostile > 0 then
        setFg(colors.red);       print("- Состояние радара: ОБНАРУЖЕНЫ ЦЕЛИ (сервер)")
                                 print("- Количество сигнатур: " .. tostring(hostile))
        setFg(colors.white)
      else
        setFg(colors.lightgreen);print("- Состояние радара: всё спокойно (сервер)")
        setFg(colors.gray);      print("- Количество сигнатур: —")
        setFg(colors.white)
      end
    else
      if stored <= 0 then
        setFg(colors.red);       print("- Состояние радара: обесточено")
        setFg(colors.gray);      print("- Количество сигнатур: —")
        setFg(colors.white)
      elseif hostile > 0 then
        setFg(colors.red);       print("- Состояние радара: Радар работает штатно — ОБНАРУЖЕНЫ ЦЕЛИ")
                                 print("- Количество сигнатур: " .. tostring(hostile))
        setFg(colors.white)
      else
        setFg(colors.lightgreen);print("- Состояние радара: Радар работает штатно — всё спокойно")
        setFg(colors.gray);      print("- Количество сигнатур: —")
        setFg(colors.white)
      end
    end

    if nukeAlert then
      setFg(colors.toxic); print("Обнаружен запуск ЯДЕРНОЙ ракеты! Срочно в укрытие!"); setFg(colors.white)
    end
    if insufficientWarn then
      setFg(colors.orange)
      print(string.format("ВНИМАНИЕ: выпущено перехватчиков меньше, чем новых целей (%d/%d)!",
            lastLaunched, math.max(0, hostile - (interceptedSoFar - lastLaunched))))
      setFg(colors.white)
    end

    print("\nНажмите 0 для выхода. Обновление в реальном времени.")
    if PRO_MODE then
      print("\n---- Автоперехват ПРО ----")
      if useRemote then
        print("- Автоматический перехват (сервер): " .. (AUTO_INTERCEPT and "ВКЛ" or "ВЫКЛ"))
        print("5 - Переключить автоперехват (сервер)")
      else
        print("- Автоматический перехват: " .. (AUTO_INTERCEPT and "ВКЛ" or "ВЫКЛ"))
        print("5 - Переключить автоперехват")
      end
    end
  end

  drawHeader(); drawBody(true)

  local lastRedraw = 0
  local function redraw(okPower)
    local now = computer.uptime()
    if now - lastRedraw > 0.1 then
      drawHeader(); drawBody(okPower); lastRedraw = now
    end
  end

  while true do
    local ev = {event.pull(1)}
    local name = ev[1]

    if name == "key_down" then
      local ch = ev[3]
      if ch == string.byte("0") or ch == string.byte("q") or ch == string.byte("Q") then
        if useRemote then radarUnsubscribe() end
        break
      elseif PRO_MODE and ch == string.byte("5") then
        if useRemote then
          local m = netOpen()
          if m and SERVER_ADDR then
            pcall(m.send, SERVER_ADDR, NET_PORT, NET_PROTO, NET_AI_TOGGLE)
          end
          -- Состояние придёт пакетом NET_AI_STATE
          redraw(true)
        else
          AUTO_INTERCEPT = not AUTO_INTERCEPT; saveSettings(); redraw(true)
        end
      end

    elseif name == "modem_message" and useRemote then
      -- распаковка входящих сетевых пакетов
      local _, _, from, port, _, proto, kind, p1, p2, p3, p4, p5 = table.unpack(ev)
      if from ~= SERVER_ADDR or port ~= NET_PORT or proto ~= NET_PROTO then
        -- не наш пакет
      else
        if kind == NET_RADAR_STATE then
          local present, s, a, h, nuke = p1, p2, p3, p4, p5
          stored    = tonumber(s) or 0
          amount    = tonumber(a) or 0
          hostile   = tonumber(h) or 0
          nukeAlert = (nuke == true) or (nuke == 1) or (nuke == "1")
          local okPower = (present == true or present == 1 or present == "1") and stored > 0
          -- при удалённом радаре локальный AI не работает; команды запуска придут через NET_AI_FIRE
          redraw(okPower)

        elseif kind == NET_AI_STATE then
          local on = (p1 == true or p1 == 1 or p1 == "1")
          AUTO_INTERCEPT = on and true or false
          saveSettings()
          redraw(true)

        elseif kind == NET_AI_FIRE then
          local need = tonumber(p1) or 0
          if PRO_MODE and need > 0 then
            -- сервер велит выпустить N перехватчиков
            lastLaunched     = autoIntercept(need)
            interceptedSoFar = interceptedSoFar + lastLaunched
            insufficientWarn = (lastLaunched < need)
            if insufficientWarn then warnBeep() end
            redraw(true)
          end
        end
      end

    elseif name == nil then
      -- таймаут: локальный опрос
      if not useRemote and localRadar then
        local okE, s = pcall(localRadar.getEnergyInfo); stored = okE and tonumber(s) or 0
        local okA, a = pcall(localRadar.getAmount);     amount = okA and tonumber(a) or 0
        local h, n = 0, false
        if amount and amount > 0 then
          for i=1,amount do
            local okT, blip = pcall(function() return localRadar.getIndexType(i) end)
            if okT and type(blip)=="number" then
              if blip >=0 and blip<=9 then h = h + 1; if blip==4 then n = true end end
            end
          end
        end
        hostile, nukeAlert = h, n

        -- локальный AI (как раньше)
        if PRO_MODE and AUTO_INTERCEPT and stored > 0 then
          if hostile == 0 then
            interceptedSoFar = 0
            insufficientWarn = false
            lastLaunched = 0
          else
            local need = math.max(0, hostile - interceptedSoFar)
            if need > 0 then
              lastLaunched     = autoIntercept(need)
              interceptedSoFar = interceptedSoFar + lastLaunched
              insufficientWarn = (lastLaunched < need)
              if insufficientWarn then warnBeep() end
            else
              insufficientWarn = false
              lastLaunched = 0
            end
          end
        end

        redraw(stored > 0)
      end
    end
  end
end



-------------------------------------------------
-- === Главный цикл ===
-------------------------------------------------
authenticate()

while true do
  term.clear()
  print(tr("main_menu"))
  for i=1,4 do drawPad(i, pads[i]) end
  print("------------------------")
  print("1 - " .. tr("set_target"))
  print("2 - " .. tr("launch_menu_btn"))
  print("3 - " .. tr("settings"))
  print("4 - Настройка радара (" .. ((function()
      if component.isAvailable("ntm_radar") then return "локальный"
      elseif SERVER_CONNECTED then return "через сервер"
      else return "недоступен" end
  end)()) .. ")")
  print("6 - " .. tr("open_manager"))
  print("0 - " .. tr("exit"))
  if SERVER_CONNECTED and SERVER_ADDR then
    print("Сервер: подключено к " .. SERVER_ADDR)
  else
    print("Сервер: не подключён")
  end
  term.write("> ")

  -- бейдж версии
  drawVersionBadge()

  local choice = io.read()
  if choice == "1" then
    setTarget()
  elseif choice == "2" then
    launchControlMenu()
  elseif choice == "3" then
    settingsMenu()
  elseif choice == "4" then
    radarMenu()
  elseif choice == "6" then
    managerMenu()
  elseif choice == "0" then
    break
  else
    print(tr("invalid_input")); wait()
  end
end
