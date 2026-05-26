-- oXEKo | o0xek0o
-- 326 lines of code

-- EnemyRenderer — client LocalScript responsible for spawning, animating,
-- and destroying all enemy models during waves. The server never touches
-- visual state; this script derives every position from a shared path
-- formula so the server needs zero per-frame replication writes.
-- Components: Enemy OOP class (metatables), path math (CFrame), FPS
-- adaptation, a time-ordered spawn queue, and attribute-driven status FX.

-- Services used throughout this script.
-- RunService.Heartbeat fires every frame — used for movement and spawn drain.
-- TweenService produces smooth HP-bar transitions instead of instant jumps.
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

-- Shared modules from ReplicatedStorage, accessible on both client and server.
-- EnemyConfig  : wave definitions and per-enemy stat tables.
-- PathUtils    : loads waypoint data and maps a distance scalar to a
--                world-space Vector3 position + direction along the path.
-- Config       : global client settings (FPS thresholds, shadow toggle).
-- ModelUtils   : clones a character template, strips the default Animate
--                script, and applies common BasePart flags in one call.
-- EnemyRegistry: shared in-memory table of alive enemies; fires onCleared
--                when the last enemy is removed (used for wave end detection).
local Modules       = ReplicatedStorage:WaitForChild("Modules")
local Config        = require(Modules:WaitForChild("EnemyConfig"))
local PathUtils     = require(Modules:WaitForChild("PathUtils"))
local ClientConfig  = require(Modules:WaitForChild("Config"))
local ModelUtils    = require(Modules:WaitForChild("ModelUtils"))
local EnemyRegistry = require(Modules:WaitForChild("EnemyRegistry"))

-- Remote events fired by the server to drive wave lifecycle on all clients.
local Events      = ReplicatedStorage:WaitForChild("Events")
local WaveStarted = Events:WaitForChild("WaveStarted")
local AllReady    = Events:WaitForChild("AllReady")

-- Source folder for enemy model templates and the live container in Workspace.
-- We wait for child "1" before loading the path to guarantee waypoints exist.
local EnemiesSrc  = ReplicatedStorage:WaitForChild("Enemies")
local EnemyFolder = workspace:WaitForChild("Enemies")
local pathFolder  = workspace:WaitForChild("Path") :: Folder
pathFolder:WaitForChild("1")
local pathData    = PathUtils.load(pathFolder)

-- GUI references are re-fetched on every character respawn because ScreenGui
-- resets when the character respawns (ResetOnSpawn = true). Holding stale
-- references after respawn would silently stop all label updates with no error.
local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local waveLabel, countLabel, timerLabel

local function fetchGuiRefs()
	local screenGui = playerGui:WaitForChild("ScreenGui")
	local upperGui  = screenGui:WaitForChild("Upper Gui")
	waveLabel  = upperGui:WaitForChild("Wave number")
	countLabel = upperGui:WaitForChild("Enemy Count")
	timerLabel = upperGui:WaitForChild("Timer")
end

fetchGuiRefs()
localPlayer.CharacterAdded:Connect(fetchGuiRefs)

-- TOTAL_WAVES computed once so the wave label can display "Wave X / N".
-- HP_BAR_TWEEN defines easing for health bar shrink — Quad Out feels snappy.
-- MAX_SPAWNS_PER_FRAME caps instantiation per Heartbeat tick, preventing a
-- frame spike when many enemies share the exact same spawn timestamp.
local TOTAL_WAVES: number          = #Config.WAVES
local HP_BAR_TWEEN: TweenInfo      = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WALK_ANIM_ID: string         = "rbxassetid://913402848"
local MAX_SPAWNS_PER_FRAME: number = 5

-- avgFps is an exponential moving average (EMA) of instantaneous frame rate.
-- Formula each frame:  avgFps = avgFps * 0.9 + currentFps * 0.1
-- The 0.9 weight on history smooths transient spikes so shadow toggling
-- stays stable and does not oscillate rapidly around the threshold.
-- spawnQueue is time-sorted; spawnQueueHead is a forward-only pointer.
-- Advancing it is O(1) and avoids the O(n) cost of table.remove per frame.
local avgFps: number      = ClientConfig.AVG_FPS_INIT
local shadowsOn: boolean  = ClientConfig.SHADOWS_ON
local waveActive: boolean = false
local spawnQueue: { { id: number, enemyType: string, spawnTime: number } } = {}
local spawnQueueHead: number = 1
local startCountdown: (seconds: number, prefix: string) -> ()

-- Enemy IDs encode the originating wave and spawn index into one integer:
--   id = waveNum * 10000 + index   (boss always uses index 9999)
-- Any system can recover which wave an enemy belongs to from the id alone.
local function getEnemyId(waveNum: number, index: number): number
	return waveNum * 10000 + index
