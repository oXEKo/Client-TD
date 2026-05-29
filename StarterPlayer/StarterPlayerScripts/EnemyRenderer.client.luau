--[[
	Script by oXEKo | o0xek0o (roblox)
	328 lines of code
	Client script: spawning, rendering, animation and enemy movement
]]

-- Services
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

-- Modules
local Modules       = ReplicatedStorage:WaitForChild("Modules")
local Config        = require(Modules:WaitForChild("EnemyConfig"))
local PathUtils     = require(Modules:WaitForChild("PathUtils"))
local ClientConfig  = require(Modules:WaitForChild("Config"))
local ModelUtils    = require(Modules:WaitForChild("ModelUtils"))
local EnemyRegistry = require(Modules:WaitForChild("EnemyRegistry"))

-- Events
local Events      = ReplicatedStorage:WaitForChild("Events")
local WaveStarted = Events:WaitForChild("WaveStarted")
local AllReady    = Events:WaitForChild("AllReady")

-- Path and path data
local EnemiesSrc  = ReplicatedStorage:WaitForChild("Enemies")
local EnemyFolder = workspace:WaitForChild("Enemies")
local pathFolder  = workspace:WaitForChild("Path") :: Folder
pathFolder:WaitForChild("1")
local pathData    = PathUtils.load(pathFolder)

-- LocalPlayer and PlayerGui
local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- GUI references
local screenGui = playerGui:WaitForChild("ScreenGui")
local upperGui  = screenGui:WaitForChild("Upper Gui")
local waveLabel  = upperGui:WaitForChild("Wave number")
local countLabel = upperGui:WaitForChild("Enemy Count")
local timerLabel = upperGui:WaitForChild("Timer")

-- Constants
local TOTAL_WAVES: number          = #Config.WAVES
local HP_BAR_TWEEN: TweenInfo      = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WALK_ANIM_ID: string         = "rbxassetid://913402848"
local MAX_SPAWNS_PER_FRAME: number = 5
local FPS_LOW: number              = ClientConfig.FPS_LOW
local FPS_HIGH: number             = ClientConfig.FPS_HIGH

-- Runtime state
local avgFps: number      = ClientConfig.AVG_FPS_INIT
local shadowsOn: boolean  = ClientConfig.SHADOWS_ON
local waveActive: boolean = false
local spawnQueue: { { id: number, enemyType: string, spawnTime: number } } = {}
local spawnQueueHead: number = 1
local startCountdown: (seconds: number, prefix: string) -> ()

-- Get Enemy ID based on wave number and index
local function getEnemyId(waveNum: number, index: number): number
	return waveNum * 10000 + index
end

-- 9999 is reserved for the boss slot
local function getBossId(waveNum: number): number
	return waveNum * 10000 + 9999
end

-- how many seconds after wave start the boss spawns (must be after the last enemy finishes the path)
local function getBossSpawnOffset(waveConfig: { any }): number?
	local boss = waveConfig.boss
	if not boss then return nil end
	-- if trigger is "delay", just use a fixed offset
	if boss.trigger == "delay" then return boss.delay end

	local maxEndTime: number = 0
	local offset: number     = 0

	for _, batch in waveConfig do
		-- waveConfig has a "boss" key and others; batches are identified by having a count field
		if type(batch) ~= "table" or not batch.count then continue end

		for i = 1, batch.count do
			-- spawn offset + time for enemy to walk the full path = arrival time for this enemy
			local endT = offset + (i - 1) * batch.interval
				+ pathData.totalLength / Config.ENEMY_TYPES[batch.type].speed

			if endT > maxEndTime then maxEndTime = endT end
		end
		-- track where the next batch starts
		offset += batch.count * batch.interval
	end

	-- +1 so the last enemy fully exits the path
	return maxEndTime + 1
end

