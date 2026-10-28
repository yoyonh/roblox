local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local TextChatService = game:GetService("TextChatService")
local AntiCheat = require(game.ServerScriptService:WaitForChild("Systems"):WaitForChild("AntiCheat"))

local adminMuteStore = DataStoreService:GetDataStore("AdminChatMutes_v1")

local event = ReplicatedStorage:WaitForChild("SendMessageEvent")
local messageTemplate = ReplicatedStorage:WaitForChild("Message")

local bubbleEvent = ReplicatedStorage:FindFirstChild("BubbleEvent")
if not bubbleEvent then
	bubbleEvent = Instance.new("RemoteEvent")
	bubbleEvent.Name = "BubbleEvent"
	bubbleEvent.Parent = ReplicatedStorage
end

local MAX_CHARACTERS = 120
local MAX_RAW_BYTES = 480
local MAX_CHAR_RUN = 6
local CAPS_MIN_LETTERS = 12
local CAPS_RATIO = 0.7

local TOKEN_CAPACITY = 4
local BASE_TOKENS_PER_SECOND = 0.55
local TRUST_TOKENS_BONUS = 0.20

local RATE_WINDOW = 20
local RATE_SOFT_LIMIT = 7
local RATE_HARD_LIMIT = 10

local HISTORY_SIZE = 4
local HISTORY_WINDOW = 30
local SIMILARITY_THRESHOLD = 0.82

local STRIKE_LIMIT = 3
local STRIKE_DECAY_SECONDS = 75

local TRUST_START = 0.5
local TRUST_GAIN = 0.02
local TRUST_LOSS_VIOLATION = 0.12
local TRUST_LOSS_MUTE = 0.2

local BLOCK_SCORE = 0.65
local HARD_SCORE = 0.90
local WATCH_SCORE = 0.45

local FIRST_MUTE_SECONDS = 90
local MAX_MUTE_SECONDS = 900
local GOOD_BEHAVIOR_RESET = 1800

local FLOOD_REMOVE_WINDOW = 30
local WARNING_COOLDOWN = 3
local COMMAND_COOLDOWN = 1
local CHAT_HISTORY_LIMIT = 40
local CHAT_HISTORY_LIFETIME = 15 * 60
local MAX_DISPLAYED_MESSAGES = 120
local STATE_RETENTION = 1800
local MAX_PHONE_DIGITS = 7

local MAX_PENDING_PER_PLAYER = 2
local FILTER_TIMEOUT = 10
local HASH_BLOCK_RATIO = 0.85
local HASH_BACKOFF_AFTER = 2
local HASH_BACKOFF_SECONDS = 30
local MASK_MAX_RATIO = 0.5

local MAX_TAG_CHARACTERS = 16
local MAX_NAME_CHARACTERS = 50
local MAX_SYSTEM_TEXT_CHARACTERS = 400
local MAX_ADMIN_MUTE_SECONDS = 30 * 24 * 3600

local SYSTEM_COLOR = Color3.fromRGB(75, 160, 255)
local MUTE_COLOR = Color3.fromRGB(255, 205, 70)
local BAN_COLOR = Color3.fromRGB(255, 75, 75)

local states = {}
local leftAt = {}
local chatMessagesBySender = {}
local systemMessages = {}
local recentMessages = {}
local displayOrder = 0

local RUSSIAN_UPPER_TO_LOWER = {
	["А"]="а", ["Б"]="б", ["В"]="в", ["Г"]="г", ["Д"]="д", ["Е"]="е", ["Ё"]="ё",
	["Ж"]="ж", ["З"]="з", ["И"]="и", ["Й"]="й", ["К"]="к", ["Л"]="л", ["М"]="м",
	["Н"]="н", ["О"]="о", ["П"]="п", ["Р"]="р", ["С"]="с", ["Т"]="т", ["У"]="у",
	["Ф"]="ф", ["Х"]="х", ["Ц"]="ц", ["Ч"]="ч", ["Ш"]="ш", ["Щ"]="щ", ["Ъ"]="ъ",
	["Ы"]="ы", ["Ь"]="ь", ["Э"]="э", ["Ю"]="ю", ["Я"]="я",
}
local RUSSIAN_LOWER_TO_UPPER = {}
for upper, lower in pairs(RUSSIAN_UPPER_TO_LOWER) do
	RUSSIAN_LOWER_TO_UPPER[lower] = upper
end

local HOMOGLYPHS = {
	["0"]="о", ["o"]="о", ["a"]="а", ["@"]="а", ["4"]="а", ["e"]="е", ["3"]="е",
	["c"]="с", ["x"]="х", ["p"]="р", ["y"]="у", ["k"]="к", ["h"]="н", ["m"]="м",
	["t"]="т", ["b"]="в", ["6"]="б", ["ё"]="е", ["й"]="и",
}

local INVISIBLE_CODEPOINTS = {
	[0x00AD]=true, [0x180E]=true, [0x200B]=true, [0x200C]=true, [0x200D]=true,
	[0x200E]=true, [0x200F]=true, [0x2060]=true, [0x2061]=true, [0x2062]=true,
	[0x2063]=true, [0x2064]=true, [0xFEFF]=true, [0x202A]=true, [0x202B]=true,
	[0x202C]=true, [0x202D]=true, [0x202E]=true,
}

local SEPARATOR_CODEPOINTS = {
	[0x00AB]=true, [0x00BB]=true, [0x2013]=true, [0x2014]=true, [0x2018]=true,
	[0x2019]=true, [0x201C]=true, [0x201D]=true, [0x2026]=true, [0x00A0]=true,
	[0x3000]=true,
}

