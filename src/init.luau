--!native
--!optimize 2

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Config = require(script:FindFirstChild("Config"))
local LZAV = assert(script:FindFirstChild("LZAV"), "LZAV module not found")
LZAV = require(LZAV)

type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
type Signal<T...> = {
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
}

local function CreateSignal<T...>(): Signal<T...>
	local Bindable = Instance.new("BindableEvent")
	local Self = {}
	function Self:Connect(Callback) return Bindable.Event:Connect(Callback) end
	function Self:Once(Callback) return Bindable.Event:Once(Callback) end
	function Self:Fire(...) Bindable:Fire(...) end
	function Self:Wait() return Bindable.Event:Wait() end
	return Self :: any
end

export type Cursor = {
	Buffer: buffer,
	BufferLength: number,
	BufferOffset: number,
	Instances: {Instance},
	InstancesOffset: number,
}

local ActiveCursor: Cursor
local ActiveBuffer: buffer
local BufferLength: number
local BufferOffset: number
local Instances: {Instance}
local InstancesOffset: number

local TypeReads = {}
local TypeWrites = {}

local MAX_BUFFER_SIZE = Config.Security.MaxBufferSize
local BASE_BUFFER_SIZE = Config.Network.BaseBufferSize
local RATE_LIMIT_WINDOW = Config.Security.RateLimitWindow
local RATE_LIMIT_BYTES = Config.Security.MaxRateLimitBytes
local MAX_BATCH_SIZE = Config.Network.MaxBatchSize
local COMPRESSION_THRESHOLD = Config.Network.CompressionThreshold
local MAX_STRING_SIZE = Config.Security.MaxStringSize
local MAX_ARRAY_SIZE = Config.Security.MaxArraySize

local DeltaCache: {[number]: {Cache: {[any]: {any}}, LRU: {any}, Size: number}} = {}
local InboundDeltaCache: {[number]: {[any]: {any}}} = {}

local function Allocate(Bytes: number)
	local Target = BufferOffset + Bytes
	if BufferLength < Target then
		if Target > MAX_BUFFER_SIZE then
			error(`Buffer overflow: trying to allocate {Target} bytes (max: {MAX_BUFFER_SIZE})`)
		end
		while BufferLength < Target do BufferLength *= 2 end
		if BufferLength > MAX_BUFFER_SIZE then BufferLength = MAX_BUFFER_SIZE end
		local New = buffer.create(BufferLength)
		buffer.copy(New, 0, ActiveBuffer, 0, BufferOffset)
		ActiveCursor.Buffer = New
		ActiveBuffer = New
	end
end

local function ReadU8()
	if BufferOffset + 1 > BufferLength then error("Buffer underflow") end
	local V = buffer.readu8(ActiveBuffer, BufferOffset)
	BufferOffset += 1
	return V
end

local function WriteU8(V: number) buffer.writeu8(ActiveBuffer, BufferOffset, V) BufferOffset += 1 end
local function ReadU16()
	if BufferOffset + 2 > BufferLength then error("Buffer underflow") end
	local V = buffer.readu16(ActiveBuffer, BufferOffset)
	BufferOffset += 2
	return V
end
local function WriteU16(V: number) buffer.writeu16(ActiveBuffer, BufferOffset, V) BufferOffset += 2 end
local function ReadU32()
	if BufferOffset + 4 > BufferLength then error("Buffer underflow") end
	local V = buffer.readu32(ActiveBuffer, BufferOffset)
	BufferOffset += 4
	return V
end
local function WriteU32(V: number) buffer.writeu32(ActiveBuffer, BufferOffset, V) BufferOffset += 4 end
local function ReadI8()
	if BufferOffset + 1 > BufferLength then error("Buffer underflow") end
	local V = buffer.readi8(ActiveBuffer, BufferOffset)
	BufferOffset += 1
	return V
end
local function WriteI8(V: number) buffer.writei8(ActiveBuffer, BufferOffset, V) BufferOffset += 1 end
local function ReadI16()
	if BufferOffset + 2 > BufferLength then error("Buffer underflow") end
	local V = buffer.readi16(ActiveBuffer, BufferOffset)
	BufferOffset += 2
	return V
end
local function WriteI16(V: number) buffer.writei16(ActiveBuffer, BufferOffset, V) BufferOffset += 2 end
local function ReadI32()
	if BufferOffset + 4 > BufferLength then error("Buffer underflow") end
	local V = buffer.readi32(ActiveBuffer, BufferOffset)
	BufferOffset += 4
	return V
end
local function WriteI32(V: number) buffer.writei32(ActiveBuffer, BufferOffset, V) BufferOffset += 4 end
local function ReadF32()
	if BufferOffset + 4 > BufferLength then error("Buffer underflow") end
	local V = buffer.readf32(ActiveBuffer, BufferOffset)
	BufferOffset += 4
	return V
end
local function WriteF32(V: number) buffer.writef32(ActiveBuffer, BufferOffset, V) BufferOffset += 4 end
local function ReadF64()
	if BufferOffset + 8 > BufferLength then error("Buffer underflow") end
	local V = buffer.readf64(ActiveBuffer, BufferOffset)
	BufferOffset += 8
	return V
end
local function WriteF64(V: number) buffer.writef64(ActiveBuffer, BufferOffset, V) BufferOffset += 8 end
local function ReadString(Len: number)
	if BufferOffset + Len > BufferLength then error("Buffer underflow") end
	local V = buffer.readstring(ActiveBuffer, BufferOffset, Len)
	BufferOffset += Len
	return V
end
local function WriteString(V: string) buffer.writestring(ActiveBuffer, BufferOffset, V) BufferOffset += #V end
local function ReadInstance()
	InstancesOffset += 1
	return Instances[InstancesOffset]
end
local function WriteInstance(V: Instance)
	InstancesOffset += 1
	Instances[InstancesOffset] = V
end