-- adds an enemy with parameters to spawnQueue for later spawning
local function queueEnemy(id: number, enemyType: string, spawnTime: number): ()
	spawnQueue[#spawnQueue + 1] = { id = id, enemyType = enemyType, spawnTime = spawnTime }
end

-- updates the enemy count label in the GUI
local function updateCountLabel(): ()
	countLabel.Text = `Enemies: {EnemyRegistry.count()}`
end

-- Enables or disables shadows on all enemy model parts based on the enabled parameter (depends on FPS)
local function setEnemyShadows(enemy: any, enabled: boolean): ()
	for _, part in enemy.model:GetDescendants() do
		-- skip non-BasePart objects to avoid errors when setting CastShadow
		if not part:IsA("BasePart") then continue end
		(part :: BasePart).CastShadow = enabled
	end
end

-- full reset before a new wave -- also removes any remaining enemies from the previous wave (just in case)
local function cleanupAllEnemies(): ()
	for _, enemy in EnemyRegistry.all() do
		if enemy.isAlive then
			if enemy.walkTrack then enemy.walkTrack:Stop() end
			enemy.model:Destroy()
		end
	end
	EnemyRegistry.clear()
	spawnQueue      = {}
	spawnQueueHead  = 1
	countLabel.Text = "Enemies: 0"
end

-- Async countdown timer so it doesn't block the rest of the code
startCountdown = function(seconds: number, prefix: string): ()
	task.spawn(function()
		for i = seconds, 1, -1 do
			-- if the wave started during countdown, exit early
			if waveActive then
				timerLabel.Text = ""
				return
			end
			timerLabel.Text = `{prefix}{i}`
			task.wait(1)
		end
		timerLabel.Text = ""
	end)
end

-- fires when the last enemy dies AND the queue is empty -- wave complete
EnemyRegistry.onCleared:Connect(function()
	if waveActive and spawnQueueHead > #spawnQueue then
		waveActive = false
		startCountdown(Config.BETWEEN_WAVES_MIN_DELAY, "Next wave in: ")
	end
end)

-- Enemy class with metatables: all instances share methods via __index
local Enemy = {}
Enemy.__index = Enemy

-- creates and returns an Enemy instance (clones the model, sets up animation + HP bar, syncs position on the path via server time)
function Enemy.new(id: number, enemyType: string, spawnTime: number): any
	local self  = setmetatable({}, Enemy)
	local stats = Config.ENEMY_TYPES[enemyType]

	self.id        = id
	self.type      = enemyType
	self.speed     = stats.speed
	self.maxHp     = stats.maxHp
	self.hp        = stats.maxHp
	self.spawnTime = spawnTime
	self.isAlive   = true
	self.slowDebt  = 0
	self.wasSlowed = false
	self.slowStart = 0
	self.curFactor = 1
	self.bleeding  = false
	self.bleedBox  = nil
	self.iceBlock  = nil

	-- Clone the model template
	local template   = EnemiesSrc:FindFirstChild(enemyType) :: Instance
	local model, hrp = ModelUtils.cloneAndPrepare(template, {
		castShadow = shadowsOn,
		canCollide = false,
	})
	model.Name   = `Enemy_{id}`
	model.Parent = EnemyFolder
	self.model   = model
	self.hrp     = hrp

	-- Walk animation
	local animController  = Instance.new("AnimationController")
	animController.Parent = model
	local animator        = Instance.new("Animator")
	animator.Parent       = animController
	self.walkTrack        = ModelUtils.makeAnimTrack(animator, WALK_ANIM_ID)
	self.walkTrack:Play()

	-- use server time so a late spawn is synced with other clients and the server
	local now0     = workspace:GetServerTimeNow()
	local initDist = math.max(0, (now0 - spawnTime) * stats.speed)
	local initPos, initDir = PathUtils.getPosition(pathData, initDist)
	-- check if the enemy already finished the path by spawn time; if so, place at the first waypoint, otherwise use the calculated position
	self.smoothCF = initPos
		and CFrame.lookAt(initPos, initPos + (initDir or Vector3.new(0, 0, 1)))
		or  CFrame.new(pathData.waypoints[1])
	model:PivotTo(self.smoothCF)

	-- Find the BillboardGui and set it up
	local billboard = model:FindFirstChildOfClass("BillboardGui")
	if billboard then
		self.nameLabel   = billboard:FindFirstChild("Name")
		self.healthLabel = billboard:FindFirstChild("Health")
		local hFrame     = billboard:FindFirstChild("Health Frame")
		self.filledBar   = hFrame and hFrame:FindFirstChild("Filled")
		if self.nameLabel   then self.nameLabel.Text   = enemyType end
		if self.healthLabel then self.healthLabel.Text = tostring(stats.maxHp) end
		if self.filledBar   then self.filledBar.Size   = UDim2.new(0.96, 0, 0.8, 0) end
	end

	-- register the enemy in the global registry so other code can find it by id, then update the enemy count
	EnemyRegistry.add(id, self)
	updateCountLabel()
	return self
end

-- get distance traveled (elapsed time * speed, minus slow debt and current slow offset)
function Enemy:_distance(now: number): number
	local curOffset = self.wasSlowed
		and (1 - self.curFactor) * self.speed * (now - self.slowStart) or 0
	return math.max(0, (now - self.spawnTime) * self.speed - self.slowDebt - curOffset)
end

-- get path progress, where 0 = 0% and 1 = 100%
function Enemy:GetProgress(): number
	local dist = self:_distance(workspace:GetServerTimeNow())
	return math.clamp(dist / pathData.totalLength, 0, 1)
end

-- Update the health bar with a tween, and update the health label text if present
function Enemy:UpdateHpBar(): ()
	local ratio = math.clamp(self.hp / self.maxHp, 0, 1)
	if self.filledBar then
		TweenService:Create(self.filledBar, HP_BAR_TWEEN, {
			Size = UDim2.new(ratio * 0.96, 0, 0.8, 0),
		}):Play()
	end
	if self.healthLabel then
		self.healthLabel.Text = tostring(math.ceil(self.hp))
	end
end

-- deals damage, calls Destroy if hp drops to zero
function Enemy:TakeDamage(amount: number): ()
	if not self.isAlive then return end
	self.hp = math.max(0, self.hp - amount)
	self:UpdateHpBar()
	if self.hp <= 0 then self:Destroy() end
end

-- manages the ice block and slowDebt: factor 0 = stun (yellow), otherwise slow (blue ice)
-- slowDebt accumulates distance lost while slowed so the enemy doesn't jump forward when the effect ends
function Enemy:ApplySlow(factor: number, duration: number): ()
	if not self.isAlive then return end
	if type(factor) ~= "number" or type(duration) ~= "number" then return end
	local now = workspace:GetServerTimeNow()
	-- accumulate distance lost while slowed so the enemy doesn't jump forward
	if self.wasSlowed then
		self.slowDebt += (1 - self.curFactor) * self.speed * (now - self.slowStart)
	end
	self.curFactor = factor
	self.slowStart = now
	self.wasSlowed = true
	local startToken = now

	if self.iceBlock then self.iceBlock:Destroy() end
	local ice        = Instance.new("Part")
	ice.Size         = Vector3.new(2.2, 2.2, 2.2)
	-- factor 0 = stun (yellow plastic), otherwise slow (blue ice)
	ice.Material     = factor == 0 and Enum.Material.SmoothPlastic or Enum.Material.Ice
	ice.Color        = factor == 0
		and Color3.fromRGB(255, 230, 50)
		or  Color3.fromRGB(100, 210, 255)
	ice.Transparency = 0.3
	ice.CanCollide   = false
	ice.CanQuery     = false
	ice.CanTouch     = false
	ice.CastShadow   = false
	ice.Anchored     = true
	ice.CFrame       = self.hrp.CFrame
	ice.Parent       = self.model
	self.iceBlock    = ice

	-- after duration expires, remove the slow effect, but only if the enemy is still alive and hasn't received a new slow (that's why we check slowStart)
	task.delay(duration, function()
		if not self.isAlive or not self.wasSlowed or self.slowStart ~= startToken then return end
		self.slowDebt += (1 - self.curFactor) * self.speed
			* (workspace:GetServerTimeNow() - self.slowStart)
		self.wasSlowed = false
		if self.iceBlock then self.iceBlock:Destroy(); self.iceBlock = nil end
	end)
