local Players = game:GetService("Players")
local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GROUP_ID = 32605034
local REWARD_COINS = 50

local request = ReplicatedStorage:FindFirstChild("GroupJoinRewardRequest")
if not request then
	request = Instance.new("RemoteEvent")
	request.Name = "GroupJoinRewardRequest"
	request.Parent = ReplicatedStorage
end

local result = ReplicatedStorage:FindFirstChild("GroupJoinRewardResult")
if not result then
	result = Instance.new("RemoteEvent")
	result.Name = "GroupJoinRewardResult"
	result.Parent = ReplicatedStorage
end

local REQUEST_COOLDOWN = 5

local inFlight = {}
local lastRequestAt = {}

local function isMember(player, useFreshGroupQuery)
	if useFreshGroupQuery then
		-- Этот запрос не использовался при первом входе, поэтому после PromptJoinAsync
		-- он даёт свежую проверку и не полагается на старый кэш Player:IsInGroupAsync.
		local ok, roles = pcall(function()
			return GroupService:GetRolesInGroupAsync(player.UserId, GROUP_ID)
		end)
		if ok and type(roles) == "table" then
			return roles.IsMember == true
		end
		-- GetRolesInGroupAsync бывает отключён/недоступен — тогда проверяем обычным способом.
	end
	local ok, member = pcall(function()
		return player:IsInGroupAsync(GROUP_ID)
	end)
	return ok and member == true
end

local function claimReward(player)
	local shopServer = game.ServerScriptService:FindFirstChild("ShopServer")
	local coinsApi = shopServer and shopServer:FindFirstChild("AdminCoins")
	if not coinsApi then return false end

	-- Профиль монет может ещё загружаться в первые секунды входа.
	for _ = 1, 10 do
		if player.Parent ~= Players then return false end
		local ok, success, status = pcall(coinsApi.Invoke, coinsApi, "claimGroupJoinReward", player, REWARD_COINS)
		if ok and success then
			return status == "claimed"
		end
		task.wait(1)
	end
	return false
end

local function checkInitialMembership(player)
	player:SetAttribute("ICEGroupCheckFinished", false)
	player:SetAttribute("ICEGroupMember", false)

	local member = isMember(player, false)
	if player.Parent ~= Players then return end

	player:SetAttribute("ICEGroupMember", member)
	player:SetAttribute("ICEGroupCheckFinished", true)

	if member then
		-- Уже состоящим в группе окно не показываем; награда всё равно только одна.
		claimReward(player)
	end
end

request.OnServerEvent:Connect(function(player)
	if inFlight[player] then return end
	local now = os.clock()
	if now - (lastRequestAt[player] or -math.huge) < REQUEST_COOLDOWN then return end
	lastRequestAt[player] = now
	inFlight[player] = true

	-- После нативного окна Roblox даём сервисам короткое время обновить членство.
	task.wait(2)
	local member = isMember(player, true)
	if player.Parent ~= Players then
		inFlight[player] = nil
		return
	end

	player:SetAttribute("ICEGroupMember", member)
	player:SetAttribute("ICEGroupCheckFinished", true)
	local rewarded = member and claimReward(player) or false
	result:FireClient(player, member, rewarded)
	inFlight[player] = nil
end)

Players.PlayerAdded:Connect(function(player)
	task.spawn(checkInitialMembership, player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(checkInitialMembership, player)
end

Players.PlayerRemoving:Connect(function(player)
	inFlight[player] = nil
	lastRequestAt[player] = nil
end)
