local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local event = ReplicatedStorage:FindFirstChild("ChatTypingEvent")
if not event then
	event = Instance.new("RemoteEvent")
	event.Name = "ChatTypingEvent"
	event.Parent = ReplicatedStorage
end

local MAX_REQUESTS_PER_WINDOW = 10
local RATE_WINDOW = 1
local STALE_TIMEOUT = 8

local typingSince = {}
local rateLimits = {}

-- Скользящее окно вместо жёсткого кулдауна: быстрое "начал/закончил"
-- проходит, а флуд отбрасывается.
local function allowRequest(player, now)
	local limit = rateLimits[player]
	if not limit or now - limit.windowStart >= RATE_WINDOW then
		rateLimits[player] = { windowStart = now, count = 1 }
		return true
	end
	if limit.count >= MAX_REQUESTS_PER_WINDOW then
		return false
	end
	limit.count += 1
	return true
end

local function broadcast(player, isTyping)
	event:FireAllClients(player.UserId, player.Name, isTyping)
end

event.OnServerEvent:Connect(function(player, isTyping)
	if type(isTyping) ~= "boolean" then
		return
	end
	local now = os.clock()
	if not allowRequest(player, now) then
		return
	end

	local wasTyping = typingSince[player] ~= nil
	if isTyping then
		typingSince[player] = now
	else
		typingSince[player] = nil
	end
	if wasTyping ~= isTyping then
		broadcast(player, isTyping)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if typingSince[player] then
		broadcast(player, false)
	end
	typingSince[player] = nil
	rateLimits[player] = nil
end)

task.spawn(function()
	while true do
		task.wait(2)
		local now = os.clock()
		for player, updatedAt in pairs(typingSince) do
			if player.Parent ~= Players then
				typingSince[player] = nil
			elseif now - updatedAt > STALE_TIMEOUT then
				typingSince[player] = nil
				broadcast(player, false)
			end
		end
	end
end)
