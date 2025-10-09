--// Services used in this script
local Players = game:GetService("Players") -- service for players
local UserInputService = game:GetService("UserInputService") -- service for input
local RunService = game:GetService("RunService") -- service for heartbeat/renderstep
local TweenService = game:GetService("TweenService") -- service for tweens
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- service for replicated data
local StarterGui = game:GetService("StarterGui") -- service for ui
local Debris = game:GetService("Debris") -- service for cleanup

--// Player references
local localPlayer = Players.LocalPlayer -- variable for local player
repeat task.wait() until localPlayer.Character -- wait for character to exist
local character = localPlayer.Character -- variable for character
local humanoid = character:WaitForChild("Humanoid") -- variable for humanoid
local humanoidRootPart = character:WaitForChild("HumanoidRootPart") -- variable for root part

if character.PrimaryPart.Name ~= "HumanoidRootPart" then -- check if primary part is not hrp
	character.PrimaryPart = humanoidRootPart -- set hrp as primary part
end

local primaryPart = character.PrimaryPart -- variable for primary part
local animator = humanoid:WaitForChild("Animator") -- variable for animator

--// Required modules
local controlModule = require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"):WaitForChild("ControlModule")) -- module for movement
local playerStats = require(ReplicatedStorage:WaitForChild("PlayerStats")) -- module for player stats

--// Animations
local flyIdleAnim = script:WaitForChild("FlyIdle") -- idle animation asset
local flyForwardAnim = script:WaitForChild("FlyForward") -- forward animation asset
local flyLeftAnim = script:WaitForChild("FlyLeft") -- left animation asset
local flyRightAnim = script:WaitForChild("FlyRight") -- right animation asset
local flyBackwardAnim = script:WaitForChild("FlyBackward") -- backward animation asset

--// Animation tracks
local idleTrack = animator:LoadAnimation(flyIdleAnim) -- track for idle
local forwardTrack = animator:LoadAnimation(flyForwardAnim) -- track for forward

--// Trails
local leftTrail = script:WaitForChild("leftTrail") -- left trail
local rightTrail = script:WaitForChild("rightTrail") -- right trail

--// Constraints
local vectorForce = script:WaitForChild("VectorForce") -- vector force
local alignOrientation = script:WaitForChild("AlignOrientation") -- align orientation
vectorForce.Attachment0 = primaryPart.RootAttachment -- set attachment for vector
alignOrientation.Attachment0 = primaryPart.RootAttachment -- set attachment for align

--// Camera
local camera = workspace.CurrentCamera -- variable for camera

--// UI
local staminaUI = StarterGui:WaitForChild("Stamina") -- variable for stamina ui

--// FX + Event
local effectsFolder = ReplicatedStorage.Effects:WaitForChild("FlightEffects") -- variable for flight effects
local flightEvent = ReplicatedStorage:WaitForChild("FlightEvent") -- variable for remote event

--// Flight variables
local gravityVector = Vector3.new(0, workspace.Gravity, 0) -- vector for gravity
local isFlying = false -- bool for flying state
local isHyper = false -- bool for hyper state
local flightConnection = nil -- connection for heartbeat
local targetFOV = 120 -- target fov
local momentum = 5 -- momentum value
local dragConstant = 0.7 -- drag constant
local currentForce = playerStats.DefaultFlySpeed -- current fly speed
local stamina = 100 -- starting stamina
local maxStamina = playerStats.MaxStamina -- max stamina
local hyperSpeed = playerStats.MaxFlySpeed -- boosted fly speed
local canBoost = true -- bool for boost state
local isADown = false -- bool for A key
local isDDown = false -- bool for D key
local isSDown = false -- bool for S key
local sideTrack -- variable for side animation track
local backTrack -- variable for back animation track

--// Helper function: tween camera fov
local function tweenFOV(targetFOVValue, duration)
	local tweenInfo = TweenInfo.new(duration or 0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out) -- tween info
	local tweenGoals = { FieldOfView = targetFOVValue } -- goal for fov
	local tween = TweenService:Create(camera, tweenInfo, tweenGoals) -- create tween
	tween:Play() -- play tween
end

