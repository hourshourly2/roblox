local RoundManager = {}

local replicatedStorage = game:GetService("ReplicatedStorage")
local serverScriptService = game:GetService("ServerScriptService")
local serverStorage = game:GetService("ServerStorage")
local players = game:GetService("Players")

local events = replicatedStorage.RemoteEvents
local gameStartEvent = events.GameStartEvent
local mapVoteEvent = events.MapVoteEvent
local roundEndEvent = events.RoundEndEvent
local taggerEvent = events.TaggerEvent
local pendingRewardsEvent = replicatedStorage.PendingRewards

local roundInformation = require(serverScriptService.Directories.RoundInformation)
local playerManager = require(serverScriptService.Utilities.PlayerManager)
local LavaHandler = require(script.LavaHandler)
local gameInfo = require(serverScriptService.Directories.GameInformation)

local roundLength = replicatedStorage.GameInformation.RoundLength
local intermissionLength = replicatedStorage.GameInformation.IntermissionLength

local currentMap = workspace.CurrentMap
local selectionBox = workspace.SelectionBox
local lobby = workspace.Lobby
local lobbySpawns = lobby.LobbySpawns:GetChildren()

local SURVIVOR_HIGHLIGHT = Color3.fromRGB(177, 119, 255)
local INFECTED_HIGHLIGHT = Color3.fromRGB(255, 18, 4)
local ELIMINATED_HIGHLIGHT = Color3.fromRGB(63, 221, 0)

local currentPlayers = {}
local infectedHandlers = {}
local pendingRewards = {}
local currMap = nil
local roundEnded = true
local playerRemovingConnection
local playerAddedConnection
local activeMapSpawns
local votingState = nil

local MAP_VOTE_DURATION = 10

--[[

TODO: Simplify/Shorten Code to ~600 lines
TODO: change to general class for other games (???)
TODO: finish highlight cool stuff


--]]

local function getRoundPlayers()
	local roundPlayers = {}
	for _, player in ipairs(players:GetPlayers()) do
		if not player:GetAttribute("IsInTutorial") and player:GetAttribute("TutorialComplete") == true then
			table.insert(roundPlayers, player)
		end
	end
	return roundPlayers
end

local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

