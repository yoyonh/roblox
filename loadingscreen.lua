local ReplicatedFirst = game:GetService("ReplicatedFirst")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local CONFIG = {
	Title = nil, -- nil = use the experience's name
	BackgroundTop = Color3.fromRGB(18, 14, 40),
	BackgroundBottom = Color3.fromRGB(4, 4, 12),
	AccentA = Color3.fromRGB(120, 90, 255),
	AccentB = Color3.fromRGB(0, 210, 255),
	StarCount = 60,
	DotCount = 5,
	TipInterval = 4,
	Tips = {
		"Tip: Explore every corner — secrets are hidden everywhere.",
		"Tip: Team up with friends to progress faster.",
		"Tip: Check the settings menu to customise your controls.",
		"Tip: Take a break every now and then!",
		"Tip: Be kind to other players.",
	},
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LoadingScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 1000
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- A CanvasGroup lets the whole screen fade out with one tween.
local background = Instance.new("CanvasGroup")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.new(1, 1, 1)
background.BorderSizePixel = 0
background.Parent = screenGui

local bgGradient = Instance.new("UIGradient")
bgGradient.Color = ColorSequence.new(CONFIG.BackgroundTop, CONFIG.BackgroundBottom)
bgGradient.Rotation = 90
bgGradient.Parent = background

local uiScale = Instance.new("UIScale")
uiScale.Parent = background

-- Starfield
local starsHolder = Instance.new("Frame")
starsHolder.Name = "Stars"
starsHolder.Size = UDim2.fromScale(1, 1)
starsHolder.BackgroundTransparency = 1
starsHolder.Parent = background

local stars = {}
for i = 1, CONFIG.StarCount do
	local size = math.random(2, 4)
	local star = Instance.new("Frame")
	star.Name = "Star" .. i
	star.Size = UDim2.fromOffset(size, size)
	star.AnchorPoint = Vector2.new(0.5, 0.5)
	star.BackgroundColor3 = Color3.new(1, 1, 1)
	star.BorderSizePixel = 0
	star.Parent = starsHolder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = star

	stars[i] = {
		frame = star,
		x = math.random(),
		y = math.random(),
		speed = 0.01 + math.random() * 0.03 * (size / 2),
		phase = math.random() * math.pi * 2,
		twinkle = 1 + math.random() * 2,
	}
end

-- Center content
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.fromOffset(460, 260)
content.AnchorPoint = Vector2.new(0.5, 0.5)
content.Position = UDim2.fromScale(0.5, 0.45)
content.BackgroundTransparency = 1
content.Parent = background

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(1, 0, 0, 56)
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBlack
titleLabel.Text = CONFIG.Title or ""
titleLabel.TextColor3 = Color3.new(1, 1, 1)
titleLabel.TextScaled = true
titleLabel.Parent = content

local titleSizeLimit = Instance.new("UITextSizeConstraint")
titleSizeLimit.MaxTextSize = 44
titleSizeLimit.Parent = titleLabel

local titleGradient = Instance.new("UIGradient")
titleGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, CONFIG.AccentA),
	ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
	ColorSequenceKeypoint.new(1, CONFIG.AccentB),
})
titleGradient.Parent = titleLabel

if not CONFIG.Title then
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(game.PlaceId)
		end)
		if ok and info and info.Name and screenGui.Parent then
			titleLabel.Text = info.Name
		end
	end)
end

local dotsHolder = Instance.new("Frame")
dotsHolder.Name = "DotsHolder"
dotsHolder.Size = UDim2.new(1, 0, 0, 70)
dotsHolder.Position = UDim2.fromOffset(0, 80)
dotsHolder.BackgroundTransparency = 1
dotsHolder.Parent = content

local DOT_SIZE = 16
local DOT_SPACING = 30
local dots = {}
for i = 1, CONFIG.DotCount do
	local dot = Instance.new("Frame")
	dot.Name = "Dot" .. i
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.BorderSizePixel = 0
	dot.Parent = dotsHolder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	local glow = Instance.new("UIStroke")
	glow.Thickness = 3
	glow.Transparency = 0.6
	glow.Parent = dot

	dots[i] = {frame = dot, glow = glow}
end

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Size = UDim2.new(1, 0, 0, 24)
statusLabel.Position = UDim2.fromOffset(0, 165)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.Text = ""
statusLabel.TextColor3 = Color3.fromRGB(210, 210, 235)
statusLabel.TextSize = 18
statusLabel.Parent = content

-- Progress bar
local barTrack = Instance.new("Frame")
barTrack.Name = "BarTrack"
barTrack.Size = UDim2.new(0.8, 0, 0, 8)
barTrack.AnchorPoint = Vector2.new(0.5, 0)
barTrack.Position = UDim2.new(0.5, 0, 0, 205)
barTrack.BackgroundColor3 = Color3.new(1, 1, 1)
barTrack.BackgroundTransparency = 0.88
barTrack.BorderSizePixel = 0
barTrack.Parent = content
Instance.new("UICorner", barTrack).CornerRadius = UDim.new(1, 0)

local barFill = Instance.new("Frame")
barFill.Name = "Fill"
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Color3.new(1, 1, 1)
barFill.BorderSizePixel = 0
barFill.ClipsDescendants = true
barFill.Parent = barTrack
Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

local fillGradient = Instance.new("UIGradient")
fillGradient.Color = ColorSequence.new(CONFIG.AccentA, CONFIG.AccentB)
fillGradient.Parent = barFill

local shine = Instance.new("Frame")
shine.Name = "Shine"
shine.Size = UDim2.fromScale(1, 1)
shine.BackgroundColor3 = Color3.new(1, 1, 1)
shine.BorderSizePixel = 0
shine.Parent = barFill

