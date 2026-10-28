local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TextService = game:GetService("TextService")
local AntiCheat = require(ServerScriptService:WaitForChild("Systems"):WaitForChild("AntiCheat"))

local CONFIG = {
	Admins = {
		8601251212
	},

	AutoOwnerAdmin = true,  -- владелец игры / группы — админ автоматически
	GroupAdminRank = 255,   -- для групповых игр: ранг в группе >= этого = админ
	AllowInStudio = true,   -- в Studio все админы (удобно тестировать)

	-- require/rq исполняет произвольный серверный код по asset id.
	-- Выключено по умолчанию; даже включённое доступно только владельцу и админам из Admins.
	AllowRequireCommand = false,

	BanApplyToUniverse = true, -- бан во всех плейсах вселенной
	BanExcludeAlts = false,    -- false = баним и альт-аккаунты тоже
	DefaultBanReason = "Нарушение правил",
	DefaultKickReason = "Кикнут администратором",

	AnnounceTime = 5,          -- сколько секунд висит объявление
	DefaultFlySpeed = 60,

	MaxInputLength = 300,      -- макс. длина строки команды от клиента
	MaxReasonLength = 200,     -- макс. длина причины / текста объявления
	MaxTagLength = 32,
	MaxDurationSeconds = 315360000, -- 10 лет
	MaxCoins = 1000000000,
}

--------------------------------------------------------------------------------
-- Ремоуты
--------------------------------------------------------------------------------

local remotes = Instance.new("Folder")
remotes.Name = "AdminConsoleRemotes"

local cmdRemote = Instance.new("RemoteEvent")
cmdRemote.Name = "Command"
cmdRemote.Parent = remotes

local outRemote = Instance.new("RemoteEvent")
outRemote.Name = "Output"
outRemote.Parent = remotes

local annRemote = Instance.new("RemoteEvent")
annRemote.Name = "Announce"
annRemote.Parent = remotes

local actRemote = Instance.new("RemoteEvent")
actRemote.Name = "ClientAction"
actRemote.Parent = remotes

local isAdminRF = Instance.new("RemoteFunction")
isAdminRF.Name = "IsAdmin"
isAdminRF.Parent = remotes

remotes.Parent = ReplicatedStorage

--------------------------------------------------------------------------------
-- Права
--------------------------------------------------------------------------------

-- Уровни: 0 = не админ, 1 = админ, 2 = админ из CONFIG.Admins, 3 = владелец
local LEVEL_OWNER = 3
local LEVEL_TRUSTED = 2

local adminCache = {}     -- [player] = level
local adminFailedAt = {}  -- [player] = os.clock() неудачной проверки группы (повтор не чаще раза в 15с)

local function levelOfUserId(userId)
	if CONFIG.AutoOwnerAdmin and game.CreatorType == Enum.CreatorType.User and userId == game.CreatorId then
		return LEVEL_OWNER
	end
	if table.find(CONFIG.Admins, userId) then
		return LEVEL_TRUSTED
	end
	return 0
end

local function getLevel(player)
	local cached = adminCache[player]
	if cached ~= nil then
		return cached
	end
	local failedAt = adminFailedAt[player]
	if failedAt and os.clock() - failedAt < 15 then
		return 0
	end

	local level = levelOfUserId(player.UserId)
	if level < LEVEL_TRUSTED and CONFIG.AutoOwnerAdmin and game.CreatorType ~= Enum.CreatorType.User then
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		if ok and type(rank) == "number" then
			if rank == 255 then
				level = LEVEL_OWNER
			elseif rank >= CONFIG.GroupAdminRank then
				level = math.max(level, 1)
			end
		else
			adminFailedAt[player] = os.clock()
			return 0
		end
	end
	if level == 0 and CONFIG.AllowInStudio and RunService:IsStudio() then
		level = 1
	end

	-- игрок мог выйти, пока шла проверка
	if player.Parent ~= Players then
		return level
	end
	adminCache[player] = level
	adminFailedAt[player] = nil
	if level > 0 then
		AntiCheat.SetExempt(player, true)
	end
	return level
end

local function isAdmin(player)
	return getLevel(player) > 0
end

--------------------------------------------------------------------------------
-- Антиспам: token bucket на игрока
--------------------------------------------------------------------------------

local buckets = {} -- [player] = { tokens, last }
local BUCKET_MAX, BUCKET_REFILL = 6, 2 -- запас и токенов в секунду

local function allowRequest(player)
	local now = os.clock()
	local b = buckets[player]
	if not b then
		b = { tokens = BUCKET_MAX, last = now }
		buckets[player] = b
	end
	b.tokens = math.min(BUCKET_MAX, b.tokens + (now - b.last) * BUCKET_REFILL)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

isAdminRF.OnServerInvoke = function(player)
	if not allowRequest(player) then
		return false
	end
	return isAdmin(player) == true