local TYPE_NIL = 0
local TYPE_BOOL = 1
local TYPE_NUMBER = 2
local TYPE_STRING = 3
local TYPE_BUFFER = 4
local TYPE_VECTOR2 = 5
local TYPE_VECTOR3 = 6
local TYPE_CFRAME = 7
local TYPE_COLOR3 = 8
local TYPE_INSTANCE = 12
local TYPE_ENUM = 13
local TYPE_TABLE = 16
local TYPE_INT_U8 = 17
local TYPE_INT_U16 = 18
local TYPE_INT_U32 = 19
local TYPE_INT_I16 = 20
local TYPE_INT_I32 = 21

local EnumCache = {} :: {[EnumItem]: string}
local StringToEnumCache = {} :: {[string]: EnumItem}

TypeReads.U8 = ReadU8
TypeWrites.U8 = function(V) Allocate(1) WriteU8(V) end
TypeReads.U16 = ReadU16
TypeWrites.U16 = function(V) Allocate(2) WriteU16(V) end
TypeReads.U32 = ReadU32
TypeWrites.U32 = function(V) Allocate(4) WriteU32(V) end
TypeReads.I8 = ReadI8
TypeWrites.I8 = function(V) Allocate(1) WriteI8(V) end
TypeReads.I16 = ReadI16
TypeWrites.I16 = function(V) Allocate(2) WriteI16(V) end
TypeReads.I32 = ReadI32
TypeWrites.I32 = function(V) Allocate(4) WriteI32(V) end
TypeReads.F32 = ReadF32
TypeWrites.F32 = function(V) Allocate(4) WriteF32(V) end
TypeReads.F64 = ReadF64
TypeWrites.F64 = function(V) Allocate(8) WriteF64(V) end
TypeReads.Bool = function() return ReadU8() == 1 end
TypeWrites.Bool = function(V) Allocate(1) WriteU8(if V then 1 else 0) end

local function ReadVarInt(): number
	local C = 0
	local V = 0
	local B
	repeat
		B = buffer.readu8(ActiveBuffer, BufferOffset)
		BufferOffset += 1
		V = bit32.bor(V, bit32.lshift(bit32.band(B, 0x7F), C))
		C += 7
	until bit32.band(B, 0x80) == 0
	return V
end

local function WriteVarInt(V: number)
	while V >= 128 do
		buffer.writeu8(ActiveBuffer, BufferOffset, bit32.bor(V, 0x80))
		BufferOffset += 1
		V = bit32.rshift(V, 7)
	end
	buffer.writeu8(ActiveBuffer, BufferOffset, V)
	BufferOffset += 1
end

TypeReads.String = function()
	local Len = ReadVarInt()
	if Len > MAX_STRING_SIZE then error(`String too long: {Len} > {MAX_STRING_SIZE}`) end
	return ReadString(Len)
end
TypeWrites.String = function(V)
	local L = #V
	Allocate(5 + L)
	WriteVarInt(L)
	WriteString(V)
end

TypeReads.Buffer = function()
	local Len = ReadVarInt()
	if Len > MAX_BUFFER_SIZE then error(`Buffer too large: {Len}`) end
	local B = buffer.create(Len)
	buffer.copy(B, 0, ActiveBuffer, BufferOffset, Len)
	BufferOffset += Len
	return B
end
TypeWrites.Buffer = function(V: buffer)
	local Len = buffer.len(V)
	Allocate(5 + Len)
	WriteVarInt(Len)
	buffer.copy(ActiveBuffer, BufferOffset, V, 0, Len)
	BufferOffset += Len
end

TypeReads.Vector3 = function() return Vector3.new(ReadF32(), ReadF32(), ReadF32()) end
TypeWrites.Vector3 = function(V: Vector3) Allocate(12) WriteF32(V.X) WriteF32(V.Y) WriteF32(V.Z) end
TypeReads.Vector2 = function() return Vector2.new(ReadF32(), ReadF32()) end
TypeWrites.Vector2 = function(V: Vector2) Allocate(8) WriteF32(V.X) WriteF32(V.Y) end

TypeReads.CFrame = function()
	local Px, Py, Pz = ReadF32(), ReadF32(), ReadF32()
	local Qw, Qx, Qy, Qz = ReadF32(), ReadF32(), ReadF32(), ReadF32()
	local Xx, Yy, Zz = Qx * Qx, Qy * Qy, Qz * Qz
	local Xy, Xz, Yz = Qx * Qy, Qx * Qz, Qy * Qz
	local Wx, Wy, Wz = Qw * Qx, Qw * Qy, Qw * Qz
	return CFrame.new(Px, Py, Pz,
		1 - 2 * (Yy + Zz), 2 * (Xy - Wz), 2 * (Xz + Wy),
		2 * (Xy + Wz), 1 - 2 * (Xx + Zz), 2 * (Yz - Wx),
		2 * (Xz - Wy), 2 * (Yz + Wx), 1 - 2 * (Xx + Yy))
end
TypeWrites.CFrame = function(V: CFrame)
	Allocate(28)
	local X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = V:GetComponents()
	local Trace = R00 + R11 + R22
	local Qw, Qx, Qy, Qz
	if Trace > 0 then
		local S = math.sqrt(Trace + 1) * 2
		Qw, Qx, Qy, Qz = 0.25 * S, (R21 - R12) / S, (R02 - R20) / S, (R10 - R01) / S
	else
		if R00 > R11 and R00 > R22 then
			local S = math.sqrt(1 + R00 - R11 - R22) * 2
			Qw, Qx, Qy, Qz = (R21 - R12) / S, 0.25 * S, (R01 + R10) / S, (R02 + R20) / S
		elseif R11 > R22 then
			local S = math.sqrt(1 + R11 - R00 - R22) * 2
			Qw, Qx, Qy, Qz = (R02 - R20) / S, (R01 + R10) / S, 0.25 * S, (R12 + R21) / S
		else
			local S = math.sqrt(1 + R22 - R00 - R11) * 2
			Qw, Qx, Qy, Qz = (R10 - R01) / S, (R02 + R20) / S, (R12 + R21) / S, 0.25 * S
		end
	end
	WriteF32(X) WriteF32(Y) WriteF32(Z)
	WriteF32(Qw) WriteF32(Qx) WriteF32(Qy) WriteF32(Qz)
