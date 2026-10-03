local RoundManager = {}  

local replicatedStorage = game:GetService("ReplicatedStorage") 
local serverScriptService = game:GetService("ServerScriptService")  
local serverStorage = game:GetService("ServerStorage")  
local players = game:GetService("Players") 

local events = replicatedStorage.RemoteEvents 
local gameStartEvent = events.GameStartEvent  -- remoteevent reference used by the server to tell one client that round setup is starting
local mapVoteEvent = events.MapVoteEvent  -- same remote handles vote messages in both directions, so the server can broadcast and receive choices
local roundEndEvent = events.RoundEndEvent  -- remoteevent is reused for showing round results and receiving the claimed reward multiplier
local taggerEvent = events.TaggerEvent  -- remoteevent sends infection visuals to clients without making the client authoritative
local pendingRewardsEvent = replicatedStorage.PendingRewards  -- bindable event stays on the server and only changes reward state internally

local roundInformation = require(serverScriptService.Directories.RoundInformation)  -- require runs this module once and gives this script its round timing config table
local playerManager = require(serverScriptService.Utilities.PlayerManager)  -- player manager module keeps money, xp, wins, and level logic outside the round manager
local LavaHandler = require(script.LavaHandler)  -- lava handler module owns the infected character behavior while this script owns round state
local gameInfo = require(serverScriptService.Directories.GameInformation)  -- shared game config is required once so reward values come from one source

local roundLength = replicatedStorage.GameInformation.RoundLength  -- value object is replicated so clients can read the current round countdown
local intermissionLength = replicatedStorage.GameInformation.IntermissionLength  -- replicated value object is used the same way for the intermission countdown

local currentMap = workspace.CurrentMap  -- workspace folder is the runtime container for whichever map clone is active
local selectionBox = workspace.SelectionBox  -- workspace model is used for the infected preview before the round begins
local lobby = workspace.Lobby  -- cached lobby reference avoids repeatedly walking the workspace hierarchy
local lobbySpawns = lobby.LobbySpawns:GetChildren()  -- getchildren returns the lobby spawn instances as an array for random indexing

local SURVIVOR_HIGHLIGHT = Color3.fromRGB(177, 119, 255)  -- color3.fromrgb builds the survivor outline color from 0-255 rgb values
local INFECTED_HIGHLIGHT = Color3.fromRGB(255, 18, 4)  -- constant keeps the infected outline color in one place
local ELIMINATED_HIGHLIGHT = Color3.fromRGB(63, 221, 0)  -- constant keeps eliminated players visually separate from both active roles

local currentPlayers = {}  -- dictionary keyed by player name stores the server's current role/state record for each participant
local infectedHandlers = {}  -- dictionary keeps each infected player's lava handler so it can be reused and cleaned later
local pendingRewards = {}  -- temporary server table tracks which reward multiplier each player is currently allowed to claim
local currMap = nil  -- holds the actual cloned map instance so cleanup can destroy it after the round
local roundEnded = true  -- boolean acts like a round-wide guard so delayed callbacks know when their work is stale
local playerRemovingConnection
local playerAddedConnection
local activeMapSpawns
local votingState = nil  -- nil when voting is inactive, otherwise this table holds choices, votes, and time left

local MAP_VOTE_DURATION = 10

local function getRoundPlayers()  -- local function keeps this helper inside this module; it builds the eligible player list used by voting and round setup
	local roundPlayers = {}
	for _, player in ipairs(players:GetPlayers()) do
		if not player:GetAttribute("IsInTutorial") and player:GetAttribute("TutorialComplete") == true then
			table.insert(roundPlayers, player)
		end
	end
	return roundPlayers
end

local function disconnect(connection)  -- local function keeps this helper inside this module; small cleanup helper makes disconnecting optional connections safe
	if connection then
		connection:Disconnect()
	end
end

