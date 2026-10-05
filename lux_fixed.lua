-- Lux AI - Versión corregida
-- Fixes: forward references, funciones faltantes (FollowPlayer/StopFollowing),
--        orden de definición de SaveMapData y WipeKeyData

repeat task.wait() until game:IsLoaded()

local HttpService        = game:GetService("HttpService")
local Players            = game:GetService("Players")
local TweenService       = game:GetService("TweenService")
local UserInputService   = game:GetService("UserInputService")
local RunService         = game:GetService("RunService")

local HttpRequest = (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

local LP        = Players.LocalPlayer
local playerGui = LP:WaitForChild("PlayerGui")

-- ============================================================
-- CONFIGURACIÓN
-- ============================================================
local KEY_FILE_NAME        = "Lux_API_Key.txt"
local VALIDATION_FILE_NAME = "Lux_Validation.txt"
local API_KEY              = ""
local API_TIMEOUT_SECONDS  = 15
local API_PROVIDER         = "gemini"
local GROQ_MODEL_URL       = "https://api.groq.com/openai/v1/chat/completions"
local GROQ_MODEL           = "openai/gpt-oss-120b"
local GEMINI_MODEL_URL     = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"

local PRIVATE_MODE = true
local scriptOwner  = LP

-- ============================================================
-- SCRIPTS DISPONIBLES
-- ============================================================
local AVAILABLE_SCRIPTS = {
    { keywords = {"grip","gripscript"},               url = "https://pastebin.com/raw/cCRTZzbP",                                    name = "GRIP Script",    description = "Script de agarre mejorado" },
    { keywords = {"proteger","no daños","evitar daños","proteger jugador","god","godmode"}, url = "https://pastebin.com/raw/3QRfTGkG", name = "God Mode",       description = "Protección contra daños" },
    { keywords = {"vuelo","volar","permitir vuelo","permitir volar","levitar","fly"},       url = "https://pastebin.com/raw/GjCJ5e8u", name = "Fly Script",     description = "Script de vuelo" },
    { keywords = {"inf yield","yield","infinite","infinite yield","iy"},                   url = "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source", name = "Infinite Yield", description = "Admin commands" },
    { keywords = {"nameless","less","namelessscript","nameless admin"},                    url = "https://rawscripts.net/raw/Universal-Script-Nameless-admin-REWORKED-43502", name = "Nameless Admin", description = "Admin script" },
}

-- ============================================================
-- ESTADOS DEL SISTEMA
-- ============================================================
local Settings = {
    AI_Enabled    = false,
    IsThinking    = false,
    IsServerBusy  = false,
    IsProbing     = false,
    NextReqTime   = 0,
}
local ThinkingStartTime = 0
local BusyStartTime     = 0

-- Variables UI (se asignan más abajo)
local ScreenGui, AuthFrame, MainFrame, StatusIndicator
local APIKeyBox, ValidateButton, ToggleButton, ConsoleLabel, ShowButton

-- ============================================================
-- UTILS: CONSOLA (debe definirse antes de usarse)
-- ============================================================
local function UpdateConsole(text, status)
    if not ScreenGui or not ScreenGui.Parent then return end
    local displayText = text or ""
    if status then displayText = displayText .. " | " .. status end
    if #displayText > 50 then displayText = displayText:sub(1, 47) .. "..." end
    ConsoleLabel.Text = displayText
end

-- ============================================================
-- ARCHIVOS: API KEY Y VALIDACIÓN
-- (WipeKeyData antes de WipeValidation para evitar nil call)
-- ============================================================
local function SaveAPIKey(key)
    if writefile then pcall(function() writefile(KEY_FILE_NAME, key) end) end
end

local function LoadAPIKey()
    if isfile and isfile(KEY_FILE_NAME) then
        local ok, key = pcall(function() return readfile(KEY_FILE_NAME):gsub("%s+","") end)
        if ok and #key > 10 then return key end
    end
    return nil
end

local function WipeKeyData()          -- definida ANTES de WipeValidation
    if isfile and isfile(KEY_FILE_NAME) then delfile(KEY_FILE_NAME) end
    API_KEY = ""
end

local function SaveValidation(apiKey, provider)
    if writefile then
        pcall(function()
            writefile(VALIDATION_FILE_NAME, HttpService:JSONEncode({
                apiKey    = apiKey,
                provider  = provider or "gemini",
                validated = true,
                timestamp = os.time(),
            }))
        end)
    end
end

local function LoadValidation()
    if isfile and isfile(VALIDATION_FILE_NAME) then
        local ok, data = pcall(function()
            return HttpService:JSONDecode(readfile(VALIDATION_FILE_NAME))
        end)
        if ok and data and data.validated and data.apiKey and #data.apiKey > 10 then
            return data.apiKey, data.provider or "gemini"
        end
    end
    return nil, nil
end

local function WipeValidation()       -- WipeKeyData ya existe aquí
    if isfile and isfile(VALIDATION_FILE_NAME) then delfile(VALIDATION_FILE_NAME) end
    WipeKeyData()
end

-- ============================================================
-- EJECUCIÓN DE SCRIPTS (definida ANTES de las funciones que la usan)
-- ============================================================
local function SafeExecuteScript(url)
    if not url or url == "" then return false, "URL inválida" end
    if not game.HttpGet or not loadstring then return false, "Funciones de ejecución no disponibles" end
    local ok, result = pcall(function()
        local content = game:HttpGet(url, true)
        if not content or content == "" then error("No se pudo descargar el script") end
        local fn = loadstring(content)
        if fn then fn() else error("Error al compilar el script") end
    end)
    return ok, ok and "Script ejecutado correctamente" or ("Error al ejecutar: " .. tostring(result))
end

local function FindScriptByKeyword(userInput)
    userInput = userInput:lower():gsub("%s+"," "):gsub("^%s+",""):gsub("%s+$","")
    for _, script in ipairs(AVAILABLE_SCRIPTS) do
        for _, kw in ipairs(script.keywords) do
            if userInput == kw:lower() then return script, nil end
        end
    end
    local suggestions = {}
    for _, script in ipairs(AVAILABLE_SCRIPTS) do
        for _, kw in ipairs(script.keywords) do
            if kw:lower():find(userInput,1,true) or userInput:find(kw:lower(),1,true) then
                table.insert(suggestions, {script=script, keyword=kw})
            end
        end
    end
    return nil, (#suggestions > 0 and suggestions or nil)
end

-- ============================================================
-- BAILE
-- ============================================================
local CurrentDanceTrack = nil

local function MakeCharacterDance()
    local character = LP.Character
    if not character then return false, "Personaje no encontrado" end
    local humanoid = character:FindFirstChild("Humanoid")
    if not humanoid then return false, "Humanoid no encontrado" end
    if CurrentDanceTrack and CurrentDanceTrack.IsPlaying then
        return false, "Ya estoy bailando! Di 'detener baile' para parar"
    end
    local anim = Instance.new("Animation")
    anim.AnimationId = "rbxassetid://10214311282"
    local ok, result = pcall(function()
        local animator = humanoid:FindFirstChildOfClass("Animator")
            or Instance.new("Animator", humanoid)
        CurrentDanceTrack = animator:LoadAnimation(anim)
        CurrentDanceTrack.Looped = true
        CurrentDanceTrack:Play()
    end)
    return ok, ok and "Bailando breakdance en loop! 💃" or ("Error al bailar: " .. tostring(result))
end

local function StopCharacterDance()
    if CurrentDanceTrack and CurrentDanceTrack.IsPlaying then
        CurrentDanceTrack:Stop(); CurrentDanceTrack = nil
        return true, "Baile detenido"
    end
    return false, "No estoy bailando"
end

-- ============================================================
-- SEGUIMIENTO (FollowPlayer / StopFollowing — FALTABAN en el original)
-- ============================================================
local FollowTarget     = nil
local FollowConnection = nil

local function StopFollowing()
    FollowTarget = nil
    if FollowConnection then FollowConnection:Disconnect(); FollowConnection = nil end
end

local function FollowPlayer(player)
    if not player or not player.Character then return false, "jugador sin personaje" end
    StopFollowing()
    FollowTarget = player
    FollowConnection = RunService.Heartbeat:Connect(function()
        if not FollowTarget or not FollowTarget.Character then StopFollowing(); return end
        local myChar  = LP.Character
        if not myChar then return end
        local myRoot  = myChar:FindFirstChild("HumanoidRootPart")
        local tarRoot = FollowTarget.Character:FindFirstChild("HumanoidRootPart")
        local hum     = myChar:FindFirstChild("Humanoid")
        if not myRoot or not tarRoot or not hum then return end
        local dist = (myRoot.Position - tarRoot.Position).Magnitude
        if dist > 5 then
            hum:MoveTo(tarRoot.Position)
        end
    end)
    return true, "Siguiendo a " .. (player.DisplayName or player.Name)
end

-- ============================================================
-- GOD MODE + AUTO-DODGE
-- ============================================================
local GodModeActive    = false
local AutoDodgeActive  = false
local DodgeConnection  = nil
local LastDodgeTime    = 0
local DODGE_COOLDOWN   = 0.5

local function IsEnemy(player)
    if not player or player == LP then return false end
    if LP.Team and player.Team and LP.Team ~= player.Team then return true end
    local character = player.Character
    if character then
        local dangerousKW = {"sword","gun","rifle","knife","blade","weapon","espada","pistola","cuchillo"}
        local function hasDangerousTool(parent)
            for _, child in pairs(parent:GetChildren()) do
                if child:IsA("Tool") then
                    local n = child.Name:lower()
                    for _, kw in ipairs(dangerousKW) do if n:find(kw) then return true end end
                end
            end
            return false
        end
        if hasDangerousTool(character) then return true end
        local bp = player:FindFirstChild("Backpack")
        if bp and hasDangerousTool(bp) then return true end
    end
    return false
end

local function CheckEnemyProximity()
    local character = LP.Character
    if not character then return nil, nil end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return nil, nil end
    local nearestEnemy, nearestDist = nil, math.huge
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LP and IsEnemy(player) and player.Character then
            local enemyRoot = player.Character:FindFirstChild("HumanoidRootPart")
            if enemyRoot then
                local d = (rootPart.Position - enemyRoot.Position).Magnitude
                if d < 15 and d < nearestDist then nearestEnemy = player; nearestDist = d end
            end
        end
    end
    return nearestEnemy, nearestDist
end

local function DodgeEnemy(enemy)
    local character = LP.Character
    if not character then return false end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChild("Humanoid")
    if not rootPart or not humanoid then return false end
    local enemyRoot = enemy.Character:FindFirstChild("HumanoidRootPart")
    if not enemyRoot then return false end
    if tick() - LastDodgeTime < DODGE_COOLDOWN then return false end
    local dirToEnemy = (enemyRoot.Position - rootPart.Position).Unit
    local side = math.random() > 0.5 and 1 or -1
    local perp = Vector3.new(-dirToEnemy.Z, 0, dirToEnemy.X) * side
    local dodgePos = enemyRoot.Position + (perp * 10) + Vector3.new(0, 2, 0)
    pcall(function()
        rootPart.CFrame = CFrame.new(dodgePos, enemyRoot.Position)
        rootPart.Velocity = Vector3.new(0, 0, 0)
    end)
    LastDodgeTime = tick()
    return true
end

local function ActivateGodModeWithDodge()
    local ok, msg = SafeExecuteScript("https://pastebin.com/raw/3QRfTGkG")
    if not ok then return false, "Error al activar God Mode: " .. msg end
    GodModeActive = true; AutoDodgeActive = true
    if DodgeConnection then DodgeConnection:Disconnect() end
    DodgeConnection = RunService.Heartbeat:Connect(function()
        if not AutoDodgeActive then
            if DodgeConnection then DodgeConnection:Disconnect(); DodgeConnection = nil end
            return
        end
        local nearestEnemy, distance = CheckEnemyProximity()
        if nearestEnemy and distance and distance < 12 then DodgeEnemy(nearestEnemy) end
    end)
    return true, "Protección activada con esquive automático"
end

local function DeactivateGodMode()
    GodModeActive = false; AutoDodgeActive = false
    if DodgeConnection then DodgeConnection:Disconnect(); DodgeConnection = nil end
end

-- ============================================================
-- ENVIRONMENT / PLAYERS
-- ============================================================
local EnvironmentData = {
    LastUpdate     = 0,
    UpdateInterval = 2,
    CachedData     = nil,
    PlayersData    = {},
    OwnerPosition  = Vector3.new(0,0,0),
}

local function GetDistance(p1,p2) return math.floor((p1-p2).Magnitude) end

local function GetPlayerData(player)
    if not player or not player.Character then return nil end
    local char     = player.Character
    local humanoid = char:FindFirstChild("Humanoid")
    local rootPart = char:FindFirstChild("HumanoidRootPart")
    if not rootPart then return nil end
    local ownerRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local dist = ownerRoot and GetDistance(rootPart.Position, ownerRoot.Position) or 9999
    return {
        name            = player.DisplayName or player.Name,
        username        = player.Name,
        userId          = player.UserId,
        position        = rootPart.Position,
        health          = humanoid and math.floor(humanoid.Health) or 0,
        maxHealth       = humanoid and math.floor(humanoid.MaxHealth) or 100,
        distanceFromYou = dist,
        isAlive         = humanoid and humanoid.Health > 0 or false,
        team            = player.Team and player.Team.Name or "No team",
    }
end

local function ScanEnvironment()
    local now = tick()
    if now - EnvironmentData.LastUpdate < EnvironmentData.UpdateInterval then
        return EnvironmentData.CachedData
    end
    EnvironmentData.LastUpdate = now
    local ownerChar   = LP.Character
    local ownerRoot   = ownerChar and ownerChar:FindFirstChild("HumanoidRootPart")
    local ownerHum    = ownerChar and ownerChar:FindFirstChild("Humanoid")
    if ownerRoot then EnvironmentData.OwnerPosition = ownerRoot.Position end
    local ownerData = {
        health    = ownerHum and math.floor(ownerHum.Health) or 0,
        maxHealth = ownerHum and math.floor(ownerHum.MaxHealth) or 100,
        position  = ownerRoot and ownerRoot.Position or Vector3.new(0,0,0),
        isAlive   = ownerHum and ownerHum.Health > 0 or false,
    }
    local playersData = {}
    local playerCount, playersNearby = 0, 0
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LP then
            local data = GetPlayerData(player)
            if data then
                table.insert(playersData, data)
                playerCount = playerCount + 1
                if data.distanceFromYou < 9 then playersNearby = playersNearby + 1 end
            end
        end
    end
    table.sort(playersData, function(a,b) return a.distanceFromYou < b.distanceFromYou end)
    local nearestPlayers = {}
    for i = 1, math.min(5, #playersData) do table.insert(nearestPlayers, playersData[i]) end
    local ok, gameName = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
    end)
    local env = {
        owner          = ownerData,
        totalPlayers   = playerCount,
        playersNearby  = playersNearby,
        nearestPlayers = nearestPlayers,
        gameName       = (ok and gameName) or "Unknown",
        timestamp      = os.date("%H:%M:%S"),
    }
    EnvironmentData.CachedData  = env
    EnvironmentData.PlayersData = playersData
    return env
end

local function FindPlayerByName(searchName)
    if not searchName or searchName == "" then return nil end
    searchName = searchName:lower()
    ScanEnvironment()
    for _, pdata in ipairs(EnvironmentData.PlayersData) do
        if pdata.name:lower() == searchName or pdata.username:lower() == searchName then return pdata end
        if pdata.name:lower():find(searchName,1,true) or pdata.username:lower():find(searchName,1,true) then return pdata end
    end
    return nil
end

local function GetEnvironmentSummary()
    local env = ScanEnvironment()
    if not env then return "No puedo ver el entorno en este momento." end
    local summary = string.format("Tu salud: %d/%d | Jugadores: %d total, %d cercanos",
        env.owner.health, env.owner.maxHealth, env.totalPlayers, env.playersNearby)
    if #env.nearestPlayers > 0 then
        local names = {}
        for i = 1, math.min(3, #env.nearestPlayers) do
            local p = env.nearestPlayers[i]
            table.insert(names, string.format("%s (%d studs)", p.name, p.distanceFromYou))
        end
        summary = summary .. " | Más cerca: " .. table.concat(names, ", ")
    end
    return summary
end

local function FormatEnvironmentForLux()
    local env = ScanEnvironment()
    if not env then return "Environment data unavailable" end
    local compactData = {
        your_health    = env.owner.health .. "/" .. env.owner.maxHealth,
        alive          = env.owner.isAlive,
        total_players  = env.totalPlayers,
        players_nearby = env.playersNearby,
        game           = env.gameName,
    }
    if #env.nearestPlayers > 0 then
        compactData.nearest_players = {}
        for i = 1, math.min(3, #env.nearestPlayers) do
            local p = env.nearestPlayers[i]
            table.insert(compactData.nearest_players, {
                name     = p.name,
                username = p.username,
                distance = p.distanceFromYou .. " studs",
                health   = p.health .. "/" .. p.maxHealth,
                alive    = p.isAlive,
            })
        end
    end
    return HttpService:JSONEncode(compactData)
end

-- ============================================================
-- ENEMIGOS
-- ============================================================
local function GetNearbyEnemies(maxDistance)
    maxDistance = maxDistance or 50
    local enemies = {}
    ScanEnvironment()
    for _, pdata in ipairs(EnvironmentData.PlayersData) do
        if pdata.distanceFromYou <= maxDistance then
            local player = Players:GetPlayerByUserId(pdata.userId)
            if player and IsEnemy(player) then
                table.insert(enemies, {
                    name      = pdata.name,
                    distance  = pdata.distanceFromYou,
                    health    = pdata.health,
                    maxHealth = pdata.maxHealth,
                    isAlive   = pdata.isAlive,
                    team      = pdata.team,
                })
            end
        end
    end
    table.sort(enemies, function(a,b) return a.distance < b.distance end)
    return enemies
end

local function FormatEnemyList(enemies, maxCount)
    if #enemies == 0 then return "sin hostiles detectados" end
    maxCount = maxCount or 3
    local result = {}
    for i = 1, math.min(maxCount, #enemies) do
        local e = enemies[i]
        table.insert(result, string.format("%s %ds h%d/%d", e.name, e.distance, e.health, e.maxHealth))
    end
    if #enemies > maxCount then table.insert(result, string.format("mas %d", #enemies - maxCount)) end
    return table.concat(result, " | ")
end

-- ============================================================
-- HIGHLIGHTS
-- ============================================================
local ActiveHighlights = {}

local function RemoveHighlight(key)
    if ActiveHighlights[key] then
        pcall(function() ActiveHighlights[key].highlight:Destroy() end)
        ActiveHighlights[key] = nil
    end
end

local function ClearAllHighlights()
    for key, data in pairs(ActiveHighlights) do
        pcall(function() data.highlight:Destroy() end)
    end
    ActiveHighlights = {}
end

local function HighlightObject(objectName, objectInstance)
    if not objectInstance then return end
    RemoveHighlight(objectName)
    local h = Instance.new("Highlight")
    h.Name                = "LuxObjectHighlight"
    h.FillColor           = Color3.fromRGB(50, 150, 255)
    h.OutlineColor        = Color3.fromRGB(150, 200, 255)
    h.FillTransparency    = 0.4
    h.OutlineTransparency = 0
    h.Parent              = objectInstance
    ActiveHighlights[objectName] = { highlight = h, type = "object", instance = objectInstance }
end

local function HighlightEnemy(player)
    if not player or not player.Character then return end
    local key = "enemy_" .. player.UserId
    RemoveHighlight(key)
    local h = Instance.new("Highlight")
    h.Name                = "LuxEnemyHighlight"
    h.FillColor           = Color3.fromRGB(255, 50, 50)
    h.OutlineColor        = Color3.fromRGB(255, 200, 200)
    h.FillTransparency    = 0.5
    h.OutlineTransparency = 0
    h.Parent              = player.Character
    ActiveHighlights[key] = { highlight = h, type = "enemy", player = player }
end

local function UpdateObjectHighlights()
    local character = LP.Character
    if not character then return end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return end
    for key, data in pairs(ActiveHighlights) do
        if data.type == "object" and data.instance then
            local pos
            if data.instance:IsA("Model") then
                local prim = data.instance.PrimaryPart or data.instance:FindFirstChildWhichIsA("BasePart")
                if prim then pos = prim.Position end
            elseif data.instance:IsA("BasePart") then
                pos = data.instance.Position
            end
            if pos and (rootPart.Position - pos).Magnitude < 5 then RemoveHighlight(key) end
        end
    end
end

local function UpdateEnemyHighlights()
    local enemies = GetNearbyEnemies(50)
    for _, enemyData in ipairs(enemies) do
        local player = Players:GetPlayerByUserId(enemyData.userId or 0)
        if player and IsEnemy(player) then HighlightEnemy(player) end
    end
    for key, data in pairs(ActiveHighlights) do
        if data.type == "enemy" and data.player then
            local player = data.player
            if not player or not player.Character then
                RemoveHighlight(key)
            else
                local pdata = GetPlayerData(player)
                if not IsEnemy(player) or (pdata and pdata.distanceFromYou > 50) then
                    RemoveHighlight(key)
                end
            end
        end
    end
end

-- ============================================================
-- MAPA
-- ============================================================
local MAP_DATA_FILE = "Lux_MapData.json"
local ScannedObjects = {}
local LastMapScan    = 0
local MAP_SCAN_COOLDOWN = 300

-- SaveMapData definida ANTES de ScanMapObjects (que la llama)
local function SaveMapData()
    if not writefile then return end
    pcall(function()
        local ok, gameName = pcall(function()
            return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
        end)
        writefile(MAP_DATA_FILE, HttpService:JSONEncode({
            objects    = ScannedObjects,
            scannedAt  = os.time(),
            placeName  = (ok and gameName) or "Unknown",
        }))
    end)
end

local function ScanMapObjects()
    if tick() - LastMapScan < MAP_SCAN_COOLDOWN then return ScannedObjects end
    ScannedObjects = {}
    local function scanFolder(folder, depth)
        if depth > 3 then return end
        for _, obj in pairs(folder:GetChildren()) do
            if obj:IsA("BasePart") or obj:IsA("Model") then
                local name = obj.Name:lower()
                if not name:match("baseplate") and not name:match("terrain") and #obj.Name > 2 then
                    local position
                    if obj:IsA("Model") then
                        local prim = obj.PrimaryPart or obj:FindFirstChild("HumanoidRootPart") or obj:FindFirstChildWhichIsA("BasePart")
                        if prim then position = prim.Position end
                    else
                        position = obj.Position
                    end
                    if position then
                        ScannedObjects[obj.Name] = {
                            position = position,
                            type     = obj.ClassName,
                            parent   = folder.Name,
                            color    = obj:IsA("BasePart") and obj.BrickColor.Name or nil,
                        }
                    end
                end
                if obj:IsA("Model") then scanFolder(obj, depth + 1) end
            end
        end
    end
    scanFolder(workspace, 0)
    LastMapScan = tick()
    SaveMapData()   -- ahora SaveMapData ya existe
    return ScannedObjects
end

local function LoadMapData()
    if not isfile or not isfile(MAP_DATA_FILE) then ScanMapObjects(); return end
    pcall(function()
        local data = HttpService:JSONDecode(readfile(MAP_DATA_FILE))
        if data.objects then ScannedObjects = data.objects end
    end)
end

local function FindMapObject(searchTerm)
    searchTerm = searchTerm:lower():gsub("%s+","")
    if next(ScannedObjects) == nil then ScanMapObjects() end
    local matches = {}
    for objName, objData in pairs(ScannedObjects) do
        local name  = objName:lower()
        local color = objData.color and objData.color:lower() or ""
        if (name .. " " .. color):find(searchTerm, 1, true) then
            table.insert(matches, { name = objName, data = objData, relevance = #searchTerm/#name })
        end
    end
    table.sort(matches, function(a,b) return a.relevance > b.relevance end)
    return matches
end

local function FormatObjectInfo(objName, objData)
    local pos = objData.position
    local ownerRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
    local distance  = ownerRoot and math.floor((pos - ownerRoot.Position).Magnitude) or 0
    return string.format("%s %ds pos %.0f %.0f %.0f", objName, distance, pos.X, pos.Y, pos.Z)
end

local function TeleportToObject(objData)
    local character = LP.Character
    if not character then return false, "personaje no encontrado" end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false, "rootpart no encontrado" end
    local humanoid = character:FindFirstChild("Humanoid")
    if humanoid then humanoid:ChangeState(Enum.HumanoidStateType.Physics) end
    local offsets = {
        Vector3.new(0,10,0), Vector3.new(5,10,0), Vector3.new(-5,10,0),
        Vector3.new(0,10,5), Vector3.new(0,10,-5),
    }
    local success = false
    for _, offset in ipairs(offsets) do
        pcall(function() rootPart.CFrame = CFrame.new(objData.position + offset) end)
        task.wait(0.1)
        if (rootPart.Position - objData.position).Magnitude < 50 then success = true; break end
    end
    task.wait(0.2)
    if humanoid then humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end
    return success, success and "teleportado" or "no se pudo tp intenta de nuevo"
end

-- ============================================================
-- COOLDOWNS DE COMANDOS
-- ============================================================
local CommandCooldowns = {}
local COMMAND_COOLDOWN = 4

local function CanUseCommand(userId, commandName)
    if not CommandCooldowns[userId] then CommandCooldowns[userId] = {} end
    local lastUse = CommandCooldowns[userId][commandName] or 0
    local timeSince = tick() - lastUse
    if timeSince >= COMMAND_COOLDOWN then
        CommandCooldowns[userId][commandName] = tick()
        return true
    end
    return false, math.ceil(COMMAND_COOLDOWN - timeSince)
end

-- ============================================================
-- SERVER PROBE
-- ============================================================
local function ProbeServer()
    if Settings.IsProbing then return end
    Settings.IsProbing = true
    UpdateConsole("Rate Limit Hit", "Cooling Down")
    task.wait(5)
    local backoff = 5
    while Settings.IsServerBusy and ScreenGui.Parent do
        task.wait(backoff)
        UpdateConsole("Probing Server", "Backoff: " .. backoff .. "s")
        local probeBody = HttpService:JSONEncode({
            contents         = {{role="user", parts={{text="."}}}},
            generationConfig = {maxOutputTokens=1},
        })
        local ok, res = pcall(function()
            return HttpRequest({
                Url     = GEMINI_MODEL_URL .. "?key=" .. API_KEY,
                Method  = "POST",
                Headers = {["Content-Type"]="application/json"},
                Body    = probeBody,
            })
        end)
        local recovered = false
        if ok and res then
            if res.StatusCode and res.StatusCode ~= 429 and res.StatusCode ~= 503 and res.StatusCode ~= 500 then
                recovered = true
            elseif res.Body and not res.Body:find("429") and not res.Body:find("503") then
                recovered = true
            end
        end
        if recovered then
            Settings.IsServerBusy = false; Settings.IsProbing = false
            UpdateConsole("Server Recovered", "Online")
            Settings.NextReqTime = tick() + 2; BusyStartTime = 0
        else
            backoff = math.min(backoff + 5, 30)
            UpdateConsole("Still Busy", "Wait " .. backoff .. "s")
        end
        if Settings.IsServerBusy and (tick() - BusyStartTime) > 90 then
            Settings.IsServerBusy = false; Settings.IsProbing = false
            UpdateConsole("Probe Timeout", "Forced Reset")
            BusyStartTime = 0; break
        end
    end
    Settings.IsProbing = false
end

-- ============================================================
-- VALIDAR API KEY
-- ============================================================
local function ValidateAPIKey(apiKey, bypassSettings)
    if not bypassSettings and tick() < Settings.NextReqTime then return nil, "COOLDOWN" end
    if apiKey == "" or #apiKey < 10 then return false, "API Key muy corta o vacía" end
    if Settings.IsThinking then return nil, "THINKING" end
    Settings.IsThinking = true; ThinkingStartTime = tick()
    if Settings.IsServerBusy then
        if (tick() - BusyStartTime) > 60 then
            Settings.IsServerBusy = false; UpdateConsole("Reset Busy State","Retry")
        else
            UpdateConsole("Server Busy","Probing...")
            Settings.IsThinking = false
            if not Settings.IsProbing then task.spawn(ProbeServer) end
            return nil, "BUSY"
        end
    end
    UpdateConsole("Validating API", "Detecting provider...")
    local detectedProvider = "gemini"
    if apiKey:match("^gsk_") then detectedProvider = "groq"
    elseif apiKey:match("^AI") then detectedProvider = "gemini" end
    local url, body, headers
    if detectedProvider == "groq" then
        url     = GROQ_MODEL_URL
        headers = {["Content-Type"]="application/json", ["Authorization"]="Bearer "..apiKey}
        body    = HttpService:JSONEncode({model=GROQ_MODEL, messages={{role="user",content="test"}}, max_tokens=5})
    else
        url     = GEMINI_MODEL_URL .. "?key=" .. apiKey
        headers = {["Content-Type"]="application/json"}
        body    = HttpService:JSONEncode({contents={{role="user",parts={{text="test"}}}}, generationConfig={maxOutputTokens=5}})
    end
    local ok, res = pcall(function()
        return HttpRequest({Url=url, Method="POST", Headers=headers, Body=body})
    end)
    Settings.IsThinking = false
    if ok and res and res.Body then
        local data
        local decOk = pcall(function() data = HttpService:JSONDecode(res.Body) end)
        if not decOk then return false, "Respuesta inválida del servidor" end
        local isValid = false
        if detectedProvider == "groq" then
            if data.choices and data.choices[1] then isValid = true
            elseif data.error then
                if data.error.code == "invalid_api_key" then return false, "API Key de Groq inválida" end
                return false, data.error.message or "Error de Groq"
            end
        else
            if data.candidates and data.candidates[1] then isValid = true
            elseif data.error then
                if data.error.code == 400 then return false, "API Key de Gemini inválida"
                elseif data.error.code == 429 or data.error.code == 503 then
                    Settings.IsServerBusy = true; BusyStartTime = tick()
                    if not Settings.IsProbing then task.spawn(ProbeServer) end
                    return nil, "BUSY"
                end
                return false, data.error.message or "Error de Gemini"
            end
        end
        if isValid then
            API_PROVIDER = detectedProvider
            UpdateConsole("Validation Success", detectedProvider:upper() .. " OK")
            Settings.NextReqTime = tick() + 4
            return true, "API Key válida (" .. detectedProvider .. ")"
        else
            return false, "Respuesta vacía del servidor"
        end
    else
        UpdateConsole("Network Timeout", "Check Connection")
        return false, "Error de conexión HTTP"
    end
end

-- ============================================================
-- ANIMACIONES DE UI
-- ============================================================
local function CloseAuthWithAnimation(frame, callback)
    local ti = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local frameTween = TweenService:Create(frame, ti, {
        Size                = UDim2.new(frame.Size.X.Scale, frame.Size.X.Offset, 0, 0),
        Position            = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset, 0.5, 0),
        BackgroundTransparency = 1,
    })
    for _, child in pairs(frame:GetDescendants()) do
        if child:IsA("GuiObject") then
            TweenService:Create(child, ti, {BackgroundTransparency=1, TextTransparency=1}):Play()
        end
    end
    frameTween:Play()
    frameTween.Completed:Connect(function()
        frame.Visible = false
        if callback then callback() end
    end)
end

local function ShowMainFrameWithAnimation()
    if not MainFrame then return end
    MainFrame.Size = UDim2.new(0,300,0,0)
    MainFrame.Position = UDim2.new(0.5,-150,0.5,0)
    MainFrame.BackgroundTransparency = 1
    MainFrame.Visible = true
    for _, child in pairs(MainFrame:GetDescendants()) do
        if child:IsA("GuiObject") then
            pcall(function() child.BackgroundTransparency = 1 end)
            if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
                pcall(function() child.TextTransparency = 1 end)
            end
        end
    end
    local ti = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    TweenService:Create(MainFrame, ti, {
        Size = UDim2.new(0,300,0,200), Position = UDim2.new(0.5,-150,0.5,-100), BackgroundTransparency = 0,
    }):Play()
    task.spawn(function()
        task.wait(0.2)
        for _, child in pairs(MainFrame:GetDescendants()) do
            if child:IsA("GuiObject") and child ~= MainFrame then
                pcall(function()
                    local bgT, txT = 0, 0
                    if child.Name:match("Corner") then bgT = 1 end
                    if child:IsA("TextLabel") then bgT = 1 end
                    TweenService:Create(child, TweenInfo.new(0.3), {
                        BackgroundTransparency = bgT, TextTransparency = txT,
                    }):Play()
                end)
            end
        end
    end)
end

local function HideMainFrameWithAnimation(callback)
    if not MainFrame then if callback then callback() end; return end
    local ti = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    for _, child in pairs(MainFrame:GetDescendants()) do
        if child:IsA("GuiObject") then
            pcall(function()
                local props = {}
                if child:IsA("Frame") or child:IsA("TextButton") or child:IsA("TextBox") or child:IsA("TextLabel") or child:IsA("ImageLabel") or child:IsA("ImageButton") then
                    props.BackgroundTransparency = 1
                end
                if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then props.TextTransparency = 1 end
                if child:IsA("ImageLabel") or child:IsA("ImageButton") then props.ImageTransparency = 1 end
                if next(props) then TweenService:Create(child, ti, props):Play() end
            end)
        end
    end
    local ft = TweenService:Create(MainFrame, ti, {
        Size = UDim2.new(0,300,0,0), Position = UDim2.new(0.5,-150,0.5,0), BackgroundTransparency = 1,
    })
    ft:Play()
    ft.Completed:Connect(function() MainFrame.Visible = false; if callback then callback() end end)
end

-- ============================================================
-- CREAR UI
-- ============================================================
ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "LuxAPISystem"
ScreenGui.ResetOnSpawn = false
if game:GetService("CoreGui"):FindFirstChild("LuxAPISystem") then
    game:GetService("CoreGui").LuxAPISystem:Destroy()
end
ScreenGui.Parent = game:GetService("CoreGui")

-- Auth Frame
AuthFrame = Instance.new("Frame")
AuthFrame.Name = "AuthFrame"
AuthFrame.Size = UDim2.new(0,360,0,260)
AuthFrame.Position = UDim2.new(0.5,-180,0.5,-130)
AuthFrame.BackgroundColor3 = Color3.fromRGB(20,20,25)
AuthFrame.BorderSizePixel = 0
AuthFrame.Visible = false
AuthFrame.Parent = ScreenGui
Instance.new("UICorner", AuthFrame).CornerRadius = UDim.new(0,14)

local function MakeDraggable(frame)
    local dragging, dragInput, dragStart, startPos
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    frame.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+delta.X, startPos.Y.Scale, startPos.Y.Offset+delta.Y)
        end
    end)
end
MakeDraggable(AuthFrame)

local authTitle = Instance.new("TextLabel", AuthFrame)
authTitle.Size = UDim2.new(1,-40,0,45); authTitle.Position = UDim2.new(0,20,0,15)
authTitle.BackgroundTransparency = 1; authTitle.Text = "⚡ LUX AI - SETUP"
authTitle.TextColor3 = Color3.fromRGB(100,200,255); authTitle.Font = Enum.Font.GothamBold
authTitle.TextSize = 20; authTitle.TextXAlignment = Enum.TextXAlignment.Left

local authInstruction = Instance.new("TextLabel", AuthFrame)
authInstruction.Size = UDim2.new(1,-40,0,25); authInstruction.Position = UDim2.new(0,20,0,70)
authInstruction.BackgroundTransparency = 1; authInstruction.Text = "Enter your Gemini or Groq API Key:"
authInstruction.TextColor3 = Color3.fromRGB(180,180,185); authInstruction.Font = Enum.Font.Gotham
authInstruction.TextSize = 13; authInstruction.TextXAlignment = Enum.TextXAlignment.Left

APIKeyBox = Instance.new("TextBox", AuthFrame)
APIKeyBox.Name = "APIKeyBox"; APIKeyBox.Size = UDim2.new(1,-40,0,42)
APIKeyBox.Position = UDim2.new(0,20,0,100); APIKeyBox.BackgroundColor3 = Color3.fromRGB(35,35,40)
APIKeyBox.BorderSizePixel = 0; APIKeyBox.Text = ""
APIKeyBox.PlaceholderText = "Paste your API key here..."; APIKeyBox.PlaceholderColor3 = Color3.fromRGB(120,120,125)
APIKeyBox.TextColor3 = Color3.fromRGB(255,255,255); APIKeyBox.Font = Enum.Font.GothamMedium
APIKeyBox.TextSize = 12; APIKeyBox.ClearTextOnFocus = false
Instance.new("UICorner", APIKeyBox).CornerRadius = UDim.new(0,8)

local getKeyButton = Instance.new("TextButton", AuthFrame)
getKeyButton.Size = UDim2.new(1,-40,0,32); getKeyButton.Position = UDim2.new(0,20,0,155)
getKeyButton.BackgroundColor3 = Color3.fromRGB(70,130,200); getKeyButton.Text = "📋 Get API Key (Copy Link)"
getKeyButton.TextColor3 = Color3.fromRGB(255,255,255); getKeyButton.Font = Enum.Font.GothamSemibold
getKeyButton.TextSize = 12
Instance.new("UICorner", getKeyButton).CornerRadius = UDim.new(0,8)
getKeyButton.MouseButton1Click:Connect(function()
    if setclipboard then
        setclipboard("https://aistudio.google.com/app/apikey")
        getKeyButton.Text = "✓ Link Copied!"; task.wait(1.5)
        getKeyButton.Text = "📋 Get API Key (Copy Link)"
    end
end)

ValidateButton = Instance.new("TextButton", AuthFrame)
ValidateButton.Name = "ValidateButton"; ValidateButton.Size = UDim2.new(1,-40,0,45)
ValidateButton.Position = UDim2.new(0,20,0,200); ValidateButton.BackgroundColor3 = Color3.fromRGB(80,160,255)
ValidateButton.Text = "✓ VALIDATE & START"; ValidateButton.TextColor3 = Color3.fromRGB(255,255,255)
ValidateButton.Font = Enum.Font.GothamBold; ValidateButton.TextSize = 14
Instance.new("UICorner", ValidateButton).CornerRadius = UDim.new(0,8)

-- Main Frame
MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"; MainFrame.Size = UDim2.new(0,300,0,200)
MainFrame.Position = UDim2.new(0.5,-150,0.5,-100); MainFrame.BackgroundColor3 = Color3.fromRGB(20,20,25)
MainFrame.BorderSizePixel = 0; MainFrame.Visible = false; MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0,14)
MakeDraggable(MainFrame)

local mainTitle = Instance.new("TextLabel", MainFrame)
mainTitle.Size = UDim2.new(1,-60,0,40); mainTitle.Position = UDim2.new(0,15,0,10)
mainTitle.BackgroundTransparency = 1; mainTitle.Text = "⚡ LUX AI"
mainTitle.TextColor3 = Color3.fromRGB(100,200,255); mainTitle.Font = Enum.Font.GothamBold
mainTitle.TextSize = 18; mainTitle.TextXAlignment = Enum.TextXAlignment.Left

StatusIndicator = Instance.new("Frame", MainFrame)
StatusIndicator.Name = "StatusIndicator"; StatusIndicator.Size = UDim2.new(0,12,0,12)
StatusIndicator.Position = UDim2.new(1,-25,0,24); StatusIndicator.BackgroundColor3 = Color3.fromRGB(80,220,120)
StatusIndicator.BorderSizePixel = 0
Instance.new("UICorner", StatusIndicator).CornerRadius = UDim.new(1,0)
task.spawn(function()
    while ScreenGui.Parent do
        TweenService:Create(StatusIndicator, TweenInfo.new(0.8, Enum.EasingStyle.Sine), {Size=UDim2.new(0,14,0,14)}):Play()
        task.wait(0.8)
        TweenService:Create(StatusIndicator, TweenInfo.new(0.8, Enum.EasingStyle.Sine), {Size=UDim2.new(0,12,0,12)}):Play()
        task.wait(0.8)
    end
end)

local closeButton = Instance.new("TextButton", MainFrame)
closeButton.Size = UDim2.new(0,28,0,28); closeButton.Position = UDim2.new(1,-40,0,12)
closeButton.BackgroundColor3 = Color3.fromRGB(200,60,60); closeButton.Text = "✕"
closeButton.TextColor3 = Color3.fromRGB(255,255,255); closeButton.Font = Enum.Font.GothamBold; closeButton.TextSize = 14
Instance.new("UICorner", closeButton).CornerRadius = UDim.new(0,6)

ToggleButton = Instance.new("TextButton", MainFrame)
ToggleButton.Name = "ToggleButton"; ToggleButton.Size = UDim2.new(0.9,0,0,45)
ToggleButton.Position = UDim2.new(0.05,0,0.3,0); ToggleButton.BackgroundColor3 = Color3.fromRGB(90,90,95)
ToggleButton.Text = "💡 ACTIVATE AI"; ToggleButton.TextColor3 = Color3.fromRGB(255,255,255)
ToggleButton.Font = Enum.Font.GothamBold; ToggleButton.TextSize = 14
Instance.new("UICorner", ToggleButton).CornerRadius = UDim.new(0,8)

local modeButton = Instance.new("TextButton", MainFrame)
modeButton.Size = UDim2.new(0.43,0,0,35); modeButton.Position = UDim2.new(0.05,0,0.65,0)
modeButton.BackgroundColor3 = PRIVATE_MODE and Color3.fromRGB(150,80,200) or Color3.fromRGB(80,150,200)
modeButton.Text = PRIVATE_MODE and "🔐 PRIVATE" or "🌍 PUBLIC"
modeButton.TextColor3 = Color3.fromRGB(255,255,255); modeButton.Font = Enum.Font.GothamSemibold; modeButton.TextSize = 11
Instance.new("UICorner", modeButton).CornerRadius = UDim.new(0,8)
modeButton.MouseButton1Click:Connect(function()
    PRIVATE_MODE = not PRIVATE_MODE
    modeButton.BackgroundColor3 = PRIVATE_MODE and Color3.fromRGB(150,80,200) or Color3.fromRGB(80,150,200)
    modeButton.Text = PRIVATE_MODE and "🔐 PRIVATE" or "🌍 PUBLIC"
end)

local clearHistoryButton = Instance.new("TextButton", MainFrame)
clearHistoryButton.Size = UDim2.new(0.43,0,0,35); clearHistoryButton.Position = UDim2.new(0.52,0,0.65,0)
clearHistoryButton.BackgroundColor3 = Color3.fromRGB(200,100,60); clearHistoryButton.Text = "🗑️ CLEAR"
clearHistoryButton.TextColor3 = Color3.fromRGB(255,255,255); clearHistoryButton.Font = Enum.Font.GothamSemibold; clearHistoryButton.TextSize = 11
Instance.new("UICorner", clearHistoryButton).CornerRadius = UDim.new(0,8)

ConsoleLabel = Instance.new("TextLabel", MainFrame)
ConsoleLabel.Name = "ConsoleLabel"; ConsoleLabel.Size = UDim2.new(0.9,0,0,15)
ConsoleLabel.Position = UDim2.new(0.05,0,0.93,0); ConsoleLabel.BackgroundTransparency = 1
ConsoleLabel.Text = "System Ready"; ConsoleLabel.TextColor3 = Color3.fromRGB(140,140,145)
ConsoleLabel.Font = Enum.Font.Code; ConsoleLabel.TextSize = 9; ConsoleLabel.TextXAlignment = Enum.TextXAlignment.Left

-- ShowButton
ShowButton = Instance.new("TextButton")
ShowButton.Name = "ShowButton"; ShowButton.Size = UDim2.new(0,100,0,35)
ShowButton.Position = UDim2.new(0.5,-50,0.02,0); ShowButton.BackgroundColor3 = Color3.fromRGB(20,20,25)
ShowButton.BackgroundTransparency = 1; ShowButton.Text = "MOSTRAR"
ShowButton.TextColor3 = Color3.fromRGB(100,200,255); ShowButton.TextTransparency = 1
ShowButton.Font = Enum.Font.GothamBold; ShowButton.TextSize = 12; ShowButton.Visible = false
ShowButton.Parent = ScreenGui
Instance.new("UICorner", ShowButton).CornerRadius = UDim.new(0,8)

-- ============================================================
-- HISTORIAL DE CHAT POR USUARIO
-- ============================================================
local UserChatHistories    = {}
local HISTORY_FILE_NAME    = "Lux_UserChatHistories.json"
local MAX_USER_HISTORY     = 12
local ActiveConversations  = {}
local ACTIVE_CONVERSATIONS_FILE = "Lux_ActiveConversations.json"
local CONVERSATION_TIMEOUT = 900
local LastMessageTime      = {}

local function SaveChatHistory()
    if not writefile then return end
    pcall(function()
        writefile(HISTORY_FILE_NAME, HttpService:JSONEncode({histories=UserChatHistories, lastSaved=os.time()}))
    end)
end

local function LoadChatHistory()
    if not isfile or not isfile(HISTORY_FILE_NAME) then return end
    pcall(function()
        local data = HttpService:JSONDecode(readfile(HISTORY_FILE_NAME))
        if data.histories then UserChatHistories = data.histories end
    end)
end

local function ClearChatHistory()
    UserChatHistories = {}; SaveChatHistory()
end

local function GetUserHistory(userId)
    if not UserChatHistories[userId] then
        UserChatHistories[userId] = {history={}, lastUpdate=tick()}
    end
    return UserChatHistories[userId].history
end

local function AddToUserHistory(userId, role, text)
    local history = GetUserHistory(userId)
    table.insert(history, {role=role, parts={{text=text}}})
    while #history > MAX_USER_HISTORY do table.remove(history,1) end
    UserChatHistories[userId].lastUpdate = tick()
    SaveChatHistory()
end

local function SaveActiveConversations()
    if not writefile then return end
    pcall(function()
        local saveData = {}
        for userId in pairs(ActiveConversations) do table.insert(saveData, userId) end
        writefile(ACTIVE_CONVERSATIONS_FILE, HttpService:JSONEncode(saveData))
    end)
end

local function LoadActiveConversations()
    if not isfile or not isfile(ACTIVE_CONVERSATIONS_FILE) then return end
    pcall(function()
        local saveData = HttpService:JSONDecode(readfile(ACTIVE_CONVERSATIONS_FILE))
        for _, userId in ipairs(saveData) do ActiveConversations[userId] = true end
    end)
end

local function AddToActiveConversation(userId)
    if not ActiveConversations[userId] then
        ActiveConversations[userId] = true; SaveActiveConversations()
    end
    LastMessageTime[userId] = tick()
end

local function IsInActiveConversation(userId) return ActiveConversations[userId] == true end

local function RemoveFromActiveConversation(userId)
    if ActiveConversations[userId] then
        ActiveConversations[userId] = nil; LastMessageTime[userId] = nil; SaveActiveConversations()
    end
end

local function CleanupInactiveConversations()
    local now = tick()
    for userId in pairs(ActiveConversations) do
        if now - (LastMessageTime[userId] or 0) > CONVERSATION_TIMEOUT then
            RemoveFromActiveConversation(userId)
        end
    end
end

local function GetActiveConversationsCount()
    local n = 0; for _ in pairs(ActiveConversations) do n = n + 1 end; return n
end

-- ============================================================
-- CHAT → ROBLOX
-- ============================================================
local TextChatService    = game:GetService("TextChatService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local function SendChatMessage(text)
    if not text or text:gsub("%s+","") == "" then return end
    local sent = false
    if not sent and TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
        local channels = TextChatService:FindFirstChild("TextChannels")
        if channels then
            local ch = channels:FindFirstChild("RBXGeneral") or channels:FindFirstChild("General")
            if ch then pcall(function() ch:SendAsync("[Lux]: "..text); sent = true end) end
        end
    end
    if not sent then
        local cfg = TextChatService:FindFirstChild("ChatInputBarConfiguration")
        if cfg and cfg.TargetTextChannel then
            pcall(function() cfg.TargetTextChannel:SendAsync("[Lux]: "..text); sent = true end)
        end
    end
    if not sent then
        local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if events then
            local sayReq = events:FindFirstChild("SayMessageRequest")
            if sayReq then pcall(function() sayReq:FireServer("[Lux]: "..text,"All"); sent = true end) end
        end
    end
    if not sent then pcall(function() game:GetService("Players"):Chat("[Lux]: "..text) end) end
end

-- ============================================================
-- PEDIR A LA IA
-- ============================================================
local function AskAI(userMessage, playerName, playerUserId)
    if API_KEY == "" or not _G.LuxAPIReady then return nil, "API Key no configurada" end
    if not Settings.AI_Enabled then return nil, "IA no activada" end
    if tick() < Settings.NextReqTime then return nil, "Cooldown activo" end
    if Settings.IsThinking then return nil, "Ya estoy procesando otra petición" end
    if Settings.IsServerBusy then
        if not Settings.IsProbing then task.spawn(ProbeServer) end
        return nil, "Servidor ocupado"
    end
    Settings.IsThinking = true; ThinkingStartTime = tick()
    UpdateConsole("Processing: " .. userMessage:sub(1,20), "Thinking...")

    local environmentContext = FormatEnvironmentForLux()
    local personality = [[
You are Lux, a friendly AI assistant with script execution and environment perception capabilities.
PERSONALITY: Friendly, casual, Spanish, max 200 chars per message, no asterisks for actions.
ENVIRONMENT: You receive real-time JSON data. NEVER invent player names or positions.
SCRIPTS (PRIVATE mode only): reply [EXECUTE:keyword] to run scripts.
Keywords: grip, proteger, vuelo, inf yield, nameless.
Player: ]] .. playerName .. [[
Time: ]] .. os.date("%H:%M") .. [[
Mode: ]] .. (PRIVATE_MODE and "PRIVATE" or "PUBLIC")

    local url, requestBody, headers
    if API_PROVIDER == "groq" then
        url     = GROQ_MODEL_URL
        headers = {["Content-Type"]="application/json", ["Authorization"]="Bearer "..API_KEY}
        local messages = {
            {role="system", content=personality},
            {role="system", content="DATOS REALES DEL JUEGO:\n"..environmentContext},
        }
        for _, msg in ipairs(GetUserHistory(playerUserId)) do
            table.insert(messages, {role = msg.role == "user" and "user" or "assistant", content = msg.parts[1].text})
        end
        table.insert(messages, {role="user", content=userMessage})
        requestBody = HttpService:JSONEncode({model=GROQ_MODEL, messages=messages, max_tokens=120, temperature=0.9})
    else
        url     = GEMINI_MODEL_URL .. "?key=" .. API_KEY
        headers = {["Content-Type"]="application/json"}
        local contents = {}
        for _, msg in ipairs(GetUserHistory(playerUserId)) do table.insert(contents, msg) end
        table.insert(contents, {role="user", parts={{text=userMessage}}})
        requestBody = HttpService:JSONEncode({
            systemInstruction = {parts={{text=personality.."\nDATOS REALES:\n"..environmentContext}}},
            contents          = contents,
            generationConfig  = {maxOutputTokens=120, temperature=0.9, topP=0.95, topK=40},
        })
    end

    local ok, res = pcall(function()
        return HttpRequest({Url=url, Method="POST", Headers=headers, Body=requestBody})
    end)
    Settings.IsThinking = false

    if ok and res and res.Body then
        local data
        local decOk = pcall(function() data = HttpService:JSONDecode(res.Body) end)
        if not decOk then UpdateConsole("Error: JSON Decode Failed"); return nil, "Error decodificando respuesta" end
        local reply
        if API_PROVIDER == "groq" then
            if data.choices and data.choices[1] and data.choices[1].message then
                reply = data.choices[1].message.content
            elseif data.error then return nil, data.error.message or "Error de Groq" end
        else
            if data.candidates and data.candidates[1] and data.candidates[1].content then
                reply = data.candidates[1].content.parts[1].text
            elseif data.error then
                if data.error.code == 429 or data.error.code == 503 then
                    Settings.IsServerBusy = true; BusyStartTime = tick()
                    if not Settings.IsProbing then task.spawn(ProbeServer) end
                    return nil, "Servidor ocupado"
                end
                return nil, data.error.message or "Error de Gemini"
            end
        end
        if reply then
            reply = reply:gsub("^%s+",""):gsub("%s+$","")
            if #reply > 200 then reply = reply:sub(1,197) .. "..." end
            if PRIVATE_MODE and reply:match("%[EXECUTE:") then
                local keyword = reply:match("%[EXECUTE:(.-)%]")
                if keyword then
                    local script, suggestions = FindScriptByKeyword(keyword)
                    if script then
                        local execOk, execErr = SafeExecuteScript(script.url)
                        reply = execOk and ("✅ " .. script.name .. " ejecutado!") or ("❌ Error: " .. execErr)
                    elseif suggestions and #suggestions > 0 then
                        reply = "🤔 ¿Quisiste decir: " .. suggestions[1].keyword .. "?"
                    else
                        reply = "❌ Script no encontrado."
                    end
                end
            end
            AddToUserHistory(playerUserId, "user", userMessage)
            AddToUserHistory(playerUserId, "model", reply)
            UpdateConsole("Response OK | User: " .. tostring(playerUserId), "Sent")
            Settings.NextReqTime = tick() + 4
            return reply, nil
        else
            UpdateConsole("Empty Response"); return nil, "Respuesta vacía"
        end
    else
        UpdateConsole("Network Error"); return nil, "Error de conexión"
    end
end

-- ============================================================
-- MANEJAR MENSAJE DE CHAT
-- ============================================================
local BOT_NAME      = "lux"
local CHAT_COOLDOWN = 3
local lastChatTime  = 0

local function HandleChatMessage(player, messageText)
    if not Settings.AI_Enabled or not _G.LuxAPIReady then return end
    if PRIVATE_MODE and player ~= scriptOwner then return end
    if not PRIVATE_MODE and player == scriptOwner then return end

    -- Filtro de distancia: 9 studs
    local ownerChar  = scriptOwner.Character
    local playerChar = player.Character
    if ownerChar and playerChar then
        local ownerRoot  = ownerChar:FindFirstChild("HumanoidRootPart")
        local playerRoot = playerChar:FindFirstChild("HumanoidRootPart")
        if ownerRoot and playerRoot then
            if (ownerRoot.Position - playerRoot.Position).Magnitude > 9 then return end
        end
    end

    local userId       = player.UserId
    local lowerMessage = messageText:lower()
    local startsWithLux = lowerMessage:match("^" .. BOT_NAME)
    local isInConv      = IsInActiveConversation(userId)

    local userMessage = ""
    if startsWithLux then
        userMessage = messageText:sub(#BOT_NAME + 1):gsub("^%s+","")
        if not isInConv then
            AddToActiveConversation(userId)
            if userMessage == "" or #userMessage < 2 then
                SendChatMessage("¡Hola! Ya no necesitas decir 'lux' antes de cada mensaje 😊"); return
            end
        end
    elseif isInConv then
        userMessage = messageText
        AddToActiveConversation(userId)
    else
        return
    end
    if #userMessage < 1 then return end

    -- Comandos especiales
    local lMsg = userMessage:lower()

    if lMsg == "adios" or lMsg == "chao" or lMsg == "salir" then
        local ok, rem = CanUseCommand(userId, "salir")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        RemoveFromActiveConversation(userId); SendChatMessage("¡Hasta luego! 👋"); return
    end

    if lMsg == "olvida" or lMsg == "resetear" or lMsg == "clear" then
        local ok, rem = CanUseCommand(userId, "olvida")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        UserChatHistories[userId] = nil; SaveChatHistory()
        SendChatMessage("Historial limpiado 🔄"); return
    end

    if lMsg == "entorno" or lMsg == "alrededor" or lMsg == "quien esta aqui" then
        local ok, rem = CanUseCommand(userId, "entorno")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        SendChatMessage(GetEnvironmentSummary()); return
    end

    if lMsg:match("^donde esta%s+") or lMsg:match("^ubicacion%s+") then
        local ok, rem = CanUseCommand(userId, "buscar")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        local pName = lMsg:match("^donde esta%s+(.+)") or lMsg:match("^ubicacion%s+(.+)")
        if pName then
            local pdata = FindPlayerByName(pName)
            if pdata then
                SendChatMessage(string.format("%s está a %d studs (HP: %d/%d)", pdata.name, pdata.distanceFromYou, pdata.health, pdata.maxHealth))
            else
                SendChatMessage("No encontré a '" .. pName .. "'")
            end
        end
        return
    end

    if lMsg == "cercanos" or lMsg == "quien cerca" then
        local ok, rem = CanUseCommand(userId, "cercanos")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        local env = ScanEnvironment()
        if env and #env.nearestPlayers > 0 then
            local names = {}
            for i = 1, math.min(3, #env.nearestPlayers) do
                local p = env.nearestPlayers[i]; table.insert(names, p.name.." ("..p.distanceFromYou.." studs)")
            end
            SendChatMessage("Cercanos: " .. table.concat(names, ", "))
        else
            SendChatMessage("No hay jugadores cerca")
        end
        return
    end

    if lMsg == "enemigos" or lMsg == "hostiles" then
        UpdateEnemyHighlights()
        SendChatMessage(FormatEnemyList(GetNearbyEnemies(50), 3)); return
    end

    if lMsg == "limpiar" then ClearAllHighlights(); SendChatMessage("Highlights eliminados ✨"); return end

    if lMsg:match("^buscar%s+") or lMsg:match("^find%s+") then
        local term = lMsg:match("^buscar%s+(.+)") or lMsg:match("^find%s+(.+)")
        if term then
            local matches = FindMapObject(term)
            if #matches > 0 then
                local best = matches[1]
                SendChatMessage(FormatObjectInfo(best.name, best.data) .. " | di tp para ir")
                _G.LuxLastFoundObject = best.data
                local function findInWS(n)
                    for _, obj in pairs(workspace:GetDescendants()) do
                        if obj.Name == n and (obj:IsA("BasePart") or obj:IsA("Model")) then return obj end
                    end
                end
                local found = findInWS(best.name)
                if found then HighlightObject(best.name, found) end
            else
                SendChatMessage("no encontrado, intenta en inglés")
            end
        end
        return
    end

    if lMsg == "tp" or lMsg == "teleport" or lMsg == "ir" then
        if _G.LuxLastFoundObject then
            local ok2, msg2 = TeleportToObject(_G.LuxLastFoundObject)
            SendChatMessage(ok2 and "tp exitoso ✅" or "error: "..msg2)
            _G.LuxLastFoundObject = nil
        else
            SendChatMessage("primero busca un objeto")
        end
        return
    end

    if lMsg:match("^tp a%s+") then
        local ok, rem = CanUseCommand(userId, "tpplayer")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        local searchName = lMsg:match("^tp a%s+(.+)")
        if searchName and #searchName >= 3 then
            local bestMatch = nil
            for _, pl in ipairs(Players:GetPlayers()) do
                local dn = (pl.DisplayName or ""):lower()
                local un = pl.Name:lower()
                if dn:find(searchName,1,true) or un:find(searchName,1,true) then bestMatch = pl; break end
            end
            if bestMatch and bestMatch.Character then
                local tarRoot = bestMatch.Character:FindFirstChild("HumanoidRootPart")
                local myRoot  = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
                if tarRoot and myRoot then
                    myRoot.CFrame = CFrame.new(tarRoot.Position + Vector3.new(3,0,3))
                    SendChatMessage("TP a " .. (bestMatch.DisplayName or bestMatch.Name) .. " ✅")
                else SendChatMessage("error de personaje") end
            else SendChatMessage("no encontré a '"..searchName.."'") end
        else SendChatMessage("nombre muy corto (min 3 letras)") end
        return
    end

    if lMsg == "estado" or lMsg == "status" then
        local ok, rem = CanUseCommand(userId, "estado")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        local hist = GetUserHistory(userId)
        SendChatMessage("Convs: "..GetActiveConversationsCount().." | Tu historial: "..#hist.." msgs"); return
    end

    if lMsg:match("bail") or lMsg:match("dance") then
        local ok, rem = CanUseCommand(userId, "baila")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        local s, m = MakeCharacterDance(); SendChatMessage((s and "💃 " or "❌ ") .. m); return
    end

    if lMsg == "detener baile" or lMsg == "stop dance" or lMsg == "para de bailar" then
        local s, m = StopCharacterDance(); SendChatMessage((s and "🛑 " or "❌ ") .. m); return
    end

    if lMsg:match("^sigu") or lMsg:match("^seg") or lMsg == "ven" then
        local ok, rem = CanUseCommand(userId, "seguir")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        local s, m = FollowPlayer(player)
        SendChatMessage(s and "¡Voy para allá! 🏃" or "No puedo: "..m); return
    end

    if lMsg == "detente" or lMsg == "para" or lMsg == "quieto" then
        local ok, rem = CanUseCommand(userId, "detener")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        if FollowTarget then StopFollowing(); SendChatMessage("Me detengo 🛑")
        else SendChatMessage("No estoy siguiendo a nadie") end
        return
    end

    if PRIVATE_MODE and (lMsg == "scripts" or lMsg == "lista") then
        local ok, rem = CanUseCommand(userId, "scripts")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        SendChatMessage("📜 Scripts: GRIP, God Mode, Fly, Infinite Yield, Nameless. Di 'ejecuta [nombre]'"); return
    end

    if PRIVATE_MODE and lMsg:match("^ejecuta?%s+") then
        local ok, rem = CanUseCommand(userId, "ejecutar")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        local kw = lMsg:match("^ejecuta?%s+(.+)")
        if kw then
            local script, suggestions = FindScriptByKeyword(kw)
            if script then
                local s, e = SafeExecuteScript(script.url)
                SendChatMessage(s and "✅ "..script.name.." ejecutado!" or "❌ Error: "..e)
            elseif suggestions and #suggestions > 0 then
                SendChatMessage("🤔 ¿Quisiste decir: "..suggestions[1].keyword.."?")
            else SendChatMessage("❌ Script no encontrado.") end
        end
        return
    end

    if PRIVATE_MODE and (lMsg:match("proteg") or lMsg == "god" or lMsg == "godmode") then
        local ok, rem = CanUseCommand(userId, "godmode")
        if not ok then SendChatMessage("Espera "..rem.."s ⏳"); return end
        if GodModeActive then SendChatMessage("Ya estoy en modo protección 🛡️")
        else
            local s, m = ActivateGodModeWithDodge()
            SendChatMessage(s and "🛡️ Protección + Esquive activado!" or "❌ "..m)
        end
        return
    end

    if lMsg:match("dejar de proteg") or lMsg:match("no proteg") or lMsg == "desactivar god" then
        if not GodModeActive then SendChatMessage("No estoy en modo protección")
        else DeactivateGodMode(); SendChatMessage("🛑 Protección desactivada") end
        return
    end

    -- Cooldown global
    if tick() - lastChatTime < CHAT_COOLDOWN then return end
    lastChatTime = tick()

    task.spawn(function()
        local response, err = AskAI(userMessage, player.DisplayName or player.Name, userId)
        if response then
            SendChatMessage(response)
        elseif err == "Servidor ocupado" then
            SendChatMessage("Un momento... ⏳")
        end
    end)
end

-- ============================================================
-- EVENTOS DE UI
-- ============================================================
local function ShowFeedback(message, isSuccess)
    local lbl = Instance.new("TextLabel", MainFrame)
    lbl.Size = UDim2.new(1,-40,0,28); lbl.Position = UDim2.new(0,20,0,165)
    lbl.BackgroundColor3 = isSuccess and Color3.fromRGB(60,180,100) or Color3.fromRGB(220,70,70)
    lbl.Text = message; lbl.TextColor3 = Color3.fromRGB(255,255,255)
    lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 11; lbl.BackgroundTransparency = 0
    Instance.new("UICorner", lbl).CornerRadius = UDim.new(0,6)
    task.wait(2.5)
    TweenService:Create(lbl, TweenInfo.new(0.5), {TextTransparency=1, BackgroundTransparency=1}):Play()
    task.delay(0.55, function() lbl:Destroy() end)
end

closeButton.MouseButton1Click:Connect(function()
    HideMainFrameWithAnimation(function()
        ShowButton.Visible = true
        TweenService:Create(ShowButton, TweenInfo.new(0.3), {BackgroundTransparency=0.5, TextTransparency=0}):Play()
    end)
end)

ShowButton.MouseButton1Click:Connect(function()
    TweenService:Create(ShowButton, TweenInfo.new(0.2), {BackgroundTransparency=1, TextTransparency=1}):Play()
    task.delay(0.22, function() ShowButton.Visible = false end)
    ShowMainFrameWithAnimation()
end)

clearHistoryButton.MouseButton1Click:Connect(function()
    ClearChatHistory(); clearHistoryButton.Text = "✓ DONE"
    task.delay(1, function() clearHistoryButton.Text = "🗑️ CLEAR" end)
end)

ValidateButton.MouseButton1Click:Connect(function()
    local apiKey = APIKeyBox.Text:gsub("%s+","")
    if apiKey == "" then
        APIKeyBox.PlaceholderText = "⚠️ Please enter a key!"; APIKeyBox.PlaceholderColor3 = Color3.fromRGB(220,70,70)
        task.delay(2, function()
            APIKeyBox.PlaceholderText = "Paste your API key here..."; APIKeyBox.PlaceholderColor3 = Color3.fromRGB(120,120,125)
        end)
        return
    end
    ValidateButton.Text = "⏳ VALIDATING..."; ValidateButton.BackgroundColor3 = Color3.fromRGB(120,120,125)
    task.spawn(function()
        local isValid, message = ValidateAPIKey(apiKey, true)
        if isValid then
            API_KEY = apiKey; SaveAPIKey(apiKey); SaveValidation(apiKey, API_PROVIDER)
            ValidateButton.Text = "✅ VALIDATED!"; ValidateButton.BackgroundColor3 = Color3.fromRGB(60,180,100)
            _G.LuxAPIKey = apiKey; _G.LuxAPIReady = true
            task.wait(0.8)
            CloseAuthWithAnimation(AuthFrame, function()
                ShowMainFrameWithAnimation()
                Settings.AI_Enabled = true
                ToggleButton.Text = "💡 AI ACTIVE"; ToggleButton.BackgroundColor3 = Color3.fromRGB(60,180,100)
                _G.LuxAIEnabled = true; UpdateConsole("AI Active","Ready")
            end)
        elseif message == "BUSY" then
            ValidateButton.Text = "⏳ Server busy..."; task.wait(2)
            ValidateButton.Text = "✓ VALIDATE & START"; ValidateButton.BackgroundColor3 = Color3.fromRGB(80,160,255)
        else
            ValidateButton.Text = "❌ " .. (message or "Error"); ValidateButton.BackgroundColor3 = Color3.fromRGB(220,70,70)
            task.wait(2); ValidateButton.Text = "✓ VALIDATE & START"; ValidateButton.BackgroundColor3 = Color3.fromRGB(80,160,255)
        end
    end)
end)

ToggleButton.MouseButton1Click:Connect(function()
    if API_KEY == "" or not _G.LuxAPIReady then ShowFeedback("⚠️ Validate API Key first", false); return end
    Settings.AI_Enabled = not Settings.AI_Enabled
    if Settings.AI_Enabled then
        ToggleButton.Text = "💡 AI ACTIVE"; ToggleButton.BackgroundColor3 = Color3.fromRGB(60,180,100)
        ShowFeedback("✅ Lux AI activated", true); UpdateConsole("AI Status","ACTIVE"); _G.LuxAIEnabled = true
    else
        ToggleButton.Text = "💡 ACTIVATE AI"; ToggleButton.BackgroundColor3 = Color3.fromRGB(90,90,95)
        ShowFeedback("⏸️ Lux AI deactivated", true); UpdateConsole("AI Status","STANDBY"); _G.LuxAIEnabled = false
    end
end)

-- Auto-reset thinking
task.spawn(function()
    while ScreenGui.Parent do
        task.wait(2)
        if Settings.IsThinking and (tick() - ThinkingStartTime > API_TIMEOUT_SECONDS + 1) then
            Settings.IsThinking = false; UpdateConsole("Auto-Reset","Idle")
        end
    end
end)

-- ============================================================
-- INICIO AUTOMÁTICO
-- ============================================================
task.spawn(function()
    task.wait(0.5)
    local savedKey, savedProvider = LoadValidation()
    if savedKey then
        API_KEY = savedKey; API_PROVIDER = savedProvider or "gemini"
        _G.LuxAPIKey = savedKey; _G.LuxAPIReady = true
        ShowMainFrameWithAnimation()
        task.wait(0.3)
        Settings.AI_Enabled = true
        ToggleButton.Text = "💡 AI ACTIVE"; ToggleButton.BackgroundColor3 = Color3.fromRGB(60,180,100)
        _G.LuxAIEnabled = true; UpdateConsole("AI Active","Auto-started")
    else
        AuthFrame.Visible = true
        local oldKey = LoadAPIKey()
        if oldKey then APIKeyBox.Text = oldKey end
    end
end)

-- ============================================================
-- CONECTAR CHAT
-- ============================================================
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    TextChatService.MessageReceived:Connect(function(textChatMessage)
        if not textChatMessage.TextSource then return end
        local player = Players:GetPlayerByUserId(textChatMessage.TextSource.UserId)
        if not player then return end
        if PRIVATE_MODE then
            if player == scriptOwner then HandleChatMessage(player, textChatMessage.Text) end
        else
            if player ~= scriptOwner then HandleChatMessage(player, textChatMessage.Text) end
        end
    end)
else
    local function ConnectPlayerChat(player)
        if not player then return end
        player.Chatted:Connect(function(message)
            if PRIVATE_MODE then
                if player == scriptOwner then HandleChatMessage(player, message) end
            else
                if player.UserId ~= scriptOwner.UserId then HandleChatMessage(player, message) end
            end
        end)
    end
    for _, player in pairs(Players:GetPlayers()) do ConnectPlayerChat(player) end
    Players.PlayerAdded:Connect(ConnectPlayerChat)
end

-- ============================================================
-- LOOPS DE MANTENIMIENTO
-- ============================================================
LoadChatHistory()
LoadActiveConversations()
LoadMapData()

task.spawn(function()
    while ScreenGui.Parent do task.wait(60); CleanupInactiveConversations() end
end)

task.spawn(function()
    while ScreenGui.Parent do
        task.wait(3)
        if Settings.AI_Enabled then UpdateEnemyHighlights() end
    end
end)

task.spawn(function()
    while ScreenGui.Parent do
        task.wait(0.5)
        if Settings.AI_Enabled then UpdateObjectHighlights() end
    end
end)

-- Limpieza al cerrar
ScreenGui.AncestryChanged:Connect(function()
    if not ScreenGui.Parent then
        StopFollowing(); DeactivateGodMode(); ClearAllHighlights()
    end
end)

print("[Lux] Sistema cargado correctamente")
print("[Lux] Modo:", PRIVATE_MODE and "PRIVADO (solo dueño)" or "PÚBLICO")
print("[Lux] Di 'lux hola' para iniciar conversación")
