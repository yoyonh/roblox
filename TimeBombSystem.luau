local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local RagdollService = require(game.ServerScriptService:WaitForChild("Systems"):WaitForChild("RagdollService"))

local ROUND_DURATION = 15
local MIN_PLAYERS = 2
local LOBBY_COUNTDOWN = 3
local INTERMISSION_DURATION = 3
local ELIMINATION_LOCK = 6

local ZONE_CHECK_INTERVAL = 0.1
local EXIT_GRACE = 0.45
local PASS_SCAN_INTERVAL = 0.06
local PASS_COOLDOWN = 0.7
local RETURN_PASS_PROTECTION = 0.9
local MAX_ROOT_PASS_DISTANCE = 4.75
local MAX_BOMB_PASS_DISTANCE = 3.8
local MAX_BOMB_FROM_HOLDER = 5.5

local TICK_SOUND_ID = "rbxassetid://125472551458252"

local bombZone = workspace:WaitForChild("TimeBomb"):WaitForChild("BombZone")
local bombTemplate = ReplicatedStorage:WaitForChild("Tools"):WaitForChild("TimeBomb")

local oldStorage = ServerStorage:FindFirstChild("TimeBombStoredTools")
if oldStorage then
	oldStorage:Destroy()
end
local storage = Instance.new("Folder")
storage.Name = "TimeBombStoredTools"
storage.Parent = ServerStorage

local oldStatus = bombZone:FindFirstChild("BombZoneStatus")
if oldStatus then
	oldStatus:Destroy()
end

local statusGui = Instance.new("BillboardGui")
statusGui.Name = "BombZoneStatus"
statusGui.Adornee = bombZone
statusGui.AlwaysOnTop = true
statusGui.Enabled = false
statusGui.Size = UDim2.fromOffset(360, 46)
statusGui.DistanceLowerLimit = 60
statusGui.DistanceUpperLimit = 60
statusGui.StudsOffsetWorldSpace = Vector3.new(0, bombZone.Size.Y / 2 + 2, 0)
statusGui.Parent = bombZone

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.fromScale(1, 1)
statusLabel.BackgroundTransparency = 1
statusLabel.BorderSizePixel = 0
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextColor3 = Color3.new(1, 1, 1)
statusLabel.TextScaled = true
statusLabel.TextStrokeTransparency = 0.35
statusLabel.Parent = statusGui

local inside = {}
local outsideSince = {}
local storedFolders = {}
local savedMovement = {}
local jumpConnections = {}
local toolGuardConnections = {}
local eliminatedUntil = {}
local pendingRestore = {}

local phase = "Waiting"
local phaseEndsAt = 0
local intermissionMessage = ""
local holder = nil
local activeBomb = nil
local roundParticipants = {}
local roundId = 0
local lastPassAt = 0
local blockedReturnTarget = nil
local blockedReturnUntil = 0
local roundThread = nil

local function setStatus(text, color, enabled)
	statusLabel.Text = text or ""
	statusLabel.TextColor3 = color or Color3.new(1, 1, 1)
	statusGui.Enabled = enabled ~= false and text ~= nil and text ~= ""
end

local function getHumanoid(player)
	local character = player and player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function getRoot(player)
	local character = player and player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function isPlayerInsideBombZone(player)
	local root = getRoot(player)
	if not root then
		return false
	end
	local position = bombZone.CFrame:PointToObjectSpace(root.Position)
	local halfSize = bombZone.Size * 0.5
	return math.abs(position.X) <= halfSize.X
		and math.abs(position.Y) <= halfSize.Y
		and math.abs(position.Z) <= halfSize.Z
end

local function isAlive(player)
	local humanoid = getHumanoid(player)
	return player and player.Parent == Players and humanoid and humanoid.Health > 0
end

local function isAliveInZone(player)
	return inside[player] and isAlive(player) and isPlayerInsideBombZone(player)
end

local function isEligible(player)
	return isAliveInZone(player) and os.clock() >= (eliminatedUntil[player] or 0)
end

local function getEligiblePlayers()
	local candidates = {}
	for player in pairs(inside) do
		if isEligible(player) then
			table.insert(candidates, player)
		end
	end
	table.sort(candidates, function(a, b)
		return a.UserId < b.UserId
	end)
	return candidates
end

local function getActiveParticipantCount()
	local count = 0
	for player in pairs(roundParticipants) do
		if inside[player] and isAlive(player) then
			count += 1
		end
	end
	return count
end

