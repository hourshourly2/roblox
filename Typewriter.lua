local Typewriter = {}

function Typewriter:Typewrite(obj : TextLabel, text : string, len : number)
  local types = {"!", "?", ".", ";", ":"}
	for i= 1, #text, 1 do
		obj.Text = string.sub(text, 1, i)
		local currentCharacter = text:sub(i - 1, i - 1)
		if table.find(types, currentCharacter) then
			task.wait(0.15)
		end
		task.wait(len)
	end
end

return Typewriter
