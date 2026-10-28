local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local AUTOSAVE_INTERVAL = 120
local BOARD_UPDATE_INTERVAL = 60

local timeStore = DataStoreService:GetOrderedDataStore("PlaytimeLeaderboard_v2")

local boardPart = workspace:FindFirstChild("TimeLeaderboard", true)

local SAVE_RETRIES = 3
local SHUTDOWN_BUDGET = 25
local MAX_SESSION_DELTA = 7 * 86400

-- Per-UserId so a save can finish after the Player object is gone.
-- pending = seconds earned but not yet written; saving = in-flight lock.
local saveStates = {}
local inFlightSaves = 0

local DANCE_ANIMATION_IDS = {
	"rbxassetid://507771019",
	"rbxassetid://507771955",
	"rbxassetid://507772104",
	"rbxassetid://507776043",
	"rbxassetid://507776720",
	"rbxassetid://507776879",
	"rbxassetid://507777268",
	"rbxassetid://507777451",
	"rbxassetid://507777623",
}

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds))
	local days = seconds // 86400
	local hours = (seconds % 86400) // 3600
	local minutes = (seconds % 3600) // 60

	if days > 0 then
		return ("%dd %dh %dm"):format(days, hours, minutes)
	elseif hours > 0 then
		return ("%dh %dm"):format(hours, minutes)
	else
		return ("%dm"):format(minutes)
	end
end

local function waitForBudget(requestType)
	for _ = 1, 10 do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if not ok or (type(budget) == "number" and budget > 0) then
			return true
		end
		task.wait(1)
	end
	return false
end

local function trackPlayer(player)
	if player.UserId <= 0 or saveStates[player.UserId] then
		return
	end
	saveStates[player.UserId] = { lastAt = os.clock(), pending = 0, saving = false }
end

-- Incremental UpdateAsync, so no prior load is needed and nothing is double counted:
-- elapsed time is claimed into `pending` once, and only cleared after a successful write.
local function saveTime(player, deadline)
	local userId = player.UserId
	local state = saveStates[userId]
	if not state then
		return
	end

	while state.saving do
		if deadline and os.clock() >= deadline then
			return
		end
		task.wait(0.1)
	end
	state.saving = true
	inFlightSaves += 1

	local now = os.clock()
	local elapsed = now - state.lastAt
	state.lastAt = now
	if elapsed == elapsed and elapsed > 0 then
		state.pending += math.min(math.floor(elapsed), MAX_SESSION_DELTA)
	end

	local delta = state.pending
	if delta > 0 then
		local key = tostring(userId)
		for attempt = 1, SAVE_RETRIES do
			if deadline and os.clock() >= deadline then
				break
			end
			if waitForBudget(Enum.DataStoreRequestType.UpdateAsync) then
				local ok = pcall(function()
					timeStore:UpdateAsync(key, function(old)
						if type(old) ~= "number" or old ~= old or old < 0 then
							old = 0
						end
						return math.floor(old) + delta
					end)
				end)
				if ok then
					state.pending -= delta
					break
				end
			end
			if attempt < SAVE_RETRIES then
				task.wait(2)
			end
		end
	end

	state.saving = false
	inFlightSaves -= 1
end

local nameCache = {}

local function getPlayerName(userId)
	if nameCache[userId] then
		return nameCache[userId]
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(name) == "string" then
		nameCache[userId] = name
		return name
	end
	return "???"
end

local rig = boardPart and boardPart:FindFirstChild("Rig")
local currentTopUserId = nil
local danceTrack = nil
local danceIndex = 0
local rigUpdateSerial = 0
local rigHome = {
	captured = false,
	parent = nil,
	rootCFrame = nil,
	hipHeight = 2,
	scale = 1,
}

local function captureRigHome(fromRig)
	if rigHome.captured or not fromRig then
		return
	end
	local root = fromRig:FindFirstChild("HumanoidRootPart")
	local humanoid = fromRig:FindFirstChildOfClass("Humanoid")
	rigHome.parent = fromRig.Parent
	rigHome.rootCFrame = root and root.CFrame or fromRig:GetPivot()
	rigHome.hipHeight = (humanoid and humanoid.HipHeight > 0) and humanoid.HipHeight or 2
	local scaleOk, scale = pcall(function()
		return fromRig:GetScale()
	end)
	rigHome.scale = (scaleOk and type(scale) == "number" and scale > 0) and scale or 1
	rigHome.captured = true