--// Helper function: stop all flight animations
local function stopAllFlightAnimations()
	if idleTrack then idleTrack:Stop() end -- stop idle
	if forwardTrack then forwardTrack:Stop() end -- stop forward
	if sideTrack then sideTrack:Stop() end -- stop side
	if backTrack then backTrack:Stop() end -- stop back
end

--// Helper function: reset boost
local function resetBoost()
	isHyper = false -- set hyper to false
	currentForce = 3000 -- reset force
	leftTrail.Enabled = false -- disable left trail
	rightTrail.Enabled = false -- disable right trail
end

--// Helper function: play idle animation
local function playIdle()
	for _, track in pairs(animator:GetPlayingAnimationTracks()) do -- loop all tracks
		track:Stop() -- stop track
	end
	idleTrack:Play() -- play idle
end

--// Helper function: update stamina values
local function updateStamina()
	if isHyper and canBoost and stamina > 0 then -- if boosting and has stamina
		stamina -= 0.25 -- drain stamina
		humanoid:SetAttribute("Stamina", stamina) -- update attribute
	elseif stamina < maxStamina and not isHyper then -- if not boosting and not full
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

--// Helper function: calculate force vectors
local function calculateFlightForce()
	alignOrientation.CFrame = camera.CFrame -- align with camera
	vectorForce.Force = gravityVector * primaryPart.AssemblyMass -- apply gravity

	local moveVector = controlModule:GetMoveVector() -- get movement input
	local direction = camera.CFrame.RightVector * moveVector.X + camera.CFrame.LookVector * (moveVector.Z * -1) -- calculate direction

	if direction:Dot(direction) > 0 then -- if not zero
		direction = direction.Unit -- normalize direction
	end

	vectorForce.Force += direction * currentForce * primaryPart.AssemblyMass -- apply directional force

	if primaryPart.AssemblyLinearVelocity.Magnitude > 0 then -- if moving
		local dragVector = -primaryPart.AssemblyLinearVelocity.Unit -- drag opposite velocity
		local velocityPower = primaryPart.AssemblyLinearVelocity.Magnitude ^ 1.6 -- drag power
		vectorForce.Force += dragVector * dragConstant * primaryPart.AssemblyMass * velocityPower -- apply drag
	end
end

--// Helper function: handle animation switching
local function handleAnimationState()
	if humanoid.MoveDirection ~= Vector3.new() then -- if moving
		momentum = 5 -- reset momentum
		if not forwardTrack.IsPlaying then -- if forward not playing
			idleTrack:Stop() -- stop idle
			forwardTrack:Play() -- play forward
		end
	else -- if idle
		momentum = 0 -- reset momentum
		if forwardTrack.IsPlaying then -- if forward is playing
			forwardTrack:Stop() -- stop forward
			idleTrack:Play() -- play idle
		end
	end
end

--// Helper function: start flying
local function startFlight()
	humanoid:SetAttribute("IsFlying", true) -- set attribute

	if humanoid.FloorMaterial ~= Enum.Material.Air then -- if grounded
		humanoid:ChangeState("Jumping") -- jump state
		flightEvent:FireServer("Jump") -- fire event
		task.wait(0.09) -- small delay
	end

	isFlying = true -- set flying
	alignOrientation.Enabled = true -- enable align
	vectorForce.Enabled = true -- enable vector
	playIdle() -- play idle animation
	humanoid:ChangeState("Physics") -- physics state
	staminaUI.Background.Visible = true -- show stamina ui

	flightConnection = RunService.Heartbeat:Connect(function() -- connect heartbeat
		updateStamina() -- update stamina
		calculateFlightForce() -- calculate force
		handleAnimationState() -- handle animations
	end)
end

--// Helper function: stop flying
local function stopFlight()
	humanoid:SetAttribute("IsFlying", false) -- set attribute
	vectorForce.Enabled = false -- disable vector
	alignOrientation.Enabled = false -- disable align
	humanoid:ChangeState("Freefall") -- set freefall

	if flightConnection then -- if connection exists
		flightConnection:Disconnect() -- disconnect
		flightConnection = nil -- reset connection
	end

	isFlying = false -- set flying false
	stopAllFlightAnimations() -- stop animations

	if camera.FieldOfView == targetFOV then -- if boosted fov
		tweenFOV(70) -- reset fov
	end
end

