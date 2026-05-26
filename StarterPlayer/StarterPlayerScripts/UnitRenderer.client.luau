local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules       = ReplicatedStorage:WaitForChild("Modules")
local UnitConfig    = require(Modules:WaitForChild("UnitConfig"))
local ClientConfig  = require(Modules:WaitForChild("Config"))
local ModelUtils    = require(Modules:WaitForChild("ModelUtils"))
local EnemyRegistry = require(Modules:WaitForChild("EnemyRegistry"))

local Events     = ReplicatedStorage:WaitForChild("Events")
local UnitPlaced = Events:WaitForChild("UnitPlaced")

local UnitsSrc    = ReplicatedStorage:WaitForChild("Units")
local UnitsFolder = workspace:WaitForChild("Units") :: Folder

local SHAPE_COLORS: { [string]: Color3 } = {
	["single"]     = Color3.fromRGB(255, 215,  50),
	["aoe circle"] = Color3.fromRGB(255,  80,  80),
	["full aoe"]   = Color3.fromRGB(255, 130,  30),
	["conus"]      = Color3.fromRGB(180,  80, 255),
}
local EFFECT_COLORS: { [string]: Color3 } = {
	slow  = Color3.fromRGB( 80, 210, 255),
	stun  = Color3.fromRGB(255, 240,  80),
	bleed = Color3.fromRGB(220,  30,  30),
}
local DEFAULT_BEAM_COLOR: Color3 = Color3.fromRGB(255, 255, 200)

local function makeFxPart(color: Color3): Part
	local p        = Instance.new("Part")
	p.Material     = Enum.Material.Neon
	p.Color        = color
	p.Transparency = 0.15
	p.Anchored     = true
	p.CanCollide   = false
	p.CanQuery     = false
	p.CanTouch     = false
	p.CastShadow   = false
	p.Parent       = workspace
	return p
end

local function fadePart(p: Part, duration: number): ()
	TweenService:Create(p, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Transparency = 1 }):Play()
	task.delay(duration + 0.05, function() if p.Parent then p:Destroy() end end)
end

type Comparator = (enemy: any, dist: number) -> number
local TARGET_COMPARATORS: { [string]: Comparator } = {
	first    = function(e, _)    return  e:GetProgress() end,
	last     = function(e, _)    return -e:GetProgress() end,
	nearest  = function(_, dist) return -dist end,
	farthest = function(_, dist) return  dist end,
	weak     = function(e, _)    return -e.hp end,
	stronger = function(e, _)    return  e.hp end,
	faster   = function(e, _)    return  e.speed end,
	slower   = function(e, _)    return -e.speed end,
}

local function selectTarget(unitPos: Vector3, range: number, targeting: string): any?
	local cmp     = TARGET_COMPARATORS[targeting] or TARGET_COMPARATORS.first
	local best: any? = nil
	local bestVal = -math.huge
	for _, enemy in EnemyRegistry.all() do
		if not enemy.isAlive then continue end
		local dist = (enemy.model:GetPivot().Position - unitPos).Magnitude
		if dist > range then continue end
		local val = cmp(enemy, dist)
		if val > bestVal then bestVal = val; best = enemy end
	end
	return best
end

type AttackCtx = {
	stats      : any,
	hrp        : BasePart,
	target     : any,
	targetPos  : Vector3,
	attackDir  : Vector3,
	showFx     : boolean,
	beamColor  : Color3,
}

local ATTACK_SHAPES: { [string]: (AttackCtx) -> () } = {}

ATTACK_SHAPES["single"] = function(ctx)
	ctx.target:TakeDamage(ctx.stats.damage)
	if not ctx.showFx then return end
	local tHrp = ctx.target.model:FindFirstChild("HumanoidRootPart")
	local tPos = tHrp and (tHrp :: BasePart).Position or ctx.targetPos
	local len  = (tPos - ctx.hrp.Position).Magnitude
	if len <= 0.1 then return end
	local p  = makeFxPart(ctx.beamColor)
	p.Size   = Vector3.new(0.12, 0.12, len)
	p.CFrame = CFrame.lookAt((ctx.hrp.Position + tPos) / 2, tPos)
	fadePart(p, 0.25)
end

ATTACK_SHAPES["aoe circle"] = function(ctx)
	local r = ctx.stats.aoeRadius :: number
	for _, enemy in EnemyRegistry.all() do
		if not enemy.isAlive then continue end
		if (enemy.model:GetPivot().Position - ctx.targetPos).Magnitude <= r then
			enemy:TakeDamage(ctx.stats.damage)
		end
	end
	if not ctx.showFx then return end
	local p  = makeFxPart(ctx.beamColor)
	p.Shape  = Enum.PartType.Cylinder
	p.Size   = Vector3.new(0.15, r * 2, r * 2)
	p.CFrame = CFrame.new(ctx.targetPos) * CFrame.fromEulerAnglesXYZ(0, 0, math.rad(90))
	fadePart(p, 0.45)
end

ATTACK_SHAPES["full aoe"] = function(ctx)
	for _, enemy in EnemyRegistry.all() do
		if not enemy.isAlive then continue end
		if (enemy.model:GetPivot().Position - ctx.hrp.Position).Magnitude <= ctx.stats.range then
			enemy:TakeDamage(ctx.stats.damage)
		end
	end
	if not ctx.showFx then return end
	local p  = makeFxPart(ctx.beamColor)
	p.Shape  = Enum.PartType.Cylinder
	p.Size   = Vector3.new(0.15, ctx.stats.range * 2, ctx.stats.range * 2)
	p.CFrame = CFrame.new(ctx.hrp.Position) * CFrame.fromEulerAnglesXYZ(0, 0, math.rad(90))
	fadePart(p, 0.45)
