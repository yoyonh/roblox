local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local adminName = "Adsmored"

local function onPlayerAdded(player)
	local leaderstats = player:FindFirstChild("leaderstats")

	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local RobloBacks = leaderstats:FindFirstChild("RobloBacks")
	if not RobloBacks then
		RobloBacks = Instance.new("IntValue")
		RobloBacks.Name = "RobloBacks"
		RobloBacks.Value = 0
		RobloBacks.Parent = leaderstats
	end
end

local function resetLeaderstats(playerToReset)
	local leaderstats = playerToReset:FindFirstChild("leaderstats")
	if leaderstats then
		local RobloBacks = leaderstats:FindFirstChild("RobloBacks")
		if RobloBacks then
			RobloBacks.Value = 0
			print("Игроку " .. playerToReset.Name .. " были сброшены RobloBacks.")
		end
	end
end

local function resetAllLeaderstats()
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		resetLeaderstats(otherPlayer)
	end
end

local function onChatted(msg, player)
	if string.sub(msg, 1, 4) == "/get" and player.Name == adminName then
		local num = tonumber(string.sub(msg, 6))

		if num then
			local leaderstats = player:FindFirstChild("leaderstats")
			if leaderstats then
				local RobloBacks = leaderstats:FindFirstChild("RobloBacks")
				if RobloBacks then
					RobloBacks.Value = RobloBacks.Value + num
					print("Было добавлено " .. num .. " RobloBacks игроку " .. player.Name)
				end
			end
		end
	elseif msg == "/wipe" and player.Name == adminName then
		resetLeaderstats(player)
	elseif string.sub(msg, 1, 4) == "/Pay" then
		local splitMsg = string.split(msg, " ")
		local targetName = splitMsg[3]
		local amount = tonumber(splitMsg[2])

		local targetPlayer = nil
		for _, otherPlayer in ipairs(Players:GetPlayers()) do
			if otherPlayer.Name == targetName then
				targetPlayer = otherPlayer
				break
			end
		end

		if not targetPlayer then
			print("игрок не найден.")
			return
		end

		local senderLeaderstats = player:FindFirstChild("leaderstats")
		local targetLeaderstats = targetPlayer:FindFirstChild("leaderstats")

		if senderLeaderstats and targetLeaderstats then
			local senderRobloBacks = senderLeaderstats:FindFirstChild("RobloBacks")
			local targetRobloBacks = targetLeaderstats:FindFirstChild("RobloBacks")

			if senderRobloBacks and targetRobloBacks then
				if senderRobloBacks.Value >= amount then
					senderRobloBacks.Value = senderRobloBacks.Value - amount
					targetRobloBacks.Value = targetRobloBacks.Value + amount
					print(player.Name .. " перевел(а) " .. amount .. " RobloBacks игроку " .. targetPlayer.Name)
				else
					print("Недостаточно RobloBacks для перевода.")
				end
			end
		end
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(msg)
		onChatted(msg, player)
	end)
end)
