local base = (...):gsub('%.?init$', '') .. "."
local c    = require(base .. "iqm-ffi")
local ffi  = require "ffi"

local iqm = {
	_LICENSE     = "Inter-Quake Model Loader is distributed as public domain (Unlicense). See LICENSE.md for full text.",
	_URL         = "https://github.com/excessive/iqm",
	_VERSION     = "1.0.0",
	_DESCRIPTION = "Load an IQM 3D model into LÖVE.",
}

local love = love or lovr
love.filesystem.getInfo = love.filesystem.getInfo or lovr.filesystem.isFile
love.data.newByteData = love.data.newByteData or lovr.data.newBlob

iqm.lookup = {}

local function check_magic(magic)
	return string.sub(tostring(magic),1,16) == "INTERQUAKEMODEL\0"
end

local function load_data(file)
	local is_buffer = check_magic(file)


	-- Make sure it's a valid IQM file
	if not is_buffer then
		assert(love.filesystem.getInfo(file, "file"), string.format("File %s not found", file))
		assert(check_magic(love.filesystem.read(file, 16)))
	end

	-- Decode the header, it's got all the offsets
	local iqm_header  = ffi.typeof("struct iqmheader*")
	local size        = ffi.sizeof("struct iqmheader")
	local header_data
	if is_buffer then
		header_data = file
	else
		header_data = love.filesystem.read(file, size)
	end
	local header = ffi.cast(iqm_header, header_data)[0]

	-- We only support IQM version 2
	assert(header.version == 2)

	-- Only read the amount of data declared by the header, just in case!
	local data = is_buffer and file or love.filesystem.read(file, header.filesize)

	return header, data
end

-- Read `num` element from `data` at `offset` and convert it to a table.
local function read_offset(data, type, offset, num)
	local decoded = {}
	local type_ptr = ffi.typeof(type.."*")
	local size = ffi.sizeof(type)
	local ptr = ffi.cast(type_ptr, string.sub(data, offset+1))
	for i = 1, num do
		table.insert(decoded, ptr[i-1])
	end
	return decoded
end

-- a bit simpler than read_offset, as we don't bother converting to a table.
local function read_ptr(data, type, offset)
	local type_ptr = ffi.typeof(type.."*")
	local size = ffi.sizeof(type)
	local ptr = ffi.cast(type_ptr, string.sub(data, offset+1))
	return ptr
end

-- Collect all text data in the file.
-- Not needed for meshes because everything is byte offsets - but very
-- useful for debugging.
local function dump_strings(text)
	local strings = {}
	local advance = 1

	-- header.num_text is the length of the text block in bytes.
	repeat
		local str = ffi.string(text + advance)
		table.insert(strings, str)
		advance = advance + string.len(str) + 1
		print(str)
	until advance >= header.num_text

	return strings
end

