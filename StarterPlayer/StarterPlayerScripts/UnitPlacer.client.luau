local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules    = ReplicatedStorage:WaitForChild("Modules")
local UnitConfig = require(Modules:WaitForChild("UnitConfig"))

local Events      = ReplicatedStorage:WaitForChild("Events")
local PlaceUnit   = Events:WaitForChild("PlaceUnit")
local UnitPlaced  = Events:WaitForChild("UnitPlaced")
local GoldUpdated = Events:WaitForChild("GoldUpdated")
local PlayerReady = Events:WaitForChild("PlayerReady")

local unitsSrc = ReplicatedStorage:WaitForChild("Units")

local localPlayer = Players.LocalPlayer
local mouse       = localPlayer:GetMouse()
local camera      = workspace.CurrentCamera

local playerGui  = localPlayer:WaitForChild("PlayerGui")
local screenGui  = playerGui:WaitForChild("ScreenGui")
local hud        = screenGui:WaitForChild("Hud")
local moneyLabel = screenGui:WaitForChild("Money")

local UNIT_ORDER: { string }       = { "Unit 1", "Unit 2", "Unit 3" }
local KEYBINDS:   { Enum.KeyCode } = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
}

local SLOT_X: { number } = { 1/6, 1/2, 5/6 }
local SLOT_W = 0.30
local SLOT_H = 0.88

local COL_STROKE_NORMAL   = Color3.fromRGB(80,  80,  80)
local COL_STROKE_SELECTED = Color3.fromRGB(80, 220, 120)
local COL_STROKE_BROKE    = Color3.fromRGB(220, 80,  80)

local selectedUnit:    string?      = nil
local ghost:           Model?       = nil
local isValid:         boolean      = false
local lastResult:      RaycastResult? = nil
local currentGold:     number       = UnitConfig.START_GOLD
local placedPositions: { Vector3 }  = {}

moneyLabel.Text = tostring(UnitConfig.START_GOLD) .. "$"

for i, unitName in UNIT_ORDER do
	local button = hud:FindFirstChild(unitName)
	if not button then continue end

	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position    = UDim2.new(SLOT_X[i], 0, 0.5, 0)
	button.Size        = UDim2.new(SLOT_W, 0, SLOT_H, 0)

	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color     = COL_STROKE_NORMAL
		stroke.Thickness = 1.5
	end

	local priceLabel = button:FindFirstChild("Price")
	local stats      = UnitConfig.UNITS[unitName]
	if priceLabel then
		(priceLabel :: TextLabel).Text = tostring(stats.cost)
	end

	local vp: ViewportFrame = button:FindFirstChildOfClass("ViewportFrame") :: ViewportFrame
	if not vp then continue end

	local cam: Camera = (vp.CurrentCamera or vp:FindFirstChild("Camera")) :: Camera
	if not cam then
		cam        = Instance.new("Camera")
		cam.Parent = vp
	end
	vp.CurrentCamera = cam

	local src = unitsSrc:FindFirstChild(unitName)
	if src then
		local clone: Model = src:Clone() :: Model
		for _, child in clone:GetDescendants() do
			if child:IsA("BaseScript") then child:Destroy() end
		end
		clone:PivotTo(CFrame.new(0, -2, 0))
		clone.Parent = vp
		cam.CFrame   = CFrame.new(Vector3.new(0, 1.5, 4.5), Vector3.new(0, 0.5, 0))
	end
end

local hudTarget = hud.Position
hud.Position    = UDim2.new(hudTarget.X.Scale, hudTarget.X.Offset, 1.18, 0)
TweenService:Create(hud,
	TweenInfo.new(0.65, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	{ Position = hudTarget }
):Play()

for i, unitName in UNIT_ORDER do
	local btn = hud:FindFirstChild(unitName) :: GuiButton
	if not btn then continue end
	btn.BackgroundTransparency = 1
	task.delay(0.25 + (i - 1) * 0.1, function()
		TweenService:Create(btn,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 0 }
		):Play()
	end)
end

local function updateStrokes(activeUnit: string?): ()
	for _, unitName in UNIT_ORDER do
		local btn    = hud:FindFirstChild(unitName)
		local stroke = btn and btn:FindFirstChildOfClass("UIStroke")
		if not stroke then continue end
		if unitName == activeUnit then
			local stats     = UnitConfig.UNITS[unitName]
			local canAfford = currentGold >= stats.cost
			stroke.Color     = canAfford and COL_STROKE_SELECTED or COL_STROKE_BROKE
			stroke.Thickness = 3
		else
			stroke.Color     = COL_STROKE_NORMAL
			stroke.Thickness = 1.5
		end
	end
