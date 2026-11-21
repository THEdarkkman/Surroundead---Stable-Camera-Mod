-- SurrounDead stable-camera prototype v0.2.2. No hardcoded memory offsets.
local UEHelpers = require("UEHelpers")
local config = {
    EyeBelowCapsuleTop = 24.0, -- Unreal units (cm). Automatically follows crouch height.
    HeightAdjustment = 0.0,
    ForwardOffset = 0.0,
    HideMeshes = true,
    ShowHeldItems = true,
}
local state = nil
local hooks = {}
local log = function(message) print("[SD_StableCamera] " .. tostring(message) .. "\n") end
-- Resolve from this script, not the game's process working directory.
local sourcePath = debug.getinfo(1, "S").source
local modDirectory = sourcePath:sub(1, 1) == "@" and sourcePath:sub(2):gsub("\\", "/"):match("^(.*)/Scripts/[^/]+$")
local configPath = modDirectory and (modDirectory .. "/config.ini") or nil
local function saveHeight()
    if not configPath then
        log("Height NOT saved: could not resolve the mod directory")
        return false
    end
    local file, err = io.open(configPath, "w")
    if not file then
        log("Height NOT saved: " .. tostring(err))
        return false
    end
    local written, writeError = file:write("; SD_StableCamera: additional eye height in cm. F7/F8 save automatically.\n[Camera]\nHeightAdjustment = " .. string.format("%.17g", config.HeightAdjustment) .. "\n")
    local closed, closeError = file:close()
    if not written or not closed then
        log("Height NOT saved: " .. tostring(writeError or closeError))
        return false
    end
    return true
end
local function loadHeight()
    if not configPath then
        log("Config unavailable; using default height for this session")
        return
    end
    local file = io.open(configPath, "r")
    if not file then
        -- Missing files are created when writable. Save failures never disable the camera.
        saveHeight()
        return
    end
    local value
    for line in file:lines() do
        local setting = line:match("^%s*HeightAdjustment%s*=%s*(.-)%s*[;#].*$") or line:match("^%s*HeightAdjustment%s*=%s*(.-)%s*$")
        if setting then value = setting end
    end
    file:close()
    local height = tonumber(value)
    if height and height == height and height ~= math.huge and height ~= -math.huge then
        config.HeightAdjustment = height
        log("Loaded preferred height: " .. height .. " cm from " .. configPath)
    else
        log("Invalid/missing HeightAdjustment in " .. configPath .. "; using default (file unchanged)")
    end
end
loadHeight()
local function valid(o)
    if o == nil then return false end
    local ok, result = pcall(function() return o:IsValid() end)
    return ok and result == true
end
local function unwrapObject(value)
    if valid(value) then return value end
    local ok, object = pcall(function() return value:get() end)
    if ok and valid(object) then return object end
    error("Expected UObject array entry; got " .. type(value) .. " " .. tostring(value))
end
local function read(o, key) return o[key] end
local function vec(v) return {X=v.X, Y=v.Y, Z=v.Z} end
local function rot(v) return {Pitch=v.Pitch, Yaw=v.Yaw, Roll=v.Roll} end
local function name(o) return o:GetFullName() end
local function location(o, v) o:K2_SetRelativeLocation(v, false, {}, false) end
local function rotation(o, v) o:K2_SetRelativeRotation(v, false, {}, false) end
local function attempt(fn)
    local ok, result = pcall(fn)
    if not ok then log(result) end
    return ok, result
end
local function localPawn()
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) or not pc:IsLocalPlayerController() then return nil end
    local pawn = pc.Pawn
    if not valid(pawn) then return nil end
    return pawn
end
-- UE4SS 4.x may marshal returned arrays as Lua tables, while older builds expose
-- a TArray wrapper. Do not assume return arrays and out arrays have the same type.
local function eachObject(array, callback)
    if type(array) == "table" and type(array.ForEach) ~= "function" then
        for _, object in ipairs(array) do callback(unwrapObject(object)) end
    elseif array ~= nil then
        array:ForEach(function(_, item) callback(unwrapObject(item)) end)
    end
end
local armKeys = {"TargetArmLength", "bEnableCameraLag", "bEnableCameraRotationLag",
    "bDoCollisionTest", "bUsePawnControlRotation", "bInheritPitch", "bInheritYaw", "bInheritRoll"}
local function snapshotComponent(o)
    return {object=o, parent=o:GetAttachParent(), socket=o:GetAttachSocketName(),
        pos=vec(o.RelativeLocation), rot=rot(o.RelativeRotation)}
end
local function restoreComponent(s)
    if not valid(s.object) then return end
    if valid(s.parent) then
        assert(s.object:K2_AttachToComponent(s.parent, s.socket, 0, 0, 0, false), "Could not restore attachment")
    else
        s.object:K2_DetachFromComponent(0, 0, 0, false)
    end
    location(s.object, s.pos)
    rotation(s.object, s.rot)
