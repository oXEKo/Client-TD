local EnemyRegistry = {}

local activeEnemies: { [number]: any } = {}
local aliveCount: number               = 0

local clearedEvent: BindableEvent = Instance.new("BindableEvent")
EnemyRegistry.onCleared = clearedEvent.Event

function EnemyRegistry.add(id: number, enemy: any): ()
	if activeEnemies[id] then return end
	activeEnemies[id] = enemy
	aliveCount += 1
end

function EnemyRegistry.remove(id: number): ()
	if not activeEnemies[id] then return end
	activeEnemies[id] = nil
	aliveCount = math.max(0, aliveCount - 1)
	if aliveCount == 0 then
		clearedEvent:Fire()
	end
end

function EnemyRegistry.get(id: number): any?
	return activeEnemies[id]
end

function EnemyRegistry.all(): { [number]: any }
	return activeEnemies
end

function EnemyRegistry.count(): number
	return aliveCount
end

function EnemyRegistry.clear(): ()
	for id in activeEnemies do
		activeEnemies[id] = nil
	end
	aliveCount = 0
end

return EnemyRegistry