end

local function destroyGhost(): ()
	if ghost then ghost:Destroy(); ghost = nil end
	isValid    = false
	lastResult = nil
end

local function selectUnit(unitName: string): ()
	if selectedUnit == unitName then
		selectedUnit = nil
		destroyGhost()
		updateStrokes(nil)
		return
	end
	selectedUnit = unitName
	destroyGhost()
	local src = unitsSrc:FindFirstChild(unitName)
	if src then
		local clone: Model = src:Clone() :: Model
		for _, p in clone:GetDescendants() do
			if p:IsA("BaseScript") then p:Destroy() end
			if p:IsA("BasePart") then
				local bp = p :: BasePart
				bp.CanCollide   = false
				bp.Anchored     = true
				bp.CastShadow   = false
				bp.Transparency = 0.5
			end
		end
		local h = clone:FindFirstChildOfClass("Humanoid")
		if h then h:Destroy() end
		clone.Parent = workspace
		ghost = clone
	end
	updateStrokes(unitName)
end

for _, unitName in UNIT_ORDER do
	local btn = hud:FindFirstChild(unitName)
	if not btn then continue end
	;(btn :: TextButton).MouseButton1Click:Connect(function()
		selectUnit(unitName)
	end)
end

GoldUpdated.OnClientEvent:Connect(function(gold: number)
	currentGold     = gold
	moneyLabel.Text = tostring(gold) .. "$"
	if selectedUnit then updateStrokes(selectedUnit) end
end)

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

RunService.RenderStepped:Connect(function()
	if not selectedUnit or not ghost then return end

	local unitRay              = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local exclude: { Instance } = {}
	local unitsF       = workspace:FindFirstChild("Units")
	local markersF     = workspace:FindFirstChild("EnemyMarkers")
	local clientUnitsF = workspace:FindFirstChild("ClientUnits")
	local enemiesF     = workspace:FindFirstChild("Enemies")
	if unitsF       then table.insert(exclude, unitsF)       end
	if markersF     then table.insert(exclude, markersF)     end
	if clientUnitsF then table.insert(exclude, clientUnitsF) end
	if enemiesF     then table.insert(exclude, enemiesF)     end
	table.insert(exclude, ghost)
	local char = localPlayer.Character
	if char then table.insert(exclude, char) end
	rayParams.FilterDescendantsInstances = exclude

	local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 500, rayParams)
	lastResult = result

	if result then
		local onRoad    = result.Instance.Name == "Road"
		local canAfford = currentGold >= UnitConfig.UNITS[selectedUnit].cost
		local placePos  = result.Position + Vector3.new(0, 3, 0)
		local tooClose  = false
		for _, pos in placedPositions do
			if (placePos - pos).Magnitude < 3 then tooClose = true; break end
		end
		isValid         = not onRoad and canAfford and not tooClose
		ghost:PivotTo(CFrame.new(placePos))

		local col = isValid and Color3.fromRGB(0, 200, 0)
			or tooClose             and Color3.fromRGB(200, 0, 0)
			or (not canAfford)      and Color3.fromRGB(220, 160, 0)
			or  Color3.fromRGB(200, 0, 0)
		for _, p in ghost:GetDescendants() do
			if p:IsA("BasePart") then (p :: BasePart).Color = col end
		end
	else
		isValid = false
	end
end)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end

	for i, keyCode in KEYBINDS do
		if input.KeyCode == keyCode then
			selectUnit(UNIT_ORDER[i])
			return
		end
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if not selectedUnit or not ghost or not isValid or not lastResult then return end
		PlaceUnit:FireServer(selectedUnit, lastResult.Position)
		selectedUnit = nil
		destroyGhost()
		updateStrokes(nil)

	elseif input.UserInputType == Enum.UserInputType.MouseButton2
		or  input.KeyCode == Enum.KeyCode.Escape then
		selectedUnit = nil
		destroyGhost()
		updateStrokes(nil)
	end
end)

UnitPlaced.OnClientEvent:Connect(function(_unitType: string, position: Vector3)
	table.insert(placedPositions, position)
end)

PlayerReady:FireServer()
