local ok = shell.run("/colossal/main.lua")
if not ok then printError("Colossal Storage stopped with an error") end
