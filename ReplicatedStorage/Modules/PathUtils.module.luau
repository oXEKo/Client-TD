export type PathData = {
	waypoints      : { Vector3 },
	segmentLengths : { number },
	totalLength    : number,
}

local PathUtils = {}

function PathUtils.load(pathFolder: Folder): PathData
	local waypoints: { Vector3 } = {}
	for _, part in pathFolder:GetChildren() do
		local idx = tonumber(part.Name)
		if idx then
			local bp = part :: BasePart
			waypoints[idx] = bp.Position - Vector3.new(0, bp.Size.Y / 2, 0)
		end
	end
	local segmentLengths: { number } = {}
	local totalLength: number        = 0
	for i = 1, #waypoints - 1 do
		local len         = (waypoints[i + 1] - waypoints[i]).Magnitude
		segmentLengths[i] = len
		totalLength      += len
	end
	return { waypoints = waypoints, segmentLengths = segmentLengths, totalLength = totalLength }
end

function PathUtils.getPosition(data: PathData, distance: number): (Vector3?, Vector3?)
	local traveled: number = 0
	for i = 1, #data.waypoints - 1 do
		local segLen = data.segmentLengths[i]
		if distance <= traveled + segLen then
			local t   = (distance - traveled) / segLen
			local pos = data.waypoints[i]:Lerp(data.waypoints[i + 1], t)
			local dir = (data.waypoints[i + 1] - data.waypoints[i]).Unit
			return pos, dir
		end
		traveled += segLen
	end
	return nil, nil
end

return PathUtils
