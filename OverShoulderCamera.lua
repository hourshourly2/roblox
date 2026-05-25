local BehindShoulderCamera = {}

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = game.Players.LocalPlayer
local camera = workspace.CurrentCamera

local character = player.Character or player.CharacterAdded:Wait()
local root = character:WaitForChild("HumanoidRootPart")

local shoulderOffset = Vector3.new(2, 2, 8)
local sensitivity = 0.25
local yaw = 0
local pitch = 0


local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

local connection

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		yaw -= input.Delta.X * sensitivity
		pitch -= input.Delta.Y * sensitivity

		pitch = math.clamp(pitch, -75, 75)
	end
end)


function BehindShoulderCamera:Toggle(toggleOn : boolean)
	if toggleOn then
		camera.CameraType = Enum.CameraType.Scriptable
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		connection = RunService.RenderStepped:Connect(function()

			character = player.Character
			if not character then return end

			root = character:FindFirstChild("HumanoidRootPart")
			if not root then return end

			params.FilterDescendantsInstances = {character}

			local target = root.Position + Vector3.new(0, 2, 0)

			local rotation = CFrame.new(target) * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0)
			local desiredPos = (rotation * CFrame.new(shoulderOffset.X, shoulderOffset.Y, shoulderOffset.Z)).Position
			local direction = desiredPos - target
			local result = workspace:Raycast(target, direction, params)
			local finalPos = desiredPos

			if result then
				finalPos = result.Position + result.Normal * 0.5
			end

			local targetCF = CFrame.lookAt(finalPos, target)
			camera.CFrame = camera.CFrame:Lerp(targetCF, 0.15)
			root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, math.rad(yaw), 0)
		end)
	else
		if connection then connection:Disconnect() end
		camera.CameraType = Enum.CameraType.Custom
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

return BehindShoulderCamera
