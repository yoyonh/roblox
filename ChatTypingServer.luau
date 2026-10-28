local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local event = ReplicatedStorage:FindFirstChild("ChatTypingEvent")
if not event then
	event = Instance.new("RemoteEvent")
	event.Name = "ChatTypingEvent"
	event.Parent = ReplicatedStorage
end

local states = {}
local lastRequests = {}
local REQUEST_COOLDOWN = 0.12
local STALE_TIMEOUT = 8

event.OnServerEvent:Connect(function(player, isTyping)
	if type(isTyping) ~= "boolean" then
		return
	end
	local now = os.clock()
	if now - (lastRequests[player] or 0) < REQUEST_COOLDOWN then
		return
	end
	lastRequests[player] = now

	local state = states[player]
	if isTyping then
		states[player] = { typing = true, updatedAt = now }
	elseif state then
		states[player] = nil
	end
	event:FireAllClients(player.UserId, player.Name, isTyping)
end)

Players.PlayerRemoving:Connect(function(player)
	if states[player] then
		event:FireAllClients(player.UserId, player.Name, false)
	end
	states[player] = nil
	lastRequests[player] = nil
end)

task.spawn(function()
	while true do
		task.wait(2)
		local now = os.clock()
		for player, state in pairs(states) do
			if player.Parent ~= Players or now - state.updatedAt > STALE_TIMEOUT then
				states[player] = nil
				if player.Parent == Players then
					event:FireAllClients(player.UserId, player.Name, false)
				end
			end
		end
	end
end)