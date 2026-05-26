local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local PhysicsService      = game:GetService("PhysicsService")

pcall(function() PhysicsService:RegisterCollisionGroup("Units")   end)
pcall(function() PhysicsService:RegisterCollisionGroup("Players") end)
PhysicsService:CollisionGroupSetCollidable("Units", "Players", false)
PhysicsService:CollisionGroupSetCollidable("Units", "Units",   false)

local function applyPlayersGroup(character: Model): ()
	character.DescendantAdded:Connect(function(d: Instance)
		if d:IsA("BasePart") then (d :: BasePart).CollisionGroup = "Players" end
	end)
	for _, p in character:GetDescendants() do
		if p:IsA("BasePart") then (p :: BasePart).CollisionGroup = "Players" end
	end
end
Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(applyPlayersGroup)
end)
for _, player in Players:GetPlayers() do
	if player.Character then applyPlayersGroup(player.Character) end
end

local Modules          = ReplicatedStorage:WaitForChild("Modules")
local UnitConfig       = require(Modules:WaitForChild("UnitConfig"))
local EnemyConfig      = require(Modules:WaitForChild("EnemyConfig"))
local ServerEnemyState = require(game:GetService("ServerStorage"):WaitForChild("Modules"):WaitForChild("ServerEnemyState"))

local Events      = ReplicatedStorage:WaitForChild("Events")
local PlaceUnit   = Events:WaitForChild("PlaceUnit")
local UnitPlaced  = Events:WaitForChild("UnitPlaced")
local GoldUpdated = Events:WaitForChild("GoldUpdated")

type UnitData = { position: Vector3, owner: Player }
local serverUnits: { [number]: UnitData } = {}
local nextUnitId: number = 1
local playerGold: { [Player]: number } = {}

Players.PlayerAdded:Connect(function(player: Player)
	playerGold[player] = UnitConfig.START_GOLD
	GoldUpdated:FireClient(player, UnitConfig.START_GOLD)
end)
Players.PlayerRemoving:Connect(function(player: Player)
	playerGold[player] = nil
	for id, data in serverUnits do
		if data.owner == player then
			serverUnits[id] = nil
		end
	end
end)

ServerEnemyState.setRewardHandler(function(_id: number, kind: string, owner: Player)
	local stats = EnemyConfig.ENEMY_TYPES[kind]
	if not stats or not playerGold[owner] then return end
	playerGold[owner] += stats.reward
	GoldUpdated:FireClient(owner, playerGold[owner])
end)

type Comparator = (d: ServerEnemyState.EnemyData, dist: number, now: number) -> number
local TARGET_COMPARATORS: { [string]: Comparator } = {
	first    = function(d, _,    now) return  ServerEnemyState.progress(d.id, now) end,
	last     = function(d, _,    now) return -ServerEnemyState.progress(d.id, now) end,
	nearest  = function(_, dist, _)   return -dist end,
	farthest = function(_, dist, _)   return  dist end,
	weak     = function(d, _,    _)   return -d.hp end,
	stronger = function(d, _,    _)   return  d.hp end,
	faster   = function(d, _,    _)   return  d.speed end,
	slower   = function(d, _,    _)   return -d.speed end,
}

local function applyEffect(id: number, stats: any, owner: Player): ()
	local effect = stats.effect
	if effect == "slow" then
		ServerEnemyState.applySlow(id, 1 - (stats.slowAmount or stats.slowFactor or 0),
			stats.slowDuration :: number)
	elseif effect == "stun" then
		ServerEnemyState.applySlow(id, 0, stats.stunDuration :: number)
	elseif effect == "bleed" then
		ServerEnemyState.applyBleed(id, stats.bleedDamage :: number,
			stats.bleedDuration :: number, stats.bleedTickRate :: number, owner)
	end
end

type AttackCtx = {
	stats     : any,
	owner     : Player,
	now       : number,
	unitPos   : Vector3,
	target    : ServerEnemyState.EnemyData,
	targetId  : number,
	targetPos : Vector3,
}
local ATTACK_SHAPES: { [string]: (AttackCtx) -> () } = {}

ATTACK_SHAPES["single"] = function(ctx)
	ServerEnemyState.applyDamage(ctx.targetId, ctx.stats.damage, ctx.owner)
	applyEffect(ctx.targetId, ctx.stats, ctx.owner)
end

ATTACK_SHAPES["aoe circle"] = function(ctx)
	local r = ctx.stats.aoeRadius :: number
	for id, d in ServerEnemyState.all() do
		if d.hp <= 0 then continue end
		local pos = ServerEnemyState.position(id, ctx.now)
		if pos and (pos - ctx.targetPos).Magnitude <= r then
			ServerEnemyState.applyDamage(id, ctx.stats.damage, ctx.owner)
			applyEffect(id, ctx.stats, ctx.owner)
		end
	end