end

--------------------------------------------------------------------------------
-- Утилиты
--------------------------------------------------------------------------------

-- обрезка по символам UTF-8
local function clip(text, maxChars)
	local len = utf8.len(text)
	if len and len > maxChars then
		return text:sub(1, utf8.offset(text, maxChars + 1) - 1)
	end
	return text
end

local function reply(player, text, kind)
	if player.Parent ~= Players then
		return
	end
	text = clip(tostring(text), 1000)
	local chatScript = ServerScriptService:FindFirstChild("SendMessage")
	local privateMessage = chatScript and chatScript:FindFirstChild("PrivateSystemMessage")
	if privateMessage then
		privateMessage:Fire(player, text)
	else
		outRemote:FireClient(player, text, kind or "info")
	end
end

local function getChatControl()
	local chatScript = ServerScriptService:FindFirstChild("SendMessage")
	return chatScript and chatScript:FindFirstChild("AdminChatControl")
end

local function getTagControl()
	local tagScript = ServerScriptService:FindFirstChild("TagService")
	return tagScript and tagScript:FindFirstChild("AdminTagControl")
end

-- BindableFunction:Invoke может упасть или зависнуть на чужой ошибке — оборачиваем
local function invoke(control, ...)
	return pcall(control.Invoke, control, ...)
end

-- Текст, который увидят другие игроки, обязан пройти фильтр Roblox.
-- При сбое фильтра возвращаем fallback (nil = отказ).
local function filterText(sender, text, fallback)
	text = clip(tostring(text), CONFIG.MaxReasonLength)
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(
			text,
			sender.UserId,
			Enum.TextFilterContext.PublicChat
		)
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(filtered) == "string" and filtered ~= "" then
		return filtered
	end
	return fallback
end

local function filterAdminReason(sender, text)
	return filterText(sender, text, CONFIG.DefaultBanReason)
end

-- число из токена: без NaN/inf/hex, в пределах [min, max]
local function parseNumber(token, min, max)
	if type(token) ~= "string" or not token:match("^%-?%d+%.?%d*$") then
		return nil
	end
	local n = tonumber(token)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return math.clamp(n, min, max)
end

local function pardon(player, seconds)
	AntiCheat.MarkTeleport(player, seconds or 4)
end

local function getCharParts(player)
	local char = player.Character
	if not char then
		return nil
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	return char, humanoid, root
end

-- поиск игрока по нику/DisplayName (точное имя > точный дисплейнейм/префикс)
local function findPlayers(nameToken)
	local needle = nameToken:lower()
	local needleLen = string.len(needle)
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower() == needle then
			return { p }
		end
	end
	local matches = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local display = p.DisplayName:lower()
		if display == needle
			or p.Name:lower():sub(1, needleLen) == needle
			or display:sub(1, needleLen) == needle
		then
			table.insert(matches, p)
		end
	end
	return matches
end

-- me / all / others / ники через запятую.
-- harmful = true: цели с уровнем выше, чем у отправителя, пропускаются.
-- Третье значение: true, если ник просто не найден (для офлайн-бана).
local function resolveTargets(sender, token, harmful)
	if type(token) ~= "string" or token == "" then
		return nil, "Укажи игрока: me / all / others / часть ника (можно через запятую)"
	end
	local set, list = {}, {}
	local function add(p)
		if not set[p] then
			set[p] = true
			table.insert(list, p)
		end
	end

	for rawPart in token:gmatch("[^,]+") do
		local part = rawPart:lower()
		if part == "me" or part == "я" then
			add(sender)
		elseif part == "all" or part == "все" then
			for _, p in ipairs(Players:GetPlayers()) do
				add(p)
			end
		elseif part == "others" or part == "другие" then
			for _, p in ipairs(Players:GetPlayers()) do
				if p ~= sender then
					add(p)
				end
			end
		else
			local matches = findPlayers(part)
			if #matches == 0 then
				return nil, ("Игрок «%s» не найден"):format(clip(rawPart, 32)), true
			elseif #matches > 1 then
				local names = {}
				for _, m in ipairs(matches) do
					table.insert(names, m.Name)
				end
				return nil, ("«%s» подходит нескольким: %s — уточни ник"):format(clip(rawPart, 32), table.concat(names, ", "))
			else
				add(matches[1])
			end
		end
	end

	if harmful then
		local senderLevel = getLevel(sender)
		local allowed = {}
		for _, p in ipairs(list) do
			if p == sender or getLevel(p) <= senderLevel then
				table.insert(allowed, p)
			else
				reply(sender, ("Нельзя применять к %s — у него выше права, пропускаю"):format(p.Name), "err")
			end
		end
		list = allowed
	end

	if #list == 0 then
		return nil, "Никого не найдено"
	end
	return list
end