end
local function restore(reason, preservePerspective)
    local s = state
    state = nil -- Invalidate first: restoration may itself execute hooked functions.
    if not s then return end
    for _, mesh in pairs(s.meshes) do
        if valid(mesh.object) then
            attempt(function() mesh.object:SetHiddenInGame(mesh.hidden, false) end)
            if mesh.animTick ~= nil then
                attempt(function() mesh.object.VisibilityBasedAnimTickOption = mesh.animTick end)
            end
        end
    end
    if valid(s.arm.object) then
        attempt(function()
            for k,v in pairs(s.armValues) do s.arm.object[k] = v end
            s.arm.object.SocketOffset = s.socketOffset
            s.arm.object.TargetOffset = s.targetOffset
        end)
        attempt(function() restoreComponent(s.arm) end)
    end
    if valid(s.camera.object) then
        attempt(function()
            s.camera.object.bUsePawnControlRotation = s.cameraControl
            s.camera.object:SetActive(s.cameraActive, false)
            restoreComponent(s.camera)
        end)
    end
    if valid(s.pawn) then
        attempt(function()
            s.pawn.CameraOffset = s.offset
            s.pawn.CameraOffsetVertical = s.vertical
            if not preservePerspective then s.pawn:ChangePlayerPerspective(s.wasFP, true) end
        end)
    end
    log("OFF: " .. reason)
end
local function setActorMeshes(actor, hidden)
    if not config.HideMeshes or not valid(actor) then return end
    local meshClass = StaticFindObject("/Script/Engine.MeshComponent")
    assert(valid(meshClass), "MeshComponent class unavailable")
    local components = actor:K2_GetComponentsByClass(meshClass)
    eachObject(components, function(mesh)
        if valid(mesh) then
            local id = name(mesh)
            if not state.meshes[id] then
                state.meshes[id] = {object=mesh, hidden=mesh.bHiddenInGame}
                if mesh:IsA("/Script/Engine.SkinnedMeshComponent") then
                    state.meshes[id].animTick = mesh.VisibilityBasedAnimTickOption
                end
            end
            state.meshes[id].seen = true
            -- Hidden player bones must still refresh: equipped actors use hand sockets.
            if state.meshes[id].animTick ~= nil then mesh.VisibilityBasedAnimTickOption = 0 end
            local heldComponent = state.pawn.HeldItemInMontage
            local showComponent = config.ShowHeldItems and valid(heldComponent) and name(heldComponent) == id
            mesh:SetHiddenInGame(hidden and not showComponent, false)
        end
    end)
end
local function activeItem(pawn)
    local helper = pawn.BP_JigHelperComp
    if not valid(helper) then return nil end
    local result = {}
    helper:GetActiveWeapon(result)
    -- Object out parameters use their reflected parameter name, unlike array out parameters.
    if result.Actor == nil then return nil end
    if valid(result.Actor) then return result.Actor end
    local ok, actor = pcall(unwrapObject, result.Actor)
    return ok and actor or nil
end
local function optionalProperty(object, key)
    local ok, value = pcall(function() return object[key] end)
    return ok and value or nil
end
local function socketText(value)
    if value == nil then return "" end
    local ok, text = pcall(function() return value:ToString():lower() end)
    return ok and text ~= "none" and text or ""
end
local holsterSocketKeys = {"PrimaryUnequipSocket", "PrimaryUnequipSocketBackpack",
    "SecondaryUnequipSocket", "SecondaryUnequipSocketBackpack"}
local function storageSocketName(socket)
    for _, token in ipairs({"holster", "unequip", "back", "spine", "stow", "pelvis", "chest", "torso", "head"}) do
        if socket:find(token, 1, true) then return true end
    end
    return false
end
local function heldActor(actor)
    local current = actor
    -- Selection is not proof of being in hand. Follow each item's actual attachment.
    -- Accessories inherit the result from their parent weapon/tool.
    for _ = 1, 16 do
        if not valid(current) then break end
        local parent = current:GetAttachParentActor()
        -- Judge the item attached to the player, not accessory sockets on the item.
        -- A scope attached to a holstered rifle must not qualify on its own.
        if valid(parent) and name(parent) == state.pawnName then
        local root = current.RootComponent
        if valid(root) then
            local socket = socketText(root:GetAttachSocketName())
            if storageSocketName(socket) then return false end
            local pickup = optionalProperty(current, "BP_JigPickupComponent")
            local data = valid(pickup) and optionalProperty(pickup, "ItemDataAsset") or nil
            if valid(data) then
                -- Explicit storage sockets always win, even if this is the active item.
                for _, key in ipairs(holsterSocketKeys) do
                    local storageSocket = socketText(optionalProperty(data, key))
                    if socket ~= "" and socket == storageSocket then return false end
                end
                local equipSocket = socketText(optionalProperty(data, "EquipSocket"))
                if socket ~= "" and socket == equipSocket then return true end
                -- Known item data is authoritative: an unmatched socket is not a hand.
                if equipSocket ~= "" then return false end
            end
            -- Fallback for tools without pickup metadata. Never use selection alone.
            if (socket:find("hand", 1, true)
                or socket == "weapon_r" or socket == "meleeweapon_r") then return true end
        end
        return false
        end
        current = parent
    end
    return false
