--=====================================================================
--  CharacterCollisionService — игроки не сталкиваются друг с другом.
--  Группу выдаёт общий модуль Shared.CollisionGroups. Раньше этот скрипт
--  на каждый DescendantAdded безусловно перезаписывал CollisionGroup,
--  из-за чего части тела и коллайдеры рагдолла мгновенно теряли свою
--  группу и правила "рагдолл против рагдолла" не работали.
--=====================================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CollisionGroups = require(Shared:WaitForChild("CollisionGroups"))

-- Метка владельца: пока она стоит, чужая подсистема группу не сменит.
local OWNER = "Character"

CollisionGroups.setup()

local connections = {}

local function applyPart(instance)
	if instance:IsA("BasePart") then
		-- apply() сам откажется, если частью сейчас владеет рагдолл.
		CollisionGroups.apply(instance, CollisionGroups.Character, OWNER)
	end
end

local function setupCharacter(player, character)
	local previous = connections[player]
	if previous then
		previous:Disconnect()
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		applyPart(descendant)
	end
	connections[player] = character.DescendantAdded:Connect(applyPart)
end

local function setupPlayer(player)
	player.CharacterAdded:Connect(function(character)
		setupCharacter(player, character)
	end)
	if player.Character then
		setupCharacter(player, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	setupPlayer(player)
end
Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(function(player)
	local connection = connections[player]
	if connection then
		connection:Disconnect()
		connections[player] = nil
	end
end)