local function chooseLobbySpawn()  -- local function keeps this helper inside this module; helper centralizes random lobby spawn selection
	return lobbySpawns[math.random(1, #lobbySpawns)]
end

local function getPrompt(character)  -- local function keeps this helper inside this module; helper either reuses a tag prompt or creates the one this character needs
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

local function disablePrompt(character)  -- local function keeps this helper inside this module; helper resets a character's tag prompt when they should not be taggable
	local prompt = getPrompt(character)
	if not prompt then
		return
	end

	prompt.Enabled = false
	prompt:SetAttribute("Tagger", "_")  -- setattribute resets the prompt metadata without needing another object for state
end

local function setRoundAttributes(player, role, inRound)  -- local function keeps this helper inside this module; keeps the player and character attributes synchronized from one function
	local isInfected = role == "Infected"
	player:SetAttribute("InRound", inRound)  -- player attributes replicate simple round state to any client systems that need it
	player:SetAttribute("Tagger", isInfected)
	player:SetAttribute("RoundRole", role)

	local character = player.Character
	if not character then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	character:SetAttribute("InRound", inRound)  -- mirroring the state on the character lets character-based systems read it directly
	character:SetAttribute("Tagger", isInfected)
	character:SetAttribute("RoundRole", role)
end

local function applyHighlight(character, role)  -- local function keeps this helper inside this module; owns highlight creation and role-based outline selection
	if not character then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	local highlight = character:FindFirstChild("TagHighlight")  -- findfirstchild lets the same highlight be reused instead of stacking duplicates
	if not highlight then  -- the not check makes this branch run only when the required value/state is false or missing
		highlight = Instance.new("Highlight")
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 0
		highlight.Name = "TagHighlight"
		highlight.Parent = character
	end

	if role == "Infected" then  -- this branch checks the role string first so the right outline color can be picked
		highlight.OutlineColor = INFECTED_HIGHLIGHT
	elseif role == "Eliminated" then
		highlight.OutlineColor = ELIMINATED_HIGHLIGHT
	else
		highlight.OutlineColor = SURVIVOR_HIGHLIGHT
	end
end

local function getSpawnFolder(map)  -- local function keeps this helper inside this module; returns the map's spawn folder while safely handling a nil map
	return map and map:FindFirstChild("Spawns")  -- the and expression returns nil cleanly when either the map or folder is missing
end

local function getLavaSpawn(spawns)  -- local function keeps this helper inside this module; searches the spawn array for the dedicated infected spawn
	if not spawns then  -- the not check makes this branch run only when the required value/state is false or missing
		return nil
	end

	for _, spawn in ipairs(spawns) do  -- ipairs is used because spawns is a sequential array returned by getchildren
		if spawn.Name == "LavaSpawnLocation" then  -- the name check marks the one spawn reserved for the infected model
			return spawn
		end
	end

	return spawns[1]
end

local function getSurvivorSpawn(spawns)  -- local function keeps this helper inside this module; filters out the lava spawn before choosing a random survivor position
	if not spawns or #spawns == 0 then  -- the length check prevents math.random or indexing from using an empty array
		return nil
	end

	local validSpawns = {}
	for _, spawn in ipairs(spawns) do  -- ipairs is used because spawns is a sequential array returned by getchildren
		if spawn.Name ~= "LavaSpawnLocation" then  -- the ~= check excludes the infected-only location from survivor choices
			table.insert(validSpawns, spawn)  -- append builds a second array without changing the original map spawn list
		end
	end

	if #validSpawns == 0 then  -- this check decides whether the branch below should run using the current state
		return spawns[1]
	end

	return validSpawns[math.random(1, #validSpawns)]  -- random indexing gives survivors different valid spawn points
end

local function collectWinners()  -- local function keeps this helper inside this module; creates a name list from players who are still active survivors
	local winners = {}
	for _, state in pairs(currentPlayers) do  -- pairs is used because currentplayers is a dictionary keyed by player name
		if state.Player and state.Active and state.Role == "Survivor" then  -- both flags must be true so eliminated or infected players cannot count as winners
			table.insert(winners, state.Player.Name)  -- only the player name is stored because this list is sent to clients later
		end
	end
	return winners
end

local function getActiveCount(role)  -- local function keeps this helper inside this module; counts active players for one role so round end checks stay simple
	local count = 0
	for _, state in pairs(currentPlayers) do  -- pairs is used because currentplayers is a dictionary keyed by player name
		if state.Active and state.Role == role then  -- this check decides whether the branch below should run using the current state
			count += 1
		end
	end
	return count
end

local function queueRoundRewards()  -- local function keeps this helper inside this module; calculates round rewards first, then leaves the final money claim in pending rewards
	local winners = collectWinners()  -- the helper is called once so the same winner list is reused for rewards and ui
	
	for i, winner in pairs(winners) do
		playerManager:AddWins(game.Players:GetPlayerFromCharacter(workspace:FindFirstChild(winner)), 1)
	end

	for _, state in pairs(currentPlayers) do  -- pairs is used because currentplayers is a dictionary keyed by player name
		local player = state.Player
		if not player then  -- the not check makes this branch run only when the required value/state is false or missing
			continue
		end

		local survived = state.Active and state.Role == "Survivor"  -- both flags must be true so eliminated or infected players cannot count as winners
		local survivalCoins = survived and gameInfo.SurvivalCoins or 0
		local level = playerManager:GetLevel(player)
		if not level then  -- the not check makes this branch run only when the required value/state is false or missing
			continue
		end

		local cash = survivalCoins + gameInfo.ParticipationCoins
		local xp = (level ^ 1.35) * 151
		if survived then  -- this check decides whether the branch below should run using the current state
			xp *= 1.15
		end

		roundEndEvent:FireClient(player, survived, cash * playerManager:GetCashMultiplier(player), winners)  -- fireclient sends only this player's result payload instead of broadcasting private reward data
		pendingRewards[player.Name] = {  -- a server-only record is created so later client claims can be validated
			AllowedMultiplier = 1,
			Survived = survived,
		}
		playerManager:AddXP(player, xp)

		task.delay(15, function()  -- task.delay schedules expiry without blocking the round cleanup thread
			pendingRewards[player.Name] = nil  -- removing the record makes the same round reward impossible to claim twice
		end)
	end
end

local function clean()  -- local function keeps this helper inside this module; resets map, handlers, player state, connections, and round tables after a round
	for _, child in ipairs(currentMap:GetChildren()) do  -- ipairs walks this array in numeric order while _ ignores the index because only the value is needed
		child:Destroy()  -- destroy removes the runtime instance and all of its descendants
	end

	local previewModel = selectionBox:FindFirstChildOfClass("Model")  -- findfirstchildofclass ignores the model name and just finds the current preview model
	if previewModel then  -- this check decides whether the branch below should run using the current state
		previewModel:Destroy()  -- destroy removes this runtime instance so no stale object is left for the next round
	end

	for _, handler in pairs(infectedHandlers) do  -- pairs walks the dictionary values because its keys are not being used here
		handler:Clean()
	end
	infectedHandlers = {}  -- replacing the table drops all old handler references after they have been cleaned

	for _, player in ipairs(players:GetPlayers()) do  -- getplayers returns the current player array from the players service
		setRoundAttributes(player, "Spectator", false)
		local character = player.Character
		if character then  -- this check decides whether the branch below should run using the current state
			disablePrompt(character)
			local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")  -- findfirstchild returns nil instead of throwing if the root part is missing
			if humanoidRootPart then  -- this check decides whether the branch below should run using the current state
				humanoidRootPart.CFrame = chooseLobbySpawn().CFrame * CFrame.new(0, 4, 0)  -- cframe multiplication applies a four-stud local offset above the chosen lobby spawn
			end
		end
	end

	queueRoundRewards()

	disconnect(playerRemovingConnection)
	disconnect(playerAddedConnection)
	playerRemovingConnection = nil
	playerAddedConnection = nil

	task.delay(3, function()
		if currMap then  -- this check decides whether the branch below should run using the current state
			currMap:Destroy()  -- the cloned map is destroyed after a short delay instead of touching the serverstorage template
			currMap = nil
		end
	end)

	currentPlayers = {}  -- resetting the dictionary guarantees no previous participant state leaks into the next round
	activeMapSpawns = nil
end

local function endRound()  -- local function keeps this helper inside this module; sets the end guard once and starts the visual/character reset sequence
	if roundEnded then  -- this check decides whether the branch below should run using the current state
		return
	end

	roundEnded = true

	for _, state in pairs(currentPlayers) do  -- pairs is used because currentplayers is a dictionary keyed by player name
		local player = state.Player
		if not player or player.Parent ~= players then  -- the parent check skips stale player references that already left the server
			continue
		end

		gameStartEvent:FireClient(player, nil)  -- nil is used as the stop/reset payload for the client's round intro state

		local character = player.Character
		if character then  -- this check decides whether the branch below should run using the current state
			local highlight = character:FindFirstChild("TagHighlight")  -- findfirstchild lets the same highlight be reused instead of stacking duplicates
			if highlight then  -- this check decides whether the branch below should run using the current state
				highlight:Destroy()  -- the role outline is removed before the character is reloaded
			end
		end

		task.spawn(function()  -- task.spawn starts this work on a separate scheduler thread so the outer loop can keep moving
			if player.UserId > 0 then  -- this check decides whether the branch below should run using the current state
				pcall(function()  -- pcall contains async avatar-loading errors so one failure does not break round cleanup
					local description = players:GetHumanoidDescriptionFromUserIdAsync(player.UserId)  -- the async call rebuilds the player's normal avatar description from their userid
					player:LoadCharacterWithHumanoidDescriptionAsync(description)  -- the saved description is passed into the async character reload
				end)
			else
				player:LoadCharacter()  -- studio/test players with nonpositive userids fall back to a normal character reload
			end
		end)
	end

	task.delay(2, clean)  -- cleanup is delayed briefly so client round-end visuals can finish before the map resets
end

local function evaluateRoundState()  -- local function keeps this helper inside this module; checks the win/end conditions after deaths, infections, and players leaving
	if roundEnded then  -- this check decides whether the branch below should run using the current state
		return
	end

	local survivorCount = getActiveCount("Survivor")
	local infectedCount = getActiveCount("Infected")
	if survivorCount <= 0 or infectedCount <= 0 or #getRoundPlayers() < 2 then  -- the or chain ends the round as soon as either active team has nobody left
		endRound()
	end
end

local function attachCharacterState(player)  -- local function keeps this helper inside this module; binds this participant's humanoid death to the round state table
	local state = currentPlayers[player.Name]  -- player name is the dictionary key used consistently for this round's state lookup
	if not state then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	local character = player.Character
	if not character then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	state.Character = character
	local humanoid = character:FindFirstChildOfClass("Humanoid")  -- findfirstchildofclass gets the humanoid even if its instance name was changed
	if not humanoid then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	humanoid.Died:Once(function()  -- once automatically disconnects after the first death so this character cannot report twice
		if roundEnded then  -- this check decides whether the branch below should run using the current state
			return
		end

		local latestState = currentPlayers[player.Name]  -- player name is the dictionary key used consistently for this round's state lookup
		if not latestState or not latestState.Active then  -- the not check makes this branch run only when the required value/state is false or missing
			return
		end

		latestState.Active = false
		setRoundAttributes(player, "Eliminated", false)
		applyHighlight(player.Character, "Eliminated")
		evaluateRoundState()
	end)
end

local function spawnParticipant(player, role, spawnPart)  -- local function keeps this helper inside this module; sets up a normal participant using one role and one chosen map spawn
	if not player.Character or not spawnPart then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	local character = player.Character
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")  -- findfirstchild returns nil instead of throwing if the root part is missing
	if not humanoidRootPart then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	getPrompt(character)
	disablePrompt(character)
	setRoundAttributes(player, role, true)
	applyHighlight(character, role)

	currentPlayers[player.Name] = {  -- player name is the dictionary key used consistently for this round's state lookup
		Player = player,
		Character = character,
		Role = role,
		Active = true,
		PendingInfection = false,
	}

	player.RespawnLocation = chooseLobbySpawn()
	character:PivotTo(spawnPart.CFrame * CFrame.new(0, 2, 0))  -- pivotto moves the full character model together instead of setting individual part positions
	attachCharacterState(player)
end

local function spawnMap(mapTemplate)  -- local function keeps this helper inside this module; clones a selected map template and places the runtime copy beside the lobby
	local maps = serverStorage.Maps:GetChildren()
	local selectedTemplate = mapTemplate or maps[math.random(1, #maps)]  -- lua's or uses the voted template when provided and only falls back to a random map
	local map = selectedTemplate:Clone()  -- clone creates a runtime copy so the original template stays unchanged
	if map:IsA("Model") then  -- isa branches on the map instance type because models and parts are positioned differently
		map:PivotTo(lobby.PrimaryPart.CFrame * CFrame.new(map:GetExtentsSize().X + 125, 676, map:GetExtentsSize().Y + 125))  -- getextentssize measures the whole model so the offset can account for map dimensions
		local orientation = map:GetAttribute("Orientation")  -- the optional orientation attribute lets each template provide its own rotation data
		if orientation then  -- this check decides whether the branch below should run using the current state
			map:PivotTo(CFrame.Angles(math.rad(orientation.X), math.rad(orientation.Y), math.rad(orientation.Z)))  -- math.rad converts stored degree values because cframe.angles expects radians
		end
	elseif map:IsA("Part") then
		map.CFrame = lobby.PrimaryPart.CFrame * CFrame.new(map.Size.X + 125, 676, map.Size.Y + 125)
	end
	map.Parent = currentMap
	currMap = map
	return map
end

local function chooseMapChoices()  -- local function keeps this helper inside this module; picks up to three unique map templates without modifying serverstorage itself
	local availableMaps = serverStorage.Maps:GetChildren()
	local choices = {}
	local maxChoices = math.min(3, #availableMaps)  -- math.min caps voting at three while still supporting games with fewer maps

	for _ = 1, maxChoices do  -- numeric for keeps the loop bounds and step inside the loop header
		local index = math.random(1, #availableMaps)
		table.insert(choices, availableMaps[index])
		table.remove(availableMaps, index)  -- removing the chosen entry prevents the same map from being selected twice
	end

	return choices
end

local function serializeMapChoices(choices)  -- local function keeps this helper inside this module; converts map instances into plain data that can safely be sent through a remoteevent
	local serialized = {}
	for index, mapTemplate in ipairs(choices) do  -- ipairs preserves the numbered vote order while converting map objects to plain data
		table.insert(serialized, {
			Index = index,
			Name = mapTemplate.Name,
			DisplayName = mapTemplate:GetAttribute("DisplayName") or mapTemplate.Name,  -- the attribute is preferred but the instance name is a safe fallback
		})
	end
	return serialized
end

local function getVoteCounts()  -- local function keeps this helper inside this module; rebuilds vote totals from the player-to-choice dictionary
	local counts = {}
	if not votingState then  -- the not check makes this branch run only when the required value/state is false or missing
		return counts
	end

	for index = 1, #votingState.Choices do  -- numeric for keeps the loop bounds and step inside the loop header
		counts[index] = 0
	end

	for _, choiceIndex in pairs(votingState.PlayerVotes) do  -- pairs fits the userid-keyed vote dictionary because its keys are not sequential
		if counts[choiceIndex] then  -- this check decides whether the branch below should run using the current state
			counts[choiceIndex] += 1
		end
	end

	return counts
end

local function broadcastMapVote(action, extraPayload)  -- local function keeps this helper inside this module; packages the current voting state and sends the same snapshot to every eligible player
	local payload = extraPayload or {}
	if votingState then  -- this check decides whether the branch below should run using the current state
		payload.Choices = serializeMapChoices(votingState.Choices)  -- instances are serialized before crossing the client/server boundary
		payload.VoteCounts = getVoteCounts()
		payload.Duration = MAP_VOTE_DURATION
		payload.TimeLeft = votingState.TimeLeft or payload.TimeLeft or MAP_VOTE_DURATION  -- the or chain prefers live state, then caller data, then the default duration
	end

	for _, player in ipairs(getRoundPlayers()) do  -- ipairs walks this array in numeric order while _ ignores the index because only the value is needed
		mapVoteEvent:FireClient(player, action, payload)  -- each eligible client gets the same action string plus the serialized vote snapshot
	end
end

local function resolveMapVote()  -- local function keeps this helper inside this module; finds every tied top choice and randomly breaks the tie
	local counts = getVoteCounts()
	local topVoteCount = -1
	local topChoices = {}

	for index = 1, #votingState.Choices do  -- numeric for keeps the loop bounds and step inside the loop header
		local voteCount = counts[index] or 0
		if voteCount > topVoteCount then  -- this check decides whether the branch below should run using the current state
			topVoteCount = voteCount
			topChoices = {index}
		elseif voteCount == topVoteCount then
			table.insert(topChoices, index)  -- equal leaders are appended so ties can be broken fairly afterward
		end
	end

	if #topChoices == 0 then
		return votingState.Choices[math.random(1, #votingState.Choices)]  -- return passes this computed value back to the caller and stops this function here
	end

	local winningIndex = topChoices[math.random(1, #topChoices)]  -- randomly indexing the tied leaders avoids always favoring the lowest map index
	return votingState.Choices[winningIndex]  -- return passes this computed value back to the caller and stops this function here
end

local function runMapVote()  -- local function keeps this helper inside this module; owns the whole vote lifecycle from choices through countdown and winner selection
	local choices = chooseMapChoices()
	if #choices == 0 then
		return nil  -- return passes this computed value back to the caller and stops this function here
	end

	votingState = {  -- one table groups all data that exists only while a vote is active
		Active = true,
		Choices = choices,
		PlayerVotes = {},
		TimeLeft = MAP_VOTE_DURATION,
	}

	for countdown = MAP_VOTE_DURATION, 1, -1 do  -- numeric for counts downward by one each iteration using the -1 step
		if roundEnded then  -- this check decides whether the branch below should run using the current state
			break
		end
		votingState.TimeLeft = countdown  -- the shared state is updated before broadcasting so late logic sees the same second
		broadcastMapVote("Start", {TimeLeft = countdown})
		task.wait(1)
	end

	local selectedMap = resolveMapVote()  -- winner resolution happens only after the countdown loop finishes or is interrupted
	broadcastMapVote("End", {
		Winner = selectedMap and selectedMap.Name or nil,
		TimeLeft = 0,
	})

	votingState.Active = false
	votingState = nil  -- clearing the table makes future remote votes fail the active-state guard
	return selectedMap  -- return passes this computed value back to the caller and stops this function here
end

local function getInitialInfected()  -- local function keeps this helper inside this module; randomly chooses from players who already have a usable character root part
	local availablePlayers = {}  -- a fresh table is created here so this operation does not reuse state from a previous call
	for _, player in ipairs(getRoundPlayers()) do  -- ipairs walks this array in numeric order while _ ignores the index because only the value is needed
		if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then  -- the and chain only accepts players whose characters are ready to be moved
			table.insert(availablePlayers, player)
		end
	end

	if #availablePlayers == 0 then  -- this check decides whether the branch below should run using the current state
		return nil
	end

	return availablePlayers[math.random(1, #availablePlayers)]  -- return passes this computed value back to the caller and stops this function here
end

function RoundManager:CanInfect(sourcePlayer, targetCharacter)  -- colon syntax makes this a roundmanager method and passes self automatically; public validation method keeps all infection permission checks server-side
	if roundEnded or not sourcePlayer or not targetCharacter then  -- this guard rejects stale calls and missing inputs before any instance lookups
		return false
	end

	local targetPlayer = players:GetPlayerFromCharacter(targetCharacter)  -- the players service converts a character model back to its owning player
	if not targetPlayer then  -- the not check makes this branch run only when the required value/state is false or missing
		return false
	end

	local sourceState = currentPlayers[sourcePlayer.Name]
	local targetState = currentPlayers[targetPlayer.Name]
	if not sourceState or not targetState then  -- the not check makes this branch run only when the required value/state is false or missing
		return false
	end

	if not sourceState.Active or sourceState.Role ~= "Infected" then  -- server state must identify the source as an active infected player
		return false
	end

	if not targetState.Active or targetState.Role ~= "Survivor" or targetState.PendingInfection then  -- only active survivors can transition into the infected role
		return false
	end

	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")  -- findfirstchildofclass looks for the humanoid by class so the final health check can safely use it
	return humanoid ~= nil and humanoid.Health > 0
end

function RoundManager:InfectPlayer(targetPlayer, sourcePlayer, blobPart)  -- colon syntax makes this a roundmanager method and passes self automatically; public infection method changes one survivor into a lava handler-backed infected player
	local state = currentPlayers[targetPlayer.Name]
	if not state or not state.Active or state.Role ~= "Survivor" or state.PendingInfection then  -- the not check makes this branch run only when the required value/state is false or missing
		return false
	end

	state.PendingInfection = true
	local oldCharacter = targetPlayer.Character
	if oldCharacter then  -- this check decides whether the branch below should run using the current state
		disablePrompt(oldCharacter)
		if blobPart then  -- this check decides whether the branch below should run using the current state
			taggerEvent:FireAllClients(oldCharacter, blobPart)  -- fireallclients broadcasts the visual tag effect while the server still controls the actual role change
		end
	end

	task.delay(0.35, function()  -- the short delay gives the tag effect time to play without yielding the caller
		if roundEnded then  -- this check decides whether the branch below should run using the current state
			return
		end

		local latestState = currentPlayers[targetPlayer.Name]
		if not latestState or latestState.Role ~= "Survivor" or not latestState.PendingInfection then  -- the not check makes this branch run only when the required value/state is false or missing
			return
		end

		local handler = LavaHandler.New(targetPlayer, {  -- the handler constructor receives callbacks so lava movement and round rules stay separated
			canTag = function(infectedPlayer, targetCharacter)
				return RoundManager:CanInfect(infectedPlayer, targetCharacter)  -- returning the validator result gives lavahandler a simple true/false for this possible tag
			end,
			onTagged = function(infectedPlayer, targetCharacter, currentBlob)
				local infectedTarget = players:GetPlayerFromCharacter(targetCharacter)  -- the players service converts a character model back to its owning player
				if not infectedTarget then  -- the not check makes this branch run only when the required value/state is false or missing
					return false  -- return passes this computed value back to the caller and stops this function here
				end
				local infectedHandler = infectedHandlers[infectedPlayer.Name]
				if infectedHandler then  -- this check decides whether the branch below should run using the current state
					infectedHandler:BoostSpeed()
				end
				return RoundManager:InfectPlayer(infectedTarget, infectedPlayer, currentBlob)  -- returning this result tells the handler whether the survivor was actually accepted for infection
			end,
		})

		infectedHandlers[targetPlayer.Name] = handler
		latestState.PendingInfection = false
		latestState.Role = "Infected"
		latestState.Active = true

		local sourceHandler = sourcePlayer and infectedHandlers[sourcePlayer.Name] or nil  -- short-circuiting safely looks up the source handler only when a source player exists
		local spawnCFrame
		if sourceHandler and sourceHandler:GetPivotCFrame() then  -- the source lava model pivot is preferred so the new infected appears near the tag location
			spawnCFrame = sourceHandler:GetPivotCFrame()  -- the source lava model pivot is preferred so the new infected appears near the tag location
		elseif oldCharacter then
			spawnCFrame = oldCharacter:GetPivot()  -- getpivot gives a model cframe fallback if the source handler position is unavailable
		else
			local lavaSpawn = getLavaSpawn(activeMapSpawns)
			spawnCFrame = lavaSpawn and lavaSpawn.CFrame or CFrame.new()  -- the fallback chain always produces a cframe even if map spawn data is missing
		end

		local success = handler:InitModel(spawnCFrame)  -- initmodel is the point where the new infected's lava character is actually created/placed
		if not success then  -- the not check makes this branch run only when the required value/state is false or missing
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

	return true  -- return passes this computed value back to the caller and stops this function here
end

local function startRound(map, initialInfectedPlayer)  -- local function keeps this helper inside this module; creates the first infected handler, previews it, then spawns all round participants
	local spawnFolder = getSpawnFolder(map)
	if not spawnFolder then  -- the not check makes this branch run only when the required value/state is false or missing
		return false  -- return passes this computed value back to the caller and stops this function here
	end

	activeMapSpawns = spawnFolder:GetChildren()
	local lavaSpawn = getLavaSpawn(activeMapSpawns)
	if not lavaSpawn then  -- the not check makes this branch run only when the required value/state is false or missing
		return false  -- return passes this computed value back to the caller and stops this function here
	end

	local initialHandler = LavaHandler.New(initialInfectedPlayer, {  -- the first infected uses the same handler/callback contract as later infections
		canTag = function(infectedPlayer, targetCharacter)
			return RoundManager:CanInfect(infectedPlayer, targetCharacter)  -- returning the validator result gives lavahandler a simple true/false for this possible tag
		end,
		onTagged = function(infectedPlayer, targetCharacter, blobPart)
			local targetPlayer = players:GetPlayerFromCharacter(targetCharacter)  -- the players service converts a character model back to its owning player
			if not targetPlayer then  -- the not check makes this branch run only when the required value/state is false or missing
				return false  -- return passes this computed value back to the caller and stops this function here
			end
			local infectedHandler = infectedHandlers[infectedPlayer.Name]
			if infectedHandler then  -- this check decides whether the branch below should run using the current state
				infectedHandler:BoostSpeed()
			end
			return RoundManager:InfectPlayer(targetPlayer, infectedPlayer, blobPart)
		end,
	})

	infectedHandlers[initialInfectedPlayer.Name] = initialHandler  -- registering the handler by player name lets later tag rewards and cleanup find it
	
	
	--find osme way to get rid of this delay 
	task.delay(0.75, function()
		local preview = initialHandler.LavaModel:Clone()  -- clone creates a runtime copy so the original template stays unchanged
		preview.Parent = selectionBox
		preview:PivotTo(selectionBox.BlobStarting.CFrame)  -- pivotto aligns the entire preview model with the marked display position
	end)

	for _, player in ipairs(getRoundPlayers()) do  -- ipairs walks this array in numeric order while _ ignores the index because only the value is needed
		gameStartEvent:FireClient(player, initialInfectedPlayer)  -- the server sends the chosen infected player so each client can show the same intro
	end

	task.wait(12)

	local previewModel = selectionBox:FindFirstChildOfClass("Model")  -- findfirstchildofclass ignores the model name and just finds the current preview model
	if previewModel then  -- this check decides whether the branch below should run using the current state
		previewModel:Destroy()  -- destroy removes this runtime instance so no stale object is left for the next round
	end

	if roundEnded then  -- this check decides whether the branch below should run using the current state
		return false  -- return passes this computed value back to the caller and stops this function here
	end

	if not initialHandler:InitModel(lavaSpawn.CFrame * CFrame.new(0, 2, 0)) then  -- the initial infected model is created at the dedicated lava spawn after the preview ends
		return false  -- return passes this computed value back to the caller and stops this function here
	end

	currentPlayers[initialInfectedPlayer.Name] = {
		Player = initialInfectedPlayer,  -- the state table keeps the player instance for later reward and cleanup operations
		Character = initialInfectedPlayer.Character,
		Role = "Infected",  -- role is stored server-side as the authoritative infection state
		Active = true,
		PendingInfection = false,  -- the initial infected is already converted, so no transition lock is needed
	}
	setRoundAttributes(initialInfectedPlayer, "Infected", true)
	applyHighlight(initialInfectedPlayer.Character, "Infected")
	attachCharacterState(initialInfectedPlayer)

	for _, player in ipairs(getRoundPlayers()) do  -- ipairs walks this array in numeric order while _ ignores the index because only the value is needed
		if player == initialInfectedPlayer then  -- the chosen infected is skipped because it was already initialized separately
			continue
		end

		local survivorSpawn = getSurvivorSpawn(activeMapSpawns)  -- each survivor asks for a valid non-lava spawn from the cached map spawn array
		spawnParticipant(player, "Survivor", survivorSpawn)
	end

	return true  -- return passes this computed value back to the caller and stops this function here
end

roundEndEvent.OnServerEvent:Connect(function(player, multiplier)  -- onserverevent receives the firing player automatically before the client-supplied multiplier
	if multiplier ~= 1 and multiplier ~= 3 then  -- only the two expected values are accepted so arbitrary client numbers cannot multiply rewards
		return
	end

	local rewardData = pendingRewards[player.Name]
	if not rewardData or rewardData.AllowedMultiplier ~= multiplier then  -- the client claim must match the multiplier the server currently allows
		return
	end

	local survivalCoins = rewardData.Survived and gameInfo.SurvivalCoins or 0  -- reward amounts come from game config instead of being hardcoded in round logic
	local total = (survivalCoins + gameInfo.ParticipationCoins) * multiplier  -- participation coins are added separately so every valid participant still earns something
	playerManager:AddMoney(player, total)
	pendingRewards[player.Name] = nil  -- removing the record makes the same round reward impossible to claim twice
end)

pendingRewardsEvent.Event:Connect(function(player)  -- this is a bindableevent connection, so the trigger comes from another server script rather than a client
	local rewardData = pendingRewards[player.Name]
	if rewardData then  -- this check decides whether the branch below should run using the current state
		rewardData.AllowedMultiplier = 3
	end
end)

mapVoteEvent.OnServerEvent:Connect(function(player, choiceIndex)  -- the server owns vote validation even though the selected index originates from the client
	if not votingState or not votingState.Active then  -- the not check makes this branch run only when the required value/state is false or missing
		return
	end

	if player:GetAttribute("IsInTutorial") or player:GetAttribute("TutorialComplete") ~= true then  -- getattribute reads the server state stored directly on the player instance
		return
	end

	if typeof(choiceIndex) ~= "number" then  -- typeof validates the remote argument type before math.floor or table indexing uses it
		return
	end

	choiceIndex = math.floor(choiceIndex)  -- floor normalizes values like 2.8 into a valid integer choice index
	if not votingState.Choices[choiceIndex] then  -- indexing the server's own choices table rejects out-of-range vote numbers
		return
	end

	votingState.PlayerVotes[player.UserId] = choiceIndex  -- userid is the key so each player has exactly one current vote that can be overwritten
	broadcastMapVote("Update")
end)

function RoundManager:Init()  -- colon syntax makes this a roundmanager method and passes self automatically; starts the long-running server loop that moves through intermission, voting, and rounds
	roundLength.Value = roundInformation.RoundLength
	intermissionLength.Value = roundInformation.IntermissionLength
	
	
	--maybe use coroutines in the future?
	--alex, this works but if you have any ideas lmk

	task.spawn(function()  -- task.spawn starts this work on a separate scheduler thread so the outer loop can keep moving
		while true do
			task.wait(0.25)
			if #getRoundPlayers() < 2 then  -- the game does not start a cycle until there are at least two eligible players
				continue
			end

			roundEnded = false
			roundLength.Value = -1

			disconnect(playerRemovingConnection)
			disconnect(playerAddedConnection)

			playerRemovingConnection = players.PlayerRemoving:Connect(function(leavingPlayer)  -- the temporary leave listener updates active round state immediately when somebody exits
				currentPlayers[leavingPlayer.Name] = nil
				if votingState then  -- this check decides whether the branch below should run using the current state
					votingState.PlayerVotes[leavingPlayer.UserId] = nil  -- removing the userid entry prevents a disconnected player's vote from staying counted
					broadcastMapVote("Update")  -- after one vote changes, every eligible client receives the refreshed totals
				end

				local handler = infectedHandlers[leavingPlayer.Name]
				if handler then  -- this check decides whether the branch below should run using the current state
					handler:Clean()  -- each handler gets its own cleanup call before the handler table is replaced
					infectedHandlers[leavingPlayer.Name] = nil
				end

				if not roundEnded then  -- the not check makes this branch run only when the required value/state is false or missing
					evaluateRoundState()
				end
			end)

			playerAddedConnection = players.PlayerAdded:Connect(function(joiningPlayer)  -- the temporary join listener keeps mid-round arrivals out of the active match
				if joiningPlayer:GetAttribute("IsInTutorial") or joiningPlayer:GetAttribute("TutorialComplete") ~= true then  -- this check decides whether the branch below should run using the current state
					return
				end

				if intermissionLength.Value == -1 and not roundEnded then  -- the sentinel plus round flag identifies a live round rather than intermission
					repeat task.wait() until joiningPlayer.Character

					setRoundAttributes(joiningPlayer, "Spectator", false)
					disablePrompt(joiningPlayer.Character)
					local spawnPart = chooseLobbySpawn()
					local humanoidRootPart = joiningPlayer.Character:FindFirstChild("HumanoidRootPart")  -- findfirstchild safely returns nil when the instance is missing, so the next guard can handle it
					if humanoidRootPart then  -- this check decides whether the branch below should run using the current state
						humanoidRootPart.CFrame = spawnPart.CFrame * CFrame.new(0, 4, 0)
					end
				end
			end)

			for countdown = roundInformation.IntermissionLength, 1, -1 do  -- numeric for drives the intermission timer directly from the configured duration
				if roundEnded then  -- this check decides whether the branch below should run using the current state
					break
				end
				intermissionLength.Value = countdown
				task.wait(1)
			end

			if roundEnded then  -- this check decides whether the branch below should run using the current state
				continue
			end

			local selectedMapTemplate = runMapVote()  -- the returned template is passed into spawnmap, so voting stays separate from cloning
			if roundEnded then  -- this check decides whether the branch below should run using the current state
				continue
			end

			if #getRoundPlayers() < 2 then  -- the game does not start a cycle until there are at least two eligible players
				endRound()
				continue
			end

			local map = spawnMap(selectedMapTemplate)  -- spawnmap turns the selected serverstorage template into the live workspace map
			local initialInfectedPlayer = getInitialInfected()  -- selection happens after the map exists and only uses ready eligible players
			if not initialInfectedPlayer then  -- the not check makes this branch run only when the required value/state is false or missing
				endRound()
				continue
			end

			local roundStarted = startRound(map, initialInfectedPlayer)  -- the boolean return lets the main loop recover cleanly from setup failures
			if not roundStarted then  -- the not check makes this branch run only when the required value/state is false or missing
				if not roundEnded then  -- the not check makes this branch run only when the required value/state is false or missing
					endRound()
				end
				continue
			end

			intermissionLength.Value = -1
			for countdown = roundInformation.RoundLength, 1, -1 do  -- numeric for owns the main match countdown using the configured round length
				if roundEnded then  -- this check decides whether the branch below should run using the current state
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

return RoundManager  -- return exposes the module table to whichever server script requires this module