local function getRemainingParticipant()
	local found = nil
	local count = 0
	for player in pairs(roundParticipants) do
		if inside[player] and isAlive(player) then
			found = player
			count += 1
		end
	end
	return count == 1 and found or nil
end

local function getStoredFolder(player, create)
	local folder = storedFolders[player]
	if not folder and create then
		folder = Instance.new("Folder")
		folder.Name = tostring(player.UserId)
		folder.Parent = storage
		storedFolders[player] = folder
	end
	return folder
end

local function restrictJump(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	if not savedMovement[player] then
		local jumpingEnabled = true
		pcall(function()
			jumpingEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
		end)
		savedMovement[player] = {
			UseJumpPower = humanoid.UseJumpPower,
			JumpPower = humanoid.JumpPower,
			JumpHeight = humanoid.JumpHeight,
			JumpingEnabled = jumpingEnabled,
		}
	end

	if jumpConnections[player] then
		jumpConnections[player]:Disconnect()
	end
	jumpConnections[player] = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if inside[player] and humanoid.Parent then
			humanoid.Jump = false
		end
	end)

	humanoid.Jump = false
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	pcall(function()
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	end)
end

local function restoreJump(player)
	local connection = jumpConnections[player]
	if connection then
		connection:Disconnect()
		jumpConnections[player] = nil
	end

	local saved = savedMovement[player]
	local humanoid = getHumanoid(player)
	if saved and humanoid and humanoid.Health > 0 then
		humanoid.UseJumpPower = saved.UseJumpPower
		humanoid.JumpPower = saved.JumpPower
		humanoid.JumpHeight = saved.JumpHeight
		pcall(function()
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, saved.JumpingEnabled)
		end)
	end
	savedMovement[player] = nil
end

local function storeTools(player, folder, keepEquipped)
	local humanoid = getHumanoid(player)
	if humanoid and not keepEquipped then
		humanoid:UnequipTools()
	end

	for _, container in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
		if container then
			for _, item in ipairs(container:GetChildren()) do
				if item:IsA("Tool") and item ~= activeBomb then
					item.Parent = folder
				end
			end
		end
	end
end

local function storeNewTools(player)
	local folder = storedFolders[player]
	if folder then
		storeTools(player, folder, true)
	end
end

local function stopToolGuard(player)
	local connections = toolGuardConnections[player]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	toolGuardConnections[player] = nil
end

local function startToolGuard(player)
	stopToolGuard(player)
	local connections = {}
	toolGuardConnections[player] = connections

	local function watch(container)
		if not container then
			return
		end
		table.insert(connections, container.ChildAdded:Connect(function(item)
			if item:IsA("Tool") then
				task.defer(function()
					if inside[player] and item ~= activeBomb then
						storeNewTools(player)
					end
				end)
			end
		end))
	end

	watch(player:FindFirstChildOfClass("Backpack"))
	watch(player.Character)
end

local function restoreTools(player)
	local folder = storedFolders[player]
	if not folder then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	local humanoid = getHumanoid(player)
	if not backpack or not humanoid or humanoid.Health <= 0 then
		pendingRestore[player] = true
		return
	end

	for _, tool in ipairs(folder:GetChildren()) do
		if not backpack:FindFirstChild(tool.Name) and (not character or not character:FindFirstChild(tool.Name)) then
			tool.Parent = backpack
		else
			tool:Destroy()
		end
	end
	folder:Destroy()
	storedFolders[player] = nil
	pendingRestore[player] = nil
end

local function stopFlyingCarpet(player, character)
	local carpet = character and character:FindFirstChild("FlyingCarpet")
	if not carpet or not carpet:IsA("Tool") then
		return
	end
	local clientControl = carpet:FindFirstChild("ClientControl")
	if clientControl and clientControl:IsA("RemoteFunction") then
		-- InvokeClient never returns if the client stalls; keep it off the main loop
		task.spawn(pcall, function()
			clientControl:InvokeClient(player, "StopFlight")
		end)
	end
end

