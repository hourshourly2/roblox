--// services used in this script
local Players = game:GetService("Players") -- service for players
local UIS = game:GetService("UserInputService") -- service for input
local RS = game:GetService("RunService") -- service for heartbeat/renderstep
local TweenService = game:GetService("TweenService") -- service for tweens
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- service for replicated data
local StarterGui = game:GetService("StarterGui") -- service for ui
local Debris = game:GetService("Debris") -- service for cleanup
 
--// player references
local player = Players.LocalPlayer -- variable for local player
repeat task.wait() until player.Character -- wait for character to exist
local character = player.Character -- variable for character
local humanoid = character:WaitForChild("Humanoid") -- variable for humanoid
local HRP = character:WaitForChild("HumanoidRootPart") -- variable for root part
if character.PrimaryPart.Name ~= "HumanoidRootPart" then -- check if primary part is not hrp
    character.PrimaryPart = HRP -- set hrp as primary part
end
local primaryP = character.PrimaryPart -- variable for primary part
local animator = humanoid:WaitForChild("Animator") -- variable for animator
 
--// required modules
local controlModule = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"):WaitForChild("ControlModule")) -- module for movement
local PlayerStats = require(ReplicatedStorage:WaitForChild("PlayerStats")) -- module for player stats
 
--// animations
local FlyIdle = script:WaitForChild("FlyIdle") -- idle animation asset
local FlyForward = script:WaitForChild("FlyForward") -- forward animation asset
local FlyLeft = script:WaitForChild("FlyLeft") -- left animation asset
local FlyRight = script:WaitForChild("FlyRight") -- right animation asset
local FlyBackward = script:WaitForChild("FlyBackward") -- backward animation asset
 
--// animation tracks
local IdleTrack = animator:LoadAnimation(FlyIdle) -- track for idle
local ForwardTrack = animator:LoadAnimation(FlyForward) -- track for forward
 
--// trails
local trailL = script:WaitForChild("leftTrail") -- left trail
local trailR = script:WaitForChild("rightTrail") -- right trail
 
--// constraints
local vector = script:WaitForChild("VectorForce") -- vector force
local align = script:WaitForChild("AlignOrientation") -- align orientation
vector.Attachment0 = primaryP.RootAttachment -- set attachment for vector
align.Attachment0 = primaryP.RootAttachment -- set attachment for align
 
--// camera
local camera = workspace.CurrentCamera -- variable for camera
 
--// ui
local UI = StarterGui:WaitForChild("Stamina") -- variable for stamina ui
 
--// fx + event
local FX = ReplicatedStorage.Effects:WaitForChild("FlightEffects") -- variable for flight effects
local event = ReplicatedStorage:WaitForChild("FlightEvent") -- variable for remote event
 
--// flight variables
local gravity = Vector3.new(0, workspace.Gravity, 0) -- vector for gravity
local IsFlying = false -- bool for flying state
local IsHyper = false -- bool for hyper state
local Flight = nil -- connection for heartbeat
local FOV = 120 -- target fov
local momentum = 5 -- momentum value
local drag = 0.7 -- drag constant
local force = PlayerStats.DefaultFlySpeed -- current fly speed
local stamina = 100 -- starting stamina
local maxStamina = PlayerStats.MaxStamina -- max stamina
local hyperSpeed = PlayerStats.MaxFlySpeed -- boosted fly speed
local canBoost = true -- bool for boost state
local IsADown = false -- bool for A key
local IsDDown = false -- bool for D key
local IsSDown = false -- bool for S key
local sidetrack -- variable for side animation track
local backtrack -- variable for back animation track
 
--// helper function: tween camera fov
local function tweenFOV(targetFOV, duration)
    local info = TweenInfo.new(duration or 0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out) -- tween info
    local goals = { FieldOfView = targetFOV } -- goal for fov
    local tween = TweenService:Create(camera, info, goals) -- create tween
    tween:Play() -- play tween
end
 
--// helper function: stop all flight animations
local function stopAllFlightAnimations()
    if IdleTrack then IdleTrack:Stop() end -- stop idle
    if ForwardTrack then ForwardTrack:Stop() end -- stop forward
    if sidetrack then sidetrack:Stop() end -- stop side
    if backtrack then backtrack:Stop() end -- stop back
end
 
--// helper function: reset boost
local function resetBoost()
    IsHyper = false -- set hyper to false
    force = 3000 -- reset force
    trailL.Enabled = false -- disable left trail
    trailR.Enabled = false -- disable right trail
