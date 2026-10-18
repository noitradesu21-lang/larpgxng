--[[
    snivy | larp tool
    UI: Obsidian Library (https://raw.githubusercontent.com/deividcomsono/Obsidian/main/)
    Features:
      * Accessory Resizer & Positional Offset:
          - Real-time uniform scaling (0.1x - 5.0x)
          - Height (Y) and Depth (Z) offset adjustments
          - Supports both Session Accessories and All Character Accessories
          - Automatically scales newly equipped accessories to match current sliders
      * Headless & Korblox engine powered by SpecialMesh injection (from deobfuscated (7).lua):
          - Korblox Mesh: rbxassetid://101851696 | Texture: rbxassetid://101851254
          - Headless Mesh: rbxassetid://123456789
          - When Headless turns off: restores head mesh and applies default face (rbxasset://textures/face.png)
          - Korblox Left Leg removed (Korblox is Right Leg only)
          - ChildAdded listener + 0.6s persistent loop ensuring mods stay applied
      * Universal R6 & R15 Rig Compatibility (Evade, Violence District, custom rigs)
      * Multi-Container Map Visual Sync (workspace.Game.Players, workspace.Players, workspace)
      * Notification Toggle (mute or show notifications anytime)
      * Asset Equipper (Accessories, Clothing, Tools) accepting IDs & URLs
      * Universal Attachment Mapper for R6 avatars
      * Preset Manager (Save, Load, Delete, JSON persistence)
      * Full ThemeManager and SaveManager integration
      * Toggle with P keybind (customizable)
]]

-- Unload previous instance if active
if getgenv().SnivyLarpUnload then
    getgenv().SnivyLarpUnload()
end

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()

local Options = Library.Options
local Toggles = Library.Toggles

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local CONFIG_FILE = "larp_configs.json"

-- Notification state
local notificationsEnabled = true

local function Notify(title, desc, duration)
    if not notificationsEnabled then return end
    Library:Notify({
        Title = title or "Larp Tool",
        Description = desc or "",
        Time = duration or 3,
    })
end

-- ====================================================================
-- DEOBFUSCATED (7).LUA ENGINE CONSTANTS & HELPERS
-- ====================================================================

local S1_KORBLOX_MESH    = "rbxassetid://101851696"
local S2_KORBLOX_TEXTURE = "rbxassetid://101851254"
local S3_HEADLESS_MESH   = "rbxassetid://123456789"
local DEFAULT_FACE       = "rbxasset://textures/face.png"
local LOOP_INTERVAL      = 0.6

local T1_HEAD_PARTS = {
    [1] = "Head",
}

local T2_RIGHT_LEG_PARTS = {
    [1] = "Right Leg",
    [2] = "RightLowerLeg",
    [3] = "RightUpperLeg",
    [4] = "RightFoot",
}

-- u9: find first matching part name from list
local function u9_FindPart(model, partList)
    if not model then return nil end
    for _, name in ipairs(partList) do
        local found = model:FindFirstChild(name)
        if found then
            return found
        end
    end
    return nil
end

-- u10: check if part already has target SpecialMesh
local function u10_HasSpecialMesh(part, meshId, textureId)
    if not part then return false end
    for _, child in ipairs(part:GetChildren()) do
        if child:IsA("SpecialMesh") and tostring(child.MeshId) == tostring(meshId) and (textureId == "" or tostring(child.TextureId) == tostring(textureId)) then
            return true
        end
    end
    return false
end

-- u11: replace/create SpecialMesh inside part
local function u11_SetSpecialMesh(part, meshId, textureId, scale)
    if not part then return end
    for _, child in ipairs(part:GetChildren()) do
        if child:IsA("SpecialMesh") then
            child:Destroy()
        end
    end
    local SpecialMesh = Instance.new("SpecialMesh")
    SpecialMesh.Name = "LarpSpecialMesh"
    SpecialMesh.MeshType = Enum.MeshType.FileMesh
    SpecialMesh.MeshId = meshId or ""
    SpecialMesh.TextureId = textureId or ""
    SpecialMesh.Scale = scale or Vector3.new(1, 1, 1)
    SpecialMesh.Parent = part
    return SpecialMesh
end

-- Mod State (Korblox Right Leg & Headless)
local korbloxActive = false
local headlessActive = false
local autoSyncEnabled = true

local equippedSession = {}       -- List of asset IDs
local equippedInstances = {}     -- [instance] = true
local connections = {}
local watchedModels = {}

-- Accessory Resizer State
local currentAccessoryScale = 1
local currentAccessoryOffsetY = 0
local currentAccessoryOffsetZ = 0
local resizeTargetMode = "Session Accessories" -- "Session Accessories" or "All Character Accessories"
local accessoryProps = {} -- [Accessory] = { Handle, Weld, SpecialMesh, OriginalSize, OriginalMeshScale, OriginalC0 }

-- ====================================================================
-- MULTI-CONTAINER MAP MODEL RESOLVER (Evade, Violence District, R6)
-- ====================================================================

local function GetVisualModels()
    local models = {}
    local seen = {}

    local function addModel(m)
        if m and m:IsA("Model") and not seen[m] then
            seen[m] = true
            table.insert(models, m)
        end
    end

    -- 1. Standard Character
    if LocalPlayer.Character then
        addModel(LocalPlayer.Character)
    end

    -- 2. Evade Container: workspace.Game.Players[LocalPlayer.Name]
    local gameFolder = workspace:FindFirstChild("Game")
    if gameFolder then
        local playersFolder = gameFolder:FindFirstChild("Players")
        if playersFolder then
            local evadeChar = playersFolder:FindFirstChild(LocalPlayer.Name)
            if evadeChar then
                addModel(evadeChar)
            end
        end
    end

    -- 3. Common Framework Container: workspace.Players[LocalPlayer.Name]
    local wPlayers = workspace:FindFirstChild("Players")
    if wPlayers and wPlayers:IsA("Folder") then
        local pChar = wPlayers:FindFirstChild(LocalPlayer.Name)
        if pChar then
            addModel(pChar)
        end
    end

    -- 4. Direct Workspace Model: workspace[LocalPlayer.Name]
    local directChar = workspace:FindFirstChild(LocalPlayer.Name)
    if directChar and directChar:IsA("Model") then
        addModel(directChar)
    end

    return models
end

local function GetRigType(model)
    if not model then return "Unknown" end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid then
        if humanoid.RigType == Enum.HumanoidRigType.R6 then
            return "R6"
        elseif humanoid.RigType == Enum.HumanoidRigType.R15 then
            return "R15"
        end
    end
    if model:FindFirstChild("Torso") and model:FindFirstChild("Right Leg") then
        return "R6"
    elseif model:FindFirstChild("UpperTorso") or model:FindFirstChild("RightUpperLeg") then
        return "R15"
    end
    return "Unknown"
end

-- ====================================================================
-- ACCESSORY RESIZER & OFFSET ENGINE
-- ====================================================================

local function CacheAccessoryData(acc)
    if not acc or not acc:IsA("Accessory") then return nil end
    if accessoryProps[acc] then return accessoryProps[acc] end

    local handle = acc:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then return nil end

    local weld = handle:FindFirstChildWhichIsA("Weld")
        or handle:FindFirstChildWhichIsA("Motor6D")
        or handle:FindFirstChildWhichIsA("WeldConstraint")
    local sm = handle:FindFirstChildWhichIsA("SpecialMesh")

    local data = {
        Handle = handle,
        Weld = weld,
        SpecialMesh = sm,
        OriginalSize = handle.Size,
        OriginalMeshScale = sm and sm.Scale or Vector3.new(1, 1, 1),
        OriginalC0 = (weld and typeof(weld.C0) == "CFrame") and weld.C0 or CFrame.new(),
    }
    accessoryProps[acc] = data
    return data
end

local function ApplyScaleToAccessory(acc, scaleFactor, offsetY, offsetZ)
    local data = CacheAccessoryData(acc)
    if not data then return end

    scaleFactor = math.clamp(scaleFactor or 1, 0.05, 20)
    offsetY = offsetY or 0
    offsetZ = offsetZ or 0

    local handle = data.Handle
    local sm = data.SpecialMesh
    local weld = data.Weld

    -- 1. Resize Handle Part
    pcall(function()
        handle.Size = data.OriginalSize * scaleFactor
    end)

    -- 2. Resize SpecialMesh if present
    if sm and sm.Parent then
        pcall(function()
            sm.Scale = data.OriginalMeshScale * scaleFactor
        end)
    end

    -- 3. Adjust Weld C0 for scaling & positional offsets
    if weld and weld.Parent and typeof(weld.C0) == "CFrame" then
        pcall(function()
            local origPos = data.OriginalC0.Position
            local rot = data.OriginalC0 - origPos
            local scaledPos = origPos * scaleFactor
            local offsetVector = Vector3.new(0, -offsetY, -offsetZ)
            weld.C0 = CFrame.new(scaledPos + offsetVector) * rot
        end)
    end
end

local function GetTargetAccessories()
    local accs = {}
    local seen = {}

    if resizeTargetMode == "Session Accessories" then
        for inst, _ in pairs(equippedInstances) do
            if inst and inst.Parent and inst:IsA("Accessory") and not seen[inst] then
                seen[inst] = true
                table.insert(accs, inst)
            end
        end
    else
        -- All Character Accessories across active models
        for _, model in ipairs(GetVisualModels()) do
            for _, ch in ipairs(model:GetChildren()) do
                if ch:IsA("Accessory") and not seen[ch] then
                    seen[ch] = true
                    table.insert(accs, ch)
                end
            end
        end
    end
    return accs
end

local function UpdateAllAccessoryScales()
    local list = GetTargetAccessories()
    for _, acc in ipairs(list) do
        ApplyScaleToAccessory(acc, currentAccessoryScale, currentAccessoryOffsetY, currentAccessoryOffsetZ)
    end
end

-- ====================================================================
-- CORE MOD ENGINE (u12 & u13 from deobfuscated (7).lua)
-- ====================================================================

local function u12_ApplyMods(model)
    if not model or not model.Parent then return end

    -- 1. Headless (s3 = rbxassetid://123456789)
    if headlessActive then
        local headPart = u9_FindPart(model, T1_HEAD_PARTS) or model:FindFirstChild("Head")
        if headPart and S3_HEADLESS_MESH and S3_HEADLESS_MESH ~= "" then
            if not u10_HasSpecialMesh(headPart, S3_HEADLESS_MESH, "") then
                u11_SetSpecialMesh(headPart, S3_HEADLESS_MESH, "", Vector3.new(1, 1, 1))
            end
            headPart.Transparency = 1
            local face = headPart:FindFirstChild("face")
            if face and face:IsA("Decal") and face.Transparency ~= 1 then
                face.Transparency = 1
            end
        end
    end

    -- 2. Korblox Right Leg (s1 = rbxassetid://101851696, s2 = rbxassetid://101851254)
    if korbloxActive then
        local rightLegPart = u9_FindPart(model, T2_RIGHT_LEG_PARTS)
        if rightLegPart and S1_KORBLOX_MESH and S1_KORBLOX_MESH ~= "" then
            if not u10_HasSpecialMesh(rightLegPart, S1_KORBLOX_MESH, S2_KORBLOX_TEXTURE) then
                u11_SetSpecialMesh(rightLegPart, S1_KORBLOX_MESH, S2_KORBLOX_TEXTURE, Vector3.new(1, 1, 1))
            end
        end
        -- In R15, hide RightFoot so it doesn't block the toothpick bone
        local rFoot = model:FindFirstChild("RightFoot")
        if rFoot and rFoot:IsA("BasePart") then
            rFoot.Transparency = 1
        end
    end
end

local function u13_WatchModel(model)
    if not model or not model:IsA("Model") or watchedModels[model] then return end
    watchedModels[model] = true

    task.wait(0.08)
    local conn = model.ChildAdded:Connect(function(child)
        if child:IsA("BasePart") then
            task.wait(0.04)
            u12_ApplyMods(model)
        elseif child:IsA("Accessory") then
            task.wait(0.1)
            ApplyScaleToAccessory(child, currentAccessoryScale, currentAccessoryOffsetY, currentAccessoryOffsetZ)
        end
    end)
    table.insert(connections, conn)

    task.spawn(function()
        while model.Parent do
            if korbloxActive or headlessActive then
                u12_ApplyMods(model)
            end
            task.wait(LOOP_INTERVAL)
        end
        if conn then conn:Disconnect() end
        watchedModels[model] = nil
    end)
end

-- Clean reset helpers
local function ResetHeadOnModel(model)
    local head = u9_FindPart(model, T1_HEAD_PARTS) or model:FindFirstChild("Head")
    if head then
        for _, ch in ipairs(head:GetChildren()) do
            if ch:IsA("SpecialMesh") and tostring(ch.MeshId) == tostring(S3_HEADLESS_MESH) then
                ch:Destroy()
            end
        end

        local sm = head:FindFirstChildWhichIsA("SpecialMesh")
        if not sm then
            sm = Instance.new("SpecialMesh")
            sm.Name = "Mesh"
            sm.Parent = head
        end
        sm.MeshType = Enum.MeshType.Head
        sm.MeshId = ""
        sm.TextureId = ""
        sm.Scale = Vector3.new(1.25, 1.25, 1.25)

        head.Transparency = 0

        local face = head:FindFirstChild("face")
        if not face then
            face = Instance.new("Decal")
            face.Name = "face"
            face.Face = Enum.NormalId.Front
            face.Parent = head
        end
        face.Transparency = 0
        face.Texture = DEFAULT_FACE
    end
end

local function ResetKorbloxOnModel(model)
    for _, partName in ipairs(T2_RIGHT_LEG_PARTS) do
        local part = model:FindFirstChild(partName)
        if part then
            for _, ch in ipairs(part:GetChildren()) do
                if ch:IsA("SpecialMesh") and tostring(ch.MeshId) == tostring(S1_KORBLOX_MESH) then
                    ch:Destroy()
                end
            end
            part.Transparency = 0
        end
    end
end

-- Universal Action Handlers
local function ApplyKorbloxUniversal()
    korbloxActive = true
    local models = GetVisualModels()
    for _, m in ipairs(models) do
        u13_WatchModel(m)
        u12_ApplyMods(m)
    end
    Notify("Korblox", "Korblox (SpecialMesh) applied across " .. #models .. " model(s)!", 3)
end

local function ResetKorbloxUniversal()
    korbloxActive = false
    local models = GetVisualModels()
    for _, m in ipairs(models) do
        ResetKorbloxOnModel(m)
    end
    Notify("Korblox", "Korblox removed.", 2.5)
end

local function ApplyHeadlessUniversal()
    headlessActive = true
    local models = GetVisualModels()
    for _, m in ipairs(models) do
        u13_WatchModel(m)
        u12_ApplyMods(m)
    end
    Notify("Headless", "Headless applied across " .. #models .. " model(s)!", 3)
end

local function ResetHeadUniversal()
    headlessActive = false
    local models = GetVisualModels()
    for _, m in ipairs(models) do
        ResetHeadOnModel(m)
    end
    Notify("Headless", "Head restored with default face.", 2.5)
end

-- ====================================================================
-- UNIVERSAL ACCESSORY & CLOTHING ATTACHMENT (R6 & R15)
-- ====================================================================

local function AttachAccessoryToModel(model, accessory)
    local handle = accessory:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then return end

    handle.Transparency = 0
    handle.CanCollide = false
    handle.Anchored = false

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid then
        pcall(function() humanoid:AddAccessory(accessory) end)
    else
        accessory.Parent = model
    end

    task.delay(0.06, function()
        if not handle or not handle.Parent then return end

        local existingWeld = handle:FindFirstChildWhichIsA("Weld")
            or handle:FindFirstChildWhichIsA("Motor6D")
            or handle:FindFirstChildWhichIsA("WeldConstraint")
        if existingWeld and existingWeld.Part1 and existingWeld.Part1:IsDescendantOf(model) then
            CacheAccessoryData(accessory)
            ApplyScaleToAccessory(accessory, currentAccessoryScale, currentAccessoryOffsetY, currentAccessoryOffsetZ)
            return
        end

        local att = handle:FindFirstChildOfClass("Attachment")
        local targetPart = nil
        local targetCFrame = CFrame.new()
        local handleCFrame = att and att.CFrame or CFrame.new()

        if att then
            for _, part in ipairs(model:GetChildren()) do
                if part:IsA("BasePart") then
                    local matchAtt = part:FindFirstChild(att.Name)
                    if matchAtt and matchAtt:IsA("Attachment") then
                        targetPart = part
                        targetCFrame = matchAtt.CFrame
                        break
                    end
                end
            end
        end

        if not targetPart then
            local attName = att and att.Name or ""
            local rigType = GetRigType(model)

            if attName:find("Hat") or attName:find("Hair") then
                targetPart = model:FindFirstChild("Head")
                targetCFrame = CFrame.new(0, 0.6, 0)
            elseif attName:find("Face") then
                targetPart = model:FindFirstChild("Head")
                targetCFrame = CFrame.new(0, 0, -0.5)
            elseif attName:find("Neck") then
                targetPart = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso") or model:FindFirstChild("Head")
                targetCFrame = CFrame.new(0, 1, 0)
            elseif attName:find("Waist") or attName:find("Back") or attName:find("Body") or attName:find("Chest") then
                targetPart = model:FindFirstChild("Torso") or model:FindFirstChild("LowerTorso") or model:FindFirstChild("UpperTorso")
                if attName:find("Waist") then
                    targetCFrame = CFrame.new(0, -1, 0)
                elseif attName:find("Back") then
                    targetCFrame = CFrame.new(0, 0, 0.55)
                else
                    targetCFrame = CFrame.new(0, 0, -0.55)
                end
            elseif attName:find("RightShoulder") or attName:find("RightGrip") then
                targetPart = model:FindFirstChild("Right Arm") or model:FindFirstChild("RightUpperArm") or model:FindFirstChild("RightHand")
                targetCFrame = attName:find("Grip") and CFrame.new(0, -1, 0) or CFrame.new(0, 0.5, 0)
            elseif attName:find("LeftShoulder") or attName:find("LeftGrip") then
                targetPart = model:FindFirstChild("Left Arm") or model:FindFirstChild("LeftUpperArm") or model:FindFirstChild("LeftHand")
                targetCFrame = attName:find("Grip") and CFrame.new(0, -1, 0) or CFrame.new(0, 0.5, 0)
            elseif attName:find("RightFoot") then
                targetPart = model:FindFirstChild("Right Leg") or model:FindFirstChild("RightFoot") or model:FindFirstChild("RightLowerLeg")
                targetCFrame = CFrame.new(0, -1, 0)
            elseif attName:find("LeftFoot") then
                targetPart = model:FindFirstChild("Left Leg") or model:FindFirstChild("LeftFoot") or model:FindFirstChild("LeftLowerLeg")
                targetCFrame = CFrame.new(0, -1, 0)
            else
                targetPart = model:FindFirstChild("Head")
                targetCFrame = CFrame.new(0, 0.6, 0)
            end
        end

        if targetPart then
            local weld = Instance.new("Weld")
            weld.Name = "AccessoryWeld"
            weld.Part0 = handle
            weld.Part1 = targetPart
            weld.C0 = handleCFrame
            weld.C1 = targetCFrame
            weld.Parent = handle
            accessory.Parent = model

            CacheAccessoryData(accessory)
            ApplyScaleToAccessory(accessory, currentAccessoryScale, currentAccessoryOffsetY, currentAccessoryOffsetZ)
        end
    end)
end

local function EquipItemToModel(model, assetId, silent)
    if not model or not model.Parent then return false end

    local ok, objects = pcall(function()
        return game:GetObjects("rbxassetid://" .. tostring(assetId))
    end)

    if not (ok and objects and #objects > 0) then
        return false
    end

    local itemsToEquip = {}
    local function scan(container)
        for _, ch in ipairs(container:GetChildren()) do
            if ch:IsA("Accessory") or ch:IsA("Tool") or ch:IsA("Shirt") or ch:IsA("Pants") or ch:IsA("ShirtGraphic") then
                table.insert(itemsToEquip, ch)
            end
            scan(ch)
        end
    end

    for _, obj in ipairs(objects) do
        if obj:IsA("Accessory") or obj:IsA("Tool") or obj:IsA("Shirt") or obj:IsA("Pants") or obj:IsA("ShirtGraphic") then
            table.insert(itemsToEquip, obj)
        else
            scan(obj)
        end
    end

    if #itemsToEquip == 0 then
        return false
    end

    for _, item in ipairs(itemsToEquip) do
        local clone = item:Clone()
        if clone:IsA("Accessory") then
            AttachAccessoryToModel(model, clone)
            equippedInstances[clone] = true
        elseif clone:IsA("Tool") then
            clone.Parent = LocalPlayer:FindFirstChildOfClass("Backpack") or model
            equippedInstances[clone] = true
        elseif clone:IsA("Shirt") or clone:IsA("Pants") or clone:IsA("ShirtGraphic") then
            local old = model:FindFirstChildOfClass(clone.ClassName)
            if old then old:Destroy() end
            clone.Parent = model
            equippedInstances[clone] = true
        end
    end
    return true
end

local function EquipAssetUniversal(assetId, silent)
    local models = GetVisualModels()
    if #models == 0 then
        if not silent then
            Notify("Error", "No character models found on map.", 3)
        end
        return false
    end

    local anySuccess = false
    for _, model in ipairs(models) do
        if EquipItemToModel(model, assetId, silent) then
            anySuccess = true
        end
    end

    if anySuccess and not silent then
        table.insert(equippedSession, assetId)
    end
    return anySuccess
end

local function EquipMultiple(inputStr)
    local ids = {}
    for id in inputStr:gmatch("%d+") do
        table.insert(ids, id)
    end

    if #ids == 0 then
        Notify("Input Error", "Please provide a valid Asset ID or URL.", 3)
        return
    end

    Notify("Loading", "Equipping " .. #ids .. " item(s)...", 2.5)

    task.spawn(function()
        local loaded = 0
        for _, id in ipairs(ids) do
            if EquipAssetUniversal(id) then
                loaded = loaded + 1
            end
        end
        Notify("Equipped", "Equipped " .. loaded .. "/" .. #ids .. " item(s) on all active models.", 3.5)
    end)
end

local function ResetEverything()
    local count = 0
    for inst, _ in pairs(equippedInstances) do
        if inst and inst.Parent then
            inst:Destroy()
            count = count + 1
        end
    end
    equippedInstances = {}
    equippedSession = {}
    accessoryProps = {}
    Notify("Reset Complete", count .. " equipped item(s) removed from all map models.", 3)
end

local function SyncToMapModels()
    local models = GetVisualModels()
    if #models == 0 then
        Notify("Sync", "No models found to sync.", 2.5)
        return
    end

    for _, model in ipairs(models) do
        u13_WatchModel(model)
        for _, id in ipairs(equippedSession) do
            EquipItemToModel(model, id, true)
        end
        u12_ApplyMods(model)
    end
    UpdateAllAccessoryScales()
    Notify("Sync Complete", "Synced outfit & mods to " .. #models .. " active model(s).", 3)
end

-- ====================================================================
-- AUTO-SYNC & MAP SPAWN WATCHER
-- ====================================================================

local function HookModelSpawn(container)
    if not container then return end
    local conn = container.ChildAdded:Connect(function(child)
        if not autoSyncEnabled then return end
        if child.Name == LocalPlayer.Name then
            task.wait(0.2)
            u13_WatchModel(child)
            SyncToMapModels()
        end
    end)
    table.insert(connections, conn)
end

local charConn = LocalPlayer.CharacterAdded:Connect(function(char)
    if autoSyncEnabled then
        task.wait(0.2)
        u13_WatchModel(char)
        SyncToMapModels()
    end
end)
table.insert(connections, charConn)

local function MonitorEvadeContainer()
    local gameFolder = workspace:FindFirstChild("Game")
    if gameFolder then
        local playersFolder = gameFolder:FindFirstChild("Players")
        if playersFolder then
            HookModelSpawn(playersFolder)
        else
            local pConn = gameFolder.ChildAdded:Connect(function(c)
                if c.Name == "Players" then
                    HookModelSpawn(c)
                end
            end)
            table.insert(connections, pConn)
        end
    else
        local gConn = workspace.ChildAdded:Connect(function(c)
            if c.Name == "Game" then
                task.wait(0.1)
                local p = c:FindFirstChild("Players")
                if p then HookModelSpawn(p) end
            end
        end)
        table.insert(connections, gConn)
    end
end

local wPlayers = workspace:FindFirstChild("Players")
if wPlayers and wPlayers:IsA("Folder") then
    HookModelSpawn(wPlayers)
end

HookModelSpawn(workspace)
MonitorEvadeContainer()

-- Initialize watcher on existing models
for _, m in ipairs(GetVisualModels()) do
    u13_WatchModel(m)
end

-- ====================================================================
-- CONFIG & PRESET SYSTEM
-- ====================================================================

local function LoadConfig()
    local has = (typeof(isfile) == "function" and isfile) or function() return false end
    if has(CONFIG_FILE) and typeof(readfile) == "function" then
        local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
        if ok and typeof(data) == "table" then return data end
    end
    return {}
end

local function SaveConfig(data)
    if typeof(writefile) == "function" then
        pcall(function()
            writefile(CONFIG_FILE, HttpService:JSONEncode(data))
        end)
    end
end

local function GetPresetNames()
    local cfg = LoadConfig()
    local names = {}
    for name, ids in pairs(cfg) do
        if name ~= "ToggleKey" and typeof(ids) == "table" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    if #names == 0 then
        table.insert(names, "No Presets")
    end
    return names
end

-- ====================================================================
-- OBSIDIAN UI SETUP
-- ====================================================================

local Window = Library:CreateWindow({
    Title = "snivy | larp tool",
    Footer = "v2.3.0 (Resizer & Headless/Korblox) - by snivythegoat",
    NotifySide = "Right",
    ShowCustomCursor = false,
})

local Tabs = {
    Main = Window:AddTab("Main", "user"),
    Presets = Window:AddTab("Presets", "bookmark"),
    ["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

-- --------------------------------------------------------------------
-- TAB 1: MAIN (EQUIP, RESIZE & MODS)
-- --------------------------------------------------------------------
local EquipGroup = Tabs.Main:AddLeftGroupbox("Asset Equipper")

EquipGroup:AddInput("AssetInput", {
    Text = "Asset ID or Catalog URL",
    Default = "",
    Numeric = false,
    Finished = false,
    Placeholder = "e.g. 12345678, 87654321 or catalog URL...",
})

local EquipBtn = EquipGroup:AddButton({
    Text = "Equip Asset(s)",
    Tooltip = "Equips asset ID(s) or catalog URL on your character across the map",
    Func = function()
        local input = Options.AssetInput.Value
        if input and input ~= "" then
            EquipMultiple(input)
        else
            Notify("Input Error", "Enter an asset ID or URL first.", 3)
        end
    end,
})

EquipBtn:AddButton({
    Text = "Clear Input",
    Tooltip = "Clears the asset input text",
    Func = function()
        Options.AssetInput:SetValue("")
    end,
})

EquipGroup:AddDivider()

EquipGroup:AddButton({
    Text = "Reset Equipped Items",
    Tooltip = "Removes all accessories and clothes equipped this session",
    Func = ResetEverything,
    Risky = true,
})

EquipGroup:AddButton({
    Text = "Force Map Sync",
    Tooltip = "Re-applies all session items and mods onto your active map model (Evade / VD)",
    Func = SyncToMapModels,
})

EquipGroup:AddToggle("MainNotificationToggle", {
    Text = "Enable Notifications",
    Default = true,
    Tooltip = "Toggle on-screen notifications for equips, mods, and presets",
    Callback = function(val)
        notificationsEnabled = val
        if Toggles.SettingsNotificationToggle and Toggles.SettingsNotificationToggle.Value ~= val then
            Toggles.SettingsNotificationToggle:SetValue(val)
        end
    end,
})

EquipGroup:AddToggle("AutoSyncToggle", {
    Text = "Auto-Sync on Map Spawn",
    Default = true,
    Tooltip = "Automatically equips your outfit when spawning into rounds (Evade, Violence District, etc.)",
    Callback = function(val)
        autoSyncEnabled = val
    end,
})

-- --------------------------------------------------------------------
-- ACCESSORY RESIZER GROUPBOX
-- --------------------------------------------------------------------
local ResizeGroup = Tabs.Main:AddLeftGroupbox("Accessory Resizer")

ResizeGroup:AddSlider("AccessoryScaleSlider", {
    Text = "Uniform Scale",
    Default = 1,
    Min = 0.1,
    Max = 5,
    Rounding = 2,
    Suffix = "x",
    Tooltip = "Scales the size of equipped accessories (0.1x to 5.0x)",
    Callback = function(val)
        currentAccessoryScale = val
        UpdateAllAccessoryScales()
    end,
})

ResizeGroup:AddSlider("AccessoryOffsetYSlider", {
    Text = "Height Offset (Y)",
    Default = 0,
    Min = -5,
    Max = 5,
    Rounding = 2,
    Suffix = " studs",
    Tooltip = "Adjusts vertical position of accessories up or down",
    Callback = function(val)
        currentAccessoryOffsetY = val
        UpdateAllAccessoryScales()
    end,
})

ResizeGroup:AddSlider("AccessoryOffsetZSlider", {
    Text = "Depth Offset (Z)",
    Default = 0,
    Min = -5,
    Max = 5,
    Rounding = 2,
    Suffix = " studs",
    Tooltip = "Adjusts forward/backward position of accessories",
    Callback = function(val)
        currentAccessoryOffsetZ = val
        UpdateAllAccessoryScales()
    end,
})

ResizeGroup:AddDropdown("ResizeTargetDropdown", {
    Text = "Target Accessories",
    Values = {
        "Session Accessories",
        "All Character Accessories",
    },
    Default = 1,
    Multi = false,
    Tooltip = "Choose whether to scale only items equipped this session or all accessories on your avatar",
    Callback = function(val)
        resizeTargetMode = val
        UpdateAllAccessoryScales()
    end,
})

local ResetScaleBtn = ResizeGroup:AddButton({
    Text = "Reset Size & Offsets",
    Tooltip = "Reverts scale back to 1.0x and resets offsets to 0",
    Func = function()
        Options.AccessoryScaleSlider:SetValue(1)
        Options.AccessoryOffsetYSlider:SetValue(0)
        Options.AccessoryOffsetZSlider:SetValue(0)
        currentAccessoryScale = 1
        currentAccessoryOffsetY = 0
        currentAccessoryOffsetZ = 0
        UpdateAllAccessoryScales()
        Notify("Resizer", "Accessory scale and offsets reset to default.", 2.5)
    end,
})

ResetScaleBtn:AddButton({
    Text = "Re-Apply Scale",
    Tooltip = "Force reapplies current scale settings across active accessories",
    Func = function()
        UpdateAllAccessoryScales()
        Notify("Resizer", "Reapplied scale (" .. currentAccessoryScale .. "x) to accessories.", 2)
    end,
})

-- --------------------------------------------------------------------
-- RIGHT GROUPBOX: AVATAR MODS (KORBLOX & HEADLESS)
-- --------------------------------------------------------------------
local ModsGroup = Tabs.Main:AddRightGroupbox("Character Mods (R6 & R15)")

local currentModels = GetVisualModels()
local detectedRig = #currentModels > 0 and GetRigType(currentModels[1]) or "Unknown"

ModsGroup:AddLabel({
    Text = "Detected Rig: " .. detectedRig .. " (SpecialMesh loop active)",
    DoesWrap = true,
})

-- Korblox Toggle (s1: 101851696, s2: 101851254)
ModsGroup:AddToggle("KorbloxToggle", {
    Text = "Korblox (Right Leg)",
    Default = false,
    Tooltip = "SpecialMesh Korblox Deathspeaker Right Leg (rbxassetid://101851696)",
    Callback = function(val)
        if val then
            ApplyKorbloxUniversal()
        else
            ResetKorbloxUniversal()
        end
    end,
})

-- Headless Toggle (s3: 123456789)
ModsGroup:AddToggle("HeadlessToggle", {
    Text = "Headless",
    Default = false,
    Tooltip = "SpecialMesh Headless (rbxassetid://123456789). When turned off, restores the default face.",
    Callback = function(val)
        if val then
            ApplyHeadlessUniversal()
        else
            ResetHeadUniversal()
        end
    end,
})

ModsGroup:AddDivider()

-- Quick Action Buttons
local ModActionBtns = ModsGroup:AddButton({
    Text = "Reset Legs",
    Tooltip = "Reverts Korblox Right Leg mesh back to normal",
    Func = function()
        Toggles.KorbloxToggle:SetValue(false)
        ResetKorbloxUniversal()
    end,
})

ModActionBtns:AddButton({
    Text = "Reset Head",
    Tooltip = "Restores head visibility and reapplies the default face",
    Func = function()
        Toggles.HeadlessToggle:SetValue(false)
        ResetHeadUniversal()
    end,
})

ModsGroup:AddButton({
    Text = "Reset All Character Mods",
    Tooltip = "Reverts Korblox and Headless back to normal with default face",
    Risky = true,
    Func = function()
        Toggles.KorbloxToggle:SetValue(false)
        Toggles.HeadlessToggle:SetValue(false)
        ResetKorbloxUniversal()
        ResetHeadUniversal()
        Notify("Mods Reset", "All character modifications removed.", 2.5)
    end,
})

-- --------------------------------------------------------------------
-- TAB 2: PRESETS
-- --------------------------------------------------------------------
local PresetsGroup = Tabs.Presets:AddLeftGroupbox("Preset Manager")

PresetsGroup:AddInput("PresetNameInput", {
    Text = "Preset Name",
    Default = "",
    Numeric = false,
    Finished = false,
    Placeholder = "e.g. My Favorite Outfit",
})

local function RefreshPresetDropdown()
    local names = GetPresetNames()
    if Options.SelectedPreset then
        Options.SelectedPreset:SetValues(names)
        if #names > 0 and names[1] ~= "No Presets" then
            Options.SelectedPreset:SetValue(names[1])
        else
            Options.SelectedPreset:SetValue(nil)
        end
    end
end

PresetsGroup:AddButton({
    Text = "Save Current Session",
    Tooltip = "Saves all currently equipped session items under this preset name",
    Func = function()
        local name = Options.PresetNameInput.Value
        if not name or name == "" then
            Notify("Preset Error", "Please enter a preset name.", 3)
            return
        end
        if #equippedSession == 0 then
            Notify("Preset Error", "No equipped items in current session to save.", 3)
            return
        end

        local cfg = LoadConfig()
        cfg[name] = equippedSession
        SaveConfig(cfg)
        Options.PresetNameInput:SetValue("")
        RefreshPresetDropdown()
        Notify("Preset Saved", "Saved preset '" .. name .. "' (" .. #equippedSession .. " items).", 3.5)
    end,
})

PresetsGroup:AddDivider()

PresetsGroup:AddDropdown("SelectedPreset", {
    Text = "Saved Presets",
    Values = GetPresetNames(),
    Default = 1,
    Multi = false,
    Tooltip = "Select a saved preset to load or delete",
})

local PresetActions = PresetsGroup:AddButton({
    Text = "Load Preset",
    Tooltip = "Equips all items contained in the selected preset across your map models",
    Func = function()
        local chosen = Options.SelectedPreset.Value
        if not chosen or chosen == "No Presets" then
            Notify("Preset Error", "No valid preset selected.", 3)
            return
        end

        local cfg = LoadConfig()
        local ids = cfg[chosen]
        if ids and typeof(ids) == "table" and #ids > 0 then
            Notify("Loading Preset", "Loading '" .. chosen .. "' (" .. #ids .. " items)...", 2.5)
            task.spawn(function()
                for _, id in ipairs(ids) do
                    EquipAssetUniversal(id, true)
                end
                SyncToMapModels()
                Notify("Preset Loaded", "Loaded preset '" .. chosen .. "'.", 3.5)
            end)
        else
            Notify("Error", "Preset contains no items.", 3)
        end
    end,
})

PresetActions:AddButton({
    Text = "Delete Preset",
    Tooltip = "Permanently deletes the selected preset",
    Risky = true,
    Func = function()
        local chosen = Options.SelectedPreset.Value
        if not chosen or chosen == "No Presets" then
            Notify("Preset Error", "No preset selected to delete.", 3)
            return
        end

        local cfg = LoadConfig()
        cfg[chosen] = nil
        SaveConfig(cfg)
        RefreshPresetDropdown()
        Notify("Preset Deleted", "Deleted preset '" .. chosen .. "'.", 3)
    end,
})

PresetsGroup:AddButton({
    Text = "Refresh Preset List",
    Tooltip = "Reloads preset list from larp_configs.json",
    Func = function()
        RefreshPresetDropdown()
        Notify("Presets", "Preset list reloaded.", 2)
    end,
})

-- Right Groupbox: Session Status
local SessionGroup = Tabs.Presets:AddRightGroupbox("Current Session")

SessionGroup:AddLabel({
    Text = "Items equipped during this session will be recorded here and included when saving a preset.",
    DoesWrap = true,
})

SessionGroup:AddButton({
    Text = "Inspect Session Count",
    Tooltip = "Shows how many items are currently tracked in this session",
    Func = function()
        Notify("Session Stats", #equippedSession .. " item(s) currently recorded in session.", 3.5)
    end,
})

SessionGroup:AddButton({
    Text = "Clear Session History",
    Tooltip = "Clears session tracking without removing equipped parts",
    Func = function()
        equippedSession = {}
        Notify("Session", "Session history cleared.", 2.5)
    end,
})

-- --------------------------------------------------------------------
-- TAB 3: UI SETTINGS & UNLOAD
-- --------------------------------------------------------------------
local SettingsGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu Settings")

SettingsGroup:AddLabel("Menu Keybind"):AddKeyPicker("MenuKeybind", {
    Default = "P",
    NoUI = true,
    Text = "Menu keybind",
})

Library.ToggleKeybind = Options.MenuKeybind

SettingsGroup:AddDivider()

SettingsGroup:AddToggle("SettingsNotificationToggle", {
    Text = "Show Notifications",
    Default = true,
    Tooltip = "Toggle on-screen notification popups",
    Callback = function(val)
        notificationsEnabled = val
        if Toggles.MainNotificationToggle and Toggles.MainNotificationToggle.Value ~= val then
            Toggles.MainNotificationToggle:SetValue(val)
        end
    end,
})

SettingsGroup:AddButton({
    Text = "Unload Script",
    Tooltip = "Closes the UI and cleans up all background connections",
    Func = function()
        if getgenv().SnivyLarpUnload then
            getgenv().SnivyLarpUnload()
        end
    end,
})

-- ThemeManager & SaveManager Integration
ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({
    "MenuKeybind",
    "MainNotificationToggle",
    "SettingsNotificationToggle",
})

ThemeManager:SetFolder("SnivyWare")
SaveManager:SetFolder("SnivyWare/LarpTool")
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:ApplyToTab(Tabs["UI Settings"])

-- ====================================================================
-- UNLOAD HANDLER
-- ====================================================================

getgenv().SnivyLarpUnload = function()
    for _, c in ipairs(connections) do
        if c and typeof(c) == "RBXScriptConnection" then
            pcall(function() c:Disconnect() end)
        end
    end
    table.clear(connections)
    table.clear(watchedModels)
    table.clear(accessoryProps)
    Library:Unload()
    getgenv().SnivyLarpUnload = nil
    print("[snivy | larp tool] Unloaded cleanly.")
end

Notify("snivy | larp tool", "Loaded! Resizer, Headless & Korblox ready. Toggle UI with P.", 4)
print("[snivy | larp tool] Loaded with Accessory Resizer and SpecialMesh engine.")
