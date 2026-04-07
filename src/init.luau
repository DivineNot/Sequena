--!strict
--!optimize 2

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Config = require(script:FindFirstChild("Config")) :: any
local LZAV = require(script:FindFirstChild("LZAV")) :: any

local BufferCreate = buffer.create
local BufferCopy = buffer.copy
local BufferLen = buffer.len
local BufferReadU8 = buffer.readu8
local BufferWriteU8 = buffer.writeu8
local BufferReadU16 = buffer.readu16
local BufferWriteU16 = buffer.writeu16
local BufferReadU32 = buffer.readu32
local BufferWriteU32 = buffer.writeu32
local BufferReadI8 = buffer.readi8
local BufferWriteI8 = buffer.writei8
local BufferReadI16 = buffer.readi16
local BufferWriteI16 = buffer.writei16
local BufferReadI32 = buffer.readi32
local BufferWriteI32 = buffer.writei32
local BufferReadF32 = buffer.readf32
local BufferWriteF32 = buffer.writef32
local BufferReadF64 = buffer.readf64
local BufferWriteF64 = buffer.writef64
local BufferReadString = buffer.readstring
local BufferWriteString = buffer.writestring
local MathFloor = math.floor
local MathSqrt = math.sqrt
local MathAbs = math.abs
local TaskSpawn = task.spawn
local TaskCancel = task.cancel

type ReadFunc = () -> any
type WriteFunc = (any) -> ()
type SchemaItem = string | { Read: ReadFunc, Write: WriteFunc }