local function chooseLobbySpawn()
	return lobbySpawns[math.random(1, #lobbySpawns)]
end

local function getPrompt(character)
	local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return nil
	end

	local prompt = humanoidRootPart:FindFirstChild("TagPrompt")
	if prompt then
		return prompt
	end

	prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TagPrompt"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.ActionText = "Infect"
	prompt.Parent = humanoidRootPart
	return prompt
end

local function disablePrompt(character)
	local prompt = getPrompt(character)
	if not prompt then
		return
	end

	prompt.Enabled = false
	prompt:SetAttribute("Tagger", "_")
end

local function setRoundAttributes(player, role, inRound)
	local isInfected = role == "Infected"
	player:SetAttribute("InRound", inRound)
	player:SetAttribute("Tagger", isInfected)
	player:SetAttribute("RoundRole", role)

	local character = player.Character
	if not character then
		return
	end

	character:SetAttribute("InRound", inRound)
	character:SetAttribute("Tagger", isInfected)
	character:SetAttribute("RoundRole", role)
end

local function applyHighlight(character, role)
	if not character then
		return
	end

	local highlight = character:FindFirstChild("TagHighlight")
	if not highlight then
		highlight = Instance.new("Highlight")
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 0
		highlight.Name = "TagHighlight"
		highlight.Parent = character
	end

	if role == "Infected" then
		highlight.OutlineColor = INFECTED_HIGHLIGHT
	elseif role == "Eliminated" then
		highlight.OutlineColor = ELIMINATED_HIGHLIGHT
	else
		highlight.OutlineColor = SURVIVOR_HIGHLIGHT
	end
end

local function getSpawnFolder(map)
	return map and map:FindFirstChild("Spawns")
end

local function getLavaSpawn(spawns)
	if not spawns then
		return nil
	end

	for _, spawn in ipairs(spawns) do
		if spawn.Name == "LavaSpawnLocation" then
			return spawn
		end
	end

	return spawns[1]
end

local function getSurvivorSpawn(spawns)
	if not spawns or #spawns == 0 then
		return nil
	end

	local validSpawns = {}
	for _, spawn in ipairs(spawns) do
		if spawn.Name ~= "LavaSpawnLocation" then
			table.insert(validSpawns, spawn)
		end
	end

	if #validSpawns == 0 then
		return spawns[1]
	end

	return validSpawns[math.random(1, #validSpawns)]
end

local function collectWinners()
	local winners = {}
	for _, state in pairs(currentPlayers) do
		if state.Player and state.Active and state.Role == "Survivor" then
			table.insert(winners, state.Player.Name)
		end
	end
	return winners
end

local function getActiveCount(role)
	local count = 0
	for _, state in pairs(currentPlayers) do
		if state.Active and state.Role == role then
			count += 1
		end
	end
	return count
end

local function queueRoundRewards()
	local winners = collectWinners()
	
	for i, winner in pairs(winners) do
		playerManager:AddWins(game.Players:GetPlayerFromCharacter(workspace:FindFirstChild(winner)), 1)
	end

	for _, state in pairs(currentPlayers) do
		local player = state.Player
		if not player then
			continue
		end

		local survived = state.Active and state.Role == "Survivor"
		local survivalCoins = survived and gameInfo.SurvivalCoins or 0
		local level = playerManager:GetLevel(player)
		if not level then
			continue
		end

		local cash = survivalCoins + gameInfo.ParticipationCoins
		local xp = (level ^ 1.35) * 151
		if survived then
			xp *= 1.15
		end

		roundEndEvent:FireClient(player, survived, cash * playerManager:GetCashMultiplier(player), winners)
		pendingRewards[player.Name] = {
			AllowedMultiplier = 1,
			Survived = survived,
		}
		playerManager:AddXP(player, xp)

		task.delay(15, function()
			pendingRewards[player.Name] = nil
		end)
	end
end

local function clean()
	for _, child in ipairs(currentMap:GetChildren()) do
		child:Destroy()
	end

	local previewModel = selectionBox:FindFirstChildOfClass("Model")
	if previewModel then
		previewModel:Destroy()
	end

	for _, handler in pairs(infectedHandlers) do
		handler:Clean()
	end
	infectedHandlers = {}

	for _, player in ipairs(players:GetPlayers()) do
		setRoundAttributes(player, "Spectator", false)
		local character = player.Character
		if character then
			disablePrompt(character)
			local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
			if humanoidRootPart then
				humanoidRootPart.CFrame = chooseLobbySpawn().CFrame * CFrame.new(0, 4, 0)
			end
		end
	end

	queueRoundRewards()

	disconnect(playerRemovingConnection)
	disconnect(playerAddedConnection)
	playerRemovingConnection = nil
	playerAddedConnection = nil

	task.delay(3, function()
		if currMap then
			currMap:Destroy()
			currMap = nil
		end
	end)

	currentPlayers = {}
	activeMapSpawns = nil
end

local function endRound()
	if roundEnded then
		return
	end

	roundEnded = true

	for _, state in pairs(currentPlayers) do
		local player = state.Player
		if not player or player.Parent ~= players then
			continue
		end

		gameStartEvent:FireClient(player, nil)

		local character = player.Character
		if character then
			local highlight = character:FindFirstChild("TagHighlight")
			if highlight then
				highlight:Destroy()
			end
		end

		task.spawn(function()
			if player.UserId > 0 then
				pcall(function()
					local description = players:GetHumanoidDescriptionFromUserIdAsync(player.UserId)
					player:LoadCharacterWithHumanoidDescriptionAsync(description)
				end)
			else
				player:LoadCharacter()
			end
		end)
	end

	task.delay(2, clean)
end

local function evaluateRoundState()
	if roundEnded then
		return
	end

	local survivorCount = getActiveCount("Survivor")
	local infectedCount = getActiveCount("Infected")
	if survivorCount <= 0 or infectedCount <= 0 or #getRoundPlayers() < 2 then
		endRound()
	end
end

local function attachCharacterState(player)
	local state = currentPlayers[player.Name]
	if not state then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	state.Character = character
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.Died:Once(function()
		if roundEnded then
			return
		end

		local latestState = currentPlayers[player.Name]
		if not latestState or not latestState.Active then
			return
		end

		latestState.Active = false
		setRoundAttributes(player, "Eliminated", false)
		applyHighlight(player.Character, "Eliminated")
		evaluateRoundState()
	end)
end

local function spawnParticipant(player, role, spawnPart)
	if not player.Character or not spawnPart then
		return
	end

	local character = player.Character
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		return
	end

	getPrompt(character)
	disablePrompt(character)
	setRoundAttributes(player, role, true)
	applyHighlight(character, role)

	currentPlayers[player.Name] = {
		Player = player,
		Character = character,
		Role = role,
		Active = true,
		PendingInfection = false,
	}

	player.RespawnLocation = chooseLobbySpawn()
	character:PivotTo(spawnPart.CFrame * CFrame.new(0, 2, 0))
	attachCharacterState(player)
end

local function spawnMap(mapTemplate)
	local maps = serverStorage.Maps:GetChildren()
	local selectedTemplate = mapTemplate or maps[math.random(1, #maps)]
	local map = selectedTemplate:Clone()
	if map:IsA("Model") then
		map:PivotTo(lobby.PrimaryPart.CFrame * CFrame.new(map:GetExtentsSize().X + 125, 676, map:GetExtentsSize().Y + 125))
		local orientation = map:GetAttribute("Orientation")
		if orientation then
			map:PivotTo(CFrame.Angles(math.rad(orientation.X), math.rad(orientation.Y), math.rad(orientation.Z)))
		end
	elseif map:IsA("Part") then
		map.CFrame = lobby.PrimaryPart.CFrame * CFrame.new(map.Size.X + 125, 676, map.Size.Y + 125)
	end
	map.Parent = currentMap
	currMap = map
	return map
end

local function chooseMapChoices()
	local availableMaps = serverStorage.Maps:GetChildren()
	local choices = {}
	local maxChoices = math.min(3, #availableMaps)

	for _ = 1, maxChoices do
		local index = math.random(1, #availableMaps)
		table.insert(choices, availableMaps[index])
		table.remove(availableMaps, index)
	end

	return choices
end

local function serializeMapChoices(choices)
	local serialized = {}
	for index, mapTemplate in ipairs(choices) do
		table.insert(serialized, {
			Index = index,
			Name = mapTemplate.Name,
			DisplayName = mapTemplate:GetAttribute("DisplayName") or mapTemplate.Name,
		})
	end
	return serialized
end

local function getVoteCounts()
	local counts = {}
	if not votingState then
		return counts
	end

	for index = 1, #votingState.Choices do
		counts[index] = 0
	end

	for _, choiceIndex in pairs(votingState.PlayerVotes) do
		if counts[choiceIndex] then
			counts[choiceIndex] += 1
		end
	end

	return counts
end

local function broadcastMapVote(action, extraPayload)
	local payload = extraPayload or {}
	if votingState then
		payload.Choices = serializeMapChoices(votingState.Choices)
		payload.VoteCounts = getVoteCounts()
		payload.Duration = MAP_VOTE_DURATION
		payload.TimeLeft = votingState.TimeLeft or payload.TimeLeft or MAP_VOTE_DURATION
	end

	for _, player in ipairs(getRoundPlayers()) do
		mapVoteEvent:FireClient(player, action, payload)
	end
end

local function resolveMapVote()
	local counts = getVoteCounts()
	local topVoteCount = -1
	local topChoices = {}

	for index = 1, #votingState.Choices do
		local voteCount = counts[index] or 0
		if voteCount > topVoteCount then
			topVoteCount = voteCount
			topChoices = {index}
		elseif voteCount == topVoteCount then
			table.insert(topChoices, index)
		end
	end

	if #topChoices == 0 then
		return votingState.Choices[math.random(1, #votingState.Choices)]
	end

	local winningIndex = topChoices[math.random(1, #topChoices)]
	return votingState.Choices[winningIndex]
end

local function runMapVote()
	local choices = chooseMapChoices()
	if #choices == 0 then
		return nil
	end

	votingState = {
		Active = true,
		Choices = choices,
		PlayerVotes = {},
		TimeLeft = MAP_VOTE_DURATION,
	}

	for countdown = MAP_VOTE_DURATION, 1, -1 do
		if roundEnded then
			break
		end
		votingState.TimeLeft = countdown
		broadcastMapVote("Start", {TimeLeft = countdown})
		task.wait(1)
	end

	local selectedMap = resolveMapVote()
	broadcastMapVote("End", {
		Winner = selectedMap and selectedMap.Name or nil,
		TimeLeft = 0,
	})

	votingState.Active = false
	votingState = nil
	return selectedMap
end

local function getInitialInfected()
	local availablePlayers = {}
	for _, player in ipairs(getRoundPlayers()) do
		if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
			table.insert(availablePlayers, player)
		end
	end

	if #availablePlayers == 0 then
		return nil
	end

	return availablePlayers[math.random(1, #availablePlayers)]
end

function RoundManager:CanInfect(sourcePlayer, targetCharacter)
	if roundEnded or not sourcePlayer or not targetCharacter then
		return false
	end

	local targetPlayer = players:GetPlayerFromCharacter(targetCharacter)
	if not targetPlayer then
		return false
	end

	local sourceState = currentPlayers[sourcePlayer.Name]
	local targetState = currentPlayers[targetPlayer.Name]
	if not sourceState or not targetState then
		return false
	end

	if not sourceState.Active or sourceState.Role ~= "Infected" then
		return false
	end

	if not targetState.Active or targetState.Role ~= "Survivor" or targetState.PendingInfection then
		return false
	end

	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function RoundManager:InfectPlayer(targetPlayer, sourcePlayer, blobPart)
	local state = currentPlayers[targetPlayer.Name]
	if not state or not state.Active or state.Role ~= "Survivor" or state.PendingInfection then
		return false
	end

	state.PendingInfection = true
	local oldCharacter = targetPlayer.Character
	if oldCharacter then
		disablePrompt(oldCharacter)
		if blobPart then
			taggerEvent:FireAllClients(oldCharacter, blobPart)
		end
	end

	task.delay(0.35, function()
		if roundEnded then
			return
		end

		local latestState = currentPlayers[targetPlayer.Name]
		if not latestState or latestState.Role ~= "Survivor" or not latestState.PendingInfection then
			return
		end

		local handler = LavaHandler.New(targetPlayer, {
			canTag = function(infectedPlayer, targetCharacter)
				return RoundManager:CanInfect(infectedPlayer, targetCharacter)
			end,
			onTagged = function(infectedPlayer, targetCharacter, currentBlob)
				local infectedTarget = players:GetPlayerFromCharacter(targetCharacter)
				if not infectedTarget then
					return false
				end
				local infectedHandler = infectedHandlers[infectedPlayer.Name]
				if infectedHandler then
					infectedHandler:BoostSpeed()
				end
				return RoundManager:InfectPlayer(infectedTarget, infectedPlayer, currentBlob)
			end,
		})

		infectedHandlers[targetPlayer.Name] = handler
		latestState.PendingInfection = false
		latestState.Role = "Infected"
		latestState.Active = true

		local sourceHandler = sourcePlayer and infectedHandlers[sourcePlayer.Name] or nil
		local spawnCFrame
		if sourceHandler and sourceHandler:GetPivotCFrame() then
			spawnCFrame = sourceHandler:GetPivotCFrame()
		elseif oldCharacter then
			spawnCFrame = oldCharacter:GetPivot()
		else
			local lavaSpawn = getLavaSpawn(activeMapSpawns)
			spawnCFrame = lavaSpawn and lavaSpawn.CFrame or CFrame.new()
		end

		local success = handler:InitModel(spawnCFrame)
		if not success then
			latestState.Active = false
			setRoundAttributes(targetPlayer, "Eliminated", false)
			evaluateRoundState()
			return
		end

		latestState.Character = targetPlayer.Character
		setRoundAttributes(targetPlayer, "Infected", true)
		applyHighlight(targetPlayer.Character, "Infected")
		attachCharacterState(targetPlayer)
		evaluateRoundState()
	end)

	return true
end

local function startRound(map, initialInfectedPlayer)
	local spawnFolder = getSpawnFolder(map)
	if not spawnFolder then
		return false
	end

	activeMapSpawns = spawnFolder:GetChildren()
	local lavaSpawn = getLavaSpawn(activeMapSpawns)
	if not lavaSpawn then
		return false
	end

	local initialHandler = LavaHandler.New(initialInfectedPlayer, {
		canTag = function(infectedPlayer, targetCharacter)
			return RoundManager:CanInfect(infectedPlayer, targetCharacter)
		end,
		onTagged = function(infectedPlayer, targetCharacter, blobPart)
			local targetPlayer = players:GetPlayerFromCharacter(targetCharacter)
			if not targetPlayer then
				return false
			end
			local infectedHandler = infectedHandlers[infectedPlayer.Name]
			if infectedHandler then
				infectedHandler:BoostSpeed()
			end
			return RoundManager:InfectPlayer(targetPlayer, infectedPlayer, blobPart)
		end,
	})

	infectedHandlers[initialInfectedPlayer.Name] = initialHandler
	
	
	--find osme way to get rid of this delay 
	task.delay(0.75, function()
		local preview = initialHandler.LavaModel:Clone()
		preview.Parent = selectionBox
		preview:PivotTo(selectionBox.BlobStarting.CFrame)
	end)

	for _, player in ipairs(getRoundPlayers()) do
		gameStartEvent:FireClient(player, initialInfectedPlayer)
	end

	task.wait(12)

	local previewModel = selectionBox:FindFirstChildOfClass("Model")
	if previewModel then
		previewModel:Destroy()
	end

	if roundEnded then
		return false
	end

	if not initialHandler:InitModel(lavaSpawn.CFrame * CFrame.new(0, 2, 0)) then
		return false
	end

	currentPlayers[initialInfectedPlayer.Name] = {
		Player = initialInfectedPlayer,
		Character = initialInfectedPlayer.Character,
		Role = "Infected",
		Active = true,
		PendingInfection = false,
	}
	setRoundAttributes(initialInfectedPlayer, "Infected", true)
	applyHighlight(initialInfectedPlayer.Character, "Infected")
	attachCharacterState(initialInfectedPlayer)

	for _, player in ipairs(getRoundPlayers()) do
		if player == initialInfectedPlayer then
			continue
		end

		local survivorSpawn = getSurvivorSpawn(activeMapSpawns)
		spawnParticipant(player, "Survivor", survivorSpawn)
	end

	return true
end

roundEndEvent.OnServerEvent:Connect(function(player, multiplier)
	if multiplier ~= 1 and multiplier ~= 3 then
		return
	end

	local rewardData = pendingRewards[player.Name]
	if not rewardData or rewardData.AllowedMultiplier ~= multiplier then
		return
	end

	local survivalCoins = rewardData.Survived and gameInfo.SurvivalCoins or 0
	local total = (survivalCoins + gameInfo.ParticipationCoins) * multiplier
	playerManager:AddMoney(player, total)
	pendingRewards[player.Name] = nil
end)

pendingRewardsEvent.Event:Connect(function(player)
	local rewardData = pendingRewards[player.Name]
	if rewardData then
		rewardData.AllowedMultiplier = 3
	end
end)

mapVoteEvent.OnServerEvent:Connect(function(player, choiceIndex)
	if not votingState or not votingState.Active then
		return
	end

	if player:GetAttribute("IsInTutorial") or player:GetAttribute("TutorialComplete") ~= true then
		return
	end

	if typeof(choiceIndex) ~= "number" then
		return
	end

	choiceIndex = math.floor(choiceIndex)
	if not votingState.Choices[choiceIndex] then
		return
	end

	votingState.PlayerVotes[player.UserId] = choiceIndex
	broadcastMapVote("Update")
end)

function RoundManager:Init()
	roundLength.Value = roundInformation.RoundLength
	intermissionLength.Value = roundInformation.IntermissionLength
	
	
	--need to change logic so that it dynamically checks
	--maybe use coroutines in the future?
	--alex, this works but if you have any ideas lmk

	task.spawn(function()
		while true do
			task.wait(0.25)
			if #getRoundPlayers() < 2 then
				continue
			end

			roundEnded = false
			roundLength.Value = -1

			disconnect(playerRemovingConnection)
			disconnect(playerAddedConnection)

			playerRemovingConnection = players.PlayerRemoving:Connect(function(leavingPlayer)
				currentPlayers[leavingPlayer.Name] = nil
				if votingState then
					votingState.PlayerVotes[leavingPlayer.UserId] = nil
					broadcastMapVote("Update")
				end

				local handler = infectedHandlers[leavingPlayer.Name]
				if handler then
					handler:Clean()
					infectedHandlers[leavingPlayer.Name] = nil
				end

				if not roundEnded then
					evaluateRoundState()
				end
			end)

			playerAddedConnection = players.PlayerAdded:Connect(function(joiningPlayer)
				if joiningPlayer:GetAttribute("IsInTutorial") or joiningPlayer:GetAttribute("TutorialComplete") ~= true then
					return
				end

				if intermissionLength.Value == -1 and not roundEnded then
					repeat task.wait() until joiningPlayer.Character

					setRoundAttributes(joiningPlayer, "Spectator", false)
					disablePrompt(joiningPlayer.Character)
					local spawnPart = chooseLobbySpawn()
					local humanoidRootPart = joiningPlayer.Character:FindFirstChild("HumanoidRootPart")
					if humanoidRootPart then
						humanoidRootPart.CFrame = spawnPart.CFrame * CFrame.new(0, 4, 0)
					end
				end
			end)

			for countdown = roundInformation.IntermissionLength, 1, -1 do
				if roundEnded then
					break
				end
				intermissionLength.Value = countdown
				task.wait(1)
			end

			if roundEnded then
				continue
			end

			local selectedMapTemplate = runMapVote()
			if roundEnded then
				continue
			end

			if #getRoundPlayers() < 2 then
				endRound()
				continue
			end

			local map = spawnMap(selectedMapTemplate)
			local initialInfectedPlayer = getInitialInfected()
			if not initialInfectedPlayer then
				endRound()
				continue
			end

			local roundStarted = startRound(map, initialInfectedPlayer)
			if not roundStarted then
				if not roundEnded then
					endRound()
				end
				continue
			end

			intermissionLength.Value = -1
			for countdown = roundInformation.RoundLength, 1, -1 do
				if roundEnded then
					break
				end
				roundLength.Value = countdown
				task.wait(1)
			end

			if not roundEnded then
				endRound()
			end
		end
	end)
end

return RoundManager
