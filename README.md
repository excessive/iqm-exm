# IQM

Depends on LÖVE 0.10

Intended for use with [LÖVE3D](https://github.com/excessive/love3d), but does not depend on it (you can use this for 2D meshes, too!)

## Usage:
```lua
require "iqm"

-- load:
local model = iqm.load "foo.iqm"
-- If you've got animation data in the file (or any other) you can load it like so:
local anims = model.has_anims and iqm.load_anims "foo.iqm"
-- Note: The data will be loaded, but things like the bind pose and bone matrices will not be computed for you.
-- Utility functions (or another library for this) may be added later.

-- Make sure to enable mipmaps (and sRGB if you're using it, which you should be).
model.textures = {
	Material1 = love.graphics.newImage("foo.png", { srgb = true, mipmaps = true })
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
