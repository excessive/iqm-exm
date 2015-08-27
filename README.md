# Inter-Quake Model Loader

Depends on LÖVE 0.10

Intended for use with [LÖVE3D](https://github.com/excessive/love3d), but does not depend on it (you can use this for 2D meshes, too!)

## Usage:
```lua
require "iqm"

-- load:
local model = iqm.load("foo.iqm")

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
for _, buffer in ipairs(model) do
	local texture = model.textures[buffer.material]
	model.mesh:setTexture(texture)
	model.mesh:setDrawRange(buffer.first, buffer.last)
	love.graphics.draw(model.mesh)
end
```