local function lowerChar(ch: string)
	return RUSSIAN_UPPER_TO_LOWER[ch] or (#ch == 1 and ch:lower()) or ch
end

local function upperChar(ch: string)
	return RUSSIAN_LOWER_TO_UPPER[ch] or (#ch == 1 and ch:upper()) or ch
end

local function unicodeLower(text)
	local out = {}
	for _, cp in utf8.codes(text) do
		table.insert(out, lowerChar(utf8.char(cp)))
	end
	return table.concat(out)
end

local function isSeparatorChar(cp: number, ch: string)
	if SEPARATOR_CODEPOINTS[cp] then
		return true
	end
	return #ch == 1 and ch:match("[%s%p]") ~= nil
end

local function normalizeChar(ch)
	local lowered = lowerChar(ch)
	return HOMOGLYPHS[lowered] or lowered
end

local function buildNormalizedIndex(text)
	local chars = {}
	local pieces = {}
	local map = {}
	local index = 0
	local pos = 1
	for bytePos, cp in utf8.codes(text) do
		index += 1
		local ch = utf8.char(cp)
		chars[index] = {bytePos, bytePos + #ch - 1}
		if not isSeparatorChar(cp, ch) then
			local normalized = normalizeChar(ch)
			table.insert(pieces, normalized)
			for _ = 1, #normalized do
				map[pos] = index
				pos += 1
			end
		end
	end
	return table.concat(pieces), map, chars, index
end

local function normalizeCompact(text)
	local normalized = buildNormalizedIndex(text)
	return normalized
end

local function buildSet(str)
	local set = {}
	for _, cp in utf8.codes(str) do
		set[cp] = true
	end
	return set
end

local LAUGH_SETS = {}
for _, sample in ipairs({"ха", "хе", "хи", "ah", "eh", "ha", "ja", "ло", "lo", "ке", "ор", "хд", "xd"}) do
	table.insert(LAUGH_SETS, buildSet(normalizeCompact(sample)))
end

local BLOCKED_CONTACT_TOKENS = {}
for _, token in ipairs({
	"discord", "дискорд", "telegram", "телеграм", "whatsapp", "ватсап",
	"viber", "вайбер", "tiktok", "тикток", "t.me", "vk.com", "вконтакте",
	}) do
	table.insert(BLOCKED_CONTACT_TOKENS, normalizeCompact(token))
end

local PROFANITY_ROOTS = {}
do
	local seen = {}
	for _, root in ipairs({"гондон", "гандон", "gondon"}) do
		local normalized = normalizeCompact(root)
		if normalized ~= "" and not seen[normalized] then
			seen[normalized] = true
			table.insert(PROFANITY_ROOTS, normalized)
		end
	end
end

local function sanitizeText(raw)
	if not utf8.len(raw) then
		return nil
	end
	local out = {}
	local lastSpace = true
	for _, cp in utf8.codes(raw) do
		if cp == 9 or cp == 10 or cp == 13 or cp == 32 or cp == 0xA0 or cp == 0x3000 then
			if not lastSpace then
				table.insert(out, " ")
				lastSpace = true
			end
		elseif cp < 32 or cp == 127 or (cp >= 0x80 and cp <= 0x9F)
			or INVISIBLE_CODEPOINTS[cp] or (cp >= 0xE000 and cp <= 0xF8FF)
			or (cp >= 0xFFF0 and cp <= 0xFFFF) or (cp >= 0xD800 and cp <= 0xDFFF) then
		else
			table.insert(out, utf8.char(cp))
			lastSpace = false
		end
	end
	local text = table.concat(out):gsub("%s+$", "")
	return text
end

local function limitRuns(text)
	local out = {}
	local previous = nil
	local run = 0
	for _, cp in utf8.codes(text) do
		if cp == previous then
			run += 1
		else
			previous = cp
			run = 1
		end
		if run <= MAX_CHAR_RUN then
			table.insert(out, utf8.char(cp))
		end
	end
	return table.concat(out)
end

local function limitCaps(text)
	local letters = 0
	local upper = 0
	for _, cp in utf8.codes(text) do
		local ch = utf8.char(cp)
		if RUSSIAN_UPPER_TO_LOWER[ch] or (#ch == 1 and ch:match("%u")) then
			letters += 1
			upper += 1
		elseif RUSSIAN_LOWER_TO_UPPER[ch] or (#ch == 1 and ch:match("%l")) then
			letters += 1
		end
	end
	if letters < CAPS_MIN_LETTERS or upper / letters < CAPS_RATIO then
		return text
	end
	local lowered = unicodeLower(text)
	local firstEnd = (utf8.offset(lowered, 2) or (#lowered + 1)) - 1
	return upperChar(lowered:sub(1, firstEnd)) .. lowered:sub(firstEnd + 1)
end

local function maskKnownProfanity(text)
	local normalized, map, chars, totalChars = buildNormalizedIndex(text)
	if normalized == "" or totalChars == 0 then
		return text
	end
	local ranges = {}
	for _, root in ipairs(PROFANITY_ROOTS) do
		local init = 1
		while true do
			local first, last = normalized:find(root, init, true)
			if not first then
				break
			end
			local a, b = map[first], map[last]
			if a and b and a <= b then
				table.insert(ranges, {a, b})
			end
			init = last + 1
		end
	end
	if #ranges == 0 then
		return text
	end
	table.sort(ranges, function(a, b)
		return a[1] < b[1]
	end)
	local merged = {}
	local masked = 0
	for _, range in ipairs(ranges) do
		local lastRange = merged[#merged]
		if lastRange and range[1] <= lastRange[2] + 1 then
			masked -= lastRange[2] - lastRange[1] + 1
			lastRange[2] = math.max(lastRange[2], range[2])
			masked += lastRange[2] - lastRange[1] + 1
		else
			table.insert(merged, {range[1], range[2]})
			masked += range[2] - range[1] + 1
		end
	end
	if masked / totalChars > MASK_MAX_RATIO then
		return text
	end
	local result = text
	for i = #merged, 1, -1 do
		local range = merged[i]
		local startByte = chars[range[1]][1]
		local endByte = chars[range[2]][2]
		result = result:sub(1, startByte - 1)
			.. string.rep("#", range[2] - range[1] + 1)
			.. result:sub(endByte + 1)
	end
	return result
end

local function longestDigitGroup(text)
	local best = 0
	local current = 0
	for _, cp in utf8.codes(text) do
		if cp >= 48 and cp <= 57 then
			current += 1
			if current > best then
				best = current
			end
		elseif cp == 32 or cp == 45 or cp == 40 or cp == 41 or cp == 46 or cp == 43 or cp == 95 then
		else
			current = 0
		end
	end
	return best
end

local function containsForbiddenContact(text)
	local lower = unicodeLower(text)
	local compact = normalizeCompact(text)
	for _, token in ipairs(BLOCKED_CONTACT_TOKENS) do
		if compact:find(token, 1, true) then
			return true
		end
	end
	if lower:find("https?://") or lower:find("www%.") or lower:find("%.com%f[%A]")
		or lower:find("%.ru%f[%A]") or lower:find("%.gg%f[%A]") or lower:find("%.me%f[%A]")
		or lower:find("%.net%f[%A]") or lower:find("%.org%f[%A]") or lower:find("%.io%f[%A]") then
		return true
	end
	return longestDigitGroup(text) >= MAX_PHONE_DIGITS
end

local function hashRatio(original, filtered)
	local originalHashes, originalVisible = 0, 0
	for _, cp in utf8.codes(original) do
		if cp == 35 then
			originalHashes += 1
		end
		if cp ~= 32 then
			originalVisible += 1
		end
	end
	local filteredHashes = 0
	for _, cp in utf8.codes(filtered) do
		if cp == 35 then
			filteredHashes += 1
		end
	end
	if originalVisible == 0 then
		return 0, 0
	end
	return math.max(0, filteredHashes - originalHashes) / originalVisible, originalVisible
end

local function getState(userId)
	local state = states[userId]
	if state then
		return state
	end
	state = {
		tokens = TOKEN_CAPACITY,
		lastRefill = os.clock(),
		mutedUntil = 0,
		muteToken = 0,
		nextMuteDuration = FIRST_MUTE_SECONDS,
		lastMuteAt = 0,
		strikes = 0,
		lastStrikeAt = os.clock(),
		trust = TRUST_START,
		sentTimes = {},
		lastWarningAt = 0,
		lastCommandAt = 0,
		history = {},
		adminMuteExpiresAt = 0,
		adminMuteReason = nil,
		queue = {},
		processing = false,
		hashStreak = 0,
		filterBackoffUntil = 0,
	}
	states[userId] = state
	return state
end

local function allocateId()
	displayOrder += 1
	return displayOrder
end

local function destroyInstances(instances)
	if not instances then
		return
	end
	for _, instance in ipairs(instances) do
		if instance and instance.Parent then
			instance:Destroy()
		end
	end
end

local function escapeRichText(value)
	local text = tostring(value)
	text = text:gsub("&", "&amp;")
	text = text:gsub("<", "&lt;")
	text = text:gsub(">", "&gt;")
	text = text:gsub('"', "&quot;")
	text = text:gsub("'", "&apos;")
	return text
end

-- Strips control/invisible characters and caps length for server-supplied strings.
local function cleanLabel(value, maxCharacters, keepNewlines)
	local text = tostring(value)
	if not utf8.len(text) then
		return ""
	end
	local out = {}
	local count = 0
	for _, cp in utf8.codes(text) do
		if cp >= 32 and cp ~= 127 and not (cp >= 0x80 and cp <= 0x9F) and not INVISIBLE_CODEPOINTS[cp]
			and not (cp >= 0xE000 and cp <= 0xF8FF) and not (cp >= 0xFFF0 and cp <= 0xFFFF) then
			count += 1
			if count > maxCharacters then
				break
			end
			table.insert(out, utf8.char(cp))
		elseif cp == 9 or cp == 10 or cp == 13 then
			count += 1
			if count > maxCharacters then
				break
			end
			table.insert(out, (keepNewlines and cp == 10) and "\n" or " ")
		end
	end
	return table.concat(out)
end

local function getNameColor(userId, username)
	local numericId = tonumber(userId)
	if not numericId or numericId ~= numericId then
		numericId = 0
		for index = 1, #username do
			numericId = (numericId * 33 + string.byte(username, index)) % 2147483647
		end
	end
	local hash = (math.abs(numericId) * 1103515245 + 12345) % 2147483647
	local hue = (hash % 360) / 360
	local saturation = 0.62 + ((hash // 360) % 18) / 100
	return Color3.fromHSV(hue, saturation, 1)
end

local function colorToHex(color)
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

local SOLID_TAG_COLORS = {
	Color3.fromRGB(255, 90, 90),
	Color3.fromRGB(255, 155, 70),
	Color3.fromRGB(255, 220, 80),
	Color3.fromRGB(90, 220, 120),
	Color3.fromRGB(80, 165, 255),
}

local GRADIENT_TAG_COLORS = {
	{Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 175, 60)},
	{Color3.fromRGB(255, 215, 70), Color3.fromRGB(255, 90, 180)},
	{Color3.fromRGB(80, 235, 125), Color3.fromRGB(55, 220, 235)},
	{Color3.fromRGB(65, 220, 255), Color3.fromRGB(80, 100, 255)},
	{Color3.fromRGB(170, 80, 255), Color3.fromRGB(255, 75, 185)},
}

local function buildTagMarkup(tagText, style)
	if type(tagText) ~= "string" then
		return ""
	end
	tagText = cleanLabel(tagText, MAX_TAG_CHARACTERS)
	if tagText == "" then
		return ""
	end
	style = tonumber(style) or 1
	style = math.clamp(style == style and math.floor(style) or 1, 1, 10)
	local escapedTag = escapeRichText(tagText)
	if style <= 5 then
		return ('<font color="%s">[%s]</font> '):format(colorToHex(SOLID_TAG_COLORS[style]), escapedTag)
	end
	local pair = GRADIENT_TAG_COLORS[style - 5]
	local characters = {}
	for _, codepoint in utf8.codes(tagText) do
		table.insert(characters, utf8.char(codepoint))
	end
	local pieces = {'<font color="' .. colorToHex(pair[1]) .. '">[</font>'}
	for index, character in ipairs(characters) do
		local alpha = #characters <= 1 and 0 or (index - 1) / (#characters - 1)
		local color = pair[1]:Lerp(pair[2], alpha)
		table.insert(pieces, ('<font color="%s">%s</font>'):format(colorToHex(color), escapeRichText(character)))
	end
	table.insert(pieces, '<font color="' .. colorToHex(pair[2]) .. '">]</font> ')
	return table.concat(pieces)
end

local function getScrollingFrame(player)
	local playerGui = player:FindFirstChild("PlayerGui")
	local chatGui = playerGui and playerGui:FindFirstChild("ChatGui")
	local chatFrame = chatGui and chatGui:FindFirstChild("ChatFrame", true)
	return chatFrame and chatFrame:FindFirstChild("ScrollingFrame")
end

local function trimScrollingFrame(scrollingFrame)
	local items = {}
	for _, child in ipairs(scrollingFrame:GetChildren()) do
		if child:IsA("GuiObject") then
			table.insert(items, child)
		end
	end
	if #items <= MAX_DISPLAYED_MESSAGES then
		return
	end
	table.sort(items, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for index = 1, #items - MAX_DISPLAYED_MESSAGES do
		items[index]:Destroy()
	end
end

local function captureSender(player)
	return {
		senderUserId = player.UserId,
		username = player.Name,
		displayName = cleanLabel(player.DisplayName, MAX_NAME_CHARACTERS),
		tagText = player:GetAttribute("ChatTagText"),
		tagStyle = player:GetAttribute("ChatTagStyle"),
		developerVerified = player:GetAttribute("DeveloperVerified") == true,
		premiumVerified = player:GetAttribute("PremiumVerified") == true,
		nameColor = player:GetAttribute("ChatNameColor"),
		vip = player:GetAttribute("VIP") == true,
	}
end

local function buildMessageMarkup(entry)
	if entry.system then
		return ('<font color="%s">%s: %s</font>'):format(
			colorToHex(entry.color or SYSTEM_COLOR),
			escapeRichText(entry.displayName),
			escapeRichText(entry.text)
		)
	end
	local nameColor = typeof(entry.nameColor) == "Color3" and entry.nameColor
		or getNameColor(entry.senderUserId, entry.username)
	return ('%s%s<font color="%s">%s</font>%s%s: %s'):format(
		entry.vip and '<font color="#FFD966">[VIP]</font> ' or "",
		buildTagMarkup(entry.tagText, entry.tagStyle),
		colorToHex(nameColor),
		escapeRichText(entry.displayName),
		entry.developerVerified and (' <font color="#1D9BF0">%s</font>'):format(utf8.char(0xE000)) or "",
		entry.premiumVerified and (' <font color="#F5C542">%s</font>'):format(utf8.char(0xE003)) or "",
		escapeRichText(entry.text)
	)
end

local function createDisplayedMessage(scrollingFrame, entry, isHistory)
	if not scrollingFrame or type(entry.text) ~= "string" or entry.text == "" then
		return nil
	end
	local ok, result = pcall(function()
		local message = messageTemplate:Clone()
		local colourScript = message:FindFirstChild("ColourScript")
		if colourScript then
			colourScript:Destroy()
		end
		local messageValue = message:FindFirstChild("Message")
		local usernameValue = message:FindFirstChild("Username")
		local displayNameValue = message:FindFirstChild("DisplayName")
		if messageValue then messageValue.Value = entry.text end
		if usernameValue then usernameValue.Value = entry.username end
		if displayNameValue then displayNameValue.Value = entry.displayName end

		message:SetAttribute("SenderUserId", entry.senderUserId)
		message:SetAttribute("ChatHistoryId", entry.id)
		if isHistory then
			message:SetAttribute("IsChatHistory", true)
		end
		if entry.system then
			message:SetAttribute("IsSystem", true)
		end

		message.LayoutOrder = entry.id
		message.Visible = true
		message.RichText = true
		message.TextWrapped = true
		message.AutomaticSize = Enum.AutomaticSize.Y
		message.Size = UDim2.new(1, -6, 0, 0)
		message.Text = buildMessageMarkup(entry)
		message.Parent = scrollingFrame
		trimScrollingFrame(scrollingFrame)
		return message
	end)
	if ok then
		return result
	end
	warn("[Chat] createDisplayedMessage:", result)
	return nil
end

local function makeSystemEntry(text, color)
	if typeof(color) ~= "Color3" then
		color = nil
	end
	return {
		id = allocateId(),
		system = true,
		color = color or SYSTEM_COLOR,
		username = "Система",
		displayName = "Система",
		text = cleanLabel(text, MAX_SYSTEM_TEXT_CHARACTERS, true),
		createdAt = os.clock(),
	}
end

local function sendSystemMessage(player, text, color)
	if player.Parent ~= Players then
		return
	end
	destroyInstances(systemMessages[player.UserId])
	systemMessages[player.UserId] = {}
	local message = createDisplayedMessage(getScrollingFrame(player), makeSystemEntry(text, color), false)
	if message then
		table.insert(systemMessages[player.UserId], message)
	end
end

local function pruneHistory(now)
	local kept = {}
	for _, entry in ipairs(recentMessages) do
		if now - entry.createdAt <= CHAT_HISTORY_LIFETIME then
			table.insert(kept, entry)
		end
	end
	recentMessages = kept
	while #recentMessages > CHAT_HISTORY_LIMIT do
		table.remove(recentMessages, 1)
	end
end

local function sendPublicSystemMessage(text, color)
	local entry = makeSystemEntry(text, color)
	pruneHistory(entry.createdAt)
	table.insert(recentMessages, entry)
	for _, player in ipairs(Players:GetPlayers()) do
		createDisplayedMessage(getScrollingFrame(player), entry, false)
	end
end

local function clearChatForEveryone()
	recentMessages = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local scrollingFrame = getScrollingFrame(player)
		if scrollingFrame then
			for _, child in ipairs(scrollingFrame:GetChildren()) do
				if child:IsA("GuiObject") and child:GetAttribute("ChatHistoryId") then
					child:Destroy()
				end
			end
		end
	end
	chatMessagesBySender = {}
	systemMessages = {}
end

local function sendWarning(player, state, text, color)
	local now = os.clock()
	if now - state.lastWarningAt >= WARNING_COOLDOWN then
		state.lastWarningAt = now
		sendSystemMessage(player, text, color)
	end
end

local function updateMuteAttribute(player, remaining)
	if player.Parent ~= Players then
		return
	end
	if remaining and remaining > 0 then
		player:SetAttribute("ChatMutedUntil", os.time() + remaining)
	else
		player:SetAttribute("ChatMutedUntil", nil)
	end
end

local function getMuteInfo(state, now)
	if state.adminMuteExpiresAt > 0 then
		local remaining = state.adminMuteExpiresAt - os.time()
		if remaining > 0 then
			return remaining, state.adminMuteReason
		end
		state.adminMuteExpiresAt = 0
		state.adminMuteReason = nil
	end
	if now < state.mutedUntil then
		return math.max(1, math.ceil(state.mutedUntil - now)), nil
	end
	return nil, nil
end

local function resetAfterMute(state, now)
	state.tokens = TOKEN_CAPACITY
	state.lastRefill = now
	state.sentTimes = {}
	state.history = {}
	state.strikes = 0
	state.lastStrikeAt = now
	state.hashStreak = 0
end

local function scheduleUnmuteNotice(player, state, seconds)
	state.muteToken += 1
	local token = state.muteToken
	task.delay(seconds, function()
		if states[player.UserId] ~= state or state.muteToken ~= token then
			return
		end
		if player.Parent ~= Players then
			return
		end
		local now = os.clock()
		if getMuteInfo(state, now) then
			return
		end
		resetAfterMute(state, now)
		updateMuteAttribute(player, nil)
		sendSystemMessage(player, "Мут снят. Теперь можно писать в чат.")
	end)
end

local function removeFloodMessages(userId, now)
	local history = {}
	for _, entry in ipairs(recentMessages) do
		if not (entry.senderUserId == userId and not entry.system and now - entry.createdAt <= FLOOD_REMOVE_WINDOW) then
			table.insert(history, entry)
		end
	end
	recentMessages = history
	local messages = chatMessagesBySender[userId]
	if not messages then
		return
	end
	local kept = {}
	for _, entry in ipairs(messages) do
		if entry.instance and entry.instance.Parent then
			if now - entry.createdAt <= FLOOD_REMOVE_WINDOW then
				entry.instance:Destroy()
			else
				table.insert(kept, entry)
			end
		end
	end
	chatMessagesBySender[userId] = kept
end

local function mutePlayer(player, state, reason)
	local now = os.clock()
	if state.lastMuteAt > 0 and now - state.lastMuteAt > GOOD_BEHAVIOR_RESET then
		state.nextMuteDuration = FIRST_MUTE_SECONDS
	end
	local duration = state.nextMuteDuration
	state.mutedUntil = now + duration
	state.lastMuteAt = now
	state.nextMuteDuration = math.min(duration * 2, MAX_MUTE_SECONDS)
	state.trust = math.max(0, state.trust - TRUST_LOSS_MUTE)
	state.queue = {}
	resetAfterMute(state, now)

	removeFloodMessages(player.UserId, now)
	updateMuteAttribute(player, duration)
	sendSystemMessage(player, ("Чат заблокирован на %d сек. Причина: %s."):format(duration, reason), MUTE_COLOR)
	scheduleUnmuteNotice(player, state, duration)
end

local function applyAdminMute(player, state, expiresAt, reason, label)
	local remaining = expiresAt - os.time()
	if remaining <= 0 then
		return
	end
	state.adminMuteExpiresAt = expiresAt
	state.adminMuteReason = reason
	state.mutedUntil = math.max(state.mutedUntil, os.clock() + remaining)
	state.queue = {}
	updateMuteAttribute(player, remaining)
	sendSystemMessage(player, ("Вам выдан мут на %s. Причина: %s"):format(label or (remaining .. " сек."), reason), MUTE_COLOR)
	scheduleUnmuteNotice(player, state, remaining)
end

local function applyStoredAdminMute(player)
	local key = tostring(player.UserId)
	local ok, data = pcall(function()
		return adminMuteStore:GetAsync(key)
	end)
	if not ok or type(data) ~= "table" then
		return
	end
	local expiresAt = tonumber(data.expiresAt) or 0
	if expiresAt ~= expiresAt or expiresAt <= os.time() then
		if expiresAt > 0 then
			pcall(function()
				adminMuteStore:RemoveAsync(key)
			end)
		end
		return
	end
	task.delay(1, function()
		if player.Parent == Players then
			applyAdminMute(player, getState(player.UserId), math.min(expiresAt, os.time() + MAX_ADMIN_MUTE_SECONDS),
				cleanLabel(data.reason or "Решение администратора", 200))
		end
	end)
end

local function applyStrikeDecay(state, now)
	local decayed = (now - state.lastStrikeAt) / STRIKE_DECAY_SECONDS
	state.strikes = math.max(0, state.strikes - decayed)
	state.lastStrikeAt = now
end

local function addStrikes(player, state, amount, muteReason, warningText)
	local now = os.clock()
	applyStrikeDecay(state, now)
	state.strikes += amount * (1.6 - state.trust)
	if state.strikes >= STRIKE_LIMIT then
		mutePlayer(player, state, muteReason)
		return true
	end
	if warningText then
		sendWarning(player, state, warningText)
	end
	return false
end

local function registerViolation(player, state, reason, weight)
	state.trust = math.max(0, state.trust - TRUST_LOSS_VIOLATION)
	addStrikes(player, state, weight, reason, ("Сообщение не отправлено (%s). Продолжишь — получишь мут."):format(reason))
end

local function collapseRuns(normalized)
	local out = {}
	local previous = nil
	for _, cp in utf8.codes(normalized) do
		if cp ~= previous then
			table.insert(out, utf8.char(cp))
			previous = cp
		end
	end
	return table.concat(out)
end

local function isLaughter(normalized)
	local length = utf8.len(normalized)
	if not length or length == 0 then
		return false
	end
	for _, set in ipairs(LAUGH_SETS) do
		local matches = true
		for _, cp in utf8.codes(normalized) do
			if not set[cp] then
				matches = false
				break
			end
		end
		if matches then
			return true
		end
	end
	return false
end

local function countUnique(text)
	local unique = {}
	local total = 0
	for _, codepoint in utf8.codes(text) do
		if not unique[codepoint] then
			unique[codepoint] = true
			total += 1
		end
	end
	return total
end

local function bigrams(text)
	local grams = {}
	local previous = nil
	for _, cp in utf8.codes(text) do
		if previous then
			grams[previous .. ":" .. cp] = true
		end
		previous = cp
	end
	return grams
end

local function jaccard(a, b)
	local inter = 0
	local union = 0
	for key in pairs(a) do
		union += 1
		if b[key] then
			inter += 1
		end
	end
	for key in pairs(b) do
		if not a[key] then
			union += 1
		end
	end
	if union == 0 then
		return 0
	end
	return inter / union
end

local function pushHistory(state, collapsed, grams, now)
	table.insert(state.history, {collapsed = collapsed, grams = grams, at = now})
	while #state.history > HISTORY_SIZE do
		table.remove(state.history, 1)
	end
end

local function evaluateMessage(state, rawLength, normalized, now)
	local laughter = isLaughter(normalized)
	local collapsed = collapseRuns(normalized)
	local clen = utf8.len(collapsed) or 0
	local score = 0
	local reason = nil
	local grams = nil

	if not laughter then
		if clen >= 12 and countUnique(collapsed) <= 3 then
			score = math.max(score, 0.65)
			reason = "бессмысленный набор символов"
		end
		if rawLength >= 60 and clen <= 5 then
			score = math.max(score, 0.6)
			reason = reason or "бессмысленный набор символов"
		end
	end

	if clen >= 2 then
		grams = bigrams(collapsed)
	end

	if collapsed ~= "" then
		local similarCount = 0
		local fastRepeat = false
		for _, entry in ipairs(state.history) do
			if now - entry.at <= HISTORY_WINDOW then
				local sim = 0
				if entry.collapsed == collapsed then
					sim = 1
				elseif grams and entry.grams and clen >= 4 then
					sim = jaccard(grams, entry.grams)
				end
				if sim >= SIMILARITY_THRESHOLD then
					similarCount += 1
					if now - entry.at <= 4 then
						fastRepeat = true
					end
				end
			end
		end
		local neededRepeats = (clen <= 4) and 4 or 2
		if similarCount >= neededRepeats then
			score = math.max(score, fastRepeat and 0.9 or 0.75)
			reason = "повторяющиеся сообщения"
		elseif similarCount >= 1 and fastRepeat then
			score = math.max(score, 0.45)
			reason = reason or "повторяющиеся сообщения"
		end
	end

	if laughter then
		score = math.min(score, 0.3)
	end

	return score, reason, collapsed, grams
end

local function storeHistory(info, text)
	local now = os.clock()
	pruneHistory(now)
	local entry = info
	entry.id = allocateId()
	entry.text = text
	entry.createdAt = now
	table.insert(recentMessages, entry)
	while #recentMessages > CHAT_HISTORY_LIMIT do
		table.remove(recentMessages, 1)
	end
	return entry
end

local function broadcastEntry(entry)
	local userId = entry.senderUserId
	local kept = {}
	for _, record in ipairs(chatMessagesBySender[userId] or {}) do
		if record.instance and record.instance.Parent and entry.createdAt - record.createdAt <= FLOOD_REMOVE_WINDOW then
			table.insert(kept, record)
		end
	end
	chatMessagesBySender[userId] = kept
	for _, recipient in ipairs(Players:GetPlayers()) do
		local message = createDisplayedMessage(getScrollingFrame(recipient), entry, false)
		if message then
			table.insert(kept, {instance = message, createdAt = entry.createdAt})
		end
	end
end

local function filterWithTimeout(text, userId)
	local done = false
	local result = nil
	local failure = nil
	task.spawn(function()
		local ok, value = pcall(function()
			local filtered = TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
			return filtered:GetNonChatStringForBroadcastAsync()
		end)
		if ok then
			result = value
		else
			failure = tostring(value)
		end
		done = true
	end)
	local deadline = os.clock() + FILTER_TIMEOUT
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	if not done then
		return nil, "timeout"
	end
	return result, failure
end

local function processQueued(sender, state, item)
	if sender.Parent ~= Players then
		return
	end

	local broadcastText, failure = filterWithTimeout(item.text, sender.UserId)
	if type(broadcastText) ~= "string" or broadcastText == "" then
		warn("[Chat] filter failed:", failure)
		sendWarning(sender, state, "Сообщение не отправлено: фильтр Roblox недоступен. Попробуй ещё раз.")
		return
	end

	local now = os.clock()
	if sender.Parent ~= Players or getMuteInfo(state, now) then
		return
	end

	local canChatOk, canChat = pcall(function()
		return TextChatService:CanUserChatAsync(sender.UserId)
	end)
	if canChatOk and canChat == false then
		return
	end
	if sender.Parent ~= Players then
		return
	end

	local ratio, visible = hashRatio(item.text, broadcastText)
	if visible >= 3 and ratio >= HASH_BLOCK_RATIO then
		state.hashStreak += 1
		if state.hashStreak >= HASH_BACKOFF_AFTER then
			state.filterBackoffUntil = now + HASH_BACKOFF_SECONDS
			sendWarning(sender, state, ("Фильтр Roblox сейчас скрывает все твои сообщения (так бывает после флуда). Подожди %d сек и пиши обычные фразы."):format(HASH_BACKOFF_SECONDS), MUTE_COLOR)
		else
			sendWarning(sender, state, "Фильтр Roblox скрыл всё сообщение. Попробуй переформулировать.", MUTE_COLOR)
		end
		return
	end
	state.hashStreak = 0

	local entry = storeHistory(item.info, maskKnownProfanity(broadcastText))
	broadcastEntry(entry)
	bubbleEvent:FireAllClients(entry.senderUserId, entry.text)
end

local function enqueue(sender, state, item)
	if #state.queue >= MAX_PENDING_PER_PLAYER then
		sendWarning(sender, state, "Подожди, предыдущие сообщения ещё обрабатываются.")
		return
	end
	table.insert(state.queue, item)
	if state.processing then
		return
	end
	state.processing = true
	local queue = state.queue
	task.spawn(function()
		while true do
			local nextItem = table.remove(queue, 1)
			if not nextItem then
				break
			end
			local ok, err = pcall(processQueued, sender, state, nextItem)
			if not ok then
				warn("[Chat] processQueued:", err)
			end
		end
		if state.queue == queue then
			state.processing = false
		end
	end)
end

local function replayHistory(player)
	local playerGui = player:WaitForChild("PlayerGui", 15)
	local chatGui = playerGui and playerGui:WaitForChild("ChatGui", 15)
	local chatFrame = chatGui and chatGui:FindFirstChild("ChatFrame", true)
	local scrollingFrame = chatFrame and chatFrame:WaitForChild("ScrollingFrame", 15)
	if not scrollingFrame or player.Parent ~= Players then
		return
	end
	local existingIds = {}
	for _, child in ipairs(scrollingFrame:GetChildren()) do
		local id = child:GetAttribute("ChatHistoryId")
		if id then
			existingIds[id] = true
		end
	end
	local now = os.clock()
	for _, entry in ipairs(recentMessages) do
		if now - entry.createdAt <= CHAT_HISTORY_LIFETIME and not existingIds[entry.id] then
			createDisplayedMessage(scrollingFrame, entry, true)
		end
	end
end

local HELP_TEXT = table.concat({
	"Доступные команды:",
	"/help — показать этот список",
	"/правила — правила общения",
	"/онлайн — сколько игроков на сервере",
	"/инфо — кратко об игре",
	"/мут — сколько осталось мута",
}, "\n")

local RULES_TEXT = table.concat({
	"Правила чата:",
	"1. Не оскорбляй и не унижай других.",
	"2. Не спамь и не повторяй одно сообщение.",
	"3. Не отправляй ссылки, контакты и личные данные.",
	"4. Не пытайся обходить фильтр Roblox.",
	"5. Играй честно и уважай остальных.",
}, "\n")

local function handlePublicCommand(player, state, text, now)
	if text:sub(1, 1) ~= "/" then
		return false
	end
	if now - state.lastCommandAt < COMMAND_COOLDOWN then
		return true
	end
	state.lastCommandAt = now
	local command = unicodeLower(text):match("^(%S+)")
	if command == "/help" or command == "/помощь" or command == "/команды" then
		sendSystemMessage(player, HELP_TEXT)
	elseif command == "/правила" or command == "/rules" then
		sendSystemMessage(player, RULES_TEXT)
	elseif command == "/онлайн" or command == "/online" then
		sendSystemMessage(player, ("Сейчас на сервере игроков: %d."):format(#Players:GetPlayers()))
	elseif command == "/инфо" or command == "/info" then
		sendSystemMessage(player, "Это русскоязычная социальная игра с магазином, PvP-зонами и мини-игрой TimeBomb.")
	elseif command == "/мут" or command == "/mute" then
		local remaining, reason = getMuteInfo(state, now)
		if remaining then
			sendSystemMessage(player, ("Мут: осталось %d сек.%s"):format(remaining, reason and (" Причина: " .. reason .. ".") or ""), MUTE_COLOR)
		else
			sendSystemMessage(player, "У тебя нет мута.")
		end
	else
		sendSystemMessage(player, "Неизвестная команда. Введите /help, чтобы увидеть доступные команды.")
	end
	return true
end

local privateSystemMessage = Instance.new("BindableEvent")
privateSystemMessage.Name = "PrivateSystemMessage"
privateSystemMessage.Parent = script
privateSystemMessage.Event:Connect(function(player, text)
	if typeof(player) == "Instance" and player:IsA("Player") then
		sendSystemMessage(player, "[ADMIN] " .. cleanLabel(text, MAX_SYSTEM_TEXT_CHARACTERS))
	end
end)

local adminChatControl = Instance.new("BindableFunction")
adminChatControl.Name = "AdminChatControl"
adminChatControl.Parent = script
adminChatControl.OnInvoke = function(action, target, duration, reason, extra)
	if action == "announceBan" then
		sendPublicSystemMessage(("Игрок %s забанен на %s. Причина: %s"):format(
			cleanLabel(target, MAX_NAME_CHARACTERS), cleanLabel(duration, 40), cleanLabel(reason, 200)), BAN_COLOR)
		return true
	elseif action == "announce" then
		sendPublicSystemMessage(tostring(target), typeof(duration) == "Color3" and duration or SYSTEM_COLOR)
		return true
	elseif action == "clearChat" then
		clearChatForEveryone()
		return true
	end
	if typeof(target) ~= "Instance" or not target:IsA("Player") or target.Parent ~= Players then
		return false, "Некорректный игрок"
	end
	local state = getState(target.UserId)
	if action == "mute" then
		duration = tonumber(duration) or 0
		if duration ~= duration or duration <= 0 then
			return false, "Некорректное время мута"
		end
		duration = math.min(math.floor(duration), MAX_ADMIN_MUTE_SECONDS)
		if duration <= 0 then
			return false, "Некорректное время мута"
		end
		reason = cleanLabel(reason or "Решение администратора", 200)
		local expiresAt = os.time() + duration
		local saved = pcall(function()
			adminMuteStore:SetAsync(tostring(target.UserId), {expiresAt = expiresAt, reason = reason})
		end)
		applyAdminMute(target, state, expiresAt, reason, extra and cleanLabel(extra, 60) or nil)
		removeFloodMessages(target.UserId, os.clock())
		return true, saved
	elseif action == "unmute" then
		local now = os.clock()
		state.mutedUntil = 0
		state.adminMuteExpiresAt = 0
		state.adminMuteReason = nil
		state.muteToken += 1
		resetAfterMute(state, now)
		local removed = pcall(function()
			adminMuteStore:RemoveAsync(tostring(target.UserId))
		end)
		updateMuteAttribute(target, nil)
		sendSystemMessage(target, "Администратор снял с вас мут.", MUTE_COLOR)
		return true, removed
	elseif action == "muteInfo" then
		local remaining, muteReason = getMuteInfo(state, os.clock())
		return true, remaining, muteReason
	elseif action == "clearMessages" then
		removeFloodMessages(target.UserId, os.clock())
		return true
	end
	return false, "Неизвестное действие"
end

local function handleMessage(sender, raw)
	if sender.Parent ~= Players then
		return
	end
	if typeof(raw) ~= "string" or #raw == 0 or #raw > MAX_RAW_BYTES then
		AntiCheat.ReportExploit(sender, AntiCheat.Codes.InvalidRemoteData,
			("SendMessageEvent: %s / %d байт"):format(typeof(raw), typeof(raw) == "string" and #raw or 0))
		return
	end
	if not AntiCheat.CheckRemote(sender, "chat", 3, 6) then
		return
	end
	local text = sanitizeText(raw)
	if not text or text == "" then
		return
	end

	local state = getState(sender.UserId)
	local now = os.clock()

	if handlePublicCommand(sender, state, text, now) then
		return
	end

	local characterCount = utf8.len(text)
	if not characterCount then
		return
	end
	if characterCount > MAX_CHARACTERS then
		sendWarning(sender, state, ("Сообщение слишком длинное (максимум %d символов)."):format(MAX_CHARACTERS))
		return
	end

	local muteRemaining, muteReason = getMuteInfo(state, now)
	if muteRemaining then
		sendWarning(sender, state, ("Ты в муте ещё %d сек.%s"):format(muteRemaining, muteReason and (" Причина: " .. muteReason .. ".") or ""), MUTE_COLOR)
		return
	end

	if now < state.filterBackoffUntil then
		sendWarning(sender, state, ("Фильтр Roblox временно скрывает твои сообщения. Подожди %d сек."):format(math.ceil(state.filterBackoffUntil - now)), MUTE_COLOR)
		return
	end

	if containsForbiddenContact(text) then
		registerViolation(sender, state, "ссылки, контакты и номера запрещены", 2)
		return
	end

	local elapsed = now - state.lastRefill
	state.lastRefill = now
	local refillRate = BASE_TOKENS_PER_SECOND + TRUST_TOKENS_BONUS * state.trust
	state.tokens = math.min(TOKEN_CAPACITY, state.tokens + elapsed * refillRate)
	if state.tokens < 1 then
		addStrikes(sender, state, 0.5, "флуд", "Слишком быстро! Не долби чат — получишь мут.")
		return
	end
	state.tokens -= 1

	local recent = {}
	for _, t in ipairs(state.sentTimes) do
		if now - t <= RATE_WINDOW then
			table.insert(recent, t)
		end
	end
	state.sentTimes = recent

	if #recent + 1 >= RATE_HARD_LIMIT then
		mutePlayer(sender, state, "флуд")
		return
	end
	if #recent + 1 >= RATE_SOFT_LIMIT then
		addStrikes(sender, state, 1, "флуд", "Ты пишешь слишком часто. Сбавь темп, иначе мут.")
		return
	end
	table.insert(state.sentTimes, now)

	text = limitCaps(limitRuns(text))

	local normalized = normalizeCompact(text)
	local score, reason, collapsed, grams = evaluateMessage(state, characterCount, normalized, now)
	if collapsed ~= "" then
		pushHistory(state, collapsed, grams, now)
	end

	if score >= BLOCK_SCORE then
		registerViolation(sender, state, reason or "спам", score >= HARD_SCORE and 2 or 1.25)
		return
	end
	if score >= WATCH_SCORE then
		if addStrikes(sender, state, 0.3, "подозрительная активность в чате", nil) then
			return
		end
	elseif score < 0.2 then
		state.trust = math.min(1, state.trust + TRUST_GAIN)
	end

	enqueue(sender, state, {text = text, info = captureSender(sender)})
end

event.OnServerEvent:Connect(function(sender, raw)
	local ok, err = pcall(handleMessage, sender, raw)
	if not ok then
		warn("[Chat] handleMessage:", err)
	end
end)

local function hookPlayer(player)
	leftAt[player.UserId] = nil
	task.spawn(replayHistory, player)
	task.spawn(applyStoredAdminMute, player)
	local state = states[player.UserId]
	if state then
		state.queue = {}
		state.processing = false
		task.delay(1, function()
			if player.Parent ~= Players then
				return
			end
			local remaining, reason = getMuteInfo(state, os.clock())
			if remaining then
				updateMuteAttribute(player, remaining)
				sendSystemMessage(player, ("Ты всё ещё в муте: %d сек.%s"):format(remaining, reason and (" Причина: " .. reason .. ".") or ""), MUTE_COLOR)
				scheduleUnmuteNotice(player, state, remaining)
			end
		end)
	end
	player.CharacterAdded:Connect(function()
		task.delay(0.75, function()
			if player.Parent == Players then
				replayHistory(player)
			end
		end)
	end)
end

Players.PlayerAdded:Connect(hookPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(hookPlayer, player)
end

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	destroyInstances(systemMessages[userId])
	systemMessages[userId] = nil
	leftAt[userId] = os.clock()
	local state = states[userId]
	if state then
		state.queue = {}
	end
	local list = chatMessagesBySender[userId]
	if list then
		local kept = {}
		for _, record in ipairs(list) do
			if record.instance and record.instance.Parent then
				table.insert(kept, record)
			end
		end
		chatMessagesBySender[userId] = #kept > 0 and kept or nil
	end
end)

task.spawn(function()
	while true do
		task.wait(60)
		local now = os.clock()
		pruneHistory(now)
		for userId, at in pairs(leftAt) do
			if not Players:GetPlayerByUserId(userId) and now - at > STATE_RETENTION then
				local state = states[userId]
				if not state or (state.mutedUntil <= now and state.adminMuteExpiresAt <= os.time()) then
					states[userId] = nil
					chatMessagesBySender[userId] = nil
					leftAt[userId] = nil
				end
			end
		end
	end
end)