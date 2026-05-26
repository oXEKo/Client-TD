export type EnemyStats = {
	maxHp  : number,
	speed  : number,
	reward : number,
}

export type BatchConfig = {
	type     : string,
	count    : number,
	interval : number,
}

export type BossConfig = {
	type    : string,
	trigger : string,
	delay   : number?,
}

export type WaveConfig = { BatchConfig }

export type Config = {
	ENEMY_TYPES             : { [string]: EnemyStats },
	WAVES                   : { [number]: WaveConfig },
	WAVE_START_DELAY        : number,
	BETWEEN_WAVES_MIN_DELAY : number,
}

local config: Config = {
	ENEMY_TYPES = {
		["Small Enemy"]  = { maxHp = 60,   speed = 14, reward = 10  },
		["Normal Enemy"] = { maxHp = 180,  speed = 9,  reward = 25  },
		["Big Enemy"]    = { maxHp = 500,  speed = 5,  reward = 60  },
		["Boss Enemy"]   = { maxHp = 1200, speed = 4,  reward = 200 },
	},

	WAVES = {
		[1] = {
			{ type = "Small Enemy", count = 50, interval = 0.5 },
		},
		[2] = {
			{ type = "Small Enemy",  count = 6, interval = 1.2 },
			{ type = "Normal Enemy", count = 2, interval = 2.5 },
		},
		[3] = {
			{ type = "Normal Enemy", count = 5, interval = 1.5 },
			{ type = "Big Enemy",    count = 1, interval = 4.0 },
			boss = { type = "Boss Enemy", trigger = "after_all" },
		},
		[4] = {
			{ type = "Small Enemy",  count = 8, interval = 0.9 },
			{ type = "Normal Enemy", count = 4, interval = 1.5 },
		},
		[5] = {
			{ type = "Normal Enemy", count = 6, interval = 1.2 },
			{ type = "Big Enemy",    count = 3, interval = 3.0 },
			boss = { type = "Boss Enemy", trigger = "delay", delay = 20 },
		},
	},

	WAVE_START_DELAY        = 6,
	BETWEEN_WAVES_MIN_DELAY = 1,
}

return config
