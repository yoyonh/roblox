--=====================================================================
--  RagdollSystem — точка входа. Вся логика живёт в
--  ServerScriptService.Systems.RagdollService, чтобы другие системы
--  подключались через require(), а не через _G и BindableFunction.
--=====================================================================
local RagdollService = require(script.Parent.Systems.RagdollService)

RagdollService.start()