end

local function findBoardRig()
	if not boardPart or not boardPart.Parent then
		boardPart = workspace:FindFirstChild("TimeLeaderboard", true)
	end
	if not boardPart then
		return nil
	end
	if not rig or not rig.Parent then
		rig = boardPart:FindFirstChild("Rig")
	end
	return rig
end

local function configureDummy(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	pcall(function()
		humanoid.AutomaticScalingEnabled = false
	end)
	pcall(function()
		humanoid.EvaluateStateMachine = false
	end)
	humanoid.HipHeight = rigHome.hipHeight

	local animate = model:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end
	local health = model:FindFirstChild("Health")
	if health then
		health:Destroy()
	end

	humanoid.AutoRotate = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayName = ""
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.AutoJumpEnabled = false

	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("BasePart") then
			object.CanCollide = false
			object.CanTouch = false
			object.CanQuery = false
			object.Massless = true
			object.Anchored = object.Name == "HumanoidRootPart"
		elseif object:IsA("ForceField") or object:IsA("Sound") then
			object:Destroy()
		end
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if root then
		root.Anchored = true
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end

	return humanoid
end

local function playDance(humanoid, userId, rotate)
	if danceTrack then
		pcall(function()
			danceTrack:Stop(0.15)
			danceTrack:Destroy()
		end)
		danceTrack = nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0.15)
	end

	local startIndex
	if rotate then
		startIndex = (danceIndex % #DANCE_ANIMATION_IDS) + 1
	else
		startIndex = (math.abs(userId) % #DANCE_ANIMATION_IDS) + 1
	end

	for offset = 0, #DANCE_ANIMATION_IDS - 1 do
		local index = ((startIndex - 1 + offset) % #DANCE_ANIMATION_IDS) + 1
		local animation = Instance.new("Animation")
		animation.AnimationId = DANCE_ANIMATION_IDS[index]
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		animation:Destroy()
		if ok and track then
			track.Looped = true
			track.Priority = Enum.AnimationPriority.Action4
			track:Play(0.25, 1, 1)
			danceTrack = track
			danceIndex = index
			return
		end
	end
end

local function placeChampionModel(model, humanoid)
	pcall(function()
		humanoid.AutomaticScalingEnabled = false
	end)
	humanoid.HipHeight = rigHome.hipHeight

	model.Parent = rigHome.parent

	pcall(function()
		if rigHome.scale and rigHome.scale ~= 1 then
			model:ScaleTo(rigHome.scale)
		end
	end)

	pcall(function()
		humanoid.AutomaticScalingEnabled = false
	end)
	humanoid.HipHeight = rigHome.hipHeight

	local root = model:FindFirstChild("HumanoidRootPart")
	if root and rigHome.rootCFrame then
		model.PrimaryPart = root
		root.Anchored = true
		root.CFrame = rigHome.rootCFrame
	end
end

local function updateRig(userId)
	if not userId or userId <= 0 then
		return
	end

	local currentRig = findBoardRig()
	if currentRig then
		captureRigHome(currentRig)
	end
	if not rigHome.captured then
		return
	end

	if currentTopUserId == userId and currentRig and currentRig.Parent then
		local humanoid = currentRig:FindFirstChildOfClass("Humanoid")
		if humanoid then
			playDance(humanoid, userId, true)
		end
		return
	end

	rigUpdateSerial += 1
	local serial = rigUpdateSerial

	local okDescription, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if serial ~= rigUpdateSerial then
		return
	end
	if not okDescription or not description then
		local humanoid = currentRig and currentRig:FindFirstChildOfClass("Humanoid")
		if humanoid and currentTopUserId == userId then
			playDance(humanoid, userId, true)
		end
		return
	end

	local okModel, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(
			description,
			Enum.HumanoidRigType.R15,
			Enum.AssetTypeVerification.Always
		)
	end)
	if not okModel or not model then
		okModel, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
		end)
	end
	if serial ~= rigUpdateSerial then
		if okModel and model then
			model:Destroy()
		end
		return
	end
	if not okModel or not model then
		return
	end

	model.Name = "Rig"
	local humanoid = configureDummy(model)
	if not humanoid then
		model:Destroy()
		return
	end

	placeChampionModel(model, humanoid)

	if currentRig and currentRig ~= model then
		if danceTrack then
			pcall(function()
				danceTrack:Stop(0)
				danceTrack:Destroy()
			end)
			danceTrack = nil
		end
		currentRig:Destroy()
	end

	rig = model
	currentTopUserId = userId
	model:SetAttribute("ChampionUserId", userId)
	playDance(humanoid, userId, false)
end

local function updateBoard()
	if not boardPart or not boardPart.Parent then
		boardPart = workspace:FindFirstChild("TimeLeaderboard", true)
		if not boardPart then
			return
		end
		rig = boardPart:FindFirstChild("Rig")
		if rig then
			captureRigHome(rig)
		end
	end

	local gui = boardPart:FindFirstChild("LeaderboardGui")
	local rowsFrame = gui and gui:FindFirstChild("Root")
	rowsFrame = rowsFrame and rowsFrame:FindFirstChild("Rows")
	if not rowsFrame then
		return
	end

	if not waitForBudget(Enum.DataStoreRequestType.GetSortedAsync) then
		return
	end
	local ok, pages = pcall(function()
		return timeStore:GetSortedAsync(false, 10)
	end)
	if not ok or not pages then
		return
	end
	local okPage, top = pcall(function()
		return pages:GetCurrentPage()
	end)
	if not okPage or type(top) ~= "table" then
		return
	end

	for i = 1, 10 do
		local row = rowsFrame:FindFirstChild("Row" .. i)
		if row then
			local avatar = row:FindFirstChild("Avatar")
			local nameLabel = row:FindFirstChild("PlayerName")
			local timeLabel = row:FindFirstChild("TimePlayed")
			local entry = top[i]

			if entry then
				local userId = tonumber(entry.key)
				if nameLabel then
					nameLabel.Text = userId and getPlayerName(userId) or "???"
				end
				if timeLabel then
					timeLabel.Text = formatTime(type(entry.value) == "number" and entry.value or 0)
				end
				if avatar then
					avatar.Image = userId
							and ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(userId)
						or ""
				end
			else
				if nameLabel then nameLabel.Text = "-" end
				if timeLabel then timeLabel.Text = "-" end
				if avatar then avatar.Image = "" end
			end
		end
	end

	local topEntry = top[1]
	if topEntry then
		local userId = tonumber(topEntry.key)
		if userId then
			task.spawn(function()
				pcall(updateRig, userId)
			end)
		end
	end
end

local function onPlayerAdded(player)
	trackPlayer(player)
	player.CharacterAppearanceLoaded:Connect(function()
		if currentTopUserId == player.UserId then
			task.delay(0.5, updateRig, player.UserId)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	saveTime(player)
	local state = saveStates[player.UserId]
	-- Keep unsaved time if the write failed and the player rejoins quickly.
	if state and state.pending == 0 and not Players:GetPlayerByUserId(player.UserId) then
		saveStates[player.UserId] = nil
	end
end)

game:BindToClose(function()
	local deadline = os.clock() + SHUTDOWN_BUDGET
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(saveTime, player, deadline)
	end
	-- Also waits for PlayerRemoving saves already in flight.
	task.wait()
	while inFlightSaves > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

task.spawn(function()
	while true do
		task.wait(30)
		if currentTopUserId then
			task.spawn(function()
				pcall(updateRig, currentTopUserId)
			end)
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(saveTime, player)
		end
	end
end)

task.spawn(function()
	while true do
		local ok, err = pcall(updateBoard)
		if not ok then
			warn("[TimePlayed] board update failed: " .. tostring(err))
		end
		task.wait(BOARD_UPDATE_INTERVAL)
	end
end)
