# Inter-Quake Model + Excessive Model (.iqm/.exm) Loader

Loader depends on LÖVE 11.x. Requires [CPML](https://github.com/excessive/cpml) for animation support, but not static meshes.

# IQM/EXM specifications

The IQM specification file here (iqm.txt) is derived from upstream, but with clarifications corresponding with existing implementations of the format (upstream exporter and converter), and as implemented by this exporter.

The EXM specification is TBD, but currently the only notable change is the usage of the comment field for JSON scene metadata (objects, properties, curves...). The formats are otherwise completely compatible, and will stay as such unless there's a very good reason in the future (perhaps for a v3 format with blend shapes). It's fairly likely that a future version of the exporter will also provide more guarantees for the vertex format in EXM files.

## Blender Exporter

The Blender exporter supports exporting .iqm and .exm formats. The .exm format is backwards compatible with .iqm, but has an additional metadata block with unspecified json in it (subject to change in future revisions).

It is derived from [the IQM SDK](https://github.com/lsalzman/iqm) a few years ago before the license changed from public domain to MIT. This version has some quality of life improvements and new features as needed for Excessive's games.

## Usage:
```lua
local iqm = require "iqm"

-- load:
local model = iqm.load("foo.exm")

-- Make sure to enable mipmaps
model.textures = {
	Material1 = love.graphics.newImage("foo.png", { mipmaps = true })
}

-- Set filtering to 16x anisotropic.
for _, texture in pairs(model.textures) do
	texture:setFilter("linear", "linear", 16)
end

-- draw:
-- You can draw the whole model as one mesh (just don't set draw range), but
-- if you draw this way you can assign a different shader/textures per-mesh.
-- (naturally, at the expense of more draw calls - do what's best for you)
for _, buffer in ipairs(model.meshes) do
	local texture = model.textures[buffer.material]
	model.mesh:setTexture(texture)
	model.mesh:setDrawRange(buffer.first, buffer.last - buffer.first)
	love.graphics.draw(model.mesh)
end
```
