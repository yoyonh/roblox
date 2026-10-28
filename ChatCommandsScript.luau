local Players = game:GetService("Players")

-- Права выдаются по UserId: имя можно сменить. Имена из ADMIN_NAMES
-- переводятся в UserId один раз при старте сервера.
local ADMIN_USER_IDS = {}
local ADMIN_NAMES = { "Adsmored" }

local CURRENCY_NAME = "RobloBacks"
local MAX_BALANCE = 1e12
local MAX_GRANT = 1e9
local COMMAND_COOLDOWN = 1

local adminIds = {}
for _, userId in ipairs(ADMIN_USER_IDS) do
	adminIds[userId] = true
end

task.spawn(function()
	for _, name in ipairs(ADMIN_NAMES) do
		local ok, userId = pcall(Players.GetUserIdFromNameAsync, Players, name)
		if ok and userId then
			adminIds[userId] = true
		else
			warn("ChatCommands: не удалось получить UserId для " .. name)
		end
	end
end)

local lastCommandAt = {}

local function isAdmin(player)
	return adminIds[player.UserId] == true
end

-- Только целые положительные числа в допустимом диапазоне (отсекает NaN, inf, дроби).
local function parseAmount(text, maxValue)
	local num = tonumber(text)
	if not num or num ~= num or num <= 0 or num > maxValue or num % 1 ~= 0 then
		return nil
	end
	return num
end

local function getCurrency(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local value = leaderstats and leaderstats:FindFirstChild(CURRENCY_NAME)
	if value and value:IsA("IntValue") then
		return value
	end
	return nil
end

local function findPlayer(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local lowered = string.lower(name)
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if string.lower(otherPlayer.Name) == lowered then
			return otherPlayer
		end
	end
	return nil
end

local function onPlayerAdded(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	if not leaderstats:FindFirstChild(CURRENCY_NAME) then
		local currency = Instance.new("IntValue")
		currency.Name = CURRENCY_NAME
		currency.Value = 0
		currency.Parent = leaderstats
	end
end

local function resetLeaderstats(playerToReset)
	local currency = getCurrency(playerToReset)
	if currency then
		currency.Value = 0
		print("Игроку " .. playerToReset.Name .. " были сброшены " .. CURRENCY_NAME .. ".")
	end
end

local function handleGet(player, args)
	local amount = parseAmount(args[2], MAX_GRANT)
	local currency = getCurrency(player)
	if not amount or not currency then
		return
	end
	currency.Value = math.min(currency.Value + amount, MAX_BALANCE)
	print("Было добавлено " .. amount .. " " .. CURRENCY_NAME .. " игроку " .. player.Name)
end

local function handlePay(player, args)
	local amount = parseAmount(args[2], MAX_BALANCE)
	if not amount then
		print("Некорректная сумма перевода.")
		return
	end

	local targetPlayer = findPlayer(args[3])
	if not targetPlayer then
		print("Игрок не найден.")
		return
	end
	if targetPlayer == player then
		return
	end

	local senderCurrency = getCurrency(player)
	local targetCurrency = getCurrency(targetPlayer)
	if not senderCurrency or not targetCurrency then
		return
	end

	if senderCurrency.Value < amount then
		print("Недостаточно " .. CURRENCY_NAME .. " для перевода.")
		return
	end
	if targetCurrency.Value + amount > MAX_BALANCE then
		print("У получателя достигнут лимит " .. CURRENCY_NAME .. ".")
		return
	end

	senderCurrency.Value -= amount
	targetCurrency.Value += amount
	print(player.Name .. " перевел(а) " .. amount .. " " .. CURRENCY_NAME .. " игроку " .. targetPlayer.Name)
end

local function onChatted(msg, player)
	if type(msg) ~= "string" or string.sub(msg, 1, 1) ~= "/" or #msg > 200 then
		return
	end

	local now = os.clock()
	if now - (lastCommandAt[player] or 0) < COMMAND_COOLDOWN then
		return
	end

	local args = {}
	for word in string.gmatch(msg, "%S+") do
		table.insert(args, word)
	end
	local command = string.lower(args[1] or "")

	if command == "/get" and isAdmin(player) then
		lastCommandAt[player] = now
		handleGet(player, args)
	elseif command == "/wipe" and isAdmin(player) then
		lastCommandAt[player] = now
		resetLeaderstats(player)
	elseif command == "/pay" then
		lastCommandAt[player] = now
		handlePay(player, args)
	end
end

local function setupPlayer(player)
	onPlayerAdded(player)
	player.Chatted:Connect(function(msg)
		onChatted(msg, player)
	end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setupPlayer, player)
end

Players.PlayerRemoving:Connect(function(player)
	lastCommandAt[player] = nil
end)
