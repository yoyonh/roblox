local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LoadingScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 1000
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

local background = Instance.new("Frame")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.Position = UDim2.fromScale(0, 0)
background.BackgroundColor3 = Color3.new(0, 0, 0)
background.BorderSizePixel = 0
background.ZIndex = 1
background.Parent = screenGui

local dotsHolder = Instance.new("Frame")
dotsHolder.Name = "DotsHolder"
dotsHolder.Size = UDim2.fromOffset(180, 60)
dotsHolder.AnchorPoint = Vector2.new(0.5, 0.5)
dotsHolder.Position = UDim2.fromScale(0.5, 0.5)
dotsHolder.BackgroundTransparency = 1
dotsHolder.ZIndex = 2
dotsHolder.Parent = background

local dotsLayout = Instance.new("UIListLayout")
dotsLayout.FillDirection = Enum.FillDirection.Horizontal
dotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
dotsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
dotsLayout.Padding = UDim.new(0, 24)
dotsLayout.SortOrder = Enum.SortOrder.LayoutOrder
dotsLayout.Parent = dotsHolder

local DOT_SIZE = 22
local DOT_COLORS = {
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(255, 255, 255),
}

local dots = {}
for i = 1, 3 do
	local dot = Instance.new("Frame")
	dot.Name = "Dot" .. i
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BackgroundColor3 = DOT_COLORS[i]
	dot.BorderSizePixel = 0
	dot.LayoutOrder = i
	dot.ZIndex = 2
	dot.Parent = dotsHolder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	dots[i] = dot
end

local percentLabel = Instance.new("TextLabel")
percentLabel.Name = "PercentLabel"
percentLabel.Size = UDim2.fromOffset(300, 40)
percentLabel.AnchorPoint = Vector2.new(0.5, 1)
percentLabel.Position = UDim2.new(0.5, 0, 1, -60)
percentLabel.BackgroundTransparency = 1
percentLabel.Font = Enum.Font.GothamBold
percentLabel.Text = "0%"
percentLabel.TextColor3 = Color3.new(1, 1, 1)
percentLabel.TextSize = 22
percentLabel.TextTransparency = 0
percentLabel.ZIndex = 2
percentLabel.Parent = background

local currentPercent = 0
local displayedPercent = 0

local function updatePercentText()
	percentLabel.Text = math.floor(displayedPercent) .. "%"
end

task.spawn(function()
	while screenGui.Parent do
		if displayedPercent < currentPercent then
			displayedPercent = math.min(currentPercent, displayedPercent + math.max((currentPercent - displayedPercent) * 0.15, 0.4))
			updatePercentText()
		end
		RunService.Heartbeat:Wait()
	end
end)

local function setPercent(p)
	currentPercent = math.clamp(p, 0, 100)
end

task.spawn(function()
	local t = 0
	local bounceHeight = 14
	local baseY = 0
	while screenGui.Parent do
		t += RunService.Heartbeat:Wait()
		local offset = math.sin(t * 4.2) * bounceHeight
		dots[1].Position = UDim2.new(0.5, 0, 0.5, baseY - math.max(offset, 0))
		local scale = 1 + math.max(offset, 0) / (bounceHeight * 6)
		dots[1].Size = UDim2.fromOffset(DOT_SIZE * scale, DOT_SIZE * scale)
	end
end)

task.spawn(function()
	local t = 0
	while screenGui.Parent do
		t += RunService.Heartbeat:Wait()
		local pulse = (math.sin(t * 5) + 1) / 2
		local scale = 0.6 + pulse * 0.7
		dots[2].Size = UDim2.fromOffset(DOT_SIZE * scale, DOT_SIZE * scale)
		dots[2].BackgroundTransparency = 0.1 + (1 - pulse) * 0.5
	end
end)

task.spawn(function()
	local t = 0
	while screenGui.Parent do
		t += RunService.Heartbeat:Wait()
		dots[3].Rotation = (t * 220) % 360
		local squish = (math.sin(t * 6) + 1) / 2
		dots[3].Size = UDim2.fromOffset(DOT_SIZE * (1 + squish * 0.35), DOT_SIZE * (1 - squish * 0.25))
	end
end)

local function gatherInstances()
	local list = {}
	for _, service in ipairs({
		game:GetService("ReplicatedStorage"),
		game:GetService("StarterGui"),
		game:GetService("StarterPack"),
		game:GetService("StarterPlayer"),
		workspace,
		}) do
		local ok, descendants = pcall(function()
			return service:GetDescendants()
		end)
		if ok then
			for _, inst in ipairs(descendants) do
				list[#list + 1] = inst
			end
			list[#list + 1] = service
		end
	end
	return list
end

local function preloadAssets()
	local instances = gatherInstances()
	local total = #instances
	if total == 0 then
		setPercent(60)
		return
	end

	local loaded = 0
	local batchSize = 40
	local index = 1

	while index <= total do
		local batch = {}
		for i = index, math.min(index + batchSize - 1, total) do
			batch[#batch + 1] = instances[i]
		end

		local ok = pcall(function()
			ContentProvider:PreloadAsync(batch)
		end)
		if not ok then
			for _, inst in ipairs(batch) do
				pcall(function()
					ContentProvider:PreloadAsync({inst})
				end)
			end
		end

		loaded += #batch
		index += batchSize
		setPercent((loaded / total) * 60)
		task.wait()
	end
end

local function waitForCharacter()
	setPercent(math.max(currentPercent, 62))

	if not player.Character then
		player.CharacterAdded:Wait()
	end

	local character = player.Character
	local humanoid = character:WaitForChild("Humanoid", 15)
	local rootPart = character:WaitForChild("HumanoidRootPart", 15)

	setPercent(78)

	local deadline = os.clock() + 6
	while os.clock() < deadline do
		if rootPart and rootPart:IsDescendantOf(workspace) then
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Exclude
			overlapParams.FilterDescendantsInstances = {character}
			local nearby = workspace:GetPartBoundsInBox(rootPart.CFrame, Vector3.new(60, 60, 60), overlapParams)
			if #nearby > 0 then
				break
			end
		end
		task.wait(0.1)
	end

	setPercent(90)
end

local function waitForGraphicsSettle()
	for i = 1, 6 do
		RunService.RenderStepped:Wait()
		setPercent(90 + (i / 6) * 8)
	end
end

task.spawn(function()
	preloadAssets()
	waitForCharacter()
	waitForGraphicsSettle()
	setPercent(100)

	local deadline = os.clock() + 3
	while displayedPercent < 99.5 and os.clock() < deadline do
		task.wait(0.05)
	end
	displayedPercent = 100
	updatePercentText()

	task.wait(0.35)

	local fadeInfo = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tweens = {
		TweenService:Create(background, fadeInfo, {BackgroundTransparency = 1}),
		TweenService:Create(percentLabel, fadeInfo, {TextTransparency = 1}),
	}
	for _, dot in ipairs(dots) do
		tweens[#tweens + 1] = TweenService:Create(dot, fadeInfo, {BackgroundTransparency = 1})
	end
	for _, tw in ipairs(tweens) do
		tw:Play()
	end
	tweens[1].Completed:Wait()

	screenGui:Destroy()
end)