local function enterZone(player)
	local character = player.Character
	local humanoid = getHumanoid(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not character or not humanoid or humanoid.Health <= 0 or not backpack then
		return
	end

	local folder = getStoredFolder(player, true)

	if RagdollService.isRagdolled(character) then
		RagdollService.recover(character)
	end

	if humanoid.Sit then
		humanoid.Sit = false
	end
	humanoid.Jump = false

	stopFlyingCarpet(player, character)
	humanoid:UnequipTools()
	humanoid.PlatformStand = false
	humanoid.AutoRotate = true
	humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	task.defer(function()
		if humanoid.Parent == character and humanoid.Health > 0 and not humanoid.PlatformStand then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
	end)
	humanoid.WalkSpeed = 16
	humanoid.JumpPower = 50
	humanoid.JumpHeight = 7.2
	humanoid.UseJumpPower = true

	local root = getRoot(player)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end

	for _, object in ipairs(character:GetDescendants()) do
		if object:IsA("BodyVelocity") or object:IsA("BodyGyro") or object:IsA("BodyPosition")
			or object:IsA("BodyForce") or object:IsA("BodyThrust") or object:IsA("BodyAngularVelocity")
			or object:IsA("LinearVelocity") or object:IsA("AngularVelocity")
			or object:IsA("AlignPosition") or object:IsA("AlignOrientation") then
			object:Destroy()
		elseif object:IsA("Seat") or object:IsA("VehicleSeat") then
			object:Destroy()
		end
	end

	storeTools(player, folder, true)

	startToolGuard(player)
	restrictJump(player)
end

local function clearBomb()
	if activeBomb then
		activeBomb:Destroy()
	end
	activeBomb = nil
	holder = nil
	blockedReturnTarget = nil
	blockedReturnUntil = 0
	local thread = roundThread
	roundThread = nil
	if thread and thread ~= coroutine.running() and coroutine.status(thread) == "suspended" then
		task.cancel(thread)
	end
end

local function endRound(forRoundId, message)
	if forRoundId ~= roundId or phase ~= "Active" then
		return false
	end

	local winner = getRemainingParticipant()
	roundId += 1
	clearBomb()
	roundParticipants = {}
	phase = "Intermission"
	phaseEndsAt = os.clock() + INTERMISSION_DURATION
	if winner then
		intermissionMessage = (message or "Раунд окончен") .. " • Победитель: " .. winner.DisplayName
	else
		intermissionMessage = message or "Раунд окончен"
	end
	setStatus(intermissionMessage, Color3.fromRGB(255, 225, 120), true)
	return true
end

local function createTimerGui(handle)
	local gui = Instance.new("BillboardGui")
	gui.Name = "TimeBombTimer"
	gui.Adornee = handle
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(74, 36)
	gui.DistanceLowerLimit = 60
	gui.DistanceUpperLimit = 60
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.25, 0)
	gui.Parent = handle

	local label = Instance.new("TextLabel")
	label.Name = "Timer"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.Parent = gui

	local sound = Instance.new("Sound")
	sound.Name = "Tick"
	sound.SoundId = TICK_SOUND_ID
	sound.Volume = 0.65
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 5
	sound.RollOffMaxDistance = 40
	sound.Parent = handle

	return label, sound
end

local function explodeHolder(forRoundId, reason)
	if forRoundId ~= roundId or phase ~= "Active" or not holder then
		return
	end
	if not roundParticipants[holder] then
		return
	end

	local explodingPlayer = holder
	local humanoid = getHumanoid(explodingPlayer)
	local root = getRoot(explodingPlayer)
	local position = root and root.Position or bombZone.Position

	roundParticipants[explodingPlayer] = nil
	eliminatedUntil[explodingPlayer] = os.clock() + ELIMINATION_LOCK

	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = 6
	explosion.BlastPressure = 0
	explosion.DestroyJointRadiusPercent = 0
	explosion.Parent = workspace

	local knockback = nil
	if root then
		local direction = root.Position - bombZone.Position
		if direction.Magnitude < 0.1 then
			direction = Vector3.new(1, 0, 0)
		end
		knockback = direction.Unit * 18 + Vector3.new(0, 8, 0)
		root.AssemblyLinearVelocity = knockback
	end

	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
		if root and knockback then
			task.defer(function()
				if root.Parent then
					root.AssemblyLinearVelocity = knockback
				end
			end)
		end
	end

	endRound(forRoundId, reason or "Бомба взорвалась")
end

