local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

local Modules           = ReplicatedStorage:WaitForChild("Modules")
local Config            = require(Modules:WaitForChild("Config"))
local EnemyConfig       = require(Modules:WaitForChild("EnemyConfig"))
local PathUtils         = require(Modules:WaitForChild("PathUtils"))
local ServerEnemyState  = require(game:GetService("ServerStorage"):WaitForChild("Modules"):WaitForChild("ServerEnemyState"))

local eventsFolder = ReplicatedStorage:WaitForChild("Events")
local WaveStarted  = eventsFolder:WaitForChild("WaveStarted")
local PlayerReady  = eventsFolder:WaitForChild("PlayerReady")
local AllReady     = eventsFolder:WaitForChild("AllReady")

local markersFolder: Folder = Instance.new("Folder")
markersFolder.Name   = "EnemyMarkers"
markersFolder.Parent = workspace

local pathData = PathUtils.load(workspace:WaitForChild("Path") :: Folder)
ServerEnemyState.setPathData(pathData)

local waveAliveCount: { [number]: number }  = {}
local waveHasBoss:    { [number]: boolean } = {}
local waveBossDone:   { [number]: boolean } = {}
local waveCompleted:  { [number]: boolean } = {}
local currentWave: number = 0

local playersReady: { [Player]: boolean } = {}
local wave1Started: boolean               = false

local startWave: (waveNum: number) -> ()

local function getEnemyId(waveNum: number, index: number): number
	return waveNum * 10000 + index
end

local function getBossId(waveNum: number): number
	return waveNum * 10000 + 9999
end

local function getBossSpawnOffset(waveConfig: { any }): number?
	local boss = (waveConfig :: any).boss
	if not boss then return nil end
	if boss.trigger == "delay" then return boss.delay end
	local maxEndTime: number = 0
	local offset: number     = 0
	for _, batch in waveConfig do
		if not batch.count then continue end
		for i = 1, batch.count do
			local endT = offset + (i - 1) * batch.interval
				+ pathData.totalLength / EnemyConfig.ENEMY_TYPES[batch.type].speed
			if endT > maxEndTime then maxEndTime = endT end
		end
		offset += batch.count * batch.interval
	end
	return maxEndTime + 1
end

local function createMarker(id: number): Part
	local marker = Instance.new("Part")
	marker.Name       = "Marker_" .. id
	marker.Shape      = Enum.PartType.Ball
	marker.Size       = Vector3.new(0.8, 0.8, 0.8)
	marker.Color      = Color3.fromRGB(255, 80, 0)
	marker.Material   = Enum.Material.Neon
	marker.CastShadow = false
	marker.CanCollide = false
	marker.Anchored   = true
	marker.Transparency = if Config.SHOW_ENEMY_MARKERS then 0 else 1
	marker.Parent     = markersFolder
	return marker
end

local function checkWaveComplete(waveNum: number): ()
	if waveCompleted[waveNum] then return end
	local regularDone = (waveAliveCount[waveNum] or 0) <= 0
	local bossDone    = not waveHasBoss[waveNum] or waveBossDone[waveNum]
	if not (regularDone and bossDone) then return end
	waveCompleted[waveNum] = true
	task.delay(EnemyConfig.BETWEEN_WAVES_MIN_DELAY, function()
		startWave(waveNum + 1)
	end)
end

local MIN_RECHECK: number = 0.5

local scheduleFinishCheck: (id: number) -> ()
scheduleFinishCheck = function(id: number): ()
	local d = ServerEnemyState.get(id)
	if not d then return end
	local now = workspace:GetServerTimeNow()
	local dist = ServerEnemyState.distance(id, now)
	local remaining = pathData.totalLength - dist
	if remaining <= 0 then
		ServerEnemyState.remove(id)
		return
	end
	local effSpeed = d.wasSlowed and d.speed * d.curFactor or d.speed
	local eta: number
	if effSpeed <= 0.01 then
		eta = MIN_RECHECK
	else
		eta = math.max(MIN_RECHECK, remaining / effSpeed)
	end
	task.delay(eta + 0.05, function()
		local cur = ServerEnemyState.get(id)
		if not cur then return end
		local now2 = workspace:GetServerTimeNow()
		if ServerEnemyState.progress(id, now2) >= 1 then
			ServerEnemyState.remove(id)
		else
			scheduleFinishCheck(id)
		end
	end)
end

local function spawnEnemy(id: number, kind: string, spawnTime: number, waveNum: number, isBoss: boolean): ()
	local marker = createMarker(id)
	local data   = ServerEnemyState.register(id, kind, spawnTime, waveNum, isBoss, marker)
	if not data then
		marker:Destroy()
		return
	end
	scheduleFinishCheck(id)
end

startWave = function(waveNum: number): ()
	local waveConfig = EnemyConfig.WAVES[waveNum]
	if not waveConfig then
		print("[WaveManager] All waves completed.")
		return
	end

	currentWave            = waveNum
	waveCompleted[waveNum] = false
	waveBossDone[waveNum]  = false

	local waveStartTime: number = workspace:GetServerTimeNow()
	local totalRegular: number  = 0
	local spawnOffset: number   = 0
	local enemyIndex: number    = 0

	for _, batch in waveConfig do
		if not batch.count then continue end
		for i = 1, batch.count do
			enemyIndex   += 1
			totalRegular += 1
			local offset = spawnOffset + (i - 1) * batch.interval
			local id     = getEnemyId(waveNum, enemyIndex)
			task.delay(offset, function()
				spawnEnemy(id, batch.type, waveStartTime + offset, waveNum, false)
			end)
		end
		spawnOffset += batch.count * batch.interval
	end

	waveAliveCount[waveNum] = totalRegular

	local boss = (waveConfig :: any).boss
	if boss then
		waveHasBoss[waveNum] = true
		local bossOffset = getBossSpawnOffset(waveConfig) :: number
		local bossId     = getBossId(waveNum)
		task.delay(bossOffset, function()
			spawnEnemy(bossId, boss.type, waveStartTime + bossOffset, waveNum, true)
		end)
	else
		waveHasBoss[waveNum] = false
	end

	WaveStarted:FireAllClients(waveNum, waveStartTime)
end

if Config.SHOW_ENEMY_MARKERS then
	task.spawn(function()
		while true do
			local now = workspace:GetServerTimeNow()
			for id, d in ServerEnemyState.all() do
				if not d.marker or not d.marker.Parent then continue end
				local pos = ServerEnemyState.position(id, now)
				if pos then
					d.marker.Position = pos + Vector3.new(0, 3, 0)
				end
			end
			task.wait(0.1)
		end
	end)
end

ServerEnemyState.onRemoved:Connect(function(id: number)
	local waveNum  = math.floor(id / 10000)
	local isBossId = (id % 10000) == 9999
	if isBossId then
		waveBossDone[waveNum] = true
	else
		waveAliveCount[waveNum] = math.max(0, (waveAliveCount[waveNum] or 1) - 1)
	end
	checkWaveComplete(waveNum)
end)

local function tryStartWave1(): ()
	if wave1Started then return end
	for _, player in Players:GetPlayers() do
		if not playersReady[player] then return end
	end
	wave1Started = true
	AllReady:FireAllClients()
	task.delay(EnemyConfig.WAVE_START_DELAY, function()
		startWave(1)
	end)
end

Players.PlayerRemoving:Connect(function(player: Player)
	playersReady[player] = nil
	tryStartWave1()
end)

PlayerReady.OnServerEvent:Connect(function(player: Player)
	playersReady[player] = true
	tryStartWave1()
end)