end

ATTACK_SHAPES["full aoe"] = function(ctx)
	for id, d in ServerEnemyState.all() do
		if d.hp <= 0 then continue end
		local pos = ServerEnemyState.position(id, ctx.now)
		if pos and (pos - ctx.unitPos).Magnitude <= ctx.stats.range then
			ServerEnemyState.applyDamage(id, ctx.stats.damage, ctx.owner)
			applyEffect(id, ctx.stats, ctx.owner)
		end
	end
end

ATTACK_SHAPES["conus"] = function(ctx)
	local atkDir = (ctx.targetPos - ctx.unitPos) * Vector3.new(1, 0, 1)
	if atkDir.Magnitude <= 0.1 then return end
	atkDir = atkDir.Unit
	local halfCos = math.cos(math.rad((ctx.stats.conusAngle or 45) / 2))
	for id, d in ServerEnemyState.all() do
		if d.hp <= 0 then continue end
		local pos = ServerEnemyState.position(id, ctx.now)
		if not pos then continue end
		local toE = (pos - ctx.unitPos) * Vector3.new(1, 0, 1)
		if toE.Magnitude > 0.1 and toE.Magnitude <= ctx.stats.range
			and atkDir:Dot(toE.Unit) >= halfCos then
			ServerEnemyState.applyDamage(id, ctx.stats.damage, ctx.owner)
			applyEffect(id, ctx.stats, ctx.owner)
		end
	end
end

local function selectServerTarget(
	unitPos: Vector3, range: number, cmp: Comparator, now: number
): (ServerEnemyState.EnemyData?, number?, Vector3?)
	local best: ServerEnemyState.EnemyData? = nil
	local bestId: number?  = nil
	local bestPos: Vector3? = nil
	local bestVal: number  = -math.huge
	for id, d in ServerEnemyState.all() do
		if d.hp <= 0 then continue end
		local pos = ServerEnemyState.position(id, now)
		if not pos then continue end
		local dist = (pos - unitPos).Magnitude
		if dist > range then continue end
		local val = cmp(d, dist, now)
		if val > bestVal then
			bestVal = val; best = d; bestId = id; bestPos = pos
		end
	end
	return best, bestId, bestPos
end

local function serverAttack(unitId: number, unitType: string, unitPos: Vector3, owner: Player): ()
	local stats     = UnitConfig.UNITS[unitType]
	local interval  = 1 / stats.fireRate
	local cmp       = TARGET_COMPARATORS[stats.targeting or "first"] or TARGET_COMPARATORS.first
	local shapeFn   = ATTACK_SHAPES[stats.attackShape]

	while serverUnits[unitId] do
		local now = workspace:GetServerTimeNow()
		local target, targetId, targetPos = selectServerTarget(unitPos, stats.range, cmp, now)
		if target and targetId and targetPos and shapeFn then
			shapeFn({
				stats     = stats,
				owner     = owner,
				now       = now,
				unitPos   = unitPos,
				target    = target,
				targetId  = targetId,
				targetPos = targetPos,
			})
		end
		task.wait(interval)
	end
end

local function validatePlacement(player: Player, unitType: string, position: Vector3): (boolean, Vector3?)
	local stats = UnitConfig.UNITS[unitType]
	if not stats then return false, nil end
	if (playerGold[player] or 0) < stats.cost then return false, nil end

	local rayParams                      = RaycastParams.new()
	local rayExclude: { Instance }       = { workspace:WaitForChild("EnemyMarkers") }
	for _, p in Players:GetPlayers() do
		if p.Character then table.insert(rayExclude, p.Character) end
	end
	rayParams.FilterDescendantsInstances = rayExclude
	rayParams.FilterType                 = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(position + Vector3.new(0, 5, 0), Vector3.new(0, -10, 0), rayParams)
	if not result then return false, nil end
	if result.Instance.Name == "Road" then return false, nil end

	local placePos = position + Vector3.new(0, 3, 0)
	for _, data in serverUnits do
		if (data.position - placePos).Magnitude < 3 then return false, nil end
	end

	return true, placePos
end

PlaceUnit.OnServerEvent:Connect(function(player: Player, unitType: string, position: Vector3)
	local ok, placePos = validatePlacement(player, unitType, position)
	if not ok or not placePos then return end

	local stats = UnitConfig.UNITS[unitType]
	playerGold[player] -= stats.cost
	GoldUpdated:FireClient(player, playerGold[player])

	local unitId        = nextUnitId
	nextUnitId         += 1
	serverUnits[unitId] = { position = placePos, owner = player }

	local placedAt: number = workspace:GetServerTimeNow()
	UnitPlaced:FireAllClients(unitType, placePos, placedAt)
	task.spawn(serverAttack, unitId, unitType, placePos, player)
end)
