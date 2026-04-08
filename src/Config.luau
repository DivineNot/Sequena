local Config = {
	Security = {
		KickSuspiciousClients = true,
		MaxRateLimitBytes = 30000,
		RateLimitWindow = 1.0,
		MaxEventsPerSecond = 61,
		MaxStringSize = 10000,
		MaxArraySize = 1000,
		MaxBufferSize = 1024 * 512,
		ValidateYieldIds = true,
	},
	Network = {
		CompressionThreshold = 512,
		MaxBatchSize = 7168,
		BaseBufferSize = 1024,
		DefaultReliable = true,
		DefaultTimeout = 10,
	},
	Debug = {
		LogWarnings = true,
	},
}

return Config