end

ATTACK_SHAPES["conus"] = function(ctx)
	local atkDir  = ctx.attackDir.Magnitude > 0.1 and ctx.attackDir.Unit or Vector3.new(0, 0, 1)
	local halfRad = math.rad((ctx.stats.conusAngle or 45) / 2)
	local halfCos = math.cos(halfRad)
	for _, enemy in EnemyRegistry.all() do
		if not enemy.isAlive then continue end
		local toE = (enemy.model:GetPivot().Position - ctx.hrp.Position) * Vector3.new(1, 0, 1)
		if toE.Magnitude <= ctx.stats.range and toE.Magnitude > 0.1
			and atkDir:Dot(toE.Unit) >= halfCos then
			enemy:TakeDamage(ctx.stats.damage)
		end
	end
	if not ctx.showFx then return end
	local dir2d = Vector3.new(atkDir.X, 0, atkDir.Z)
	if dir2d.Magnitude <= 0.1 then return end
	dir2d = dir2d.Unit
	for _, ang in { -halfRad, halfRad } do
		local d  = CFrame.Angles(0, ang, 0) * dir2d
		local p  = makeFxPart(ctx.beamColor)
		p.Size   = Vector3.new(0.15, 0.06, ctx.stats.range)
		p.CFrame = CFrame.lookAt(ctx.hrp.Position + d * (ctx.stats.range * 0.5),
			ctx.hrp.Position + d * ctx.stats.range)
		fadePart(p, 0.35)
	end
end

local function setupUnitAnimations(model: Model, stats: any): (AnimationTrack?, AnimationTrack?)
	local animCtrl  = Instance.new("AnimationController")
	animCtrl.Parent = model
	local animator  = Instance.new("Animator")
	animator.Parent = animCtrl

	local idleTrack: AnimationTrack? = nil
	if stats.idleAnim and stats.idleAnim ~= "" then
		idleTrack = ModelUtils.makeAnimTrack(animator, stats.idleAnim, Enum.AnimationPriority.Idle, true)
		idleTrack:Play()
	end
	local attackTrack: AnimationTrack? = nil
	if stats.attackAnim and stats.attackAnim ~= "" then
		attackTrack = ModelUtils.makeAnimTrack(animator, stats.attackAnim, Enum.AnimationPriority.Action)
	end
	return idleTrack, attackTrack
end

local function neutralizeHumanoid(model: Model): ()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid.PlatformStand = true
	humanoid.AutoRotate    = false
	humanoid.WalkSpeed     = 0
	humanoid.JumpPower     = 0
	humanoid.JumpHeight    = 0
end

local function spawnClientUnit(unitType: string, position: Vector3, placedAt: number): ()
	local stats = UnitConfig.UNITS[unitType]
	if not stats then return end
	local template = UnitsSrc:FindFirstChild(unitType)
	if not template then return end
	local showAttackFx = if stats.showAttackFx ~= nil then stats.showAttackFx else ClientConfig.SHOW_ATTACK_FX

	local model, hrp = ModelUtils.cloneAndPrepare(template, {
		castShadow     = false,
		canCollide     = false,
		canQuery       = false,
		canTouch       = false,
		collisionGroup = "Units",
		parts_anchored = false,
	})
	model.Name = unitType
	hrp.CFrame = CFrame.new(position)
	hrp.Anchored       = true
	hrp.CollisionGroup = "Units"

	neutralizeHumanoid(model)
	model.Parent = UnitsFolder

	local idleTrack, attackTrack = setupUnitAnimations(model, stats)

	local function playAttackAnim(): ()
		if not attackTrack then return end
		if idleTrack then idleTrack:Stop(0) end
		attackTrack:Play()
		task.delay(attackTrack.Length > 0 and attackTrack.Length or 0.5, function()
			if model.Parent then
				attackTrack:Stop(0)
				if idleTrack then idleTrack:Play() end
			end
		end)
	end

	local beamColor   = EFFECT_COLORS[stats.effect] or SHAPE_COLORS[stats.attackShape] or DEFAULT_BEAM_COLOR
	local shapeFn     = ATTACK_SHAPES[stats.attackShape]
	local interval    = 1 / stats.fireRate
	local elapsed     = workspace:GetServerTimeNow() - placedAt
	local firstWait   = interval - (elapsed % interval)
	task.wait(math.max(0, firstWait))

	while model.Parent do
		local nearest = selectTarget(hrp.Position, stats.range, stats.targeting or "first")
		if nearest then
			local dir = (nearest.model:GetPivot().Position - hrp.Position) * Vector3.new(1, 0, 1)
			if dir.Magnitude > 0.1 then
				hrp.CFrame = CFrame.new(hrp.Position, hrp.Position + dir.Unit)
			end
			task.spawn(playAttackAnim)

			if shapeFn then
				shapeFn({
					stats     = stats,
					hrp       = hrp,
					target    = nearest,
					targetPos = nearest.model:GetPivot().Position,
					attackDir = dir,
					showFx    = showAttackFx,
					beamColor = beamColor,
				})
			end
		end
		task.wait(interval)
	end

	if idleTrack then idleTrack:Stop() end
end

UnitPlaced.OnClientEvent:Connect(function(unitType: string, position: Vector3, placedAt: number)
	task.spawn(spawnClientUnit, unitType, position, placedAt)
end)
