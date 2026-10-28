local ServerScriptService = game:GetService("ServerScriptService")

local AntiCheat = require(ServerScriptService:WaitForChild("Systems"):WaitForChild("AntiCheat"))

local MAX_EXEMPT_SECONDS = 600
local MAX_BAN_SECONDS = 365 * 24 * 3600

-- Конечное число в диапазоне [minValue, maxValue], иначе default (отсекает NaN и inf).
local function clampNumber(value, default, minValue, maxValue)
	local num = tonumber(value)
	if not num or num ~= num or num == math.huge or num == -math.huge then
		return default
	end
	return math.clamp(num, minValue, maxValue)
end

local function isValidPlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player")
end

local playerActions = {
	exempt = function(player, value)
		AntiCheat.Exempt(player, clampNumber(value, 5, 0, MAX_EXEMPT_SECONDS))
		return true
	end,
	setExempt = function(player, value)
		AntiCheat.SetExempt(player, value == true)
		return true
	end,
	strikes = function(player)
		return AntiCheat.GetStrikes(player)
	end,
	clear = function(player)
		AntiCheat.ClearStrikes(player)
		return true
	end,
	ping = function(player)
		return math.floor(AntiCheat.GetPing(player) * 1000)
	end,
	record = function(player)
		return AntiCheat.GetRecord(player)
	end,
	ban = function(player, value, extra, details)
		local code = math.floor(clampNumber(value, AntiCheat.Codes.Manual, 0, math.huge))
		local duration = clampNumber(extra, 3600, 1, MAX_BAN_SECONDS)
		return AntiCheat.Ban(player, code, duration, details)
	end,
	reportExploit = function(player, value, extra)
		local code = math.floor(clampNumber(value, AntiCheat.Codes.InvalidRemoteData, 0, math.huge))
		AntiCheat.ReportExploit(player, code, extra)
		return true
	end,
}

local globalActions = {
	logOnly = function(value)
		AntiCheat.Config.LogOnly = value == true
		return true
	end,
	enabled = function(value)
		AntiCheat.Config.Enabled = value ~= false
		return true
	end,
}

local control = Instance.new("BindableFunction")
control.Name = "AntiCheatControl"
control.OnInvoke = function(action, player, value, extra, details)
	if type(action) ~= "string" then
		return false
	end

	local globalAction = globalActions[action]
	if globalAction then
		-- Значение по-прежнему идёт третьим аргументом, player здесь игнорируется.
		return globalAction(value)
	end

	local playerAction = playerActions[action]
	if not playerAction or not isValidPlayer(player) then
		return false
	end
	local ok, result = pcall(playerAction, player, value, extra, details)
	if not ok then
		warn("AntiCheatControl:", action, result)
		return false
	end
	return result
end
control.Parent = script

AntiCheat.Start()