type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
type Signal<T...> = {
	Connect: (self: Signal<T...>, Callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, Callback: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
}

local function CreateSignal<T...>(): Signal<T...>
	local Callbacks: {(T...) -> ()} = {}
	local WaitingThreads: {thread} = {}
	local Self = {} :: any
	function Self:Connect(Callback: (T...) -> ()): Connection
		local Index = #Callbacks + 1
		Callbacks[Index] = Callback
		local Conn = { Connected = true, Disconnect = function(S: any) S.Connected = false; Callbacks[Index] = nil end }
		return Conn
	end
	function Self:Once(Callback: (T...) -> ()): Connection
		local Conn: Connection
		Conn = Self:Connect(function(...: any)
			Conn:Disconnect()
			Callback(...)
		end)
		return Conn
	end
	function Self:Fire(...: any)
		for _, Fn in Callbacks do
			TaskSpawn(Fn, ...)
		end
		for _, Thread in WaitingThreads do
			TaskSpawn(Thread, ...)
		end
		table.clear(WaitingThreads)
	end
	function Self:Wait(): T...
		local Thread = coroutine.running()
		WaitingThreads[#WaitingThreads + 1] = Thread
		return coroutine.yield()
	end
	return Self
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
		local New = BufferCreate(BufferLength)
		BufferCopy(New, 0, ActiveBuffer, 0, BufferOffset)
		ActiveCursor.Buffer = New
		ActiveBuffer = New
	end
end

local function ReadU8(): number
	if BufferOffset + 1 > BufferLength then error("Buffer underflow") end
	local V = BufferReadU8(ActiveBuffer, BufferOffset)
	BufferOffset += 1
	return V
end

local function WriteU8(V: number) BufferWriteU8(ActiveBuffer, BufferOffset, V); BufferOffset += 1 end
local function ReadU16(): number
	if BufferOffset + 2 > BufferLength then error("Buffer underflow") end
	local V = BufferReadU16(ActiveBuffer, BufferOffset)
	BufferOffset += 2
	return V
end
local function WriteU16(V: number) BufferWriteU16(ActiveBuffer, BufferOffset, V); BufferOffset += 2 end
local function ReadU32(): number
	if BufferOffset + 4 > BufferLength then error("Buffer underflow") end
	local V = BufferReadU32(ActiveBuffer, BufferOffset)
	BufferOffset += 4
	return V
end
local function WriteU32(V: number) BufferWriteU32(ActiveBuffer, BufferOffset, V); BufferOffset += 4 end
local function ReadI8(): number
	if BufferOffset + 1 > BufferLength then error("Buffer underflow") end
	local V = BufferReadI8(ActiveBuffer, BufferOffset)
	BufferOffset += 1
	return V
end
local function WriteI8(V: number) BufferWriteI8(ActiveBuffer, BufferOffset, V); BufferOffset += 1 end
local function ReadI16(): number
	if BufferOffset + 2 > BufferLength then error("Buffer underflow") end
	local V = BufferReadI16(ActiveBuffer, BufferOffset)
	BufferOffset += 2
	return V
end
local function WriteI16(V: number) BufferWriteI16(ActiveBuffer, BufferOffset, V); BufferOffset += 2 end
local function ReadI32(): number
	if BufferOffset + 4 > BufferLength then error("Buffer underflow") end
	local V = BufferReadI32(ActiveBuffer, BufferOffset)
	BufferOffset += 4
	return V
end
local function WriteI32(V: number) BufferWriteI32(ActiveBuffer, BufferOffset, V); BufferOffset += 4 end
local function ReadF32(): number
	if BufferOffset + 4 > BufferLength then error("Buffer underflow") end
	local V = BufferReadF32(ActiveBuffer, BufferOffset)
	BufferOffset += 4
	return V
end
local function WriteF32(V: number) BufferWriteF32(ActiveBuffer, BufferOffset, V); BufferOffset += 4 end
local function ReadF64(): number
	if BufferOffset + 8 > BufferLength then error("Buffer underflow") end
	local V = BufferReadF64(ActiveBuffer, BufferOffset)
	BufferOffset += 8
	return V
end
local function WriteF64(V: number) BufferWriteF64(ActiveBuffer, BufferOffset, V); BufferOffset += 8 end
local function ReadString(Len: number): string
	if BufferOffset + Len > BufferLength then error("Buffer underflow") end
	local V = BufferReadString(ActiveBuffer, BufferOffset, Len)
	BufferOffset += Len
	return V
end
local function WriteString(V: string) BufferWriteString(ActiveBuffer, BufferOffset, V); BufferOffset += #V end
local function ReadInstance(): Instance
	InstancesOffset += 1
	return Instances[InstancesOffset]
end
local function WriteInstance(V: Instance)
	InstancesOffset += 1
	Instances[InstancesOffset] = V
end

local function ReadF16(): number
	if BufferOffset + 2 > BufferLength then error("Buffer underflow") end
	local Raw = BufferReadU16(ActiveBuffer, BufferOffset)
	BufferOffset += 2
	local Sign = if bit32.btest(Raw, 0x8000) then -1 else 1
	local Exponent = bit32.band(bit32.rshift(Raw, 10), 0x1F)
	local Mantissa = bit32.band(Raw, 0x3FF)
	if Exponent == 0 then
		return Sign * (Mantissa / 1024) * (2 ^ -14)
	elseif Exponent == 31 then
		return if Mantissa == 0 then Sign * math.huge else 0/0
	end
	return Sign * (1 + Mantissa / 1024) * (2 ^ (Exponent - 15))
end

local function WriteF16(V: number)
	local Sign = 0
	if V < 0 then Sign = 0x8000; V = -V end
	if V == math.huge then
		BufferWriteU16(ActiveBuffer, BufferOffset, bit32.bor(Sign, 0x7C00))
		BufferOffset += 2
		return
	end
	if V ~= V then
		BufferWriteU16(ActiveBuffer, BufferOffset, bit32.bor(Sign, 0x7E00))
		BufferOffset += 2
		return
	end
	if V == 0 then
		BufferWriteU16(ActiveBuffer, BufferOffset, Sign)
		BufferOffset += 2
		return
	end
	local M, E = math.frexp(V)
	E = E + 14
	if E <= 0 then
		local Mantissa = MathFloor(M * (2 ^ (E + 9)) + 0.5)
		BufferWriteU16(ActiveBuffer, BufferOffset, bit32.bor(Sign, bit32.band(Mantissa, 0x3FF)))
	elseif E >= 31 then
		BufferWriteU16(ActiveBuffer, BufferOffset, bit32.bor(Sign, 0x7C00))
	else
		local Mantissa = MathFloor((M * 2 - 1) * 1024 + 0.5)
		BufferWriteU16(ActiveBuffer, BufferOffset, bit32.bor(Sign, bit32.lshift(E, 10), bit32.band(Mantissa, 0x3FF)))
	end
	BufferOffset += 2
end

local TYPE_NIL = 0
local TYPE_BOOL_TRUE = 1
local TYPE_BOOL_FALSE = 2
local TYPE_NUMBER = 3
local TYPE_STRING = 4
local TYPE_BUFFER = 5
local TYPE_VECTOR2 = 6
local TYPE_VECTOR3 = 7
local TYPE_CFRAME = 8
local TYPE_COLOR3 = 9
local TYPE_INSTANCE = 10
local TYPE_ENUM = 11
local TYPE_TABLE = 12
local TYPE_INT_U8 = 13
local TYPE_INT_U16 = 14
local TYPE_INT_U32 = 15
local TYPE_INT_I16 = 16
local TYPE_INT_I32 = 17
local TYPE_ZERO = 18
local TYPE_ONE = 19
local TYPE_NEGATED_INT_U8 = 20
local TYPE_ZERO_VECTOR3 = 21
local TYPE_IDENTITY_CFRAME = 22
local TYPE_EMPTY_STRING = 23

local EnumCache: {[EnumItem]: string} = {}
local StringToEnumCache: {[string]: EnumItem} = {}

TypeReads.U8 = ReadU8
TypeWrites.U8 = function(V) Allocate(1); WriteU8(V) end
TypeReads.U16 = ReadU16
TypeWrites.U16 = function(V) Allocate(2); WriteU16(V) end
TypeReads.U32 = ReadU32
TypeWrites.U32 = function(V) Allocate(4); WriteU32(V) end
TypeReads.I8 = ReadI8
TypeWrites.I8 = function(V) Allocate(1); WriteI8(V) end
TypeReads.I16 = ReadI16
TypeWrites.I16 = function(V) Allocate(2); WriteI16(V) end
TypeReads.I32 = ReadI32
TypeWrites.I32 = function(V) Allocate(4); WriteI32(V) end
TypeReads.F32 = ReadF32
TypeWrites.F32 = function(V) Allocate(4); WriteF32(V) end
TypeReads.F64 = ReadF64
TypeWrites.F64 = function(V) Allocate(8); WriteF64(V) end
TypeReads.Bool = function() return ReadU8() == 1 end
TypeWrites.Bool = function(V) Allocate(1); WriteU8(if V then 1 else 0) end

local function ReadVarInt(): number
	local C = 0
	local V = 0
	local B
	repeat
		B = BufferReadU8(ActiveBuffer, BufferOffset)
		BufferOffset += 1
		V = bit32.bor(V, bit32.lshift(bit32.band(B, 0x7F), C))
		C += 7
	until bit32.band(B, 0x80) == 0
	return V
end

local function WriteVarInt(V: number)
	while V >= 128 do
		BufferWriteU8(ActiveBuffer, BufferOffset, bit32.bor(V, 0x80))
		BufferOffset += 1
		V = bit32.rshift(V, 7)
	end
	BufferWriteU8(ActiveBuffer, BufferOffset, V)
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
	local B = BufferCreate(Len)
	BufferCopy(B, 0, ActiveBuffer, BufferOffset, Len)
	BufferOffset += Len
	return B
end
TypeWrites.Buffer = function(V: buffer)
	local Len = BufferLen(V)
	Allocate(5 + Len)
	WriteVarInt(Len)
	BufferCopy(ActiveBuffer, BufferOffset, V, 0, Len)
	BufferOffset += Len
end

TypeReads.Vector3 = function() return Vector3.new(ReadF32(), ReadF32(), ReadF32()) end
TypeWrites.Vector3 = function(V: Vector3) Allocate(12); WriteF32(V.X); WriteF32(V.Y); WriteF32(V.Z) end
TypeReads.Vector2 = function() return Vector2.new(ReadF32(), ReadF32()) end
TypeWrites.Vector2 = function(V: Vector2) Allocate(8); WriteF32(V.X); WriteF32(V.Y) end
TypeReads.Vector3I16 = function() return Vector3.new(ReadI16(), ReadI16(), ReadI16()) end
TypeWrites.Vector3I16 = function(V: Vector3) Allocate(6); WriteI16(V.X); WriteI16(V.Y); WriteI16(V.Z) end

local function MatrixToQuat(R00: number, R01: number, R02: number, R10: number, R11: number, R12: number, R20: number, R21: number, R22: number): (number, number, number, number)
	local Trace = R00 + R11 + R22
	if Trace > 0 then
		local S = MathSqrt(Trace + 1) * 2
		return 0.25 * S, (R21 - R12) / S, (R02 - R20) / S, (R10 - R01) / S
	elseif R00 > R11 and R00 > R22 then
		local S = MathSqrt(1 + R00 - R11 - R22) * 2
		return (R21 - R12) / S, 0.25 * S, (R01 + R10) / S, (R02 + R20) / S
	elseif R11 > R22 then
		local S = MathSqrt(1 + R11 - R00 - R22) * 2
		return (R02 - R20) / S, (R01 + R10) / S, 0.25 * S, (R12 + R21) / S
	else
		local S = MathSqrt(1 + R22 - R00 - R11) * 2
		return (R10 - R01) / S, (R02 + R20) / S, (R12 + R21) / S, 0.25 * S
	end
end

local function QuatToMatrix(Qw: number, Qx: number, Qy: number, Qz: number): (number, number, number, number, number, number, number, number, number)
	local Xx, Yy, Zz = Qx * Qx, Qy * Qy, Qz * Qz
	local Xy, Xz, Yz = Qx * Qy, Qx * Qz, Qy * Qz
	local Wx, Wy, Wz = Qw * Qx, Qw * Qy, Qw * Qz

	local m11 = 1 - 2 * (Yy + Zz)
	local m12 = 2 * (Xy - Wz)
	local m13 = 2 * (Xz + Wy)

	local m21 = 2 * (Xy + Wz)
	local m22 = 1 - 2 * (Xx + Zz)
	local m23 = 2 * (Yz - Wx)

	local m31 = 2 * (Xz - Wy)
	local m32 = 2 * (Yz + Wx)
	local m33 = 1 - 2 * (Xx + Yy)

	return m11, m12, m13, m21, m22, m23, m31, m32, m33
end

TypeReads.CFrame = function()
	local Px, Py, Pz = ReadF32(), ReadF32(), ReadF32()
	local Header = ReadU8()
	local LargestIdx = bit32.band(Header, 3)
	local SignBit = bit32.btest(Header, 4)
	local A, B, C = ReadF32(), ReadF32(), ReadF32()
	local SumSq = A * A + B * B + C * C
	local Largest = MathSqrt(if SumSq < 1 then 1 - SumSq else 0)
	if SignBit then Largest = -Largest end
	local Qw, Qx, Qy, Qz
	if LargestIdx == 0 then Qw, Qx, Qy, Qz = Largest, A, B, C
	elseif LargestIdx == 1 then Qw, Qx, Qy, Qz = A, Largest, B, C
	elseif LargestIdx == 2 then Qw, Qx, Qy, Qz = A, B, Largest, C
	else Qw, Qx, Qy, Qz = A, B, C, Largest end
	local R00, R01, R02, R10, R11, R12, R20, R21, R22 = QuatToMatrix(Qw, Qx, Qy, Qz)
	return CFrame.new(Px, Py, Pz, R00, R01, R02, R10, R11, R12, R20, R21, R22)
end
TypeWrites.CFrame = function(V: CFrame)
	Allocate(25)
	local X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = V:GetComponents()
	WriteF32(X); WriteF32(Y); WriteF32(Z)
	local Qw, Qx, Qy, Qz = MatrixToQuat(R00, R01, R02, R10, R11, R12, R20, R21, R22)
	local Aw, Ax, Ay, Az = MathAbs(Qw), MathAbs(Qx), MathAbs(Qy), MathAbs(Qz)
	local LargestIdx = 0
	local LargestVal = Aw
	if Ax > LargestVal then LargestIdx = 1; LargestVal = Ax end
	if Ay > LargestVal then LargestIdx = 2; LargestVal = Ay end
	if Az > LargestVal then LargestIdx = 3 end
	local SignBit = 0
	local A, B, C
	if LargestIdx == 0 then
		if Qw < 0 then SignBit = 4 end
		A, B, C = Qx, Qy, Qz
	elseif LargestIdx == 1 then
		if Qx < 0 then SignBit = 4 end
		A, B, C = Qw, Qy, Qz
	elseif LargestIdx == 2 then
		if Qy < 0 then SignBit = 4 end
		A, B, C = Qw, Qx, Qz
	else
		if Qz < 0 then SignBit = 4 end
		A, B, C = Qw, Qx, Qy
	end
	WriteU8(bit32.bor(LargestIdx, SignBit))
	WriteF32(A); WriteF32(B); WriteF32(C)
end

TypeReads.CFrameCompact = function()
	local Px, Py, Pz = ReadF32(), ReadF32(), ReadF32()
	local Header = ReadU8()
	local LargestIdx = bit32.band(Header, 3)
	local SignBit = bit32.btest(Header, 4)
	local A, B, C = ReadF16(), ReadF16(), ReadF16()
	local SumSq = A * A + B * B + C * C
	local Largest = MathSqrt(if SumSq < 1 then 1 - SumSq else 0)
	if SignBit then Largest = -Largest end
	local Qw, Qx, Qy, Qz
	if LargestIdx == 0 then Qw, Qx, Qy, Qz = Largest, A, B, C
	elseif LargestIdx == 1 then Qw, Qx, Qy, Qz = A, Largest, B, C
	elseif LargestIdx == 2 then Qw, Qx, Qy, Qz = A, B, Largest, C
	else Qw, Qx, Qy, Qz = A, B, C, Largest end
	local R00, R01, R02, R10, R11, R12, R20, R21, R22 = QuatToMatrix(Qw, Qx, Qy, Qz)
	return CFrame.new(Px, Py, Pz, R00, R01, R02, R10, R11, R12, R20, R21, R22)
end
TypeWrites.CFrameCompact = function(V: CFrame)
	Allocate(19)
	local X, Y, Z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = V:GetComponents()
	WriteF32(X); WriteF32(Y); WriteF32(Z)
	local Qw, Qx, Qy, Qz = MatrixToQuat(R00, R01, R02, R10, R11, R12, R20, R21, R22)
	local Aw, Ax, Ay, Az = MathAbs(Qw), MathAbs(Qx), MathAbs(Qy), MathAbs(Qz)
	local LargestIdx = 0
	local LargestVal = Aw
	if Ax > LargestVal then LargestIdx = 1; LargestVal = Ax end
	if Ay > LargestVal then LargestIdx = 2; LargestVal = Ay end
	if Az > LargestVal then LargestIdx = 3 end
	local SignBit = 0
	local A, B, C
	if LargestIdx == 0 then
		if Qw < 0 then SignBit = 4 end
		A, B, C = Qx, Qy, Qz
	elseif LargestIdx == 1 then
		if Qx < 0 then SignBit = 4 end
		A, B, C = Qw, Qy, Qz
	elseif LargestIdx == 2 then
		if Qy < 0 then SignBit = 4 end
		A, B, C = Qw, Qx, Qz
	else
		if Qz < 0 then SignBit = 4 end
		A, B, C = Qw, Qx, Qy
	end
	WriteU8(bit32.bor(LargestIdx, SignBit))
	WriteF16(A); WriteF16(B); WriteF16(C)
end

TypeReads.F16 = ReadF16
TypeWrites.F16 = function(V: number) Allocate(2); WriteF16(V) end

TypeReads.Color3 = function()
	return Color3.fromRGB(ReadU8(), ReadU8(), ReadU8())
end
TypeWrites.Color3 = function(V: Color3)
	Allocate(3)
	WriteU8(MathFloor(V.R * 255))
	WriteU8(MathFloor(V.G * 255))
	WriteU8(MathFloor(V.B * 255))
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
	local ValueToIndex: {[string]: number} = {}
	for I, V in Values do
		ValueToIndex[V] = I - 1
	end
	return {
		Read = function()
			return Values[ReadU8() + 1]
		end,
		Write = function(V: any)
			local Idx = ValueToIndex[V]
			if not Idx then error(`Invalid enum value: {V}`) end
			Allocate(1); WriteU8(Idx)
		end
	}
end
Types.Map = function(KeyType: string, ValueType: string, MaxSize: number?)
	local KeyRead = TypeReads[KeyType]
	local KeyWrite = TypeWrites[KeyType]
	local ValRead = TypeReads[ValueType]
	local ValWrite = TypeWrites[ValueType]
	local Max = MaxSize or MAX_ARRAY_SIZE
	return {
		Read = function()
			local Len = ReadU16()
			if Len > Max then error(`Map exceeds max size: {Len} > {Max}`) end
			local M = {}
			for _ = 1, Len do
				local K = KeyRead()
				M[K] = ValRead()
			end
			return M
		end,
		Write = function(V: any)
			local Count = 0
			for _ in V do Count += 1 end
			Count = if Count > Max then Max else Count
			Allocate(2); WriteU16(Count)
			local Written = 0
			for K, Val in V do
				if Written >= Count then break end
				KeyWrite(K); ValWrite(Val)
				Written += 1
			end
		end
	}
end
Types.Struct = function(Fields: {{any}})
	local N = #Fields
	local FieldReads = table.create(N)
	local FieldWrites = table.create(N)
	local FieldNames = table.create(N)
	for I = 1, N do
		local Def = Fields[I]
		local FName = Def[1]
		local FType = Def[2]
		FieldNames[I] = FName
		if type(FType) == "string" then
			FieldReads[I] = TypeReads[FType]
			FieldWrites[I] = TypeWrites[FType]
		elseif type(FType) == "table" and FType.Read and FType.Write then
			FieldReads[I] = FType.Read
			FieldWrites[I] = FType.Write
		else
			error(`Invalid struct field type for "{FName}"`)
		end
	end
	return {
		Read = function()
			local S: {[string]: any} = {}
			for I = 1, N do
				S[FieldNames[I] :: string] = (FieldReads[I] :: ReadFunc)()
			end
			return S
		end,
		Write = function(V: any)
			for I = 1, N do
				(FieldWrites[I] :: WriteFunc)(V[FieldNames[I] :: string])
			end
		end
	}
end
Types.RangedU8 = function(Min: number, Max: number)
	return {
		Read = function()
			local V = ReadU8()
			return V + Min
		end,
		Write = function(V: any)
			local Clamped = if V < Min then Min elseif V > Max then Max else V
			Allocate(1); WriteU8(Clamped - Min)
		end
	}
end
Types.RangedU16 = function(Min: number, Max: number)
	return {
		Read = function()
			local V = ReadU16()
			return V + Min
		end,
		Write = function(V: any)
			local Clamped = if V < Min then Min elseif V > Max then Max else V
			Allocate(2); WriteU16(Clamped - Min)
		end
	}
end
Types.Bitfield = function(Fields: {{any}})
	local TotalBits = 0
	for _, F in Fields do
		TotalBits += F[2]
	end
	local ByteCount = MathFloor((TotalBits + 7) / 8)
	return {
		Read = function()
			local Bytes = table.create(ByteCount)
			for I = 1, ByteCount do
				Bytes[I] = ReadU8()
			end
			local Result: {[string]: any} = {}
			local BitPos = 0
			for _, F in Fields do
				local FName = F[1]
				local FBits = F[2]
				local ByteIdx = MathFloor(BitPos / 8) + 1
				local BitIdx = BitPos % 8
				local Val = bit32.extract(Bytes[ByteIdx] :: number, BitIdx, math.min(FBits, 8 - BitIdx))
				if FBits > (8 - BitIdx) and ByteIdx < ByteCount then
					local Remaining = FBits - (8 - BitIdx)
					Val = bit32.bor(Val, bit32.lshift(bit32.extract(Bytes[ByteIdx + 1] :: number, 0, Remaining), 8 - BitIdx))
				end
				if FBits == 1 then
					Result[FName] = Val == 1
				else
					Result[FName] = Val
				end
				BitPos += FBits
			end
			return Result
		end,
		Write = function(V: any)
			Allocate(ByteCount)
			local Bytes = table.create(ByteCount, 0)
			local BitPos = 0
			for _, F in Fields do
				local FName = F[1]
				local FBits = F[2]
				local Val = V[FName]
				if type(Val) == "boolean" then Val = if Val then 1 else 0 end
				local ByteIdx = MathFloor(BitPos / 8) + 1
				local BitIdx = BitPos % 8
				Bytes[ByteIdx] = bit32.replace(Bytes[ByteIdx], bit32.band(Val, bit32.lshift(1, math.min(FBits, 8 - BitIdx)) - 1), BitIdx, math.min(FBits, 8 - BitIdx))
				if FBits > (8 - BitIdx) and ByteIdx < ByteCount then
					local Remaining = FBits - (8 - BitIdx)
					Bytes[ByteIdx + 1] = bit32.replace(Bytes[ByteIdx + 1], bit32.rshift(Val, 8 - BitIdx), 0, Remaining)
				end
				BitPos += FBits
			end
			for I = 1, ByteCount do
				WriteU8(Bytes[I])
			end
		end
	}
end

local function WriteAny(V: any)
	local T = typeof(V)
	if T == "nil" then
		Allocate(1); WriteU8(TYPE_NIL)
	elseif T == "boolean" then
		Allocate(1); WriteU8(if V then TYPE_BOOL_TRUE else TYPE_BOOL_FALSE)
	elseif T == "number" then
		if V == 0 then
			Allocate(1); WriteU8(TYPE_ZERO)
		elseif V == 1 then
			Allocate(1); WriteU8(TYPE_ONE)
		elseif V % 1 == 0 then
			if V >= 0 then
				if V <= 255 then
					Allocate(2); WriteU8(TYPE_INT_U8); WriteU8(V)
				elseif V <= 65535 then
					Allocate(3); WriteU8(TYPE_INT_U16); WriteU16(V)
				elseif V <= 4294967295 then
					Allocate(5); WriteU8(TYPE_INT_U32); WriteU32(V)
				else
					Allocate(9); WriteU8(TYPE_NUMBER); WriteF64(V)
				end
			else
				if V >= -128 then
					Allocate(2); WriteU8(TYPE_NEGATED_INT_U8); WriteU8(-V)
				elseif V >= -32768 and V <= 32767 then
					Allocate(3); WriteU8(TYPE_INT_I16); WriteI16(V)
				elseif V >= -2147483648 and V <= 2147483647 then
					Allocate(5); WriteU8(TYPE_INT_I32); WriteI32(V)
				else
					Allocate(9); WriteU8(TYPE_NUMBER); WriteF64(V)
				end
			end
		else
			Allocate(9); WriteU8(TYPE_NUMBER); WriteF64(V)
		end
	elseif T == "string" then
		if #V == 0 then
			Allocate(1); WriteU8(TYPE_EMPTY_STRING)
		else
			Allocate(1); WriteU8(TYPE_STRING); TypeWrites.String(V)
		end
	elseif T == "buffer" then
		Allocate(1); WriteU8(TYPE_BUFFER); TypeWrites.Buffer(V)
	elseif T == "Vector2" then
		Allocate(9); WriteU8(TYPE_VECTOR2); TypeWrites.Vector2(V)
	elseif T == "Vector3" then
		if V.X == 0 and V.Y == 0 and V.Z == 0 then
			Allocate(1); WriteU8(TYPE_ZERO_VECTOR3)
		else
			Allocate(13); WriteU8(TYPE_VECTOR3); TypeWrites.Vector3(V)
		end
	elseif T == "CFrame" then
		if V == CFrame.identity then
			Allocate(1); WriteU8(TYPE_IDENTITY_CFRAME)
		else
			Allocate(26); WriteU8(TYPE_CFRAME); TypeWrites.CFrame(V)
		end
	elseif T == "Color3" then
		Allocate(4); WriteU8(TYPE_COLOR3); TypeWrites.Color3(V)
	elseif T == "Instance" then
		Allocate(1); WriteU8(TYPE_INSTANCE); WriteInstance(V)
	elseif T == "EnumItem" then
		Allocate(1); WriteU8(TYPE_ENUM); TypeWrites.Enum(V)
	elseif T == "table" then
		Allocate(1); WriteU8(TYPE_TABLE)
		for K, Val in pairs(V) do
			WriteAny(K); WriteAny(Val)
		end
		Allocate(1); WriteU8(TYPE_NIL)
	else
		if Config.Debug.LogWarnings then
			warn("Unsupported type: " .. T)
		end
		Allocate(1); WriteU8(TYPE_NIL)
	end
end

local function ReadAny(): any
	local TypeId = ReadU8()
	if TypeId == TYPE_NIL then return nil
	elseif TypeId == TYPE_BOOL_TRUE then return true
	elseif TypeId == TYPE_BOOL_FALSE then return false
	elseif TypeId == TYPE_ZERO then return 0
	elseif TypeId == TYPE_ONE then return 1
	elseif TypeId == TYPE_NUMBER then return ReadF64()
	elseif TypeId == TYPE_STRING then return TypeReads.String()
	elseif TypeId == TYPE_EMPTY_STRING then return ""
	elseif TypeId == TYPE_BUFFER then return TypeReads.Buffer()
	elseif TypeId == TYPE_VECTOR2 then return TypeReads.Vector2()
	elseif TypeId == TYPE_VECTOR3 then return TypeReads.Vector3()
	elseif TypeId == TYPE_ZERO_VECTOR3 then return Vector3.zero
	elseif TypeId == TYPE_CFRAME then return TypeReads.CFrame()
	elseif TypeId == TYPE_IDENTITY_CFRAME then return CFrame.identity
	elseif TypeId == TYPE_COLOR3 then return TypeReads.Color3()
	elseif TypeId == TYPE_INSTANCE then return ReadInstance()
	elseif TypeId == TYPE_ENUM then return TypeReads.Enum()
	elseif TypeId == TYPE_TABLE then
		local Tbl = {}
		repeat
			local K = ReadAny()
			if K == nil then break end
			Tbl[K] = ReadAny()
		until false
		return Tbl
	elseif TypeId == TYPE_INT_U8 then return ReadU8()
	elseif TypeId == TYPE_INT_U16 then return ReadU16()
	elseif TypeId == TYPE_INT_U32 then return ReadU32()
	elseif TypeId == TYPE_INT_I16 then return ReadI16()
	elseif TypeId == TYPE_INT_I32 then return ReadI32()
	elseif TypeId == TYPE_NEGATED_INT_U8 then return -ReadU8()
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

local function Truncate(): (buffer, {Instance}?)
	local Trun = BufferCreate(BufferOffset)
	BufferCopy(Trun, 0, ActiveBuffer, 0, BufferOffset)
	return Trun, if InstancesOffset == 0 then nil else Instances
end

local function ResetCursor(C: Cursor)
	C.BufferOffset = 0
	C.InstancesOffset = 0
	table.clear(C.Instances)
	if C.BufferLength > BASE_BUFFER_SIZE * 4 then
		C.Buffer = BufferCreate(BASE_BUFFER_SIZE)
		C.BufferLength = BASE_BUFFER_SIZE
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

export type RequestResponse = {
	RequestSchema: {any},
	ResponseSchema: {any},
	Timeout: number,
}

export type Packet = {
	Id: number,
	Name: string?,
	Reliable: boolean,
	UseDelta: boolean,
	RequestResponse: RequestResponse?,
	OnServerEvent: Signal<(Player, ...any)>,
	OnClientEvent: Signal<...any>,
	OnServerInvoke: ((Player, ...any) -> ...any)?,
	OnClientInvoke: ((...any) -> ...any)?,
	Fire: (self: Packet, ...any) -> ...any,
	FireClient: (self: Packet, Player: Player, ...any) -> ...any,
	FireAllClients: (self: Packet, ...any) -> (),
	SetRequestResponse: (self: Packet, ResponseSchema: {any}, Timeout: number?) -> Packet,
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
		Buffer = BufferCreate(BASE_BUFFER_SIZE),
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
				return BroadcastReliableCursor :: Cursor
			else
				if not BroadcastUnreliableCursor then
					BroadcastUnreliableCursor = CreateCursor()
				end
				return BroadcastUnreliableCursor :: Cursor
			end
		end
		local Cursors = if Reliable then PlayerReliableCursors else PlayerUnreliableCursors
		if not Cursors[Player :: any] then
			Cursors[Player :: any] = CreateCursor()
		end
		return Cursors[Player :: any]
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
	if BufferLen(B) > COMPRESSION_THRESHOLD then
		local Compressed = LZAV.compress(B)
		local CompressedLen = BufferLen(Compressed)
		local FinalBuffer = BufferCreate(CompressedLen + 4)
		BufferWriteU32(FinalBuffer, 0, BufferLen(B))
		BufferCopy(FinalBuffer, 4, Compressed, 0, CompressedLen)
		return FinalBuffer, true
	end
	return B, false
end

local function DecompressBuffer(Incoming: buffer, Compressed: boolean): buffer
	if not Compressed then
		return Incoming
	end

	local IncomingLen = BufferLen(Incoming)
	if IncomingLen < 4 then
		error("Invalid compressed buffer: missing size header")
	end

	local DecompressedSize = BufferReadU32(Incoming, 0)

	if DecompressedSize > MAX_BUFFER_SIZE then
		error("Decompression size exceeds limit")
	end

	local PayloadSize = IncomingLen - 4

	if PayloadSize < 10 and DecompressedSize > 0 then
		error("Compressed payload too small for LZAV")
	end

	local CompressedData = BufferCreate(PayloadSize)
	if PayloadSize > 0 then
		BufferCopy(CompressedData, 0, Incoming, 4, PayloadSize)
	end

	return LZAV.decompress(CompressedData, DecompressedSize)
end

function Sequena.Define(Schema: {any}, Reliable: boolean?, Name: string?, UseDelta: boolean?): Packet
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

function Sequena.CreatePacket(Name: string)
	local Builder: {[string]: any} = {
		Schema = {} :: {any},
		Reliable = Config.Network.DefaultReliable,
		UseDelta = false,
		Timeout = Config.Network.DefaultTimeout,
		ResponseSchema = nil :: {any}?,
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
	function Builder:Build(): Packet
		local P = Sequena.Define(Builder.Schema, Builder.Reliable, Name, Builder.UseDelta)
		if Builder.ResponseSchema then
			P:SetRequestResponse(Builder.ResponseSchema, Builder.Timeout)
		end
		return P
	end
	return Builder
end

function Sequena.Listen(P: Packet, Callback: (...any) -> ...any)
	if RunService:IsServer() then
		P.OnServerInvoke = Callback :: any
	else
		P.OnClientInvoke = Callback :: any
	end
end

local function ResolvePacket(Target: Packet | string | number): Packet?
	if type(Target) == "table" and (Target :: any).Fire and (Target :: any).Id ~= nil then
		return Target :: Packet
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

function Sequena.Fire(Target: Packet | string | number, ...: any)
	local P = ResolvePacket(Target)
	if not P then return end
	P:Fire(...)
end

function Sequena.FireClient(Player: Player, Target: Packet | string | number, ...: any)
	local P = ResolvePacket(Target)
	if not P then return end
	P:FireClient(Player, ...)
end

function Sequena.FireAllClients(Target: Packet | string | number, ...: any)
	local P = ResolvePacket(Target)
	if not P then return end
	P:FireAllClients(...)
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
			BufferLength = BufferLen(ProcessBuffer),
			BufferOffset = 0,
			Instances = Inst or {},
			InstancesOffset = 0
		})

		while BufferOffset < BufferLength do
			local PacketId = ReadU8()
			local Entry = Registry[PacketId]

			if not Entry then
				if Sender then
					HandleSuspicious(Sender :: Player, `Unknown packet ID: {PacketId}`)
				end
				break
			end

			if Entry.ResponseReadFuncs then
				local YieldId = ReadU8()
				if YieldId >= 128 then
					YieldId -= 128
					if Config.Security.ValidateYieldIds then
						if RunService:IsServer() then
							local Yields = PlayerYields[Sender :: Player]
							if not Yields or not Yields[YieldId] then
								HandleSuspicious(Sender :: Player, "Invalid yield ID in response")
								return
							end
						else
							if not ClientYields[YieldId] then
								if Sender then HandleSuspicious(Sender :: Player, "Invalid yield ID in response") end
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
						local Yields = PlayerYields[Sender :: Player]
						if Yields and Yields[YieldId] then
							local YieldData = Yields[YieldId]
							if YieldData.Timeout then TaskCancel(YieldData.Timeout) end
							TaskSpawn(YieldData.Thread, table.unpack(Args))
							Yields[YieldId] = nil
						end
					else
						if ClientYields[YieldId] then
							local YieldData = ClientYields[YieldId]
							if YieldData.Timeout then TaskCancel(YieldData.Timeout) end
							TaskSpawn(YieldData.Thread, table.unpack(Args))
							ClientYields[YieldId] = nil
						end
					end
				else
					local N = #Entry.ReadFuncs
					local Args = table.create(N)
					for I = 1, N do
						Args[I] = Entry.ReadFuncs[I]()
					end
					TaskSpawn(function()
						local ResponseArgs
						local P = Entry.Packet :: Packet
						if RunService:IsServer() then
							if P.OnServerInvoke then
								ResponseArgs = { (P.OnServerInvoke :: any)(Sender :: Player, table.unpack(Args)) }
							else
								if Config.Debug.LogWarnings then
									warn(`OnServerInvoke not set for packet {PacketId}`)
								end
								return
							end
						else
							if P.OnClientInvoke then
								ResponseArgs = { (P.OnClientInvoke :: any)(table.unpack(Args)) }
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
				local TargetKey: any = if RunService:IsServer() then Sender else 1
				local Last = Cache[TargetKey]
				local Args = ApplyDelta(Last, Delta)
				Cache[TargetKey] = Delta
				if RunService:IsServer() then
					Entry.Packet.OnServerEvent:Fire(Sender :: Player, table.unpack(Args))
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
	ReliableRemote.OnServerEvent:Connect(function(Player: Player, Compressed: any, Buf: buffer, Inst: {Instance}?)
		if not CheckRateLimit(Player, BufferLen(Buf)) then
			HandleSuspicious(Player, "Rate limit exceeded")
			return
		end
		if not CheckEventRate(Player) then
			HandleSuspicious(Player, "Event rate limit exceeded")
			return
		end
		Process(Player, Buf, Inst, true, Compressed)
	end)
	UnreliableRemote.OnServerEvent:Connect(function(Player: Player, Compressed: any, Buf: buffer, Inst: {Instance}?)
		if not CheckEventRate(Player) then
			HandleSuspicious(Player, "Event rate limit exceeded")
			return
		end
		Process(Player, Buf, Inst, false, Compressed)
	end)
	Players.PlayerRemoving:Connect(function(Player: Player)
		PlayerReliableCursors[Player :: any] = nil
		PlayerUnreliableCursors[Player :: any] = nil
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
	ReliableRemote.OnClientEvent:Connect(function(Compressed: any, Buf: buffer, Inst: {Instance}?)
		Process(nil, Buf, Inst, true, Compressed)
	end)
	UnreliableRemote.OnClientEvent:Connect(function(Compressed: any, Buf: buffer, Inst: {Instance}?)
		Process(nil, Buf, Inst, false, Compressed)
	end)
end

function Sequena.FlushImmediate()
	FlushReliable()
	FlushUnreliable()
end

function Sequena.GetPacketByName(Name: string): Packet?
	local Id = NameRegistry[Name]
	if not Id then return nil end
	local Entry = Registry[Id]
	return Entry and Entry.Packet
end

function Sequena.CreateCursor(): Cursor
	return CreateCursor()
end

function Sequena.ResetCursor(C: Cursor)
	ResetCursor(C)
end

RunService.Heartbeat:Connect(function(_Dt: number)
	if RunService:IsServer() then
		for Player, Cur in PlayerReliableCursors do
			CheckAndFlushBatch(Cur, Player :: any, true)
		end
		for Player, Cur in PlayerUnreliableCursors do
			CheckAndFlushBatch(Cur, Player :: any, false)
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

return Sequena