-- 'file' can be either a filename or IQM data (as long as the magic is intact)
function iqm.load(file, save_data, preserve_cw)
	-- HACK: Workaround for a bug in LuaJIT's GC - we need to turn it off for the
	-- rest of the function or we'll get a segfault shortly into these loops.
	--
	-- I've got no idea why the GC thinks it can pull the rug out from under us,
	-- but I sure as hell don't appreciate it. Do NOT restart until the end. -ss
	collectgarbage("stop")

	local header, data = load_data(file)

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
			[c.IQM_UBYTE] = lovr and "ubyte" or "byte",
		}
		return types[type] or false
	end

	local function translate_love(type)
		local types = {
			position = lovr and "lovrPosition" or "VertexPosition",
			texcoord = lovr and "lovrTexCoord" or "VertexTexCoord",
			normal   = lovr and "lovrNormal" or "VertexNormal",
			tangent  = lovr and "lovrTangent" or "VertexTangent",
			bone     = lovr and "lovrBones" or "VertexBone",
			weight   = lovr and "lovrBoneWeights" or "VertexWeight",
			color    = lovr and "lovrVertexColor" or "VertexColor",
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

	-- If we've already got a struct of this type, reuse it.
	local type = iqm.lookup[title]
	if not type then
		local def = string.format("struct %s {\n\t%s;\n};", title, table.concat(found, ";\n\t"))
		ffi.cdef(def)

		local ct = ffi.typeof("struct " .. title)
		iqm.lookup[title] = ct
		type = ct
	end

	local blob = love.data.newByteData(header.num_vertexes * ffi.sizeof(type))
	local vertices = ffi.cast("struct " .. title .. "*", blob:getPointer())

	-- TODO: Compute XY + spherical radiuses
	local computed_bbox = { min = {}, max = {} }

	-- Interleave vertex data
	for _, va in ipairs(found_types) do
		local ptr = read_ptr(data, va.format, va.offset)
		for i = 0, header.num_vertexes-1 do
			for j = 0, va.size-1 do
				vertices[i][va.type][j] = ptr[i*va.size+j]
			end
			if va.type == "position" then
				local v = vertices[i][va.type]
				for i = 1, 3 do
					computed_bbox.min[i] = math.min(computed_bbox.min[i] or v[i-1], v[i-1])
					computed_bbox.max[i] = math.max(computed_bbox.max[i] or v[i-1], v[i-1])
				end
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
		if preserve_cw then
			table.insert(indices, triangle.vertex[0] + 1)
			table.insert(indices, triangle.vertex[1] + 1)
			table.insert(indices, triangle.vertex[2] + 1)
		else
			-- IQM uses CW winding, but we want CCW. Reverse.
			table.insert(indices, triangle.vertex[0] + 1)
			table.insert(indices, triangle.vertex[2] + 1)
			table.insert(indices, triangle.vertex[1] + 1)
		end
	end

	-- re-read the vertex data :(
	local save_buffer = {}
	if save_data then
		local buffer = {}
		for _, va in ipairs(found_types) do
			local ptr = read_ptr(data, va.format, va.offset)
			for i = 1, header.num_vertexes do
				buffer[i] = buffer[i] or {}
				buffer[i][va.type] = {}
				for j = 0, va.size-1 do
					buffer[i][va.type][j+1] = ptr[(i-1)*va.size+j]
				end
			end
		end
		for i, triangle in ipairs(triangles) do
			save_buffer[i] = {
				buffer[triangle.vertex[0] + 1],
				buffer[triangle.vertex[2] + 1],
				buffer[triangle.vertex[1] + 1]
			}
		end
	end

	local layout = {}
	for i, va in ipairs(found_types) do
		layout[i] = { va.love_type, va.format, va.size }
	end

	local m = love.graphics.newMesh(layout, blob, "triangles")
	m:setVertexMap(indices)

	-- Decode mesh/material names.
	local text = read_ptr(
		data,
		"char",
		header.ofs_text
	)

	local objects = {}
	objects.bounds = {}
	objects.bounds.base = computed_bbox
	objects.triangles = save_buffer

	if header.ofs_bounds > 0 then
		local bounds = read_offset(
			data,
			"struct iqmbounds",
			header.ofs_bounds,
			header.num_frames
		)
		for i, bb in ipairs(bounds) do
			table.insert(objects.bounds, {
				min = { bb.bbmins[0], bb.bbmins[1], bb.bbmins[2] },
				max = { bb.bbmaxs[0], bb.bbmaxs[1], bb.bbmaxs[2] }
			})
		end
	end

	-- Decode meshes
	local meshes = read_offset(
		data,
		"struct iqmmesh",
		header.ofs_meshes,
		header.num_meshes
	)

	objects.has_joints = header.ofs_joints > 0
	objects.has_anims = header.ofs_anims > 0
	objects.mesh = m
	objects.meshes = {}
	for i, mesh in ipairs(meshes) do
		local add = {
			first    = mesh.first_triangle * 3 + 1,
			count    = mesh.num_triangles * 3,
			material = ffi.string(text+mesh.material),
			name     = ffi.string(text+mesh.name)
		}
		add.last = add.first + add.count
		table.insert(objects.meshes, add)
	end

	-- in exm, this is a json chunk
	if header.num_comment == 1 then
		local comments = read_ptr(data, "char", header.ofs_comment)
		objects.metadata = ffi.string(comments)
	end

	collectgarbage("restart")

	return objects
end

function iqm.load_anims(file)
	-- Require CPML here because loading the mesh does not depend on it.
	local cpml = require "cpml"

	-- See the comment in iqm.load. Do *NOT* remove. -ss
	collectgarbage("stop")
	local header, data = load_data(file)

	-- Decode mesh/material names.
	local text = read_ptr(
		data,
		"char",
		header.ofs_text
	)

	local anims = {}

	if header.ofs_joints > 0 then
		local skeleton     = {}
		local joints       = read_offset(data, "struct iqmjoint", header.ofs_joints, header.num_joints)
		
		local joint_map    = {}
		for i, joint in ipairs(joints) do
			local name = ffi.string(text+joint.name)
			joint_map[i], joint_map[name] = name, i
		end
		anims.joint_map = joint_map

		for i, joint in ipairs(joints) do
			joint.parent = joint.parent + 1
			local bone = {
				parent   = joint.parent,
				name     = ffi.string(text+joint.name),
				position = cpml.vec3(joint.translate[0], joint.translate[1], joint.translate[2]),
				rotation = cpml.quat(joint.rotate[0], joint.rotate[1], joint.rotate[2], joint.rotate[3]),
				scale    = cpml.vec3(joint.scale[0], joint.scale[1], joint.scale[2])
			}
			skeleton[i], skeleton[bone.name] = bone, bone
		end
		anims.skeleton = skeleton
	end

	if header.ofs_anims > 0 then
		local animdata = read_offset(data, "struct iqmanim", header.ofs_anims, header.num_anims)
		for i, anim in ipairs(animdata) do
			local a = {
				name      = ffi.string(text+anim.name),
				first     = anim.first_frame+1,
				last      = anim.first_frame+anim.num_frames,
				framerate = anim.framerate,
				loop      = bit.band(anim.flags, c.IQM_LOOP) == c.IQM_LOOP
			}

			anims[i], anims[a.name] = a, a
		end
	end

	if header.ofs_poses > 0 then
		local poses = read_offset(data, "struct iqmpose", header.ofs_poses, header.num_poses)
		local framedata = read_ptr(data, "unsigned short", header.ofs_frames)

		local function readv(p, i, mask)
			local v = p.channeloffset[i]
			if bit.band(p.channelmask, mask) > 0 then
				v = v + framedata[0] * p.channelscale[i]
				-- I can see your pointers from here~ o///o
				framedata = framedata + 1
			end
			return v
		end

		anims.frames = {}
		for i = 1, header.num_frames do
			local frame = {}
			for j, p in ipairs(poses) do
				-- This code is in touch with its sensitive side, please leave it be.
				local v = {}
				for o = 0, 9 do
					v[o+1] = readv(p, o, bit.lshift(1, o))
				end
				table.insert(frame, {
					translate = cpml.vec3(v[1], v[2], v[3]),
					rotate    = cpml.quat(v[4], v[5], v[6], v[7]),
					scale     = cpml.vec3(v[8], v[9], v[10])
				})
			end
			table.insert(anims.frames, frame)
		end
	end

	collectgarbage("restart")
	return anims
end

return iqm
