local base = (...):gsub('%.init$', '') .. "."
local c = require(base .. "iqm-ffi")
local ffi = require "ffi"

local iqm = {}

iqm.lookup = {}

function iqm.load(file)
	assert(love.filesystem.isFile(file))

	-- Make sure it's a valid IQM file first
	local magic = love.filesystem.read(file, 16)
	assert(magic == "INTERQUAKEMODEL\0")

	-- HACK: Workaround for a bug in LuaJIT's GC - we need to turn it off for the
	-- rest of the function or we'll get a segfault shortly into these loops.
	--
	-- I've got no idea why the GC thinks it can pull the rug out from under us,
	-- but I sure as hell don't appreciate it. -ss
	collectgarbage("stop")

	-- Decode the header, it's got all the offsets
	local iqm_header = ffi.typeof("struct iqmheader*")
	local size   = ffi.sizeof("struct iqmheader")
	local data   = love.filesystem.read(file)
	local header = ffi.cast(iqm_header, data)[0]

	-- We only support IQM version 2
	assert(header.version == 2)

	local function read_offset(data, type, offset, num)
		local decoded = {}
		local type_ptr = ffi.typeof(type.."*")
		local size = ffi.sizeof(type)
		local ptr = ffi.cast(type_ptr, data:sub(offset+1))
		for i = 1, num do
			table.insert(decoded, ptr[i-1])
		end
		return decoded
	end

	-- a bit simpler than read_offset, don't bother converting to a table.
	local function read_ptr(data, type, offset)
		local type_ptr = ffi.typeof(type.."*")
		local size = ffi.sizeof(type)
		local ptr = ffi.cast(type_ptr, data:sub(offset+1))
		return ptr
	end

	-- Decode the vertex arrays
	local vertex_arrays = read_offset(
		data,
		"struct iqmvertexarray",
		header.ofs_vertexarrays,
		header.num_vertexarrays
	)

	local function translate_va(type)
		local types = {
			[c.IQM_POSITION]     = "position",
			[c.IQM_TEXCOORD]     = "texcoord",
			[c.IQM_NORMAL]       = "normal",
			[c.IQM_TANGENT]      = "tangent",
			[c.IQM_COLOR]        = "color",
			[c.IQM_BLENDINDEXES] = "bone",
			[c.IQM_BLENDWEIGHTS] = "weight"
		}
		return types[type] or false
	end

	local function translate_format(type)
		local types = {
			[c.IQM_FLOAT] = "float",
			[c.IQM_UBYTE] = "byte",
		}
		return types[type] or false
	end

	local function translate_love(type)
		local types = {
			position = "VertexPosition",
			texcoord = "VertexTexCoord",
			normal   = "VertexNormal",
			tangent  = "VertexTangent",
			bone     = "VertexBone",
			weight   = "VertexWeight",
			color    = "VertexColor",
		}
		return assert(types[type])
	end

	-- Build iqm_vertex struct out of whatever is in this file
	local found = {}
	local found_names = {}
	local found_types = {}

	for _, va in ipairs(vertex_arrays) do
		while true do

		local type = translate_va(va.type)
		if not type then
			break
		end

		local format = assert(translate_format(va.format))

		table.insert(found, string.format("%s %s[%d]", format, type, va.size))
		table.insert(found_names, type)
		table.insert(found_types, {
			type        = type,
			size        = va.size,
			offset      = va.offset,
			format      = format,
			love_type   = translate_love(type)
		})

		break end
	end
	table.sort(found_names)
	local title = "iqm_vertex_" .. table.concat(found_names, "_")
	print(title)

	local type = iqm.lookup[title]
	if not type then
		local def = string.format("struct %s {\n\t%s;\n};", title, table.concat(found, ";\n\t"))
		ffi.cdef(def)

		local ct = ffi.typeof("struct " .. title)
		iqm.lookup[title] = ct
		type = ct
	end

	local filedata = love.filesystem.newFileData(("\0"):rep(header.num_vertexes * ffi.sizeof(type)), "dummy")
	local vertices = ffi.cast("struct " .. title .. "*", filedata:getPointer())

	local correct_srgb = select(3, love.window.getMode()).srgb

	-- Interleave vertex data
	for _, va in ipairs(found_types) do
		local ptr = read_ptr(data, va.format, va.offset)
		for i = 0, header.num_vertexes-1 do
			for j = 0, va.size-1 do
				vertices[i][va.type][j] = ptr[i*va.size+j]
			end
			if va.type == "color" and correct_srgb then
				local v = vertices[i][va.type]
				local r, g, b = love.math.gammaToLinear(v[0] / 255, v[1] / 255, v[2] / 255)
				v[0], v[1], v[2] = r*255, g*255, b*255
			end
		end
	end

	-- Decode triangle data (index buffer)
	local triangles = read_offset(
		data,
		"struct iqmtriangle",
		header.ofs_triangles,
		header.num_triangles
	)
	assert(#triangles == header.num_triangles)

	-- Translate indices for love
	local indices = {}
	for _, triangle in ipairs(triangles) do
		table.insert(indices, triangle.vertex[0] + 1)
		table.insert(indices, triangle.vertex[1] + 1)
		table.insert(indices, triangle.vertex[2] + 1)
	end

	collectgarbage("restart")

	local layout = {}
	for i, va in ipairs(found_types) do
		layout[i] = { va.love_type, va.format, va.size }
	end

	local m = love.graphics.newMesh(layout, filedata, "triangles")
	m:setVertexMap(indices)

	-- Decode mesh/material names.
	local text = read_ptr(
		data,
		"char",
		header.ofs_text
	)
	--[[
	-- Collect all text data in the file.
	-- Not needed for meshes because everything is byte offsets - but very
	-- useful for debugging.
	local strings = {}
	local advance = 1

	-- header.num_text is the length of the text block in bytes.
	repeat
		local str = ffi.string(text + advance)
		table.insert(strings, str)
		advance = advance + str:len() + 1
		print(str)
	until advance >= header.num_text

	--]]

	-- Decode meshes
	local meshes = read_offset(
		data,
		"struct iqmmesh",
		header.ofs_meshes,
		header.num_meshes
	)

	local objects = {}
	objects.mesh = m
	for i, mesh in ipairs(meshes) do
		local add = {
			first    = mesh.first_triangle * 3 + 1,
			count    = mesh.num_triangles * 3,
			material = ffi.string(text+mesh.material),
			name     = ffi.string(text+mesh.name)
		}
		add.last = add.first + add.count
		table.insert(objects, add)
	end

	return objects
end

return iqm
