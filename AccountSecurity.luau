local Players = game:GetService("Players")

local MIN_ACCOUNT_AGE_DAYS = 1

local function validatePlayer(player)
	if player.AccountAge < MIN_ACCOUNT_AGE_DAYS then
		player:Kick(string.format(
			"Для входа аккаунту должно быть не меньше %d дн. Возраст вашего аккаунта: %d дн.",
			MIN_ACCOUNT_AGE_DAYS,
			math.max(0, player.AccountAge)
		))
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	task.defer(validatePlayer, player)
end
Players.PlayerAdded:Connect(validatePlayer)