local function namesOf(players)
	local t = {}
	for _, p in ipairs(players) do
		table.insert(t, p.Name)
	end
	return table.concat(t, ", ")
end

-- 30s / 10m / 2h / 7d / 1w / perm; число без буквы = минуты
local function parseDuration(s)
	s = s:lower()
	if s == "perm" or s == "forever" or s == "навсегда" or s == "-1" then
		return -1
	end
	local num, suffix = s:match("^(%d+%.?%d*)([smhdw]?)$")
	if not num then
		return nil
	end
	local mult = ({ s = 1, m = 60, h = 3600, d = 86400, w = 604800 })[suffix ~= "" and suffix or "m"]
	local seconds = tonumber(num) * mult
	if seconds ~= seconds or seconds < 1 or seconds > CONFIG.MaxDurationSeconds then
		return nil
	end
	return math.floor(seconds)
end

--------------------------------------------------------------------------------
-- Fly / Noclip: сервер решает, кому можно, клиент двигает.
-- Пока режим включён — ставим AntiCheatExempt, чтобы античит не резинил.
--------------------------------------------------------------------------------

local clientModes = {} -- [player] = { fly = bool, noclip = bool }

local function setMode(player, mode, enabled, extra)
	if player.Parent ~= Players then
		return
	end
	local m = clientModes[player]
	if not m then
		m = {}
		clientModes[player] = m
	end
	m[mode] = enabled
	if m.fly or m.noclip then
		player:SetAttribute("AC_Exempt", true)
	elseif not adminCache[player] or adminCache[player] <= 0 then
		player:SetAttribute("AC_Exempt", nil)
	end
	actRemote:FireClient(player, mode, enabled, extra)
end

--------------------------------------------------------------------------------
-- Команды
--------------------------------------------------------------------------------

local Commands = {}   -- имя/алиас -> команда
local Ordered = {}    -- для help

local function register(names, usage, desc, fn)
	local cmd = { name = names[1], usage = usage, desc = desc, fn = fn }
	table.insert(Ordered, cmd)
	for _, n in ipairs(names) do
		Commands[n] = cmd
	end
end

register({ "help", "cmds", "команды" }, "", "список команд", function(sender, args)
	local lines = { "===== Админ-команды (вводи в чат с ;) =====" }
	for _, cmd in ipairs(Ordered) do
		table.insert(lines, ("%s %s — %s"):format(cmd.name, cmd.usage, cmd.desc))
	end
	table.insert(lines, "clear — очистить консоль (локально)")
	table.insert(lines, "Время бана: 30s, 10m, 2h, 7d, 1w, perm (число без буквы = минуты)")
	table.insert(lines, "Игроки: me / all / others / часть ника, можно списком через запятую")
	return table.concat(lines, "\n")
end)

