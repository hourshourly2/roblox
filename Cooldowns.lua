local Cooldown = {}
Cooldown.Active = {} 


function Cooldown:Set(player, action, duration)
	if not self.Active[player] then
		self.Active[player] = {}
	end

	self.Active[player][action] = os.clock() + duration
	
	task.delay(duration, function()
		self.Active[player][action] = nil
	end)
end


function Cooldown:IsOnCooldown(player, action)
	if not self.Active[player] or not self.Active[player][action] then
		return false
	end
	return os.clock() < self.Active[player][action]
end


function Cooldown:GetRemaining(player, action)
	if not self.Active[player] or not self.Active[player][action] then
		return 0
	end
	return math.max(0, self.Active[player][action] - os.clock())
end


function Cooldown:Clear(player, action)
	if self.Active[player] then
		self.Active[player][action] = nil
	end
end

return Cooldown
