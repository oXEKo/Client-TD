
export type PrepareOpts = {
	castShadow      : boolean?,
	collisionGroup  : string?,
	anchorHRP       : boolean?,
	canCollide      : boolean?,
	canQuery        : boolean?,
	canTouch        : boolean?,
	parts_anchored  : boolean?,
}

local ModelUtils = {}

function ModelUtils.cloneAndPrepare(template: Instance, opts: PrepareOpts): (Model, BasePart)
	local model = template:Clone() :: Model

	local animScript = model:FindFirstChild("Animate")
	if animScript then animScript:Destroy() end

	local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart
	hrp.Anchored   = true
	hrp.CanCollide = false
	model.PrimaryPart = hrp

	local castShadow      = if opts.castShadow      == nil then true  else opts.castShadow
	local canCollide      = if opts.canCollide      == nil then false else opts.canCollide
	local canQuery        = opts.canQuery
	local canTouch        = opts.canTouch
	local collisionGroup  = opts.collisionGroup
	local partsAnchored   = opts.parts_anchored

	for _, part in model:GetDescendants() do
		if not part:IsA("BasePart") then continue end
		local bp = part :: BasePart
		bp.CanCollide = canCollide
		bp.CastShadow = castShadow
		if canQuery       ~= nil then bp.CanQuery       = canQuery end
		if canTouch       ~= nil then bp.CanTouch       = canTouch end
		if collisionGroup ~= nil then bp.CollisionGroup = collisionGroup end
		if partsAnchored  ~= nil and bp ~= hrp then bp.Anchored = partsAnchored end
	end

	return model, hrp
end

function ModelUtils.makeAnimTrack(
	animator: Animator,
	assetId: string,
	priority: Enum.AnimationPriority?,
	looped: boolean?
): AnimationTrack
	local anim = Instance.new("Animation")
	anim.AnimationId = assetId
	local track = animator:LoadAnimation(anim)
	if priority then track.Priority = priority end
	if looped   ~= nil then track.Looped = looped end
	return track
end

return ModelUtils