end

TypeReads.Color3 = function()
	return Color3.fromRGB(ReadU8(), ReadU8(), ReadU8())
end
TypeWrites.Color3 = function(V: Color3)
	Allocate(3)
	WriteU8(math.floor(V.R * 255))
	WriteU8(math.floor(V.G * 255))
	WriteU8(math.floor(V.B * 255))
end

TypeReads.Instance = ReadInstance
TypeWrites.Instance = WriteInstance

TypeReads.Enum = function(): EnumItem?
	local Str = TypeReads.String()
	local V = StringToEnumCache[Str]
	if V then return V end
	local Parts = string.split(Str, ".")
	if #Parts == 3 and Parts[1] == "Enum" then
		local EnumName = Parts[2]
		local ItemName = Parts[3]
		local Enum = (Enum :: any)[EnumName]
		if Enum then
			local Item = Enum[ItemName]
			if Item then
				StringToEnumCache[Str] = Item
				return Item
			end
		end
	end
	return nil
end
TypeWrites.Enum = function(V: EnumItem)
	local Str = EnumCache[V]
	if not Str then
		Str = tostring(V)
		EnumCache[V] = Str
	end
	TypeWrites.String(Str)
end

local Types = setmetatable({}, {
	__index = function(_, K) return K end,
})
Types.Array = function(InnerType: string, MaxSize: number?)
	local ReadFunc = TypeReads[InnerType]
	local WriteFunc = TypeWrites[InnerType]
	local Max = MaxSize or MAX_ARRAY_SIZE
	return {
		Read = function()
			local Len = ReadU16()
			if Len > Max then error(`Array exceeds max size: {Len} > {Max}`) end
			local Arr = table.create(Len)
			for I = 1, Len do
				Arr[I] = ReadFunc()
			end
			return Arr
		end,
		Write = function(V)
			local Len = math.min(#V, Max)
			Allocate(2)
			WriteU16(Len)
			for I = 1, Len do
				WriteFunc(V[I])
			end
		end
	}
end
Types.Optional = function(InnerType: string)
	local ReadFunc = TypeReads[InnerType]
	local WriteFunc = TypeWrites[InnerType]
	return {
		Read = function()
			if ReadU8() == 1 then
				return ReadFunc()
			end
			return nil
		end,
		Write = function(V)
			if V == nil then
				Allocate(1)
				WriteU8(0)
			else
				Allocate(1)
				WriteU8(1)
				WriteFunc(V)
			end
		end
	}
end
Types.Enum = function(Values: {string})
	local ValueToIndex = {}
	for I, V in Values do
		ValueToIndex[V] = I - 1
	end
	return {
		Read = function()
			return Values[ReadU8() + 1]
		end,
		Write = function(V)
			local Idx = ValueToIndex[V]
			if not Idx then error(`Invalid enum value: {V}`) end
			Allocate(1)
			WriteU8(Idx)
		end
	}
end

local function WriteAny(V: any)
	local T = typeof(V)
	if T == "nil" then
		Allocate(1)
		WriteU8(TYPE_NIL)
	elseif T == "boolean" then
		Allocate(2)
		WriteU8(TYPE_BOOL)
		WriteU8(if V then 1 else 0)
	elseif T == "number" then
		if V % 1 == 0 then
			if V >= 0 then
				if V <= 255 then
					Allocate(2)
					WriteU8(TYPE_INT_U8)
					WriteU8(V)
				elseif V <= 65535 then
					Allocate(3)
					WriteU8(TYPE_INT_U16)
					WriteU16(V)
				elseif V <= 4294967295 then
					Allocate(5)
					WriteU8(TYPE_INT_U32)
					WriteU32(V)
				else
					Allocate(9)
					WriteU8(TYPE_NUMBER)
					WriteF64(V)
				end
			else
				if V >= -32768 and V <= 32767 then
					Allocate(3)
					WriteU8(TYPE_INT_I16)
					WriteI16(V)
				elseif V >= -2147483648 and V <= 2147483647 then
					Allocate(5)
					WriteU8(TYPE_INT_I32)
					WriteI32(V)
				else
					Allocate(9)
					WriteU8(TYPE_NUMBER)
					WriteF64(V)
				end
			end
		else
			Allocate(9)
			WriteU8(TYPE_NUMBER)
			WriteF64(V)
		end
	elseif T == "string" then
		Allocate(1)
		WriteU8(TYPE_STRING)
		TypeWrites.String(V)
	elseif T == "buffer" then
		Allocate(1)
		WriteU8(TYPE_BUFFER)
		TypeWrites.Buffer(V)
	elseif T == "Vector2" then
		Allocate(9)
		WriteU8(TYPE_VECTOR2)
		TypeWrites.Vector2(V)
	elseif T == "Vector3" then
		Allocate(13)
		WriteU8(TYPE_VECTOR3)
		TypeWrites.Vector3(V)
	elseif T == "CFrame" then
		Allocate(29)
		WriteU8(TYPE_CFRAME)
		TypeWrites.CFrame(V)
	elseif T == "Color3" then
		Allocate(4)
		WriteU8(TYPE_COLOR3)
		TypeWrites.Color3(V)
	elseif T == "Instance" then
		Allocate(1)
		WriteU8(TYPE_INSTANCE)
		WriteInstance(V)
	elseif T == "EnumItem" then
		Allocate(1)
		WriteU8(TYPE_ENUM)
		TypeWrites.Enum(V)
	elseif T == "table" then
		Allocate(1)
		WriteU8(TYPE_TABLE)
		for K, Val in pairs(V) do
			WriteAny(K)
			WriteAny(Val)
		end
		Allocate(1)
		WriteU8(TYPE_NIL)
	else
		if Config.Debug.LogWarnings then
			warn("Unsupported type: " .. T)
		end
		Allocate(1)
		WriteU8(TYPE_NIL)
	end
end

local function ReadAny(): any
	local TypeId = ReadU8()
	if TypeId == TYPE_NIL then return nil
	elseif TypeId == TYPE_BOOL then return ReadU8() == 1
	elseif TypeId == TYPE_NUMBER then return ReadF64()
	elseif TypeId == TYPE_STRING then return TypeReads.String()
	elseif TypeId == TYPE_BUFFER then return TypeReads.Buffer()
	elseif TypeId == TYPE_VECTOR2 then return TypeReads.Vector2()
	elseif TypeId == TYPE_VECTOR3 then return TypeReads.Vector3()
	elseif TypeId == TYPE_CFRAME then return TypeReads.CFrame()
	elseif TypeId == TYPE_COLOR3 then return TypeReads.Color3()
	elseif TypeId == TYPE_INSTANCE then return ReadInstance()
	elseif TypeId == TYPE_ENUM then return TypeReads.Enum()
	elseif TypeId == TYPE_TABLE then
		local T = {}
		repeat
			local K = ReadAny()
			if K == nil then break end
			T[K] = ReadAny()
		until false
		return T
	elseif TypeId == TYPE_INT_U8 then return ReadU8()
	elseif TypeId == TYPE_INT_U16 then return ReadU16()
	elseif TypeId == TYPE_INT_U32 then return ReadU32()
	elseif TypeId == TYPE_INT_I16 then return ReadI16()
	elseif TypeId == TYPE_INT_I32 then return ReadI32()
	end
	return nil
end

TypeReads.Any = ReadAny
TypeWrites.Any = WriteAny

local function Import(Cursor: Cursor)
	ActiveCursor = Cursor
	ActiveBuffer = Cursor.Buffer
	BufferLength = Cursor.BufferLength
	BufferOffset = Cursor.BufferOffset
	Instances = Cursor.Instances
	InstancesOffset = Cursor.InstancesOffset
end

local function Export()
	ActiveCursor.BufferLength = BufferLength
	ActiveCursor.BufferOffset = BufferOffset
	ActiveCursor.InstancesOffset = InstancesOffset
	return ActiveCursor
end

local function Truncate()
	local Trun = buffer.create(BufferOffset)
	buffer.copy(Trun, 0, ActiveBuffer, 0, BufferOffset)
	return Trun, if InstancesOffset == 0 then nil else Instances
end

local function ResetCursor(Cursor: Cursor)
	Cursor.BufferOffset = 0
	Cursor.InstancesOffset = 0
	table.clear(Cursor.Instances)
	if Cursor.BufferLength > BASE_BUFFER_SIZE * 4 then
		Cursor.Buffer = buffer.create(BASE_BUFFER_SIZE)
		Cursor.BufferLength = BASE_BUFFER_SIZE
	end
end

local function ComputeDelta(PacketId: number, Target: any, Args: {any}, UseDelta: boolean): {any}?
	if not UseDelta then
		return Args
	end
	local CacheEntry = DeltaCache[PacketId]
	if not CacheEntry then
		CacheEntry = { Cache = {}, LRU = {}, Size = 0 }
		DeltaCache[PacketId] = CacheEntry
	end
	local Cache = CacheEntry.Cache
	local LRU = CacheEntry.LRU
	local LastData = Cache[Target]
	if not LastData then
		Cache[Target] = table.clone(Args)
		LRU[#LRU + 1] = Target
		CacheEntry.Size += 1
		if CacheEntry.Size > 1000 then
			local Oldest = LRU[1]
			table.remove(LRU, 1)
			Cache[Oldest] = nil
			CacheEntry.Size -= 1
		end
		return Args
	end
	for I = 1, #Args do
		if Args[I] ~= LastData[I] then
			Cache[Target] = table.clone(Args)
			for I, V in LRU do
				if V == Target then
					table.remove(LRU, I)
					break
				end
			end
			LRU[#LRU + 1] = Target
			return Args
		end
	end
	return nil
end

local function ApplyDelta(_LastData: {any}?, Delta: {any}): {any}
	return Delta
end

export type RequestResponse<A..., B...> = {
	RequestSchema: {any},
	ResponseSchema: {any},
	Timeout: number,
}

export type Packet<A..., B...> = {
	Id: number,
	Name: string?,
	Reliable: boolean,
	UseDelta: boolean,
	RequestResponse: RequestResponse<A..., B...>?,
	OnServerEvent: Signal<(Player, A...)>,
	OnClientEvent: Signal<A...>,
	OnServerInvoke: ((Player: Player, A...) -> B...)?,
	OnClientInvoke: ((A...) -> B...)?,
	Fire: (Self: Packet<A..., B...>, A...) -> B...,
	FireClient: (Self: Packet<A..., B...>, Player: Player, A...) -> B...,
	FireAllClients: (Self: Packet<A..., B...>, A...) -> (),
	SetRequestResponse: (Self: Packet<A..., B...>, ResponseSchema: {any}, Timeout: number?) -> Packet<A..., B...>,
}

local Sequena = { Types = Types, Config = Config }
local Registry: { [number]: any } = {}
local NameRegistry: { [string]: number } = {}
local PacketCount = 0

local ReliableRemote: RemoteEvent
local UnreliableRemote: UnreliableRemoteEvent

type WriterMap = {[Player | string]: Cursor}
local PlayerReliableCursors: WriterMap = {}
local PlayerUnreliableCursors: WriterMap = {}
local BroadcastReliableCursor: Cursor? = nil
local BroadcastUnreliableCursor: Cursor? = nil

local PlayerYields: { [Player]: { [number]: { Thread: thread, Timeout: thread? } } } = {}
local ClientYields: { [number]: { Thread: thread, Timeout: thread? } } = {}
local YieldIndex = 0

local PlayerRateLimits: { [Player]: { Bytes: number, LastReset: number } } = {}
local PlayerEventCounts: { [Player]: { Count: number, Reset: number } } = {}

local function CreateCursor(): Cursor
	return {
		Buffer = buffer.create(BASE_BUFFER_SIZE),
		BufferLength = BASE_BUFFER_SIZE,
		BufferOffset = 0,
		Instances = {},
		InstancesOffset = 0
	}
end

local SERVER_KEY = "SERVER"

if RunService:IsServer() then
	ReliableRemote = Instance.new("RemoteEvent")
	ReliableRemote.Name = "S_R"
	ReliableRemote.Parent = script
	UnreliableRemote = Instance.new("UnreliableRemoteEvent")
	UnreliableRemote.Name = "S_U"
	UnreliableRemote.Parent = script
else
	ReliableRemote = script:WaitForChild("S_R", 10) :: RemoteEvent
	if not ReliableRemote then error("Failed to find ReliableRemote") end
	UnreliableRemote = script:WaitForChild("S_U", 10) :: UnreliableRemoteEvent
	if not UnreliableRemote then error("Failed to find UnreliableRemote") end
end

local function GetCursor(Player: Player?, Reliable: boolean): Cursor
	if RunService:IsServer() then
		if not Player then
			if Reliable then
				if not BroadcastReliableCursor then
					BroadcastReliableCursor = CreateCursor()
				end
				return BroadcastReliableCursor
			else
				if not BroadcastUnreliableCursor then
					BroadcastUnreliableCursor = CreateCursor()
				end
				return BroadcastUnreliableCursor
			end
		end
		local Cursors = if Reliable then PlayerReliableCursors else PlayerUnreliableCursors
		if not Cursors[Player] then
			Cursors[Player] = CreateCursor()
		end
		return Cursors[Player]
	else
		local Cursors = if Reliable then PlayerReliableCursors else PlayerUnreliableCursors
		local Cursor = Cursors[SERVER_KEY]
		if not Cursor then
			Cursor = CreateCursor()
			Cursors[SERVER_KEY] = Cursor
		end
		return Cursor
	end
end

local function CheckRateLimit(Player: Player, Bytes: number): boolean
	local Limit = PlayerRateLimits[Player]
	local Now = os.clock()
	if not Limit then
		PlayerRateLimits[Player] = { Bytes = Bytes, LastReset = Now }
		return true
	end
	if Now - Limit.LastReset >= RATE_LIMIT_WINDOW then
		Limit.Bytes = Bytes
		Limit.LastReset = Now
		return true
	end
	if Limit.Bytes + Bytes > RATE_LIMIT_BYTES then
		return false
	end
	Limit.Bytes += Bytes
	return true
end

local function CheckEventRate(Player: Player): boolean
	local Now = os.clock()
	local Data = PlayerEventCounts[Player]
	if not Data or Now - Data.Reset >= 1 then
		PlayerEventCounts[Player] = { Count = 1, Reset = Now }
		return true
	end
	Data.Count += 1
	if Data.Count > Config.Security.MaxEventsPerSecond then
		return false
	end
	return true
end

local function PrepareSchema(Schema: {any}): ({any}, {any})
	local N = #Schema
	local ReadFuncs = table.create(N)
	local WriteFuncs = table.create(N)
	for I = 1, N do
		local Item = Schema[I]
		if type(Item) == "string" then
			ReadFuncs[I] = TypeReads[Item]
			WriteFuncs[I] = TypeWrites[Item]
		elseif type(Item) == "table" and Item.Read and Item.Write then
			ReadFuncs[I] = Item.Read
			WriteFuncs[I] = Item.Write
		else
			error("Invalid schema item")
		end
	end
	return ReadFuncs, WriteFuncs
end

local function CompressBuffer(B: buffer): (buffer, boolean)
	if buffer.len(B) > COMPRESSION_THRESHOLD then
		local Compressed = LZAV.compress(B)
		local FinalBuffer = buffer.create(buffer.len(Compressed) + 4)
		buffer.writeu32(FinalBuffer, 0, buffer.len(B))
		buffer.copy(FinalBuffer, 4, Compressed, 0, buffer.len(Compressed))
		return FinalBuffer, true
	end
	return B, false
end

local function DecompressBuffer(Incoming: buffer, Compressed: boolean): buffer
	if not Compressed then 
		return Incoming 
	end

	local incomingLen = buffer.len(Incoming)
	if incomingLen < 4 then
		error("Invalid compressed buffer: missing size header")
	end

	local DecompressedSize = buffer.readu32(Incoming, 0)

	-- known exploit, a "exploit" can set DecompressedSize to (eg.) 4,294,967,295 causing server memory overload
	if DecompressedSize > MAX_BUFFER_SIZE then
		error("Decompression size exceeds limit")
	end

	local payloadSize = incomingLen - 4

	-- prevents assert crash
	if payloadSize < 10 and DecompressedSize > 0 then
		error("Compressed payload too small for LZAV")
	end

	local CompressedData = buffer.create(payloadSize)
	if payloadSize > 0 then
		buffer.copy(CompressedData, 0, Incoming, 4, payloadSize)
	end

	return LZAV.decompress(CompressedData, DecompressedSize)
end

function Sequena.Define<A..., B...>(Schema: {any}, Reliable: boolean?, Name: string?, UseDelta: boolean?): Packet<A..., B...>
	local Id = PacketCount
	PacketCount += 1

	local Self = {} :: any
	Self.Id = Id
	Self.Name = Name
	Self.Reliable = if Reliable == nil then Config.Network.DefaultReliable else Reliable
	Self.UseDelta = UseDelta == true
	Self.OnServerEvent = CreateSignal()
	Self.OnClientEvent = CreateSignal()

	if Name then
		if NameRegistry[Name] then
			error(`Packet with name "{Name}" already exists`)
		end
		NameRegistry[Name] = Id
	end

	local ReadFuncs, WriteFuncs = PrepareSchema(Schema)

	function Self:SetRequestResponse(ResponseSchema: {any}, Timeout: number?)
		local RespRead, RespWrite = PrepareSchema(ResponseSchema)
		Self.RequestResponse = {
			RequestSchema = Schema,
			ResponseSchema = ResponseSchema,
			Timeout = Timeout or Config.Network.DefaultTimeout
		}
		Registry[Id].ResponseReadFuncs = RespRead
		Registry[Id].ResponseWriteFuncs = RespWrite
		return Self
	end

	function Self:Fire(...)
		local Cursor = GetCursor(nil, Self.Reliable)
		if Self.RequestResponse then
			if RunService:IsServer() then
				error("Server must use FireClient for request-response packets", 2)
			end
			local Args = {...}
			local YieldId = YieldIndex
			YieldIndex = (YieldIndex + 1) % 256
			local Thread = coroutine.running()
			local TimeoutThread = task.delay(Self.RequestResponse.Timeout, function()
				if ClientYields[YieldId] then
					ClientYields[YieldId] = nil
					task.spawn(Thread, nil)
				end
			end)
			ClientYields[YieldId] = { Thread = Thread, Timeout = TimeoutThread }
			Import(Cursor)
			Allocate(2)
			WriteU8(Id)
			WriteU8(YieldId)
			for I = 1, #WriteFuncs do WriteFuncs[I](Args[I]) end
			Export()
			return coroutine.yield()
		else
			local Args = {...}
			local Delta = ComputeDelta(Id, "server", Args, Self.UseDelta)
			if not Delta then return end
			Import(Cursor)
			Allocate(1)
			WriteU8(Id)
			for I = 1, #WriteFuncs do WriteFuncs[I](Delta[I]) end
			Export()
		end
	end

	function Self:FireClient(Player: Player, ...)
		if not RunService:IsServer() then
			error("FireClient can only be called on the server", 2)
		end
		local Cursor = GetCursor(Player, Self.Reliable)
		if Self.RequestResponse then
			local Args = {...}
			local Yields = PlayerYields[Player]
			if not Yields then
				Yields = {}
				PlayerYields[Player] = Yields
			end
			local YieldId = YieldIndex
			YieldIndex = (YieldIndex + 1) % 256
			local Thread = coroutine.running()
			local TimeoutThread = task.delay(Self.RequestResponse.Timeout, function()
				if Yields[YieldId] then
					Yields[YieldId] = nil
					task.spawn(Thread, nil)
				end
			end)
			Yields[YieldId] = { Thread = Thread, Timeout = TimeoutThread }
			Import(Cursor)
			Allocate(2)
			WriteU8(Id)
			WriteU8(YieldId)
			for I = 1, #WriteFuncs do WriteFuncs[I](Args[I]) end
			Export()
			return coroutine.yield()
		else
			local Args = {...}
			local Delta = ComputeDelta(Id, Player, Args, Self.UseDelta)
			if not Delta then return end
			Import(Cursor)
			Allocate(1)
			WriteU8(Id)
			for I = 1, #WriteFuncs do WriteFuncs[I](Delta[I]) end
			Export()
		end
	end

	function Self:FireAllClients(...)
		if not RunService:IsServer() then
			error("FireAllClients can only be called on the server", 2)
		end
		local Cursor = GetCursor(nil, Self.Reliable)
		local Args = {...}
		local Delta = ComputeDelta(Id, "broadcast", Args, Self.UseDelta)
		if not Delta then return end
		Import(Cursor)
		Allocate(1)
		WriteU8(Id)
		for I = 1, #WriteFuncs do WriteFuncs[I](Delta[I]) end
		Export()
	end

	Registry[Id] = {
		Packet = Self,
		ReadFuncs = ReadFuncs,
		WriteFuncs = WriteFuncs,
	}

	return Self
end

function Sequena.CreatePacket<A..., B...>(Name: string)
	local Builder = {
		Schema = {},
		Reliable = Config.Network.DefaultReliable,
		UseDelta = false,
		Timeout = Config.Network.DefaultTimeout,
		ResponseSchema = nil,
	}
	function Builder:SetSchema(Schema: {any})
		Builder.Schema = Schema
		return Builder
	end
	function Builder:SetReliable(Reliable: boolean)
		Builder.Reliable = Reliable
		return Builder
	end
	function Builder:SetUseDelta(UseDelta: boolean)
		Builder.UseDelta = UseDelta
		return Builder
	end
	function Builder:SetResponse(ResponseSchema: {any}, Timeout: number?)
		Builder.ResponseSchema = ResponseSchema
		Builder.Timeout = Timeout or Config.Network.DefaultTimeout
		return Builder
	end
	function Builder:Build(): Packet<A..., B...>
		local Packet = Sequena.Define(Builder.Schema, Builder.Reliable, Name, Builder.UseDelta)
		if Builder.ResponseSchema then
			Packet:SetRequestResponse(Builder.ResponseSchema, Builder.Timeout)
		end
		return Packet
	end
	return Builder
end

function Sequena.Listen(Packet: Packet<any, any>, Callback: (any) -> any)
	if RunService:IsServer() then
		Packet.OnServerInvoke = Callback :: any
	else
		Packet.OnClientInvoke = Callback :: any
	end
end

local function ResolvePacket(Target: Packet<any, any> | string | number): Packet<any, any>?
	if type(Target) == "table" and Target.Fire and Target.Id ~= nil then
		return Target :: Packet<any, any>
	end
	if type(Target) == "number" then
		local Entry = Registry[Target]
		return Entry and Entry.Packet
	end
	if type(Target) == "string" then
		local Id = NameRegistry[Target]
		if Id then
			local Entry = Registry[Id]
			return Entry and Entry.Packet
		end
	end
	return nil
end

function Sequena.Fire(Target: Packet<any, any> | string | number, ...)
	local Packet = ResolvePacket(Target)
	if not Packet then return end
	Packet:Fire(...)
end

function Sequena.FireClient(Player: Player, Target: Packet<any, any> | string | number, ...)
	local Packet = ResolvePacket(Target)
	if not Packet then return end
	Packet:FireClient(Player, ...)
end

function Sequena.FireAllClients(Target: Packet<any, any> | string | number, ...)
	local Packet = ResolvePacket(Target)
	if not Packet then return end
	Packet:FireAllClients(...)
end

local function HandleSuspicious(Player: Player, Reason: string)
	if Config.Debug.LogWarnings then
		warn(`Suspicious activity from {Player.Name}: {Reason}`)
	end
	if Config.Security.KickSuspiciousClients then
		Player:Kick(`Invalid network data: {Reason}`)
	end
end

local function Process(Sender: Player?, Incoming: buffer, Inst: {Instance}?, Reliable: boolean, Compressed: boolean)
	local Success, Err = pcall(function()
		local ProcessBuffer = DecompressBuffer(Incoming, Compressed)

		Import({
			Buffer = ProcessBuffer,
			BufferLength = buffer.len(ProcessBuffer),
			BufferOffset = 0,
			Instances = Inst or {},
			InstancesOffset = 0
		})

		while BufferOffset < BufferLength do
			local PacketId = ReadU8()
			local Entry = Registry[PacketId]

			if not Entry then
				if Sender then
					HandleSuspicious(Sender, `Unknown packet ID: {PacketId}`)
				end
				break
			end

			if Entry.ResponseReadFuncs then
				local YieldId = ReadU8()
				if YieldId >= 128 then
					YieldId -= 128
					if Config.Security.ValidateYieldIds then
						if RunService:IsServer() then
							local Yields = PlayerYields[Sender]
							if not Yields or not Yields[YieldId] then
								HandleSuspicious(Sender, "Invalid yield ID in response")
								return
							end
						else
							if not ClientYields[YieldId] then
								HandleSuspicious(Sender, "Invalid yield ID in response")
								return
							end
						end
					end
					local N = #Entry.ResponseReadFuncs
					local Args = table.create(N)
					for I = 1, N do
						Args[I] = Entry.ResponseReadFuncs[I]()
					end
					if RunService:IsServer() then
						local Yields = PlayerYields[Sender]
						if Yields and Yields[YieldId] then
							local YieldData = Yields[YieldId]
							if YieldData.Timeout then task.cancel(YieldData.Timeout) end
							task.spawn(YieldData.Thread, table.unpack(Args))
							Yields[YieldId] = nil
						end
					else
						if ClientYields[YieldId] then
							local YieldData = ClientYields[YieldId]
							if YieldData.Timeout then task.cancel(YieldData.Timeout) end
							task.spawn(YieldData.Thread, table.unpack(Args))
							ClientYields[YieldId] = nil
						end
					end
				else
					local N = #Entry.ReadFuncs
					local Args = table.create(N)
					for I = 1, N do
						Args[I] = Entry.ReadFuncs[I]()
					end
					task.spawn(function()
						local ResponseArgs
						if RunService:IsServer() then
							if Entry.Packet.OnServerInvoke then
								ResponseArgs = { Entry.Packet.OnServerInvoke(Sender, table.unpack(Args)) }
							else
								if Config.Debug.LogWarnings then
									warn(`OnServerInvoke not set for packet {PacketId}`)
								end
								return
							end
						else
							if Entry.Packet.OnClientInvoke then
								ResponseArgs = { Entry.Packet.OnClientInvoke(table.unpack(Args)) }
							else
								if Config.Debug.LogWarnings then
									warn(`OnClientInvoke not set for packet {PacketId}`)
								end
								return
							end
						end
						local ResponseCursor = GetCursor(Sender, Reliable)
						Import(ResponseCursor)
						Allocate(2)
						WriteU8(PacketId)
						WriteU8(YieldId + 128)
						local Rw = Entry.ResponseWriteFuncs
						for I = 1, #Rw do Rw[I](ResponseArgs[I]) end
						Export()
					end)
				end
			else
				local N = #Entry.ReadFuncs
				local Delta = table.create(N)
				for I = 1, N do
					Delta[I] = Entry.ReadFuncs[I]()
				end
				local Cache = InboundDeltaCache[PacketId]
				if not Cache then
					Cache = {}
					InboundDeltaCache[PacketId] = Cache
				end
				local TargetKey = if RunService:IsServer() then Sender else 1
				local Last = Cache[TargetKey]
				local Args = ApplyDelta(Last, Delta)
				Cache[TargetKey] = Delta
				if RunService:IsServer() then
					Entry.Packet.OnServerEvent:Fire(Sender, table.unpack(Args))
				else
					Entry.Packet.OnClientEvent:Fire(table.unpack(Args))
				end
			end
		end
	end)

	if not Success then
		if Sender then
			HandleSuspicious(Sender, `Packet processing error: {Err}`)
		else
			if Config.Debug.LogWarnings then
				warn(`Error processing packet: {Err}`)
			end
		end
	end
end

local function FlushReliable()
	if RunService:IsServer() then
		if BroadcastReliableCursor and BroadcastReliableCursor.BufferOffset > 0 then
			local Cursor = BroadcastReliableCursor
			BroadcastReliableCursor = nil
			Import(Cursor)
			local B, Inst = Truncate()
			local Compressed, ShouldCompress = CompressBuffer(B)
			ReliableRemote:FireAllClients(ShouldCompress, Compressed, Inst or {})
		end
		for Player, Cursor in PlayerReliableCursors do
			if Cursor.BufferOffset > 0 then
				Import(Cursor)
				local B, Inst = Truncate()
				local Compressed, ShouldCompress = CompressBuffer(B)
				ReliableRemote:FireClient(Player :: Player, ShouldCompress, Compressed, Inst or {})
				ResetCursor(Cursor)
			end
		end
	else
		local Cursor = PlayerReliableCursors[SERVER_KEY]
		if Cursor and Cursor.BufferOffset > 0 then
			Import(Cursor)
			local B, Inst = Truncate()
			local Compressed, ShouldCompress = CompressBuffer(B)
			ReliableRemote:FireServer(ShouldCompress, Compressed, Inst or {})
			ResetCursor(Cursor)
		end
	end
end

local function FlushUnreliable()
	if RunService:IsServer() then
		if BroadcastUnreliableCursor and BroadcastUnreliableCursor.BufferOffset > 0 then
			local Cursor = BroadcastUnreliableCursor
			BroadcastUnreliableCursor = nil
			Import(Cursor)
			local B, Inst = Truncate()
			UnreliableRemote:FireAllClients(false, B, Inst or {})
		end
		for Player, Cursor in PlayerUnreliableCursors do
			if Cursor.BufferOffset > 0 then
				Import(Cursor)
				local B, Inst = Truncate()
				UnreliableRemote:FireClient(Player :: Player, false, B, Inst or {})
				ResetCursor(Cursor)
			end
		end
		table.clear(PlayerUnreliableCursors)
	else
		local Cursor = PlayerUnreliableCursors[SERVER_KEY]
		if Cursor and Cursor.BufferOffset > 0 then
			Import(Cursor)
			local B, Inst = Truncate()
			UnreliableRemote:FireServer(false, B, Inst or {})
			ResetCursor(Cursor)
		end
	end
end

local function CheckAndFlushBatch(Cursor: Cursor, Player: Player?, Reliable: boolean)
	if Cursor.BufferOffset >= MAX_BATCH_SIZE then
		Import(Cursor)
		local B, Inst = Truncate()
		if Reliable then
			local Compressed, ShouldCompress = CompressBuffer(B)
			if Player then
				ReliableRemote:FireClient(Player, ShouldCompress, Compressed, Inst or {})
			else
				ReliableRemote:FireServer(ShouldCompress, Compressed, Inst or {})
			end
		else
			if Player then
				UnreliableRemote:FireClient(Player, false, B, Inst or {})
			else
				UnreliableRemote:FireServer(false, B, Inst or {})
			end
		end
		ResetCursor(Cursor)
	end
end

if RunService:IsServer() then
	ReliableRemote.OnServerEvent:Connect(function(Player, Compressed, ...)
		if not CheckRateLimit(Player, buffer.len((...))) then
			HandleSuspicious(Player, "Rate limit exceeded")
			return
		end
		if not CheckEventRate(Player) then
			HandleSuspicious(Player, "Event rate limit exceeded")
			return
		end
		Process(Player, ..., true, Compressed)
	end)
	UnreliableRemote.OnServerEvent:Connect(function(Player, Compressed, ...)
		if not CheckEventRate(Player) then
			HandleSuspicious(Player, "Event rate limit exceeded")
			return
		end
		Process(Player, ..., false, Compressed)
	end)
	Players.PlayerRemoving:Connect(function(Player)
		PlayerReliableCursors[Player] = nil
		PlayerUnreliableCursors[Player] = nil
		PlayerYields[Player] = nil
		PlayerRateLimits[Player] = nil
		PlayerEventCounts[Player] = nil
		for _, CacheEntry in DeltaCache do
			CacheEntry.Cache[Player] = nil
			for I = #CacheEntry.LRU, 1, -1 do
				if CacheEntry.LRU[I] == Player then
					table.remove(CacheEntry.LRU, I)
					CacheEntry.Size -= 1
					break
				end
			end
		end
		for _, Cache in InboundDeltaCache do
			Cache[Player] = nil
		end
	end)
else
	ReliableRemote.OnClientEvent:Connect(function(Compressed, ...)
		Process(nil, ..., true, Compressed)
	end)
	UnreliableRemote.OnClientEvent:Connect(function(Compressed, ...)
		Process(nil, ..., false, Compressed)
	end)
end

function Sequena.FlushImmediate()
	FlushReliable()
	FlushUnreliable()
end

function Sequena.GetPacketByName(Name: string): Packet<any, any>?
	local Id = NameRegistry[Name]
	if not Id then return nil end
	local Entry = Registry[Id]
	return Entry and Entry.Packet
end

RunService.Heartbeat:Connect(function(_Dt)
	if RunService:IsServer() then
		for Player, Cursor in PlayerReliableCursors do
			CheckAndFlushBatch(Cursor, Player, true)
		end
		for Player, Cursor in PlayerUnreliableCursors do
			CheckAndFlushBatch(Cursor, Player, false)
		end
	else
		local ReliableCursor = PlayerReliableCursors[SERVER_KEY]
		if ReliableCursor then
			CheckAndFlushBatch(ReliableCursor, nil, true)
		end
		local UnreliableCursor = PlayerUnreliableCursors[SERVER_KEY]
		if UnreliableCursor then
			CheckAndFlushBatch(UnreliableCursor, nil, false)
		end
	end
	FlushReliable()
	FlushUnreliable()
	if RunService:IsServer() then
		local Now = os.clock()
		for Player, Limit in PlayerRateLimits do
			if Now - Limit.LastReset >= RATE_LIMIT_WINDOW then
				PlayerRateLimits[Player] = nil
			end
		end
	end
end)

local TypeMap = {
	String = "String",
	Bool = "Bool",
	Number = "F64",
	Float = "F32",
	U8 = "U8",
	U16 = "U16",
	U32 = "U32",
	I8 = "I8",
	I16 = "I16",
	I32 = "I32",
	Int = "I32",
	Vector2 = "Vector2",
	Vector3 = "Vector3",
	CFrame = "CFrame",
	Color3 = "Color3",
	Instance = "Instance",
	Buffer = "Buffer",
	Enum = "Enum",
	Table = "Table",
	Any = "Table",
}

local PacketMeta = {
	__index = TypeMap,
	__call = function(_, Name, ...)
		local schema = {...}
		for i, v in ipairs(schema) do
			if TypeMap[v] then schema[i] = TypeMap[v] end
		end
		return Sequena.Define(schema, true, Name)
	end,
}

Sequena.Packet = setmetatable({}, PacketMeta)
Sequena.Types = TypeMap


return Sequena