end
 
--// helper function: play idle animation
local function playIdle()
    for _,v in pairs(animator:GetPlayingAnimationTracks()) do -- loop all tracks
        v:Stop() -- stop track
    end
    IdleTrack:Play() -- play idle
end
 
--// helper function: update stamina values
local function updateStamina()
    if IsHyper and canBoost and stamina > 0 then -- if boosting and has stamina
        stamina -= 0.25 -- drain stamina
        humanoid:SetAttribute("Stamina", stamina) -- update attribute
    elseif stamina < maxStamina and not IsHyper then -- if not boosting and not full
        stamina += 0.25 -- regen stamina
        humanoid:SetAttribute("Stamina", stamina) -- update attribute
    end
    if stamina == 0 then -- if stamina empty
        tweenFOV(70) -- reset fov
        resetBoost() -- reset boost state
        canBoost = false -- disable boosting
    end
    if not canBoost and stamina > 10 then -- if regen over threshold
        canBoost = true -- enable boost again
    end
end
 
--// helper function: calculate force vectors
local function calculateFlightForce()
    align.CFrame = camera.CFrame -- align with camera
    vector.Force = gravity * primaryP.AssemblyMass -- apply gravity
 
    local movevector = controlModule:GetMoveVector() -- get movement input
    local direction = camera.CFrame.RightVector * movevector.X + camera.CFrame.LookVector * (movevector.Z * -1) -- calculate direction
    if direction:Dot(direction) > 0 then -- if not zero
        direction = direction.Unit -- normalize direction
    end
    vector.Force += direction * force * primaryP.AssemblyMass -- apply directional force
 
    if primaryP.AssemblyLinearVelocity.Magnitude > 0 then -- if moving
        local dragVector = -primaryP.AssemblyLinearVelocity.Unit -- drag opposite velocity
        local v2 = primaryP.AssemblyLinearVelocity.Magnitude ^ 1.6 -- drag power
        vector.Force += dragVector * drag * primaryP.AssemblyMass * v2 -- apply drag
    end
end
 
--// helper function: handle animation switching
local function handleAnimationState()
    if humanoid.MoveDirection ~= Vector3.new() then -- if moving
        momentum = 5 -- reset momentum
        if not ForwardTrack.IsPlaying then -- if forward not playing
            IdleTrack:Stop() -- stop idle
            ForwardTrack:Play() -- play forward
        end
    else -- if idle
        momentum = 0 -- reset momentum
        if ForwardTrack.IsPlaying then -- if forward is playing
            ForwardTrack:Stop() -- stop forward
            IdleTrack:Play() -- play idle
        end
    end
end
 
--// helper function: start flying
local function startFlight()
    humanoid:SetAttribute("IsFlying", true) -- set attribute
    if humanoid.FloorMaterial ~= Enum.Material.Air then -- if grounded
        humanoid:ChangeState("Jumping") -- jump state
        event:FireServer("Jump") -- fire event
        task.wait(0.09) -- small delay
    end
    IsFlying = true -- set flying
    align.Enabled = true -- enable align
    vector.Enabled = true -- enable vector
    playIdle() -- play idle animation
    humanoid:ChangeState("Physics") -- physics state
    UI.Background.Visible = true -- show stamina ui
    Flight = RS.Heartbeat:Connect(function() -- connect heartbeat
        updateStamina() -- update stamina
        calculateFlightForce() -- calculate force
        handleAnimationState() -- handle animations
    end)
end
 
--// helper function: stop flying
local function stopFlight()
    humanoid:SetAttribute("IsFlying", false) -- set attribute
    vector.Enabled = false -- disable vector
    align.Enabled = false -- disable align
    humanoid:ChangeState("Freefall") -- set freefall
    if Flight then -- if connection exists
        Flight:Disconnect() -- disconnect
        Flight = nil -- reset connection
    end
    IsFlying = false -- set flying false
    stopAllFlightAnimations() -- stop animations
    if camera.FieldOfView == FOV then -- if boosted fov
        tweenFOV(70) -- reset fov
    end
end
 
--// input: toggle flight
UIS.InputBegan:Connect(function(input, typing)
    if typing then return end -- ignore typing
    if input.KeyCode == Enum.KeyCode.Q then -- q pressed
        if IsFlying then -- if already flying
            stopFlight() -- stop
        else -- else not flying
            startFlight() -- start
        end
    end
end)
 
