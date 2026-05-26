--[[
	UnitConfigGuide — reference for UnitConfig.UNITS fields
	Not used in game logic, developer reference only.
]]

--[[
attackShape — attack shape of the unit

"single"
	Hits a single enemy — the one currently targeted.
	Visual effect: thin beam from the unit to the target.
	No additional fields required.

"aoe circle"
	Hits all enemies in a circle around the target.
	Circle center = position of the targeted enemy.
	Visual effect: disk flash around the target.
	Required fields:
		aoeRadius : number  — hit radius in studs

"full aoe"
	Hits all enemies within range studs from the unit itself.
	Visual effect: disk flash around the unit with radius = range.
	No additional fields required (uses the range field).

"conus"
	Hits all enemies in a cone in front of the unit.
	Unit rotates toward the nearest target before attacking.
	Visual effect: fan of 5 lines in the attack direction.
	Required fields:
		conusAngle : number  — half-angle in degrees (45 = full angle 90°)
]]

--[[
effect — status effect on hit

"none"
	No effect. Damage only.

"stun"
	Fully stops the enemy for stunDuration seconds.
	Visual: yellow block around the enemy.
	Required fields:
		stunDuration : number  — duration in seconds

"slow"
	Slows the enemy for slowDuration seconds.
	Speed is multiplied by slowAmount (0.0 = full stop, 1.0 = no slow).
	Visual: blue block around the enemy.
	Required fields:
		slowAmount   : number  — speed multiplier (0.0–1.0)
		slowDuration : number  — duration in seconds

"bleed"
	Red outline around the enemy. Damage tick rate is configured in UnitManager.
]]

--[[
targeting — target selection priority

"first"     Enemy furthest along the path (closest to the finish).
"last"      Enemy closest to the spawn point.
"nearest"   Enemy closest to the unit by distance.
"farthest"  Enemy farthest from the unit by distance.
"weak"      Enemy with the lowest current HP.
"stronger"  Enemy with the highest current HP.
"faster"    Fastest enemy (by base speed).
"slower"    Slowest enemy.
]]

--[[
Example of a full unit entry:

["Unit 4"] = {
	displayName  = "Sniper",
	damage       = 80,
	range        = 25,
	fireRate     = 0.6,
	cost         = 250,
	targeting    = "first",
	attackShape  = "single",
	effect       = "stun",
	stunDuration = 1.5,
	idleAnim     = "",
	attackAnim   = "",
},
]]

return {}