end

-- red SelectionBox during bleed + damage tick on the client, bleeding flag prevents stacking
function Enemy:ApplyBleed(damage: number, duration: number, tickRate: number): ()
	if not self.isAlive or self.bleeding then return end
	if type(damage) ~= "number" or type(duration) ~= "number"
		or type(tickRate) ~= "number" or tickRate <= 0 then return end
	self.bleeding = true
	if not self.bleedBox then
		local box               = Instance.new("SelectionBox")
		box.Color3              = Color3.fromRGB(200, 0, 0)
		box.LineThickness       = 0.06
		box.SurfaceTransparency = 0.75
		box.SurfaceColor3       = Color3.fromRGB(180, 0, 0)
		box.Adornee             = self.model
		box.Parent              = workspace
		self.bleedBox           = box
	end
	-- end time is calculated using server time so the effect is synced for all clients
	local endTime = workspace:GetServerTimeNow() + duration
	-- async damage timer so it doesn't block the main thread
	task.spawn(function()
		-- check isAlive to avoid damaging a dead enemy, and check time to stop the effect after duration expires
		while self.isAlive and workspace:GetServerTimeNow() < endTime do
			self:TakeDamage(damage)
			task.wait(tickRate)
		end
		self.bleeding = false
		-- remove the bleed visual effect
		if self.bleedBox then self.bleedBox:Destroy(); self.bleedBox = nil end
	end)
end

-- update enemy position and rotation along the path
function Enemy:_updateMovement(now: number, dt: number): boolean
	local dist     = self:_distance(now)
	local pos, dir = PathUtils.getPosition(pathData, dist)
	if not pos then return false end
	local targetCF = CFrame.lookAt(pos, pos + dir)
	-- lerp smooths rotation every frame so turns aren't snappy
	self.smoothCF  = self.smoothCF:Lerp(targetCF, math.min(1, dt * 8))
	self.smoothCF  = CFrame.new(pos) * CFrame.fromMatrix(
		Vector3.zero, self.smoothCF.RightVector, self.smoothCF.UpVector, -self.smoothCF.LookVector)
	self.model:PivotTo(self.smoothCF)
	-- if there's an ice block, sync its position with the enemy
	if self.iceBlock and self.iceBlock.Parent then
		self.iceBlock.CFrame = self.hrp.CFrame
	end
	return true