--// input: boost
UIS.InputBegan:Connect(function(input, typing)
    if typing then return end -- ignore typing
    if input.KeyCode == Enum.KeyCode.Space and IsFlying and canBoost and stamina > 0 then -- space pressed
        if humanoid.MoveDirection ~= Vector3.new() then -- if moving
            event:FireServer("Boost") -- fire boost event
            tweenFOV(FOV) -- tween fov
            trailL.Enabled = true -- enable left trail
            trailR.Enabled = true -- enable right trail
        else -- if not moving
            tweenFOV(70) -- reset fov
            trailL.Enabled = false -- disable left trail
            trailR.Enabled = false -- disable right trail
        end
        IsHyper = true -- set hyper
        force = hyperSpeed -- set hyper speed
    end
end)
 
--// input: stop boost
UIS.InputEnded:Connect(function(input, typing)
    if typing then return end -- ignore typing
    if input.KeyCode == Enum.KeyCode.Space and IsFlying then -- space released
        tweenFOV(70) -- reset fov
        resetBoost() -- reset boost
    end
end)
 
--// input: left / right animations
UIS.InputBegan:Connect(function(input, typing)
    if typing then return end -- ignore typing
    if input.KeyCode == Enum.KeyCode.A and IsFlying then -- a pressed
        IsADown = true -- set a down
        if sidetrack then sidetrack:Stop() end -- stop current side
        if ForwardTrack.IsPlaying then ForwardTrack:Stop() end -- stop forward
        if IsSDown and backtrack then backtrack:Stop() end -- stop back if s pressed
        sidetrack = animator:LoadAnimation(FlyLeft) -- load left
        sidetrack:Play() -- play left
    elseif input.KeyCode == Enum.KeyCode.D and IsFlying then -- d pressed
        IsDDown = true -- set d down
        if sidetrack then sidetrack:Stop() end -- stop current side
        if ForwardTrack.IsPlaying then ForwardTrack:Stop() end -- stop forward
        if IsSDown and backtrack then backtrack:Stop() end -- stop back if s pressed
        sidetrack = animator:LoadAnimation(FlyRight) -- load right
        sidetrack:Play() -- play right
    end
end)
 
UIS.InputEnded:Connect(function(input, typing)
    if typing then return end -- ignore typing
    if input.KeyCode == Enum.KeyCode.A and IsFlying then -- a released
        IsADown = false -- set a false
        if sidetrack then sidetrack:Stop() end -- stop side
        if IsDDown then -- if d down
            sidetrack = animator:LoadAnimation(FlyRight) -- load right
            sidetrack:Play() -- play right
        end
    end
    if input.KeyCode == Enum.KeyCode.D and IsFlying then -- d released
        IsDDown = false -- set d false
        if sidetrack then sidetrack:Stop() end -- stop side
        if IsADown then -- if a down
            sidetrack = animator:LoadAnimation(FlyLeft) -- load left
            sidetrack:Play() -- play left
        end
    end
end)
 
--// input: backward animation
UIS.InputBegan:Connect(function(input, typing)
    if typing then return end -- ignore typing
    if input.KeyCode == Enum.KeyCode.S and IsFlying then -- s pressed
        IsSDown = true -- set s down
        backtrack = animator:LoadAnimation(FlyBackward) -- load backward
        backtrack:Play() -- play backward
    end
end)
 
UIS.InputEnded:Connect(function(input, typing)
    if typing then return end -- ignore typing
    if input.KeyCode == Enum.KeyCode.S and IsFlying then -- s released
        IsSDown = false -- set s false
        if backtrack then backtrack:Stop() end -- stop back
        backtrack = nil -- clear backtrack
    end
end)
 
--// event: effects
event.OnClientEvent:Connect(function(character, effect)
    if effect == "Jump" then -- if jump effect
        local jump = FX:WaitForChild("Jump"):Clone() -- clone jump fx
        jump.Parent = workspace.Effects -- parent to workspace
        jump.Position = HRP.Position - Vector3.new(0,3.75,0) -- set position
        local info = TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out) -- tween info
        local goals = { Size = jump.Size + Vector3.new(25,0,25), Transparency = 1 } -- tween goals
        local tween = TweenService:Create(jump, info, goals) -- create tween
        tween:Play() -- play tween
        Debris:AddItem(jump, 0.4) -- cleanup
    end
end)
 