local shineGradient = Instance.new("UIGradient")
shineGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0.45),
	NumberSequenceKeypoint.new(1, 1),
})
shineGradient.Parent = shine

local percentLabel = Instance.new("TextLabel")
percentLabel.Name = "PercentLabel"
percentLabel.Size = UDim2.new(1, 0, 0, 24)
percentLabel.Position = UDim2.fromOffset(0, 222)
percentLabel.BackgroundTransparency = 1
percentLabel.Font = Enum.Font.GothamBold
percentLabel.Text = "0%"
percentLabel.TextColor3 = Color3.new(1, 1, 1)
percentLabel.TextSize = 18
percentLabel.Parent = content

local tipLabel = Instance.new("TextLabel")
tipLabel.Name = "Tip"
tipLabel.Size = UDim2.new(0.9, 0, 0, 40)
tipLabel.AnchorPoint = Vector2.new(0.5, 1)
tipLabel.Position = UDim2.new(0.5, 0, 1, -40)
tipLabel.BackgroundTransparency = 1
tipLabel.Font = Enum.Font.Gotham
tipLabel.Text = ""
tipLabel.TextColor3 = Color3.fromRGB(170, 170, 200)
tipLabel.TextSize = 16
tipLabel.TextWrapped = true
tipLabel.TextTransparency = 1
tipLabel.Parent = background

local currentPercent = 0
local displayedPercent = 0
local statusText = ""
local finished = false

local function updatePercentText()
	percentLabel.Text = math.floor(displayedPercent) .. "%"
	barFill.Size = UDim2.fromScale(displayedPercent / 100, 1)
end

local function setPercent(p)
	currentPercent = math.clamp(p, 0, 100)
end

local function setStatus(text)
	statusText = text
end

local function lerpColor(t)
	return CONFIG.AccentA:Lerp(CONFIG.AccentB, (math.sin(t) + 1) / 2)
end

-- Single per-frame animation loop for everything on screen.
local elapsed = 0
local animConnection
animConnection = RunService.RenderStepped:Connect(function(dt)
	if not screenGui.Parent then
		animConnection:Disconnect()
		return
	end
	elapsed += dt

	if displayedPercent < currentPercent then
		displayedPercent = math.min(currentPercent, displayedPercent + math.max((currentPercent - displayedPercent) * 0.15, 0.4))
		updatePercentText()
	end

	bgGradient.Rotation = 90 + math.sin(elapsed * 0.3) * 25

	for _, s in ipairs(stars) do
		s.y -= s.speed * dt
		if s.y < -0.02 then
			s.y = 1.02
			s.x = math.random()
		end
		s.frame.Position = UDim2.fromScale(s.x + math.sin(elapsed * 0.5 + s.phase) * 0.005, s.y)
		s.frame.BackgroundTransparency = 0.25 + (math.sin(elapsed * s.twinkle + s.phase) + 1) * 0.3
	end

	titleGradient.Offset = Vector2.new(math.sin(elapsed * 0.8) * 0.5, 0)

	-- Wave of bouncing, colour-cycling dots
	local count = #dots
	local startX = -((count - 1) * DOT_SPACING) / 2
	for i, d in ipairs(dots) do
		local wave = math.sin(elapsed * 5 - i * 0.7)
		local lift = math.max(wave, 0)
		local scale = 0.8 + lift * 0.5
		local color = lerpColor(elapsed * 1.5 + i * 0.6)
		d.frame.Position = UDim2.new(0.5, startX + (i - 1) * DOT_SPACING, 0.5, -lift * 18)
		d.frame.Size = UDim2.fromOffset(DOT_SIZE * scale, DOT_SIZE * scale)
		d.frame.BackgroundColor3 = color
		d.glow.Color = color
		d.glow.Transparency = 0.85 - lift * 0.5
	end

	shineGradient.Offset = Vector2.new(((elapsed * 0.7) % 2) - 1, 0)

	if finished then
		statusLabel.Text = statusText
	else
		statusLabel.Text = statusText .. string.rep(".", math.floor(elapsed * 2.5) % 4)
	end
end)

-- Rotating tips
task.spawn(function()
	local tips = CONFIG.Tips
	if #tips == 0 then
		return
	end
	local index = math.random(1, #tips)
	local fadeInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad)
	while screenGui.Parent and not finished do
		tipLabel.Text = tips[index]
		TweenService:Create(tipLabel, fadeInfo, {TextTransparency = 0}):Play()
		task.wait(CONFIG.TipInterval)
		if finished or not screenGui.Parent then
			break
		end
		local out = TweenService:Create(tipLabel, fadeInfo, {TextTransparency = 1})
		out:Play()
		out.Completed:Wait()
		index = index % #tips + 1
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
	setStatus("Loading assets")
	preloadAssets()
	setStatus("Preparing your character")
	waitForCharacter()
	setStatus("Building the world")
	waitForGraphicsSettle()
	setPercent(100)

	local deadline = os.clock() + 3
	while displayedPercent < 99.5 and os.clock() < deadline do
		task.wait(0.05)
	end
	displayedPercent = 100
	updatePercentText()
	finished = true
	setStatus("Ready!")

	task.wait(0.5)

	local fadeInfo = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local fade = TweenService:Create(background, fadeInfo, {GroupTransparency = 1})
	TweenService:Create(uiScale, fadeInfo, {Scale = 1.15}):Play()
	fade:Play()
	fade.Completed:Wait()

	animConnection:Disconnect()
	screenGui:Destroy()
end)