end
local function hideMeshes()
    for _, mesh in pairs(state.meshes) do mesh.seen = false end
    setActorMeshes(state.pawn, true)
    local active = activeItem(state.pawn)
    state.activeItemName = valid(active) and name(active) or "none"
    state.heldActors = {}
    state.itemSockets = {}
    -- Only enumerate attached actors; loose items in the world are never changed.
    local attached = {}
    state.pawn:GetAttachedActors(attached, true, true)
    eachObject(attached, function(actor)
        local show = config.ShowHeldItems and heldActor(actor)
        local root = actor.RootComponent
        state.itemSockets[name(actor)] = valid(root) and socketText(root:GetAttachSocketName()) or "none"
        if show then state.heldActors[name(actor)] = true end
        setActorMeshes(actor, not show)
    end)
    -- Release dropped/detached items immediately, so they do not stay hidden in the world.
    for id, mesh in pairs(state.meshes) do
        if not mesh.seen then
            if valid(mesh.object) then
                mesh.object:SetHiddenInGame(mesh.hidden, false)
                if mesh.animTick ~= nil then mesh.object.VisibilityBasedAnimTickOption = mesh.animTick end
            end
            state.meshes[id] = nil
        end
    end
end
local function update()
    if not state then return end
    local s = state
    if not valid(s.pawn) or not valid(s.root) or not valid(s.arm.object) or not valid(s.camera.object) then
        restore("player or camera unloaded", true)
        return
    end
    if read(s.pawn, "PlayerDead?") or read(s.pawn, "InVehicle?") then
        restore("death or vehicle entry", true)
        return
    end
    if read(s.pawn, "PlayerInFirstPerson?") then
        restore("perspective changed", true)
        return
    end
    local arm, camera = s.arm.object, s.camera.object
    s.pawn.CameraOffset = 0.0
    s.pawn.CameraOffsetVertical = 0.0
    arm.TargetArmLength = 0.0
    arm.SocketOffset = {X=0,Y=0,Z=0}
    arm.TargetOffset = {X=0,Y=0,Z=0}
    arm.bEnableCameraLag = false
    arm.bEnableCameraRotationLag = false
    arm.bDoCollisionTest = false
    arm.bUsePawnControlRotation = true
    arm.bInheritPitch = true
    arm.bInheritYaw = true
    arm.bInheritRoll = false
    camera.bUsePawnControlRotation = false
    local height = s.root:GetUnscaledCapsuleHalfHeight() - config.EyeBelowCapsuleTop + config.HeightAdjustment
    location(arm, {X=config.ForwardOffset,Y=0,Z=math.max(0,height)})
    rotation(arm, {Pitch=0,Yaw=0,Roll=0})
    location(camera, {X=0,Y=0,Z=0})
    rotation(camera, {Pitch=0,Yaw=0,Roll=0})
    camera:SetActive(true, false)
    s.ticks = s.ticks + 1
    -- Catch item switches within 250 ms; the camera still updates on every player tick.
    if s.ticks == 1 or s.elapsed >= 0.25 then
        hideMeshes()
        s.elapsed = 0
    end
    if s.ticks == 2 then
        local count = 0
        for _ in pairs(s.meshes) do count = count + 1 end
        log("Live tick confirmed; eye height=" .. height .. " cm; tracked meshes=" .. count .. "; active item=" .. (s.activeItemName or "none"))
    end
end
local function guardedUpdate(dt)
    if not state then return end
    state.elapsed = state.elapsed + (dt or 0)
    local ok, err = xpcall(update, debug.traceback)
    if not ok then
        log("Update failed: " .. tostring(err))
        restore("runtime error; original camera restored", false)
    end
end
local function installTickHook(pawn)
    local class = pawn:GetClass()
    while valid(class) do
        local path = name(class):match("^[^ ]+ (.+)$")
        local functionPath = path and (path .. ":ReceiveTick")
        if functionPath and valid(StaticFindObject(functionPath)) then
            if not hooks[functionPath] then
                hooks[functionPath] = {RegisterHook(functionPath, function(context, dt)
                    if state and valid(context:get()) and name(context:get()) == state.pawnName then
                        guardedUpdate(dt:get())
                    end
                end)}
                log("Tick hook: " .. functionPath)
            end
            return
        end
        class = class:GetSuperStruct()
    end
    error("No reflected ReceiveTick found; no camera changes applied")