end

-- update enemy position, call Destroy if the enemy reached the end of the path
function Enemy:Update(dt: number): ()
	if not self.isAlive then return end
	local now = workspace:GetServerTimeNow()
	if not self:_updateMovement(now, dt) then self:Destroy() return end
end

-- removes Enemy (stops animation, destroys model, removes from registry, updates enemy count in GUI)
function Enemy:Destroy(): ()
	if not self.isAlive then return end
	self.isAlive = false
	if self.walkTrack then self.walkTrack:Stop() end
	if self.iceBlock  and self.iceBlock.Parent  then self.iceBlock:Destroy()  end
	self.iceBlock = nil
	if self.bleedBox  and self.bleedBox.Parent  then self.bleedBox:Destroy()  end
	self.bleedBox = nil
	self.model:Destroy()
	EnemyRegistry.remove(self.id)
	updateCountLabel()
end

-- main loop: spawn enemies from queue, update positions and animations, manage shadows based on FPS
RunService.Heartbeat:Connect(function(dt: number)
	-- get current time
	local now: number = workspace:GetServerTimeNow()
	-- FPS smoothing
	avgFps = avgFps * 0.9 + (1 / dt) * 0.1
	-- enable or disable shadows based on current FPS to prevent frame drops during large enemy waves
	if shadowsOn and avgFps < FPS_LOW then
		shadowsOn = false
		for _, enemy in EnemyRegistry.all() do setEnemyShadows(enemy, false) end
	elseif not shadowsOn and avgFps > FPS_HIGH then
		shadowsOn = true
		for _, enemy in EnemyRegistry.all() do setEnemyShadows(enemy, true) end
	end
	local spawned: number = 0
	-- while there are enemies in the queue and we haven't exceeded the spawn limit per frame, check the spawn time of the first enemy in the queue
	while spawnQueueHead <= #spawnQueue and spawned < MAX_SPAWNS_PER_FRAME do
		local entry = spawnQueue[spawnQueueHead]
		-- if spawn time has arrived, spawn the enemy, otherwise exit the loop
		if now >= entry.spawnTime then
			spawnQueueHead += 1
			if not EnemyRegistry.get(entry.id) then
				Enemy.new(entry.id, entry.enemyType, entry.spawnTime)
				spawned += 1
			end
		else
			-- queue is sorted by time, the rest haven't arrived yet
			break
		end
	end
	-- update position and animation of all enemies
	for _, enemy in EnemyRegistry.all() do
		enemy:Update(dt)
	end
end)

-- receives wave number and wave start time from the server
WaveStarted.OnClientEvent:Connect(function(waveNumber: number, startTime: number)
	-- get wave config, if no config for this wave, exit
	local waveConfig = Config.WAVES[waveNumber]
	if not waveConfig then return end

	-- remove all enemies and clear the spawn queue
	cleanupAllEnemies()
	waveActive      = true
	-- prepare GUI
	timerLabel.Text = ""
	waveLabel.Text  = `Wave {waveNumber} / {TOTAL_WAVES}`

	local spawnOffset: number = 0
	local enemyIndex: number  = 0
	-- iterate through enemy batches in the wave config
	for _, batch in waveConfig do
		-- waveConfig has non-batch keys like "boss", skip them
		if type(batch) ~= "table" or not batch.count then continue end

		-- for each enemy in the batch, calculate spawn time (wave start + spawn offset within the wave) and add to spawn queue
		for i = 1, batch.count do
			enemyIndex  += 1
			local offset = spawnOffset + (i - 1) * batch.interval
			-- add to queue
			queueEnemy(getEnemyId(waveNumber, enemyIndex), batch.type, startTime + offset)
		end

		-- track where the next batch starts to correctly calculate the offset for the next enemy
		spawnOffset += batch.count * batch.interval
	end

	-- boss goes last, getBossSpawnOffset calculates how late
	if waveConfig.boss then
		local bossOffset = getBossSpawnOffset(waveConfig)
		queueEnemy(getBossId(waveNumber), waveConfig.boss.type, startTime + bossOffset)
	end
end)

-- all players ready: start countdown to the first wave
AllReady.OnClientEvent:Connect(function()
	startCountdown(Config.WAVE_START_DELAY, "Wave starts in: ")
end)