register({ "ban", "бан" }, "<игрок> <время|perm> [причина]", "забанить (BanAsync, работает и офлайн по нику)", function(sender, args)
	local targetToken, durToken = args[1], args[2]
	if not targetToken or not durToken then
		return nil, "Использование: ban <игрок> <время|perm> [причина]"
	end
	local duration = parseDuration(durToken)
	if not duration then
		return nil, ("Не понял время «%s». Примеры: 30s, 10m, 2h, 7d, perm (число = минуты)"):format(clip(durToken, 32))
	end
	local reason = table.concat(args, " ", 3)
	if reason == "" then
		reason = CONFIG.DefaultBanReason
	end

	local userIds, shown = {}, {}
	local targets, err, notFound = resolveTargets(sender, targetToken, true)
	if targets then
		for _, p in ipairs(targets) do
			if p == sender then
				reply(sender, "Себя банить нельзя — пропускаю", "err")
			else
				table.insert(userIds, p.UserId)
				table.insert(shown, p.Name)
			end
		end
	elseif notFound and not targetToken:find(",") then
		-- игрока нет на сервере — офлайн-бан по нику
		if not targetToken:match("^[%w_]+$") or #targetToken > 20 then
			return nil, ("Игрок «%s» не найден"):format(clip(targetToken, 32))
		end
		local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, targetToken)
		if not (ok and type(id) == "number") then
			return nil, ("Игрок «%s» не найден ни на сервере, ни в Roblox"):format(targetToken)
		end
		if id == sender.UserId then
			return nil, "Себя банить нельзя"
		end
		if levelOfUserId(id) > getLevel(sender) then
			return nil, "Нельзя банить игрока с более высокими правами"
		end
		table.insert(userIds, id)
		table.insert(shown, targetToken .. " (офлайн)")
	else
		return nil, err
	end

	if #userIds == 0 then
		return nil, "Некого банить"
	end

	-- причина показывается забаненному, поэтому фильтруем до BanAsync
	local filteredReason = filterAdminReason(sender, reason)
	local privateReason = clip(("Забанил %s (%d) через админ-консоль"):format(sender.Name, sender.UserId), 900)

	-- BanAsync принимает до 50 UserId за вызов
	for i = 1, #userIds, 50 do
		local chunk = table.move(userIds, i, math.min(i + 49, #userIds), 1, {})
		local ok, banErr = pcall(function()
			Players:BanAsync({
				UserIds = chunk,
				ApplyToUniverse = CONFIG.BanApplyToUniverse,
				Duration = duration,
				DisplayReason = filteredReason,
				PrivateReason = privateReason,
				ExcludeAltAccounts = CONFIG.BanExcludeAlts,
			})
		end)
		if not ok then
			return nil, "BanAsync не сработал: " .. tostring(banErr) .. " (в Studio баны не работают — только в опубликованной игре)"
		end
	end

	local durText = duration == -1 and "навсегда" or durToken
	local chatControl = getChatControl()
	if chatControl then
		invoke(chatControl, "announceBan", table.concat(shown, ", "), durText, filteredReason)
	end
	return ("Забанил: %s | время: %s | причина: %s"):format(table.concat(shown, ", "), durText, filteredReason)
end)

register({ "unban", "разбан" }, "<ник или UserId>", "снять бан (UnbanAsync)", function(sender, args)
	local token = args[1]
	if not token then
		return nil, "Использование: unban <ник или UserId>"
	end
	local id
	if token:match("^%d+$") and #token <= 15 then
		id = tonumber(token)
	elseif token:match("^[%w_]+$") and #token <= 20 then
		local ok, resolved = pcall(Players.GetUserIdFromNameAsync, Players, token)
		if not ok or type(resolved) ~= "number" then
			return nil, ("Не нашёл игрока «%s»"):format(token)
		end
		id = resolved
	else
		return nil, "Использование: unban <ник или UserId>"
	end
	local ok, err = pcall(function()
		Players:UnbanAsync({
			UserIds = { id },
			ApplyToUniverse = CONFIG.BanApplyToUniverse,
		})
	end)
	if not ok then
		return nil, "UnbanAsync не сработал: " .. tostring(err)
	end
	return ("Разбанил %s (id %d)"):format(token, id)
end)

register({ "mute", "мут" }, "<игрок> <время> [причина]", "запретить писать в чат (30m, 3h, 6d)", function(sender, args)
	local targets, err = resolveTargets(sender, args[1], true)
	if not targets then
		return nil, err
	end
	local duration = args[2] and parseDuration(args[2])
	if not duration or duration <= 0 then
		return nil, "Использование: mute <игрок> <30s|10m|3h|6d|1w> [причина]"
	end
	local reason = table.concat(args, " ", 3)
	if reason == "" then
		reason = "Решение администратора"
	end
	reason = filterAdminReason(sender, reason)
	local control = getChatControl()
	if not control then
		return nil, "Система чата ещё не готова"
	end
	local muted = {}
	local persistenceFailed = false
	for _, target in ipairs(targets) do
		local called, ok, saved = invoke(control, "mute", target, duration, reason, args[2])
		if called and ok then
			table.insert(muted, target.Name)
			if not saved then
				persistenceFailed = true
			end
		end
	end
	if #muted == 0 then
		return nil, "Не удалось выдать мут"
	end
	local result = ("Выдал мут: %s | время: %s | причина: %s"):format(
		table.concat(muted, ", "),
		args[2],
		reason
	)
	if persistenceFailed then
		result ..= " | предупреждение: DataStore недоступен, мут действует в текущем сервере"
	end
	return result
end)

register({ "unmute", "размут" }, "<игрок>", "снять чат-мут", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local control = getChatControl()
	if not control then
		return nil, "Система чата ещё не готова"
	end
	for _, target in ipairs(targets) do
		invoke(control, "unmute", target)
	end
	return "Снял мут: " .. namesOf(targets)
end)

register({ "tag", "тег" }, "<игрок> <стиль 1-10> <текст>", "выдать тег (1-5 обычные, 6-10 градиентные)", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local style = math.floor(parseNumber(args[2], 0, 100) or 0)
	if style < 1 or style > 10 then
		return nil, "Использование: tag <игрок> <стиль 1-10> <текст тега>"
	end
	local text = table.concat(args, " ", 3)
	if text == "" then
		return nil, "Укажи текст тега"
	end
	text = clip(text, CONFIG.MaxTagLength)
	local control = getTagControl()
	if not control then
		return nil, "Система тегов ещё не готова"
	end
	text = filterText(sender, text)
	if not text then
		return nil, "Не удалось проверить текст тега фильтром, попробуй позже"
	end
	local tagged = {}
	for _, target in ipairs(targets) do
		local called, ok, info = invoke(control, "set", sender, target, text, style)
		if called and ok then
			table.insert(tagged, target.Name)
		else
			return nil, tostring(info or ok)
		end
	end
	return ("Выдал тег [%s], стиль %d: %s"):format(text, style, table.concat(tagged, ", "))
end)

register({ "untag", "снятьтег" }, "<игрок>", "снять тег", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local control = getTagControl()
	if not control then
		return nil, "Система тегов ещё не готова"
	end
	for _, target in ipairs(targets) do
		invoke(control, "remove", sender, target)
	end
	return "Снял тег: " .. namesOf(targets)
end)

register({ "kick", "кик" }, "<игрок> [причина]", "кикнуть с сервера", function(sender, args)
	local targets, err = resolveTargets(sender, args[1], true)
	if not targets then
		return nil, err
	end
	local reason = table.concat(args, " ", 2)
	if reason == "" then
		reason = CONFIG.DefaultKickReason
	else
		reason = filterText(sender, reason, CONFIG.DefaultKickReason)
	end
	local kicked = {}
	for _, p in ipairs(targets) do
		if p == sender then
			reply(sender, "Себя кикать нельзя — пропускаю", "err")
		else
			table.insert(kicked, p.Name)
			pcall(p.Kick, p, reason)
		end
	end
	if #kicked == 0 then
		return nil, "Некого кикать"
	end
	return ("Кикнул: %s (%s)"):format(table.concat(kicked, ", "), reason)
end)

register({ "kill", "убить" }, "<игрок>", "убить", function(sender, args)
	local targets, err = resolveTargets(sender, args[1], true)
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		local _, humanoid = getCharParts(p)
		if humanoid then
			humanoid.Health = 0
		end
	end
	return "Убил: " .. namesOf(targets)
end)

register({ "heal", "хил" }, "<игрок>", "полное здоровье", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		local _, humanoid = getCharParts(p)
		if humanoid then
			humanoid.Health = humanoid.MaxHealth
		end
	end
	return "Вылечил: " .. namesOf(targets)
end)

register({ "god", "год" }, "<игрок>", "бессмертие", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		local _, humanoid = getCharParts(p)
		if humanoid then
			humanoid.MaxHealth = math.huge
			humanoid.Health = math.huge
		end
	end
	return "Год-мод: " .. namesOf(targets)
end)

register({ "ungod", "унгод" }, "<игрок>", "убрать бессмертие", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		local _, humanoid = getCharParts(p)
		if humanoid then
			humanoid.MaxHealth = 100
			humanoid.Health = 100
		end
	end
	return "Убрал год-мод: " .. namesOf(targets)
end)

register({ "speed", "ws", "спид" }, "<игрок> <число>", "WalkSpeed (обычный = 16)", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local value = parseNumber(args[2], 0, 500)
	if not value then
		return nil, "Использование: speed <игрок> <число 0-500>"
	end
	for _, p in ipairs(targets) do
		local _, humanoid = getCharParts(p)
		if humanoid then
			humanoid.WalkSpeed = value
		end
	end
	return ("Скорость %g: %s"):format(value, namesOf(targets))
end)

register({ "jump", "jp" }, "<игрок> <число>", "JumpPower (обычный = 50)", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local value = parseNumber(args[2], 0, 500)
	if not value then
		return nil, "Использование: jump <игрок> <число 0-500>"
	end
	for _, p in ipairs(targets) do
		local _, humanoid = getCharParts(p)
		if humanoid then
			humanoid.UseJumpPower = true
			humanoid.JumpPower = value
		end
	end
	return ("Прыжок %g: %s"):format(value, namesOf(targets))
end)

local function teleportTo(player, cframe)
	local _, _, root = getCharParts(player)
	if not root then
		return false
	end
	pardon(player, 4)
	root.CFrame = cframe
	root.AssemblyLinearVelocity = Vector3.zero
	return true
end

register({ "tp", "тп" }, "<кого> <к кому>", "телепорт игрока к игроку", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local dest, err2 = resolveTargets(sender, args[2])
	if not dest then
		return nil, err2 or "Укажи, к кому телепортировать"
	end
	if #dest ~= 1 then
		return nil, "Второй аргумент должен быть ОДНИМ игроком"
	end
	local _, _, destRoot = getCharParts(dest[1])
	if not destRoot then
		return nil, "У цели нет персонажа"
	end
	local count = 0
	for i, p in ipairs(targets) do
		local offset = destRoot.CFrame.LookVector * 3 + destRoot.CFrame.RightVector * ((i - 1) * 2)
		if teleportTo(p, destRoot.CFrame + offset) then
			count += 1
		end
	end
	return ("Телепортировал %d к %s"):format(count, dest[1].Name)
end)

register({ "goto", "to", "гото" }, "<игрок>", "телепорт себя к игроку", function(sender, args)
	local dest, err = resolveTargets(sender, args[1])
	if not dest then
		return nil, err
	end
	if #dest ~= 1 then
		return nil, "Укажи одного игрока"
	end
	local _, _, destRoot = getCharParts(dest[1])
	if not destRoot then
		return nil, "У цели нет персонажа"
	end
	if not teleportTo(sender, destRoot.CFrame + destRoot.CFrame.LookVector * 3) then
		return nil, "У тебя нет персонажа"
	end
	return "Ты у " .. dest[1].Name
end)

register({ "bring", "бринг" }, "<игрок>", "телепорт игрока к себе", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local _, _, myRoot = getCharParts(sender)
	if not myRoot then
		return nil, "У тебя нет персонажа"
	end
	local count = 0
	for i, p in ipairs(targets) do
		if p ~= sender then
			local offset = myRoot.CFrame.LookVector * 3 + myRoot.CFrame.RightVector * ((i - 1) * 2)
			if teleportTo(p, myRoot.CFrame + offset) then
				count += 1
			end
		end
	end
	return ("Притащил: %d"):format(count)
end)

register({ "respawn", "re", "рес" }, "<игрок>", "переспавнить", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		pcall(p.LoadCharacter, p)
	end
	return "Респавн: " .. namesOf(targets)
end)

register({ "freeze", "фриз" }, "<игрок>", "заморозить (заякорить)", function(sender, args)
	local targets, err = resolveTargets(sender, args[1], true)
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		local _, _, root = getCharParts(p)
		if root then
			root.Anchored = true
		end
	end
	return "Заморозил: " .. namesOf(targets)
end)

register({ "thaw", "unfreeze", "анфриз" }, "<игрок>", "разморозить", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		local _, _, root = getCharParts(p)
		if root then
			root.Anchored = false
		end
	end
	return "Разморозил: " .. namesOf(targets)
end)

local function setAdminEffect(targets, className, enabled)
	for _, player in ipairs(targets) do
		local _, humanoid, root = getCharParts(player)
		if className == "Sit" then
			if humanoid then
				humanoid.Sit = enabled
				if not enabled then humanoid.Jump = true end
			end
		elseif root then
			local effectName = "Admin" .. className
			local existing = root:FindFirstChild(effectName)
			if enabled and not existing then
				local effect = Instance.new(className)
				effect.Name = effectName
				if effect:IsA("Fire") then
					effect.Color = Color3.fromRGB(80, 170, 255)
					effect.SecondaryColor = Color3.fromRGB(170, 80, 255)
					effect.Heat = 5
					effect.Size = 5
				elseif effect:IsA("Sparkles") then
					effect.SparkleColor = Color3.fromRGB(90, 200, 255)
				end
				effect.Parent = root
			elseif not enabled and existing then
				existing:Destroy()
			end
		end
	end
end

register({ "sit", "сесть" }, "<игрок>", "посадить игрока", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then return nil, err end
	setAdminEffect(targets, "Sit", true)
	return "Посадил: " .. namesOf(targets)
end)

register({ "unsit", "встать" }, "<игрок>", "поднять игрока", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then return nil, err end
	setAdminEffect(targets, "Sit", false)
	return "Поднял: " .. namesOf(targets)
end)

register({ "sparkles", "искры" }, "<игрок>", "добавить голубые искры", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then return nil, err end
	setAdminEffect(targets, "Sparkles", true)
	return "Добавил искры: " .. namesOf(targets)
end)

register({ "unsparkles", "убратьискры" }, "<игрок>", "убрать искры", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then return nil, err end
	setAdminEffect(targets, "Sparkles", false)
	return "Убрал искры: " .. namesOf(targets)
end)

register({ "fire", "огонь" }, "<игрок>", "добавить декоративный огонь", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then return nil, err end
	setAdminEffect(targets, "Fire", true)
	return "Добавил огонь: " .. namesOf(targets)
end)

register({ "unfire", "убратьогонь" }, "<игрок>", "убрать огонь", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then return nil, err end
	setAdminEffect(targets, "Fire", false)
	return "Убрал огонь: " .. namesOf(targets)
end)

local function setDeveloperRainbow(targets, enabled)
	for _, target in ipairs(targets) do
		local _, _, root = getCharParts(target)
		if root then
			local old = root:FindFirstChild("DeveloperRainbow")
			if enabled and not old then
				local highlight = Instance.new("Highlight")
				highlight.Name = "DeveloperRainbow"
				highlight.Adornee = target.Character
				highlight.FillTransparency = 0.48
				highlight.OutlineTransparency = 0.05
				highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				highlight.Parent = root
				task.spawn(function()
					while highlight.Parent do
						local color = Color3.fromHSV((os.clock() * 0.18) % 1, 0.85, 1)
						highlight.FillColor = color
						highlight.OutlineColor = color:Lerp(Color3.new(1, 1, 1), 0.35)
						task.wait(0.08)
					end
				end)
			elseif not enabled and old then
				old:Destroy()
			end
		end
	end
end

register({ "rainbow", "радуга" }, "<игрок>", "радужное свечение (разработчик)", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then return nil, err end
	setDeveloperRainbow(targets, true)
	return "Радуга вкл: " .. namesOf(targets)
end)

register({ "unrainbow", "убратьрадугу" }, "<игрок>", "убрать радужное свечение", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then return nil, err end
	setDeveloperRainbow(targets, false)
	return "Радуга выкл: " .. namesOf(targets)
end)

register({ "spin", "крутить" }, "<игрок>", "крутить персонажа (разработчик)", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then return nil, err end
	for _, target in ipairs(targets) do
		local _, _, root = getCharParts(target)
		if root and not root:FindFirstChild("DeveloperSpin") then
			local spin = Instance.new("BodyAngularVelocity")
			spin.Name = "DeveloperSpin"
			spin.AngularVelocity = Vector3.new(0, 12, 0)
			spin.MaxTorque = Vector3.new(0, math.huge, 0)
			spin.P = 3000
			spin.Parent = root
		end
	end
	return "Вращение вкл: " .. namesOf(targets)
end)

register({ "unspin", "не крутить" }, "<игрок>", "остановить вращение", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then return nil, err end
	for _, target in ipairs(targets) do
		local _, _, root = getCharParts(target)
		local spin = root and root:FindFirstChild("DeveloperSpin")
		if spin then spin:Destroy() end
	end
	return "Вращение выкл: " .. namesOf(targets)
end)

register({ "fly", "флай" }, "[игрок] [скорость]", "полёт (по умолчанию себе)", function(sender, args)
	local targetToken, speed = args[1], parseNumber(args[2], 1, 500)
	if targetToken and parseNumber(targetToken, 1, 500) then
		speed = parseNumber(targetToken, 1, 500)
		targetToken = "me"
	end
	local targets, err = resolveTargets(sender, targetToken or "me")
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		setMode(p, "fly", true, speed or CONFIG.DefaultFlySpeed)
	end
	return "Полёт вкл: " .. namesOf(targets)
end)

register({ "unfly", "анфлай" }, "[игрок]", "выключить полёт", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		setMode(p, "fly", false)
	end
	return "Полёт выкл: " .. namesOf(targets)
end)

register({ "noclip", "ноуклип" }, "[игрок]", "проход сквозь стены", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		setMode(p, "noclip", true)
	end
	return "Ноуклип вкл: " .. namesOf(targets)
end)

register({ "clip", "клип" }, "[игрок]", "выключить ноуклип", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then
		return nil, err
	end
	for _, p in ipairs(targets) do
		setMode(p, "noclip", false)
	end
	return "Ноуклип выкл: " .. namesOf(targets)
end)

local function getCoinApi()
	local shopServer = ServerScriptService:FindFirstChild("ShopServer")
	return shopServer and shopServer:FindFirstChild("AdminCoins")
end

local function changeCoins(sender, args, action, verb)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then
		return nil, err
	end
	local amount = parseNumber(args[2], 0, CONFIG.MaxCoins)
	if not amount or args[2]:sub(1, 1) == "-" then
		return nil, ("Использование: %s <игрок> <количество>"):format(verb)
	end
	amount = math.floor(amount)
	local api = getCoinApi()
	if not api then
		return nil, "Система монет ещё не готова"
	end
	for _, target in ipairs(targets) do
		local ok, success, message = pcall(api.Invoke, api, action, target, amount)
		if not ok or not success then
			return nil, type(message) == "string" and message or "Не удалось изменить монеты"
		end
	end
	return ("%s %d монет: %s"):format(verb, amount, namesOf(targets))
end

register({ "givecoins", "addcoins", "датьмонеты" }, "<игрок> <количество>", "выдать монеты", function(sender, args)
	return changeCoins(sender, args, "add", "Выдано")
end)

register({ "takecoins", "removecoins", "забратьмонеты" }, "<игрок> <количество>", "забрать монеты", function(sender, args)
	return changeCoins(sender, args, "take", "Забрано")
end)

register({ "setcoins", "монеты" }, "<игрок> <количество>", "установить баланс монет", function(sender, args)
	return changeCoins(sender, args, "set", "Установлено")
end)

register({ "balance", "coins" }, "[игрок]", "показать баланс монет", function(sender, args)
	local targets, err = resolveTargets(sender, args[1] or "me")
	if not targets then
		return nil, err
	end
	local api = getCoinApi()
	if not api then
		return nil, "Система монет ещё не готова"
	end
	local result = {}
	for _, target in ipairs(targets) do
		local ok, success, value = pcall(api.Invoke, api, "get", target)
		if ok and success and type(value) == "number" then
			table.insert(result, ("%s: %d"):format(target.Name, value))
		end
	end
	return table.concat(result, " | ")
end)

register({ "health", "hp" }, "<игрок> <число>", "установить здоровье", function(sender, args)
	local targets, err = resolveTargets(sender, args[1])
	if not targets then return nil, err end
	local value = parseNumber(args[2], 0, 1000000)
	if not value then return nil, "Использование: health <игрок> <число>" end
	for _, target in ipairs(targets) do
		local _, humanoid = getCharParts(target)
		if humanoid then
			humanoid.MaxHealth = math.max(humanoid.MaxHealth, value)
			humanoid.Health = value
		end
	end
	return ("Здоровье %g: %s"):format(value, namesOf(targets))
end)

register({ "announce", "m", "объявление" }, "<текст>", "объявление всем игрокам", function(sender, args)
	local text = table.concat(args, " ")
	if text == "" then
		return nil, "Использование: announce <текст>"
	end
	local filtered = filterText(sender, text)
	if not filtered then
		return nil, "Не удалось проверить текст фильтром, попробуй позже"
	end
	annRemote:FireAllClients(filtered, CONFIG.AnnounceTime)
	return "Объявление отправлено"
end)

register({ "require", "rq" }, "<assetId>", "загрузить модуль на сервере (ТОЛЬКО доверенные!)", function(sender, args)
	if not CONFIG.AllowRequireCommand then
		return nil, "Команда require отключена (CONFIG.AllowRequireCommand = false)"
	end
	if getLevel(sender) < LEVEL_TRUSTED then
		return nil, "require доступен только владельцу и админам из CONFIG.Admins"
	end
	local token = args[1]
	local id = token and token:match("^%d+$") and #token <= 15 and tonumber(token)
	if not id or id <= 0 then
		return nil, "Использование: require <assetId модуля>"
	end
	warn(("[AdminConsole] %s (%d) выполняет require(%d)"):format(sender.Name, sender.UserId, id))
	local ok, result = pcall(require, id)
	if not ok then
		return nil, "require не удался: " .. tostring(result)
	end
	if type(result) == "function" then
		local ok2, err2 = pcall(result)
		if not ok2 then
			return nil, "Модуль загружен, но при вызове упал: " .. tostring(err2)
		end
		return ("Модуль %d загружен и вызван"):format(id)
	end
	return ("Модуль %d загружен (вернул %s)"):format(id, typeof(result))
end)

register({ "shutdown", "шатдаун" }, "[причина]", "кикнуть всех (перезапуск сервера)", function(sender, args)
	local reason = table.concat(args, " ")
	if reason == "" then
		reason = "Сервер перезапускается"
	else
		reason = filterText(sender, reason, "Сервер перезапускается")
	end
	for _, p in ipairs(Players:GetPlayers()) do
		pcall(p.Kick, p, reason)
	end
	return "Сервер очищен"
end)

--------------------------------------------------------------------------------
-- Приём команд
--------------------------------------------------------------------------------

local busy = {} -- [player] = true, пока выполняется команда (защита от наложения yield-команд)

cmdRemote.OnServerEvent:Connect(function(player, text)
	if type(text) ~= "string" or not allowRequest(player) then
		return
	end
	if not isAdmin(player) then
		warn(("[AdminConsole] НЕ-админ %s (%d) пытался выполнить команду"):format(player.Name, player.UserId))
		return
	end
	if busy[player] or #text > CONFIG.MaxInputLength * 4 or not utf8.len(text) then
		return
	end
	text = clip(text, CONFIG.MaxInputLength)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return
	end

	print(("[AdminConsole] %s: %s"):format(player.Name, text)) -- аудит-лог в консоль сервера

	local args = {}
	for word in text:gmatch("%S+") do
		table.insert(args, word)
	end
	local cmdName = table.remove(args, 1):lower()

	local cmd = Commands[cmdName]
	if not cmd then
		reply(player, ("Неизвестная команда «%s». Введи help"):format(clip(cmdName, 32)), "err")
		return
	end

	busy[player] = true
	local ok, r1, r2 = pcall(cmd.fn, player, args)
	busy[player] = nil
	if not ok then
		warn("[AdminConsole] ошибка команды " .. cmd.name .. ": " .. tostring(r1))
		reply(player, "Внутренняя ошибка команды " .. cmd.name, "err")
	elseif r1 == nil and r2 then
		reply(player, r2, "err")
	elseif type(r1) == "string" then
		reply(player, r1, "ok")
	end
end)

Players.PlayerRemoving:Connect(function(player)
	adminCache[player] = nil
	adminFailedAt[player] = nil
	clientModes[player] = nil
	buckets[player] = nil
	busy[player] = nil
end)

Players.PlayerAdded:Connect(function(player)
	task.defer(getLevel, player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.defer(getLevel, player)
end