local function equipBomb(player, bomb)
	local character = player.Character
	local humanoid = getHumanoid(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not character or not humanoid or humanoid.Health <= 0 or not backpack then
		return false
	end
	bomb.Parent = backpack
	humanoid:EquipTool(bomb)
	return bomb.Parent == character
end

local function enforceBombHolder(forRoundId)
	if forRoundId ~= roundId or phase ~= "Active" or not activeBomb or not holder then
		return false
	end

	local humanoid = getHumanoid(holder)
	if not humanoid or humanoid.Health <= 0 then
		roundParticipants[holder] = nil
		endRound(forRoundId, "Носитель выбыл")
		return false
	end
	if not inside[holder] then
		explodeHolder(forRoundId, "Носитель вышел из зоны")
		return false
	end

	if activeBomb.Parent ~= holder.Character then
		if not equipBomb(holder, activeBomb) then
			explodeHolder(forRoundId, "Бомба потеряна")
			return false
		end
	end

	local handle = activeBomb:FindFirstChild("Handle")
	local root = getRoot(holder)
	if handle and root and (handle.Position - root.Position).Magnitude > MAX_BOMB_FROM_HOLDER then
		activeBomb.Parent = holder:FindFirstChildOfClass("Backpack")
		if not equipBomb(holder, activeBomb) then
			explodeHolder(forRoundId, "Бомба потеряна")
			return false
		end
	end
	return true
end

local function hasLineOfSight(fromPlayer, targetPlayer)
	local fromRoot = getRoot(fromPlayer)
	local targetRoot = getRoot(targetPlayer)
	if not fromRoot or not targetRoot then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {fromPlayer.Character, activeBomb}
	local hit = workspace:Raycast(fromRoot.Position, targetRoot.Position - fromRoot.Position, params)
	return not hit or hit.Instance:IsDescendantOf(targetPlayer.Character)
end

local function passBomb(forRoundId, target)
	if forRoundId ~= roundId or phase ~= "Active" or not activeBomb or not holder or target == holder then
		return false
	end
	if not roundParticipants[target] or not isAliveInZone(target) then
		return false
	end

	local now = os.clock()
	if now - lastPassAt < PASS_COOLDOWN then
		return false
	end
	if target == blockedReturnTarget then
		return false
	end

	local oldHolder = holder
	local holderRoot = getRoot(oldHolder)
	local targetRoot = getRoot(target)
	local handle = activeBomb:FindFirstChild("Handle")
	if not holderRoot or not targetRoot or not handle then
		return false
	end
	if (holderRoot.Position - targetRoot.Position).Magnitude > MAX_ROOT_PASS_DISTANCE then
		return false
	end
	if (handle.Position - targetRoot.Position).Magnitude > MAX_BOMB_PASS_DISTANCE then
		return false
	end
	if not hasLineOfSight(oldHolder, target) then
		return false
	end

	local oldHumanoid = getHumanoid(oldHolder)
	holder = target
	lastPassAt = now
	blockedReturnTarget = oldHolder
	blockedReturnUntil = now + RETURN_PASS_PROTECTION

	if oldHumanoid then
		oldHumanoid:UnequipTools()
	end
	if not equipBomb(target, activeBomb) then
		holder = oldHolder
		blockedReturnTarget = nil
		blockedReturnUntil = 0
		if isAlive(oldHolder) then
			equipBomb(oldHolder, activeBomb)
		end
		return false
	end
	return true
end

local function scanForPassTarget(forRoundId)
	if forRoundId ~= roundId or phase ~= "Active" or not activeBomb or not holder then
		return
	end
	local holderRoot = getRoot(holder)
	local handle = activeBomb:FindFirstChild("Handle")
	if not holderRoot or not handle then
		return
	end
	if (handle.Position - holderRoot.Position).Magnitude > MAX_BOMB_FROM_HOLDER then
		return
	end

	local now = os.clock()
	if blockedReturnTarget and now >= blockedReturnUntil then
		blockedReturnTarget = nil
		blockedReturnUntil = 0
	end

	local nearest = nil
	local nearestDistance = math.huge
	for player in pairs(roundParticipants) do
		if player ~= holder and isAliveInZone(player) then
			local root = getRoot(player)
			if root then
				local rootDistance = (holderRoot.Position - root.Position).Magnitude
				local bombDistance = (handle.Position - root.Position).Magnitude
				if rootDistance <= MAX_ROOT_PASS_DISTANCE and bombDistance <= MAX_BOMB_PASS_DISTANCE
					and rootDistance < nearestDistance and hasLineOfSight(holder, player) then
					nearest = player
					nearestDistance = rootDistance
				end
			end
		end
	end
	if nearest then
		passBomb(forRoundId, nearest)
	end
end

local function beginRound(candidates)
	if phase ~= "Countdown" or activeBomb then
		return
	end

	local valid = {}
	for _, player in ipairs(candidates) do
		if isEligible(player) then
			table.insert(valid, player)
		end
	end
	if #valid < MIN_PLAYERS then
		phase = "Waiting"
		return
	end

	roundId += 1
	local myRound = roundId
	roundParticipants = {}
	for _, player in ipairs(valid) do
		roundParticipants[player] = true
	end

	local bomb = bombTemplate:Clone()
	local handle = bomb:FindFirstChild("Handle")
	local hitbox = bomb:FindFirstChild("Hitbox")
	if not handle or not hitbox then
		warn("TimeBomb template is missing Handle or Hitbox")
		bomb:Destroy()
		roundParticipants = {}
		phase = "Waiting"
		return
	end

	holder = valid[math.random(1, #valid)]
	activeBomb = bomb
	activeBomb.Name = "TimeBomb"
	activeBomb.CanBeDropped = false
	activeBomb:SetAttribute("TimeBombActive", true)

	hitbox.CanCollide = false
	hitbox.CanTouch = false
	hitbox.CanQuery = false
	hitbox.Size = Vector3.new(1.6, 1.6, 1.6)

	for _, part in ipairs(activeBomb:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "BombHighlight"
	highlight.Adornee = handle
	highlight.FillColor = Color3.fromRGB(255, 55, 55)
	highlight.FillTransparency = 0.55
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.OutlineTransparency = 0.15
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = activeBomb

	local label, tickSound = createTimerGui(handle)
	phase = "Active"
	lastPassAt = os.clock()
	blockedReturnTarget = nil
	blockedReturnUntil = 0

	activeBomb.Unequipped:Connect(function()
		task.defer(function()
			if myRound == roundId and phase == "Active" and activeBomb and holder
				and inside[holder] and isAlive(holder) and activeBomb.Parent ~= holder.Character then
				equipBomb(holder, activeBomb)
			end
		end)
	end)

	if not equipBomb(holder, activeBomb) then
		endRound(myRound, "Раунд отменён")
		return
	end

	local thread = task.spawn(function()
		local ok, err = pcall(function()
			local deadline = os.clock() + ROUND_DURATION
			local nextTickAt = 0
			local nextPassScan = 0
			local nextEnforce = 0

			while myRound == roundId and phase == "Active" and activeBomb and holder do
				local now = os.clock()
				local remainingExact = math.max(0, deadline - now)
				local remaining = math.ceil(remainingExact)
				label.Text = tostring(remaining)

				if remaining <= 5 then
					label.TextColor3 = Color3.fromRGB(255, 65, 65)
					label.Visible = math.floor(now * 5) % 2 == 0
				else
					label.TextColor3 = Color3.new(1, 1, 1)
					label.Visible = true
				end

				if remaining > 0 and now >= nextTickAt then
					local progress = math.clamp(1 - remainingExact / ROUND_DURATION, 0, 1)
					local urgency = progress * progress
					tickSound.PlaybackSpeed = 1 + progress * 1.05
					tickSound:Play()
					nextTickAt = now + math.max(0.16, 1 - urgency * 0.84)
				end

				if now >= nextPassScan then
					nextPassScan = now + PASS_SCAN_INTERVAL
					scanForPassTarget(myRound)
				end

				if now >= nextEnforce then
					nextEnforce = now + PASS_SCAN_INTERVAL
					if not enforceBombHolder(myRound) then
						break
					end
				end

				if remainingExact <= 0 then
					explodeHolder(myRound, "Бомба взорвалась")
					break
				end
				task.wait(0.03)
			end

		end)
		if not ok then
			warn("TimeBomb round error: " .. tostring(err))
			endRound(myRound, "Раунд прерван")
		end
	end)
	if myRound == roundId and phase == "Active" then
		roundThread = thread
	end
end

local function eliminateLeaver(player)
	eliminatedUntil[player] = os.clock() + ELIMINATION_LOCK
	local humanoid = getHumanoid(player)
	local root = getRoot(player)
	if root then
		root.AssemblyLinearVelocity = Vector3.new(0, 7, 0)
	end
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = 0
	end
end

local function handleParticipantExit(player)
	if phase ~= "Active" or not roundParticipants[player] then
		return
	end

	if player == holder then
		explodeHolder(roundId, "Носитель вышел из зоны")
		return
	end

	roundParticipants[player] = nil
	eliminateLeaver(player)
	if getActiveParticipantCount() < MIN_PLAYERS then
		endRound(roundId, "Соперник покинул зону")
	end
end

local function exitZone(player)
	handleParticipantExit(player)
	stopToolGuard(player)
	restoreJump(player)
	restoreTools(player)
end

local function handleRoundDeath(player)
	if phase ~= "Active" or not roundParticipants[player] then
		return
	end

	roundParticipants[player] = nil
	eliminatedUntil[player] = os.clock() + ELIMINATION_LOCK
	if player == holder then
		endRound(roundId, "Носитель погиб")
	elseif getActiveParticipantCount() < MIN_PLAYERS then
		endRound(roundId, "Раунд окончен")
	end
end

local function onCharacterAdded(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or player.Parent ~= Players or player.Character ~= character then
		return
	end

	inside[player] = nil
	outsideSince[player] = nil
	stopToolGuard(player)

	humanoid.Died:Connect(function()
		handleRoundDeath(player)
	end)

	task.defer(function()
		if pendingRestore[player] or storedFolders[player] then
			restoreTools(player)
		end
		restoreJump(player)
	end)
end

local function setupPlayer(player)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end
Players.PlayerAdded:Connect(setupPlayer)

Players.PlayerRemoving:Connect(function(player)
	if phase == "Active" and roundParticipants[player] then
		roundParticipants[player] = nil
		if player == holder then
			endRound(roundId, "Игрок покинул сервер")
		elseif getActiveParticipantCount() < MIN_PLAYERS then
			endRound(roundId, "Игрок покинул сервер")
		end
	end
	inside[player] = nil
	outsideSince[player] = nil
	eliminatedUntil[player] = nil
	pendingRestore[player] = nil
	stopToolGuard(player)
	local connection = jumpConnections[player]
	if connection then
		connection:Disconnect()
	end
	jumpConnections[player] = nil
	local folder = storedFolders[player]
	if folder then
		folder:Destroy()
	end
	storedFolders[player] = nil
	savedMovement[player] = nil
	if blockedReturnTarget == player then
		blockedReturnTarget = nil
	end
end)

local function step()
	local now = os.clock()
	local current = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if isAlive(player) and isPlayerInsideBombZone(player) then
			current[player] = true
		end
	end

	for player in pairs(current) do
		outsideSince[player] = nil
		if not inside[player] then
			inside[player] = true
			enterZone(player)
		else
			storeNewTools(player)
		end
	end

	for player in pairs(inside) do
		if not current[player] then
			if not outsideSince[player] then
				outsideSince[player] = now
			elseif now - outsideSince[player] >= EXIT_GRACE then
				outsideSince[player] = nil
				inside[player] = nil
				exitZone(player)
			end
		end
	end

	if phase == "Waiting" then
		local candidates = getEligiblePlayers()
		if #candidates >= MIN_PLAYERS then
			phase = "Countdown"
			phaseEndsAt = now + LOBBY_COUNTDOWN
			setStatus("Подготовка к раунду", Color3.new(1, 1, 1), true)
		elseif #candidates >= 1 then
			setStatus("Требуется ещё " .. (MIN_PLAYERS - #candidates) .. " игрок(ов)", Color3.new(1, 1, 1), true)
		else
			setStatus("", Color3.new(1, 1, 1), false)
		end
	elseif phase == "Countdown" then
		local candidates = getEligiblePlayers()
		if #candidates < MIN_PLAYERS then
			phase = "Waiting"
			setStatus("Требуется ещё " .. (MIN_PLAYERS - #candidates) .. " игрок(ов)", Color3.new(1, 1, 1), #candidates >= 1)
		else
			local remaining = math.max(1, math.ceil(phaseEndsAt - now))
			setStatus("Старт через " .. remaining, Color3.fromRGB(255, 235, 150), true)
			if now >= phaseEndsAt then
				beginRound(candidates)
			end
		end
	elseif phase == "Intermission" then
		local remaining = math.max(0, math.ceil(phaseEndsAt - now))
		if remaining > 0 then
			setStatus(intermissionMessage .. " • новый раунд через " .. remaining, Color3.fromRGB(255, 225, 120), true)
		else
			phase = "Waiting"
			intermissionMessage = ""
		end
	end

	if phase == "Active" and (not activeBomb or not holder) then
		endRound(roundId, "Раунд окончен")
	end

	for player in pairs(pendingRestore) do
		if not inside[player] then
			restoreTools(player)
		end
	end

	if phase == "Active" then
		local participants = getActiveParticipantCount()
		setStatus("Раунд идёт • игроков: " .. participants, Color3.fromRGB(255, 120, 120), true)
	end

end

while true do
	local ok, err = pcall(step)
	if not ok then
		warn("TimeBomb loop error: " .. tostring(err))
	end
	task.wait(ZONE_CHECK_INTERVAL)
end