--// Input: toggle flight
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore typing

	if input.KeyCode == Enum.KeyCode.Q then -- q pressed
		if isFlying then -- if already flying
			stopFlight() -- stop
		else -- else not flying
			startFlight() -- start
		end
	end
end)

--// Input: boost
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore typing

	if input.KeyCode == Enum.KeyCode.Space and isFlying and canBoost and stamina > 0 then -- space pressed
		if humanoid.MoveDirection ~= Vector3.new() then -- if moving
			flightEvent:FireServer("Boost") -- fire boost event
			tweenFOV(targetFOV) -- tween fov
			leftTrail.Enabled = true -- enable left trail
			rightTrail.Enabled = true -- enable right trail
		else -- if not moving
			tweenFOV(70) -- reset fov
			leftTrail.Enabled = false -- disable left trail
			rightTrail.Enabled = false -- disable right trail
		end

		isHyper = true -- set hyper
		currentForce = hyperSpeed -- set hyper speed
	end
end)

--// Input: stop boost
UserInputService.InputEnded:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore typing

	if input.KeyCode == Enum.KeyCode.Space and isFlying then -- space released
		tweenFOV(70) -- reset fov
		resetBoost() -- reset boost
	end
end)

--// Input: left / right animations
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore typing

	if input.KeyCode == Enum.KeyCode.A and isFlying then -- a pressed
		isADown = true -- set a down

		if sideTrack then sideTrack:Stop() end -- stop current side
		if forwardTrack.IsPlaying then forwardTrack:Stop() end -- stop forward
		if isSDown and backTrack then backTrack:Stop() end -- stop back if s pressed

		sideTrack = animator:LoadAnimation(flyLeftAnim) -- load left
		sideTrack:Play() -- play left

	elseif input.KeyCode == Enum.KeyCode.D and isFlying then -- d pressed
		isDDown = true -- set d down

		if sideTrack then sideTrack:Stop() end -- stop current side
		if forwardTrack.IsPlaying then forwardTrack:Stop() end -- stop forward
		if isSDown and backTrack then backTrack:Stop() end -- stop back if s pressed

		sideTrack = animator:LoadAnimation(flyRightAnim) -- load right
		sideTrack:Play() -- play right
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore typing

	if input.KeyCode == Enum.KeyCode.A and isFlying then -- a released
		isADown = false -- set a false

		if sideTrack then sideTrack:Stop() end -- stop side
		if isDDown then -- if d down
			sideTrack = animator:LoadAnimation(flyRightAnim) -- load right
			sideTrack:Play() -- play right
		end
	end

	if input.KeyCode == Enum.KeyCode.D and isFlying then -- d released
		isDDown = false -- set d false

		if sideTrack then sideTrack:Stop() end -- stop side
		if isADown then -- if a down
			sideTrack = animator:LoadAnimation(flyLeftAnim) -- load left
			sideTrack:Play() -- play left
		end
	end
end)

--// Input: backward animation
UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore typing

	if input.KeyCode == Enum.KeyCode.S and isFlying then -- s pressed
		isSDown = true -- set s down
		backTrack = animator:LoadAnimation(flyBackwardAnim) -- load backward
		backTrack:Play() -- play backward
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessedEvent)
	if gameProcessedEvent then return end -- ignore typing

	if input.KeyCode == Enum.KeyCode.S and isFlying then -- s released
		isSDown = false -- set s false

		if backTrack then backTrack:Stop() end -- stop back
		backTrack = nil -- clear backtrack
	end
end)

--// Event: effects
flightEvent.OnClientEvent:Connect(function(char, effect)
	if effect == "Jump" then -- if jump effect
		local jumpEffect = effectsFolder:WaitForChild("Jump"):Clone() -- clone jump fx
		jumpEffect.Parent = workspace.Effects -- parent to workspace
		jumpEffect.Position = humanoidRootPart.Position - Vector3.new(0, 3.75, 0) -- set position

		local tweenInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out) -- tween info
		local tweenGoals = { Size = jumpEffect.Size + Vector3.new(25, 0, 25), Transparency = 1 } -- tween goals
		local tween = TweenService:Create(jumpEffect, tweenInfo, tweenGoals) -- create tween
		tween:Play() -- play tween
		Debris:AddItem(jumpEffect, 0.4) -- cleanup
	end
end)
