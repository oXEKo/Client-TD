
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules     = ReplicatedStorage:WaitForChild("Modules")
local EnemyConfig = require(Modules:WaitForChild("EnemyConfig"))
local PathUtils   = require(Modules:WaitForChild("PathUtils"))

export type EnemyData = {
	id        : number,
	kind      : string,
	spawnTime : number,
	speed     : number,
	maxHp     : number,
	hp        : number,
	wave      : number,
	isBoss    : boolean,
	slowDebt  : number,
	wasSlowed : boolean,
	slowStart : number,
	curFactor : number,
	bleeding  : boolean,
	marker    : BasePart?,
}

type PathData = typeof(PathUtils.load(Instance.new("Folder")))

local ServerEnemyState = {}

local serverEnemies: { [number]: EnemyData } = {}
local pathData: PathData? = nil

local removedSig: BindableEvent = Instance.new("BindableEvent")
ServerEnemyState.onRemoved = removedSig.Event

local rewardHandler: ((id: number, kind: string, owner: Player) -> ())? = nil


function ServerEnemyState.setPathData(data: PathData): ()
	pathData = data
end

function ServerEnemyState.setRewardHandler(fn: (id: number, kind: string, owner: Player) -> ()): ()
	rewardHandler = fn
end


function ServerEnemyState.register(
	id: number, kind: string, spawnTime: number,
	wave: number, isBoss: boolean, marker: BasePart?
): EnemyData?
	local stats = EnemyConfig.ENEMY_TYPES[kind]
	if not stats then return nil end
	local data: EnemyData = {
		id        = id,
		kind      = kind,
		spawnTime = spawnTime,
		speed     = stats.speed,
		maxHp     = stats.maxHp,
		hp        = stats.maxHp,
		wave      = wave,
		isBoss    = isBoss,
		slowDebt  = 0,
		wasSlowed = false,
		slowStart = 0,
		curFactor = 1,
		bleeding  = false,
		marker    = marker,
	}
	serverEnemies[id] = data
	return data
end

function ServerEnemyState.remove(id: number, killedBy: Player?): ()
	local d = serverEnemies[id]
	if not d then return end
	serverEnemies[id] = nil
	if d.marker then d.marker:Destroy() end
	removedSig:Fire(id, killedBy)
end

function ServerEnemyState.get(id: number): EnemyData?
	return serverEnemies[id]
end

function ServerEnemyState.all(): { [number]: EnemyData }
	return serverEnemies
end


local function distanceTraveled(d: EnemyData, now: number): number
	local cur = d.wasSlowed
		and (1 - d.curFactor) * d.speed * (now - d.slowStart) or 0
	return math.max(0, (now - d.spawnTime) * d.speed - d.slowDebt - cur)
end

function ServerEnemyState.position(id: number, now: number): Vector3?
	local d = serverEnemies[id]
	if not d or not pathData then return nil end
	local dist = distanceTraveled(d, now)
	local pos  = PathUtils.getPosition(pathData, dist)
	return pos
end

function ServerEnemyState.progress(id: number, now: number): number
	local d = serverEnemies[id]
	if not d or not pathData then return 0 end
	local dist = distanceTraveled(d, now)
	return math.clamp(dist / pathData.totalLength, 0, 1)
end

function ServerEnemyState.distance(id: number, now: number): number
	local d = serverEnemies[id]
	if not d then return 0 end
	return distanceTraveled(d, now)
end


function ServerEnemyState.applyDamage(id: number, amount: number, owner: Player): boolean
	local d = serverEnemies[id]
	if not d or d.hp <= 0 then return false end
	d.hp = math.max(0, d.hp - amount)
	if d.hp > 0 then return false end
	if rewardHandler then rewardHandler(id, d.kind, owner) end
	ServerEnemyState.remove(id, owner)
	return true
end


local function accumulateSlowDebt(d: EnemyData, now: number): ()
	if not d.wasSlowed then return end
	d.slowDebt += (1 - d.curFactor) * d.speed * (now - d.slowStart)
	d.wasSlowed = false
end

function ServerEnemyState.applySlow(id: number, factor: number, duration: number): ()
	local d = serverEnemies[id]
	if not d then return end
	if type(factor) ~= "number" or type(duration) ~= "number" then
		warn("[ServerEnemyState] applySlow: invalid factor/duration for enemy", id)
		return
	end
	local now = workspace:GetServerTimeNow()
	accumulateSlowDebt(d, now)
	d.curFactor = factor
	d.slowStart = now
	d.wasSlowed = true
	local startToken = d.slowStart
	task.delay(duration, function()
		local cur = serverEnemies[id]
		if not cur or not cur.wasSlowed or cur.slowStart ~= startToken then return end
		accumulateSlowDebt(cur, workspace:GetServerTimeNow())
	end)
end


function ServerEnemyState.applyBleed(
	id: number, damage: number, duration: number, tickRate: number, owner: Player
): ()
	local d = serverEnemies[id]
	if not d or d.bleeding then return end
	d.bleeding = true
	local endTime = workspace:GetServerTimeNow() + duration
	task.spawn(function()
		while workspace:GetServerTimeNow() < endTime do
			local cur = serverEnemies[id]
			if not cur then return end
			ServerEnemyState.applyDamage(id, damage, owner)
			task.wait(tickRate)
		end
		local cur = serverEnemies[id]
		if cur then
			cur.bleeding = false
		end
	end)
end

return ServerEnemyState
