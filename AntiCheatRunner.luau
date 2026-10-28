local AntiCheat = require(game.ServerScriptService:WaitForChild("Systems"):WaitForChild("AntiCheat"))

local control = Instance.new("BindableFunction")
control.Name = "AntiCheatControl"
control.Parent = script
control.OnInvoke = function(action, player, value, extra, details)
	if action == "exempt" then
		AntiCheat.Exempt(player, tonumber(value) or 5)
		return true
	elseif action == "setExempt" then
		AntiCheat.SetExempt(player, value == true)
		return true
	elseif action == "strikes" then
		return AntiCheat.GetStrikes(player)
	elseif action == "clear" then
		AntiCheat.ClearStrikes(player)
		return true
	elseif action == "ping" then
		return math.floor(AntiCheat.GetPing(player) * 1000)
	elseif action == "record" then
		return AntiCheat.GetRecord(player)
	elseif action == "ban" then
		return AntiCheat.Ban(player, tonumber(value) or AntiCheat.Codes.Manual, tonumber(extra) or 3600, details)
	elseif action == "reportExploit" then
		AntiCheat.ReportExploit(player, tonumber(value) or AntiCheat.Codes.InvalidRemoteData, extra)
		return true
	elseif action == "logOnly" then
		AntiCheat.Config.LogOnly = value == true
		return true
	elseif action == "enabled" then
		AntiCheat.Config.Enabled = value ~= false
		return true
	end
	return false
end

AntiCheat.Flagged:Connect(function(player, reason, details, weight, count)
end)

AntiCheat.Kicked:Connect(function(player, code, details)
end)

AntiCheat.Banned:Connect(function(player, code, duration, details)
end)

AntiCheat.Start()