end

local function getBossId(waveNum: number): number
	return waveNum * 10000 + 9999
end

-- Calculates the boss spawn offset (seconds after wave start).
-- trigger == "delay": use the explicit delay value from config.
-- Otherwise: simulate every regular enemy's travel time and spawn the boss
-- 1 second after the last one would reach the end, so the boss always
-- arrives after the regular wave has cleared.
local function getBossSpawnOffset(waveConfig: { any }): number?
	local boss = waveConfig.boss
	if not boss then return nil end
	if boss.trigger == "delay" then return boss.delay end
	local maxEndTime: number = 0
	local offset: number     = 0
	for _, batch in waveConfig do
		if type(batch) ~= "table" or not batch.count then continue end
		for i = 1, batch.count do
			local endT = offset + (i - 1) * batch.interval
				+ pathData.totalLength / Config.ENEMY_TYPES[batch.type].speed
			if endT > maxEndTime then maxEndTime = endT end
		end
		offset += batch.count * batch.interval
	end
	return maxEndTime + 1
end

-- Appends a future spawn entry. Heartbeat drains this queue in time order,
-- creating enemy instances at the correct server-synchronized moment.
local function queueEnemy(id: number, enemyType: string, spawnTime: number): ()
	spawnQueue[#spawnQueue + 1] = { id = id, enemyType = enemyType, spawnTime = spawnTime }
end

local function updateCountLabel(): ()
	countLabel.Text = `Enemies: {EnemyRegistry.count()}`
end

-- Toggles CastShadow on every BasePart of the enemy model.
-- Called globally when the FPS EMA crosses a threshold, shedding shadow
-- draw calls across all enemies at once to recover frame budget.
local function setEnemyShadows(enemy: any, enabled: boolean): ()
	for _, part in enemy.model:GetDescendants() do
		if not part:IsA("BasePart") then continue end
		(part :: BasePart).CastShadow = enabled
	end
end

-- Destroys all live models and resets the spawn queue before a new wave.
-- Stopping the walk animation before Destroy prevents the Animator from
-- firing callbacks on an already-destroyed model instance.
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

-- Runs a countdown in a separate thread so it does not block the caller.
-- Exits early if waveActive flips true mid-countdown (next wave arrived).
startCountdown = function(seconds: number, prefix: string): ()
	task.spawn(function()
		for i = seconds, 1, -1 do
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

-- onCleared fires when the last enemy is removed from EnemyRegistry.
-- We only start the between-wave countdown when the spawn queue is also
-- exhausted — otherwise enemies are still queued but not yet instantiated.
EnemyRegistry.onCleared:Connect(function()
	if waveActive and spawnQueueHead > #spawnQueue then
		waveActive = false
		startCountdown(Config.BETWEEN_WAVES_MIN_DELAY, "Next wave in: ")
	end
end)

-- Enemy class implemented with Luau metatables for lightweight OOP.
-- __index = Enemy means any method lookup on an instance falls through to
-- the class table, so all instances share one method table without copying
-- functions into each individual object (memory efficient).
local Enemy = {}
Enemy.__index = Enemy

-- Constructor: initialises state, clones the model via ModelUtils, sets up
-- an AnimationController + Animator pair (required for non-Humanoid rigs —
-- a Humanoid has its own built-in Animator), then positions the model at the
-- correct path offset accounting for server-to-client spawn latency.
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
	-- slowDebt accumulates the distance-equivalent already saved during past
	-- slow windows so the position formula stays continuous when a slow ends.
	self.slowDebt  = 0
	self.wasSlowed = false
	self.slowStart = 0
	self.curFactor = 1
	self.bleedBox  = nil
	self.iceBlock  = nil

	local template   = EnemiesSrc:FindFirstChild(enemyType) :: Instance
	local model, hrp = ModelUtils.cloneAndPrepare(template, {
		castShadow = shadowsOn,
		canCollide = false,
	})
	model.Name   = `Enemy_{id}`
	model.Parent = EnemyFolder
	self.model   = model
	self.hrp     = hrp

	-- AnimationController + Animator is the correct pair for non-Humanoid
	-- rigs. Without AnimationController the Animator has no root to bind to.
	local animController  = Instance.new("AnimationController")
	animController.Parent = model
	local animator        = Instance.new("Animator")
	animator.Parent       = animController
	self.walkTrack        = ModelUtils.makeAnimTrack(animator, WALK_ANIM_ID)
	self.walkTrack:Play()

	-- Compute how far the enemy has already traveled between its server
	-- spawnTime and the moment this client instantiates it (latency + queue).
	-- CFrame.lookAt builds a rotation with +Z toward the path direction,
	-- giving the enemy the correct facing immediately on first placement.
	local now0     = workspace:GetServerTimeNow()
	local initDist = math.max(0, (now0 - spawnTime) * stats.speed)
	local initPos, initDir = PathUtils.getPosition(pathData, initDist)
	self.smoothCF = initPos
		and CFrame.lookAt(initPos, initPos + (initDir or Vector3.new(0, 0, 1)))
		or  CFrame.new(pathData.waypoints[1])
	model:PivotTo(self.smoothCF)

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

	EnemyRegistry.add(id, self)
	updateCountLabel()
	return self
end

-- Computes actual distance traveled along the path at time `now`.
-- Base formula:  dist = (now - spawnTime) * speed
-- slowDebt   : total distance-time saved by all previously ended slows.
-- curOffset  : distance-time currently being saved by the active slow.
-- math.max(0) prevents a negative result at the moment of spawning.
function Enemy:_distance(now: number): number
	local curOffset = self.wasSlowed
		and (1 - self.curFactor) * self.speed * (now - self.slowStart) or 0
	return math.max(0, (now - self.spawnTime) * self.speed - self.slowDebt - curOffset)
end

-- Returns 0–1 normalized progress along the path.
-- Used by UnitRenderer targeting comparators ("first" = max, "last" = min).
function Enemy:GetProgress(): number
	local dist = self:_distance(workspace:GetServerTimeNow())
	return math.clamp(dist / pathData.totalLength, 0, 1)
end

-- Animates the HP bar via TweenService for smooth visual feedback on hits.
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

-- Applies damage, refreshes the HP bar, and calls Destroy when HP hits 0.
-- isAlive guard prevents double-processing on a dying enemy in the same frame.
function Enemy:TakeDamage(amount: number): ()
	if not self.isAlive then return end
	self.hp = math.max(0, self.hp - amount)
	self:UpdateHpBar()
	if self.hp <= 0 then self:Destroy() end
end

-- Reads "Slowed" and "SlowFactor" marker attributes set by the server to
-- show or hide the slow/stun block visual.
-- factor == 0  →  full stun: yellow SmoothPlastic block.
-- factor > 0   →  partial slow: blue Ice material block.
-- On slow-end we commit the saved distance into slowDebt so _distance stays
-- continuous — without this the enemy would visually jump forward.
function Enemy:_handleSlow(now: number, marker: Instance?): ()
	local isSlowed = marker ~= nil and marker:GetAttribute("Slowed") == true
	local factor: number = 1
	if isSlowed then
		local f = marker:GetAttribute("SlowFactor")
		if type(f) == "number" then factor = f end
	end
	if isSlowed and not self.wasSlowed then
		self.slowStart = now
		self.curFactor = factor
		self.wasSlowed = true
		if not self.iceBlock then
			local ice        = Instance.new("Part")
			ice.Size         = Vector3.new(2.2, 2.2, 2.2)
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
		end
	elseif not isSlowed and self.wasSlowed then
		self.slowDebt += (1 - self.curFactor) * self.speed * (now - self.slowStart)
		self.wasSlowed = false
		if self.iceBlock then self.iceBlock:Destroy(); self.iceBlock = nil end
	end
end

-- Reads the "Bleeding" attribute to toggle a SelectionBox adornment.
-- SelectionBox draws a colored wireframe around the whole model with no
-- mesh or texture changes — a built-in Roblox API decoration object.
function Enemy:_handleBleed(marker: Instance?): ()
	local isBleeding = marker ~= nil and marker:GetAttribute("Bleeding") == true
	if isBleeding and not self.bleedBox then
		local box               = Instance.new("SelectionBox")
		box.Color3              = Color3.fromRGB(200, 0, 0)
		box.LineThickness       = 0.06
		box.SurfaceTransparency = 0.75
		box.SurfaceColor3       = Color3.fromRGB(180, 0, 0)
		box.Adornee             = self.model
		box.Parent              = workspace
		self.bleedBox           = box
	elseif not isBleeding and self.bleedBox then
		self.bleedBox:Destroy()
		self.bleedBox = nil
	end
end

-- Per-frame movement using three CFrame techniques combined:
-- 1. CFrame.lookAt    — builds a rotation with +Z facing the path direction.
-- 2. :Lerp            — interpolates smoothCF toward the target at dt*8 rate,
--                       producing momentum-like rotation smoothing each frame.
-- 3. CFrame.fromMatrix — reconstructs the CFrame from lerped axis vectors
--                        while snapping position exactly to the path point,
--                        preventing accumulated floating-point drift over time.
-- Returns false when PathUtils returns nil position (enemy passed path end).
function Enemy:_updateMovement(now: number, dt: number): boolean
	local dist     = self:_distance(now)
	local pos, dir = PathUtils.getPosition(pathData, dist)
	if not pos then return false end
	local targetCF = CFrame.lookAt(pos, pos + dir)
	self.smoothCF  = self.smoothCF:Lerp(targetCF, math.min(1, dt * 8))
	self.smoothCF  = CFrame.new(pos) * CFrame.fromMatrix(
		Vector3.zero, self.smoothCF.RightVector, self.smoothCF.UpVector, -self.smoothCF.LookVector)
	self.model:PivotTo(self.smoothCF)
	if self.iceBlock and self.iceBlock.Parent then
		self.iceBlock.CFrame = self.hrp.CFrame
	end
	return true
end

-- Per-frame dispatch. Order is intentional: slow before movement so
-- _distance uses the correct curFactor; bleed last as it is purely visual.
function Enemy:Update(dt: number): ()
	if not self.isAlive then return end
	local now      = workspace:GetServerTimeNow()
	local markersF = workspace:FindFirstChild("EnemyMarkers")
	local marker   = markersF and markersF:FindFirstChild(`Marker_{self.id}`)
	self:_handleSlow(now, marker)
	if not self:_updateMovement(now, dt) then self:Destroy() return end
	self:_handleBleed(marker)
end

-- isAlive flag prevents re-entry: Destroy can be triggered both from
-- TakeDamage (hp = 0) and _updateMovement (path end) in the same frame.
-- Visual attachments are cleaned up before model:Destroy to avoid
-- Roblox adornment warnings on destroyed instances.
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

-- Heartbeat runs three sequential phases every frame:
-- Phase 1 — FPS adaptation: update EMA, bulk-toggle shadows if threshold crossed.
-- Phase 2 — Spawn drain: instantiate up to MAX_SPAWNS_PER_FRAME enemies whose
--            spawnTime has arrived. Queue is pre-sorted so we break on the first
--            future entry — O(1) best case per frame.
-- Phase 3 — Update loop: call Update(dt) on every currently alive enemy.
RunService.Heartbeat:Connect(function(dt: number)
	local now: number = workspace:GetServerTimeNow()
	avgFps = avgFps * 0.9 + (1 / dt) * 0.1
	if shadowsOn and avgFps < ClientConfig.FPS_LOW then
		shadowsOn = false
		for _, enemy in EnemyRegistry.all() do setEnemyShadows(enemy, false) end
	elseif not shadowsOn and avgFps > ClientConfig.FPS_HIGH then
		shadowsOn = true
		for _, enemy in EnemyRegistry.all() do setEnemyShadows(enemy, true) end
	end
	local spawned: number = 0
	while spawnQueueHead <= #spawnQueue and spawned < MAX_SPAWNS_PER_FRAME do
		local entry = spawnQueue[spawnQueueHead]
		if now >= entry.spawnTime then
			spawnQueueHead += 1
			if not EnemyRegistry.get(entry.id) then
				Enemy.new(entry.id, entry.enemyType, entry.spawnTime)
				spawned += 1
			end
		else
			break
		end
	end
	for _, enemy in EnemyRegistry.all() do
		enemy:Update(dt)
	end
end)

-- WaveStarted carries the wave number and authoritative server start timestamp.
-- Every client independently rebuilds the full spawn queue from the wave config
-- using the same timestamp so enemies appear in sync without extra messaging.
WaveStarted.OnClientEvent:Connect(function(waveNumber: number, startTime: number)
	local waveConfig = Config.WAVES[waveNumber]
	if not waveConfig then return end

	cleanupAllEnemies()
	waveActive      = true
	timerLabel.Text = ""
	waveLabel.Text  = `Wave {waveNumber} / {TOTAL_WAVES}`

	local spawnOffset: number = 0
	local enemyIndex: number  = 0
	for _, batch in waveConfig do
		if type(batch) ~= "table" or not batch.count then continue end
		for i = 1, batch.count do
			enemyIndex  += 1
			local offset = spawnOffset + (i - 1) * batch.interval
			queueEnemy(getEnemyId(waveNumber, enemyIndex), batch.type, startTime + offset)
		end
		spawnOffset += batch.count * batch.interval
	end

	if waveConfig.boss then
		local bossOffset = getBossSpawnOffset(waveConfig)
		queueEnemy(getBossId(waveNumber), waveConfig.boss.type, startTime + bossOffset)
	end
end)

-- AllReady fires when all connected players have clicked Ready.
-- Starts the pre-wave countdown shown in the timer label.
AllReady.OnClientEvent:Connect(function()
	startCountdown(Config.WAVE_START_DELAY, "Wave starts in: ")
end)