end
local function enable()
    local pawn = localPawn()
    assert(valid(pawn), "Load a save before enabling")
    assert(not read(pawn, "InVehicle?"), "Exit the vehicle first")
    assert(not read(pawn, "PlayerDead?"), "Player is dead")
    local camera, arm, root = pawn.Camera, pawn.SpringArm, pawn.CapsuleComponent
    assert(valid(camera) and valid(arm) and valid(root), "Expected Camera, SpringArm and CapsuleComponent not found")
    installTickHook(pawn)
    local s = {pawn=pawn, pawnName=name(pawn), root=root, camera=snapshotComponent(camera),
        arm=snapshotComponent(arm), armValues={}, meshes={}, ticks=0, elapsed=0,
        wasFP=read(pawn,"PlayerInFirstPerson?"), offset=pawn.CameraOffset, vertical=pawn.CameraOffsetVertical,
        socketOffset=vec(arm.SocketOffset), targetOffset=vec(arm.TargetOffset),
        cameraControl=camera.bUsePawnControlRotation, cameraActive=camera:IsActive()}
    for _, key in ipairs(armKeys) do s.armValues[key] = arm[key] end
    state = s -- Snapshot exists before the first mutation, including on partial failure.
    pawn:ChangePlayerPerspective(false, true)
    assert(arm:K2_AttachToComponent(root, FName("None"), 0, 0, 0, false), "Could not attach spring arm to capsule")
    assert(camera:K2_AttachToComponent(arm, FName("SpringEndpoint"), 0, 0, 0, false), "Could not attach camera to spring arm")
    guardedUpdate(0)
    if state then log("ON: stable camera; body hidden; held items=" .. tostring(config.ShowHeldItems)) end
end
local function onGameThread(fn)
    ExecuteInGameThread(function()
        local ok, err = pcall(fn)
        if not ok then
            log(err)
            restore("operation failed", false)
        end
    end)
end
RegisterKeyBind(Key.F6, function()
    onGameThread(function()
        if state then restore("F6 toggle", false) else enable() end
    end)
end)
RegisterKeyBind(Key.F4, function()
    onGameThread(function()
        config.ShowHeldItems = not config.ShowHeldItems
        if state then hideMeshes() end
        log("Show held weapons/tools: " .. tostring(config.ShowHeldItems))
    end)
end)
RegisterKeyBind(Key.F7, function()
    onGameThread(function()
        config.HeightAdjustment = config.HeightAdjustment - 2
        guardedUpdate(0)
        saveHeight()
        log("Height adjustment: " .. config.HeightAdjustment .. " cm" .. (state and "" or " (camera OFF; press F6 to enable)"))
    end)
end)
RegisterKeyBind(Key.F8, function()
    onGameThread(function()
        config.HeightAdjustment = config.HeightAdjustment + 2
        guardedUpdate(0)
        saveHeight()
        log("Height adjustment: " .. config.HeightAdjustment .. " cm" .. (state and "" or " (camera OFF; press F6 to enable)"))
    end)
end)
RegisterKeyBind(Key.F9, function()
    onGameThread(function()
        local pawn = localPawn()
        log("Diagnostic: " .. (valid(pawn) and name(pawn) or "no local player"))
        log("Config: " .. (configPath or "unavailable") .. "; preferred height=" .. config.HeightAdjustment .. " cm")
        if valid(pawn) then
            for _, key in ipairs({"Camera", "SpringArm", "FirstPersonCamera", "SpringArmFP", "CapsuleComponent"}) do
                local o = pawn[key]
                if valid(o) then
                    local parent = o:GetAttachParent()
                    log(key .. " = " .. name(o) .. "; parent=" .. (valid(parent) and name(parent) or "none"))
                end
            end
        end
        if state then
            log("Active; ticks=" .. state.ticks .. "; height adjustment=" .. config.HeightAdjustment)
            log("Active item: " .. (state.activeItemName or "none"))
            for actorName in pairs(state.heldActors or {}) do log("Visible held actor: " .. actorName) end
            for actorName, socket in pairs(state.itemSockets or {}) do
                log("Item socket: " .. actorName .. " -> " .. socket)
            end
        else
            log("Camera OFF; press F6 to enable")
        end
    end)
end)
-- Low-frequency lifecycle guard, not a timer-driven camera (avoids camera-update jitter).
LoopAsync(1000, function()
    if state then
        onGameThread(function()
            if state then
                local pawn = localPawn()
                if not valid(pawn) or name(pawn) ~= state.pawnName then restore("local player changed", true) end
            end
        end)
    end
    return false
end)
log("Loaded v0.2.2 (disabled). F4 held items; F6 camera; F7/F8 height (auto-saved); F9 diagnostics.")
