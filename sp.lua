--[[=====================================================================
      V E N I C E   H U B   |   bLockerman's Minesweeper
      ------------------------------------------------------------------
      Меню      : RightShift  (меняется в «Настройках»)
      Функции   : Показать все мины (решатель + подсветка)
                  Auto Flag, Auto Reveal, FOV, Fullbright,
                  своё небо (6 пресетов), скины на флаг (7 видов)
      Игра      : roblox.com/games/7871169780
      Экзекьютор: любой (Delta / Xeno / Solara / Wave / Krnl / Velocity)
=======================================================================]]

--================= 0. ЧИСТКА ПРЕДЫДУЩЕГО ЗАПУСКА =====================
if _G.__VENICE_MS and type(_G.__VENICE_MS.destroy) == "function" then
    pcall(_G.__VENICE_MS.destroy)
end

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local Tween      = game:GetService("TweenService")
local Lighting   = game:GetService("Lighting")
local Workspace  = workspace

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")
local Camera      = Workspace.CurrentCamera

local VMS = { version = "1.0" }
_G.__VENICE_MS = VMS

local alive = true
local conns = {}
local function bind(c) conns[#conns + 1] = c; return c end

local warned = {}
local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    warn("[Venice Hub] " .. msg)
end

--=========================== 1. НАСТРОЙКИ ============================
local CFG = {
    showMines  = true,     -- подсветка мин / безопасных клеток
    autoFlag   = false,    -- автоматически ставить флаги на найденные мины
    autoReveal = false,    -- прыгать по безопасным клеткам
    fov        = 70,
    fullbright = false,
    sky        = "Default",
    flagSkin   = "Default",
    skinHue    = 280,
    keybind    = Enum.KeyCode.RightShift,
}

--====================== 2. ЦВЕТА И ХЕЛПЕРЫ ===========================
local THEME = {
    bg      = Color3.fromRGB(9, 9, 11),
    panel   = Color3.fromRGB(16, 16, 20),
    panel2  = Color3.fromRGB(24, 24, 30),
    stroke  = Color3.fromRGB(40, 40, 50),
    text    = Color3.fromRGB(238, 238, 245),
    sub     = Color3.fromRGB(126, 128, 142),
    accent  = Color3.fromRGB(150, 92, 255),
    accent2 = Color3.fromRGB(92, 196, 255),
    on      = Color3.fromRGB(120, 232, 150),
    off     = Color3.fromRGB(46, 46, 56),
}

local function new(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function tw(obj, props, dur, style, dir)
    local t = Tween:Create(obj,
        TweenInfo.new(dur or 0.25, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
    t:Play()
    return t
end

local function corner(o, r) return new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
local function stroke(o, c, th, tr)
    return new("UIStroke", { Color = c, Thickness = th or 1, Transparency = tr or 0.4,
                             ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end
local function colorClose(a, b)
    return math.abs(a.R - b.R) < 0.03 and math.abs(a.G - b.G) < 0.03 and math.abs(a.B - b.B) < 0.03
end

--====================== 3. ЛОГИКА ИГРЫ ===============================
local Board = {
    folder = nil, cells = {}, covered = {}, numbers = {},
    grid = {}, w = 0, h = 0, lastCount = -1, attrKey = nil,
}

local PAINT_MINE = Color3.fromRGB(255, 58, 58)
local PAINT_SAFE = Color3.fromRGB(0, 255, 118)

-- поиск доски (Flag.Parts + авто-поиск)
local function findBoard()
    local root = Workspace:FindFirstChild("Flag")
    local parts = root and root:FindFirstChild("Parts")
    if parts and #parts:GetChildren() > 0 then return parts end

    for _, m in ipairs(Workspace:GetChildren()) do
        if m:IsA("Model") then
            local f = m:FindFirstChild("Parts")
            if not f then
                for _, c in ipairs(m:GetChildren()) do
                    if c:IsA("Folder") then f = c break end
                end
            end
            if f then
                local n = 0
                for _, c in ipairs(f:GetChildren()) do
                    if c:IsA("BasePart") then n += 1 else n = 0 break end
                end
                if n >= 9 then return f end
            end
        end
    end
    return nil
end

local function minDiff(list)
    local s = {}
    for i = 1, #list do s[i] = list[i] end
    table.sort(s)
    local m
    for i = 2, #s do
        local d = s[i] - s[i - 1]
        if d > 0.01 and (not m or d < m) then m = d end
    end
    return m or 5
end

local function cluster(list, tol)
    table.sort(list)
    local out, sum, n = {}, 0, 0
    for i = 1, #list do
        local v = list[i]
        if n > 0 and v - (sum / n) > tol then
            out[#out + 1] = sum / n
            sum, n = 0, 0
        end
        sum += v; n += 1
    end
    if n > 0 then out[#out + 1] = sum / n end
    return out
end

local function nearest(list, v)
    local best, bd = 1, math.huge
    for i = 1, #list do
        local d = math.abs(list[i] - v)
        if d < bd then best, bd = i, d end
    end
    return best
end

local function findMineAttr(part)
    for k, v in pairs(part:GetAttributes()) do
        local lk = string.lower(k)
        if type(v) == "boolean" and (lk:find("mine") or lk:find("bomb")) then return k end
    end
end

local function buildGrid(folder)
    local parts = {}
    for _, ch in ipairs(folder:GetChildren()) do
        if ch:IsA("BasePart") then parts[#parts + 1] = ch end
    end
    if #parts < 4 then Board.cells = {}; Board.w, Board.h = 0, 0; return end

    local xs, zs, sumY = {}, {}, 0
    for i = 1, #parts do
        local p = parts[i].Position
        xs[i] = p.X; zs[i] = p.Z; sumY += p.Y
    end

    local sp = math.max(minDiff(xs), minDiff(zs), 1)
    local cx, cz = cluster(xs, sp * 0.45), cluster(zs, sp * 0.45)
    local planeY = sumY / #parts
    local w, h = #cx, #cz

    local grid, cells = {}, {}
    for ix = 1, w do grid[ix] = {} end

    for i = 1, #parts do
        local p = parts[i]
        local ix, iz = nearest(cx, p.Position.X), nearest(cz, p.Position.Z)
        local cell = grid[ix][iz]
        if not cell then
            cell = { part = p, ix = ix, iz = iz, pos = Vector3.new(cx[ix], planeY, cz[iz]) }
            grid[ix][iz] = cell
            cells[#cells + 1] = cell
        elseif (p.Position - cell.pos).Magnitude < (cell.part.Position - cell.pos).Magnitude then
            cell.part = p
        end
    end

    for ix = 1, w do
        for iz = 1, h do
            local c = grid[ix][iz]
            if c then
                local nb = {}
                for dx = -1, 1 do
                    for dz = -1, 1 do
                        if dx ~= 0 or dz ~= 0 then
                            local row = grid[ix + dx]
                            local r = row and row[iz + dz]
                            if r then nb[#nb + 1] = r end
                        end
                    end
                end
                c.neigh = nb
            end
        end
    end

    Board.grid, Board.w, Board.h, Board.cells = grid, w, h, cells
    Board.attrKey = findMineAttr(parts[1])
    Board.covered, Board.numbers = {}, {}
end

-- определение состояния клетки
local function numberAt(part)
    local gui = part:FindFirstChild("NumberGui")
    local lbl = gui and gui:FindFirstChild("TextLabel")
    return lbl and tonumber(lbl.Text) or nil
end

local function isGreen(col)   -- закрытая клетка (Moss / Shamrock)
    return col.G > col.R + 0.03 and col.G > col.B + 0.03 and col.G > 0.18
end
local function isGray(col)
    return math.abs(col.R - col.G) < 0.09 and math.abs(col.G - col.B) < 0.09
end

local function setPaint(cell, kind)
    local part = cell.part
    if not part or not part.Parent then return end
    if kind == cell.painted then return end

    if kind == nil then
        if cell.painted then
            if cell.origColor then part.Color = cell.origColor end
            if cell.origMaterial then part.Material = cell.origMaterial end
            cell.painted, cell.applied, cell.origColor, cell.origMaterial = nil, nil, nil, nil
        end
        return
    end

    if not cell.origColor then
        cell.origColor, cell.origMaterial = part.Color, part.Material
    end
    local col = (kind == "mine") and PAINT_MINE or PAINT_SAFE
    part.Color = col
    part.Material = Enum.Material.Neon
    cell.painted, cell.applied = kind, col
end

local function refresh()
    Board.covered, Board.numbers = {}, {}
    local cells = Board.cells
    for i = 1, #cells do
        local c = cells[i]
        local part = c.part
        if part and part.Parent then
            -- если игра сама перекрасила клетку — снимаем свою покраску
            if c.painted and c.applied and not colorClose(part.Color, c.applied) then
                c.painted, c.applied, c.origColor, c.origMaterial = nil, nil, nil, nil
            end

            c.attrMine, c.attrSafe = nil, nil
            if Board.attrKey then
                local v = part:GetAttribute(Board.attrKey)
                if v == true then c.attrMine = true elseif v == false then c.attrSafe = true end
            end

            local num = numberAt(part)
            if num then
                c.state, c.number = "number", num
                Board.numbers[#Board.numbers + 1] = c
            else
                c.number = nil
                if part:FindFirstChildOfClass("Model") then
                    c.state = "flagged"
                elseif c.painted or c.attrMine then
                    c.state = "unknown"
                elseif isGreen(part.Color) then
                    c.state = "unknown"
                elseif isGray(part.Color) then
                    c.state = "blank"
                else
                    c.state = "unknown"
                end
                if c.state == "unknown" or c.state == "flagged" then
                    Board.covered[#Board.covered + 1] = c
                end
            end
        end
    end
end

-- решатель: тривиальная логика + правило подмножеств
local function solve()
    local mine, safe = {}, {}
    local covered = Board.covered

    for i = 1, #covered do
        local c = covered[i]
        if c.state == "flagged" or c.painted == "mine" or c.attrMine then mine[c] = true end
        if c.painted == "safe" or c.attrSafe then safe[c] = true end
    end

    local function constraint(c)
        local unk, mines = {}, 0
        for i = 1, #c.neigh do
            local n = c.neigh[i]
            if mine[n] then mines += 1
            elseif not safe[n] and n.state == "unknown" then unk[#unk + 1] = n end
        end
        return unk, (c.number or 0) - mines
    end

    local numbers = Board.numbers
    for _ = 1, 10 do
        local changed = false

        for i = 1, #numbers do
            local unk, rem = constraint(numbers[i])
            if #unk > 0 then
                if rem <= 0 then
                    for k = 1, #unk do
                        if not safe[unk[k]] then safe[unk[k]] = true; changed = true end
                    end
                elseif rem >= #unk then
                    for k = 1, #unk do
                        if not mine[unk[k]] then mine[unk[k]] = true; changed = true end
                    end
                end
            end
        end

        if not changed then
            local cons = {}
            for i = 1, #numbers do
                local unk, rem = constraint(numbers[i])
                if rem > 0 and rem <= #unk then
                    local set = {}
                    for k = 1, #unk do set[unk[k]] = true end
                    cons[#cons + 1] = { c = numbers[i], set = set, rem = rem, n = #unk }
                end
            end
            for i = 1, #cons do
                local a = cons[i]
                for j = i + 1, #cons do
                    local b = cons[j]
                    if math.abs(a.c.ix - b.c.ix) <= 2 and math.abs(a.c.iz - b.c.iz) <= 2 then
                        local A, B = a, b
                        if a.n > b.n then A, B = b, a end
                        local sub = true
                        for u in pairs(A.set) do
                            if not B.set[u] then sub = false break end
                        end
                        if sub then
                            local diff = B.rem - A.rem
                            if diff >= 0 then
                                local only = {}
                                for u in pairs(B.set) do
                                    if not A.set[u] then only[#only + 1] = u end
                                end
                                if #only > 0 then
                                    if diff == 0 then
                                        for k = 1, #only do
                                            if not safe[only[k]] then safe[only[k]] = true; changed = true end
                                        end
                                    elseif diff == #only then
                                        for k = 1, #only do
                                            if not mine[only[k]] then mine[only[k]] = true; changed = true end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if not changed then break end
    end
    return mine, safe
end

local lastFlag = 0
local function autoFlag(mine)
    if os.clock() - lastFlag < 0.06 then return end
    for c in pairs(mine) do
        local part = c.part
        if part and part.Parent and not part:FindFirstChildOfClass("Model") then
            local cd = part:FindFirstChildOfClass("ClickDetector")
            if cd then
                local ok = pcall(fireclickdetector, cd)
                if not ok then
                    warnOnce("fcd", "fireclickdetector недоступен — Auto Flag выключен.")
                    CFG.autoFlag = false
                end
                lastFlag = os.clock()
                return
            end
        end
    end
end

local function autoReveal()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local best, bd
    for i = 1, #Board.covered do
        local c = Board.covered[i]
        if c.state == "unknown" and c.painted == "safe" then
            local d = (c.pos - hrp.Position).Magnitude
            if not bd or d < bd then best, bd = c, d end
        end
    end
    if best and bd and bd > 0.6 then
        local y = best.pos.Y + best.part.Size.Y / 2 + 3
        hrp.CFrame = CFrame.new(best.pos.X, y, best.pos.Z)
        hrp.AssemblyLinearVelocity = Vector3.new(0, -170, 0)
        task.wait(0.07)
        hrp.AssemblyLinearVelocity = Vector3.zero
    end
end

--====================== 4. ВИЗУАЛЫ: FOV / НЕБО / ФЛАГ ================
local savedFOV = Camera and Camera.FieldOfView or 70
local function applyFOV()
    if Camera then Camera.FieldOfView = CFG.fov end
end

local lightingOrig, hadSky = nil, false
local cc, bloom
local function saveLighting()
    if lightingOrig then return end
    local sky = Lighting:FindFirstChildOfClass("Sky")
    hadSky = sky ~= nil
    lightingOrig = {
        clock = Lighting.ClockTime, amb = Lighting.Ambient, out = Lighting.OutdoorAmbient,
        bright = Lighting.Brightness, fog = Lighting.FogColor,
        fogEnd = Lighting.FogEnd, fogStart = Lighting.FogStart,
        skyProps = sky and {
            Bk = sky.SkyboxBk, Dn = sky.SkyboxDn, Ft = sky.SkyboxFt,
            Lf = sky.SkyboxLf, Rt = sky.SkyboxRt, Up = sky.SkyboxUp,
            stars = sky.StarCount, cel = sky.CelestialBodiesShown, sun = sky.SunAngularSize,
        } or nil,
    }
end

local function getSky()
    local s = Lighting:FindFirstChildOfClass("Sky")
    if not s then
        s = new("Sky", { Name = "VeniceSky" }, Lighting)
    end
    return s
end

local SKY_A = { Bk = 159454299, Dn = 159454296, Ft = 159454293, Lf = 159454286, Rt = 159454300, Up = 159454288 }
local SKY_B = { Bk = 144933338, Dn = 144931530, Ft = 144933262, Lf = 144933244, Rt = 144933299, Up = 144931564 }

local SKY = {
    ["Default"]       = {},
    ["Ночь / звёзды"] = { tex = SKY_A, clock = 0, star = 6000, sun = 8, bright = 1.6,
                          amb = Color3.fromRGB(22, 22, 40), out = Color3.fromRGB(40, 40, 70),
                          fog = Color3.fromRGB(15, 15, 30), fogEnd = 600 },
    ["Космос"]        = { tex = SKY_B, clock = 0, star = 9000, cel = false, bright = 0.8,
                          amb = Color3.fromRGB(8, 8, 18), out = Color3.fromRGB(15, 15, 35),
                          fog = Color3.fromRGB(5, 5, 12), fogEnd = 900 },
    ["Закат"]         = { tex = SKY_A, clock = 17.6, star = 1200, sun = 26, bright = 2.2,
                          amb = Color3.fromRGB(90, 55, 45), out = Color3.fromRGB(130, 80, 60),
                          fog = Color3.fromRGB(255, 150, 90), fogEnd = 450 },
    ["Неон-сити"]     = { tex = SKY_B, clock = 2, star = 4000, bright = 1.2,
                          amb = Color3.fromRGB(50, 25, 80), out = Color3.fromRGB(80, 40, 130),
                          fog = Color3.fromRGB(90, 40, 160), fogEnd = 350,
                          tint = Color3.fromRGB(190, 130, 255), sat = 0.25, bloom = 1 },
    ["Кровавая луна"] = { tex = SKY_A, clock = 0, star = 3000, sun = 14, bright = 1.1,
                          amb = Color3.fromRGB(70, 18, 18), out = Color3.fromRGB(110, 25, 25),
                          fog = Color3.fromRGB(80, 10, 15), fogEnd = 400,
                          tint = Color3.fromRGB(255, 130, 115), sat = 0.2 },
    ["Лёд"]           = { tex = SKY_B, clock = 12, star = 2000, bright = 2,
                          amb = Color3.fromRGB(120, 150, 170), out = Color3.fromRGB(150, 180, 200),
                          fog = Color3.fromRGB(190, 225, 240), fogEnd = 500,
                          tint = Color3.fromRGB(185, 228, 255), sat = 0.15 },
}

local function applySky(name)
    saveLighting()
    local p = SKY[name]

    if not p or name == "Default" then
        local o = lightingOrig
        Lighting.ClockTime, Lighting.Ambient, Lighting.OutdoorAmbient = o.clock, o.amb, o.out
        Lighting.Brightness, Lighting.FogColor = o.bright, o.fog
        Lighting.FogEnd, Lighting.FogStart = o.fogEnd, o.fogStart
        local sky = Lighting:FindFirstChildOfClass("Sky")
        if not hadSky then
            if sky then sky:Destroy() end
        elseif sky and o.skyProps then
            sky.SkyboxBk, sky.SkyboxDn, sky.SkyboxFt = o.skyProps.Bk, o.skyProps.Dn, o.skyProps.Ft
            sky.SkyboxLf, sky.SkyboxRt, sky.SkyboxUp = o.skyProps.Lf, o.skyProps.Rt, o.skyProps.Up
            sky.StarCount, sky.CelestialBodiesShown, sky.SunAngularSize = o.skyProps.stars, o.skyProps.cel, o.skyProps.sun
        end
        if cc then cc.Enabled = false end
        if bloom then bloom.Enabled = false end
        return
    end

    local sky = getSky()
    if p.tex then
        sky.SkyboxBk = "rbxassetid://" .. p.tex.Bk
        sky.SkyboxDn = "rbxassetid://" .. p.tex.Dn
        sky.SkyboxFt = "rbxassetid://" .. p.tex.Ft
        sky.SkyboxLf = "rbxassetid://" .. p.tex.Lf
        sky.SkyboxRt = "rbxassetid://" .. p.tex.Rt
        sky.SkyboxUp = "rbxassetid://" .. p.tex.Up
    end
    sky.StarCount = p.star or 3000
    sky.CelestialBodiesShown = (p.cel ~= false)
    sky.SunAngularSize = p.sun or 12

    if p.clock then Lighting.ClockTime = p.clock end
    if p.bright then Lighting.Brightness = p.bright end
    if p.amb then Lighting.Ambient = p.amb end
    if p.out then Lighting.OutdoorAmbient = p.out end
    if p.fog then Lighting.FogColor = p.fog end
    if p.fogEnd then Lighting.FogEnd = p.fogEnd end
    Lighting.FogStart = 0

    if p.tint then
        cc = cc or new("ColorCorrectionEffect", { Name = "VeniceCC" }, Lighting)
        cc.Enabled = true
        cc.TintColor = p.tint
        cc.Saturation = p.sat or 0
    elseif cc then
        cc.Enabled = false
    end

    if p.bloom then
        bloom = bloom or new("BloomEffect", { Name = "VeniceBloom", Size = 24, Threshold = 0.9, Intensity = 0.9 }, Lighting)
        bloom.Enabled = true
    elseif bloom then
        bloom.Enabled = false
    end
end

local function applyFullbright()
    if CFG.fullbright then
        Lighting.Brightness = 3
        Lighting.Ambient = Color3.fromRGB(160, 160, 160)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
        Lighting.FogEnd = 100000
    else
        applySky(CFG.sky)
    end
end

-- скины на флаг
local flagOrig = setmetatable({}, { __mode = "k" })
local function skinDefault(p)
    local o = flagOrig[p]
    if o then
        p.Color, p.Material, p.Transparency, p.Reflectance =
            o.Color, o.Material, o.Transparency, o.Reflectance
    end
end

local SKINS = {
    ["Default"]      = skinDefault,
    ["Neon Violet"]  = function(p) p.Color = Color3.fromRGB(170, 92, 255); p.Material = Enum.Material.Neon; p.Transparency = 0 end,
    ["Cyan Ice"]     = function(p) p.Color = Color3.fromRGB(120, 225, 255); p.Material = Enum.Material.Glass; p.Transparency = 0.25; p.Reflectance = 0.2 end,
    ["Gold"]         = function(p) p.Color = Color3.fromRGB(255, 200, 70); p.Material = Enum.Material.Metal; p.Reflectance = 0.35 end,
    ["Blood"]        = function(p) p.Color = Color3.fromRGB(205, 20, 35); p.Material = Enum.Material.Neon end,
    ["Ghost"]        = function(p) p.Color = Color3.fromRGB(255, 255, 255); p.Material = Enum.Material.ForceField; p.Transparency = 0.35 end,
    ["Rainbow"]      = function(p, t) p.Color = Color3.fromHSV((t * 0.22) % 1, 0.75, 1); p.Material = Enum.Material.Neon end,
    ["Custom Hue"]   = function(p) p.Color = Color3.fromHSV((CFG.skinHue % 360) / 360, 0.85, 1); p.Material = Enum.Material.Neon end,
}

local function applySkins(t)
    local fn = SKINS[CFG.flagSkin] or skinDefault
    local cells = Board.cells
    for i = 1, #cells do
        local part = cells[i].part
        if part and part.Parent then
            local model = part:FindFirstChildOfClass("Model")
            if model then
                for _, p in ipairs(model:GetDescendants()) do
                    if p:IsA("BasePart") then
                        if not flagOrig[p] then
                            flagOrig[p] = { Color = p.Color, Material = p.Material,
                                            Transparency = p.Transparency, Reflectance = p.Reflectance }
                        end
                        fn(p, t)
                    end
                end
            end
        end
    end
end

local function clearAllPaint()
    for i = 1, #Board.cells do setPaint(Board.cells[i], nil) end
end

--====================== 5. UI ========================================
local gui = new("ScreenGui", {
    Name = "VeniceMinesweeper", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
}, PlayerGui)

local main = new("Frame", {
    Name = "Main", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(620, 400), BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0, ClipsDescendants = true, Visible = false,
}, gui)
corner(main, 16)
stroke(main, THEME.accent, 1, 0.7)
new("UIGradient", { Rotation = 90,
    Color = ColorSequence.new(Color3.fromRGB(17, 17, 22), Color3.fromRGB(8, 8, 10)) }, main)
local mainScale = new("UIScale", { Scale = 1 }, main)

local top = new("Frame", { Size = UDim2.new(1, 0, 0, 50), BackgroundTransparency = 1 }, main)

local title = new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 18, 0, 11), Size = UDim2.new(0, 320, 0, 20),
    Font = Enum.Font.GothamBold, TextSize = 16, Text = "VENICE HUB",
    TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left,
}, top)
new("UIGradient", { Color = ColorSequence.new(THEME.accent2, THEME.accent) }, title)

new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 18, 0, 29), Size = UDim2.new(0, 320, 0, 14),
    Font = Enum.Font.Gotham, TextSize = 11, Text = "bLockerman's Minesweeper",
    TextColor3 = THEME.sub, TextXAlignment = Enum.TextXAlignment.Left,
}, top)

local collapsed = false
local function toggleWindow()
    if main.Visible then
        tw(mainScale, { Scale = 0.92 }, 0.16)
        local t = tw(main, { BackgroundTransparency = 0 }, 0.16, Enum.EasingStyle.Quad)
        t.Completed:Connect(function()
            if not main.Visible then return end
            main.Visible = false
        end)
    else
        main.Visible = true
        mainScale.Scale = 0.92
        tw(mainScale, { Scale = 1 }, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    end
end

local function topButton(txt, x, cb)
    local b = new("TextButton", {
        Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(1, x, 0, 12),
        BackgroundColor3 = THEME.panel2, Text = txt, Font = Enum.Font.GothamBold,
        TextSize = 15, TextColor3 = THEME.text, AutoButtonColor = false, BorderSizePixel = 0,
    }, top)
    corner(b, 8)
    bind(b.MouseEnter:Connect(function() tw(b, { BackgroundColor3 = THEME.accent }, 0.15) end))
    bind(b.MouseLeave:Connect(function() tw(b, { BackgroundColor3 = THEME.panel2 }, 0.15) end))
    bind(b.MouseButton1Click:Connect(cb))
    return b
end

topButton("×", -36, function()
    tw(mainScale, { Scale = 0.9 }, 0.18)
    tw(main, { BackgroundTransparency = 1 }, 0.18)
    task.delay(0.19, function() main.Visible = false end)
end)

topButton("—", -70, function()
    collapsed = not collapsed
    tw(main, { Size = UDim2.fromOffset(620, collapsed and 50 or 400) }, 0.32)
    if not collapsed then
        sidebar.Visible, content.Visible, statusbar.Visible = true, true, true
    else
        task.delay(0.18, function()
            if collapsed then sidebar.Visible, content.Visible, statusbar.Visible = false, false, false end
        end)
    end
end)

-- перетаскивание окна
do
    local dragging, startPos, startMouse
    bind(top.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, startMouse, startPos = true, input.Position, main.Position
        end
    end))
    bind(UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - startMouse
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    bind(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

local sidebar = new("Frame", {
    Size = UDim2.new(0, 152, 1, -80), Position = UDim2.new(0, 0, 0, 50),
    BackgroundTransparency = 1,
}, main)

local indicator = new("Frame", {
    Size = UDim2.fromOffset(3, 18), Position = UDim2.new(0, 0, 0, 20),
    BackgroundColor3 = THEME.accent, BorderSizePixel = 0,
}, sidebar)
corner(indicator, 2)

local content = new("Frame", {
    Size = UDim2.new(1, -170, 1, -86), Position = UDim2.new(0, 162, 0, 52),
    BackgroundTransparency = 1,
}, main)

local statusbar = new("TextLabel", {
    Size = UDim2.new(1, -36, 0, 22), Position = UDim2.new(0, 18, 1, -28),
    BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 12,
    TextColor3 = THEME.sub, TextXAlignment = Enum.TextXAlignment.Left, Text = "...",
}, main)

local pages, tabButtons, currentTab = {}, {}, nil

local function makePage(name)
    local p = new("ScrollingFrame", {
        Name = name, Size = UDim2.new(1, 0, 1, 0), Position = UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
        ScrollBarThickness = 3, ScrollBarImageColor3 = THEME.accent,
        CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, content)
    new("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 8),
                       PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 10) }, p)
    new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, p)
    pages[name] = p
    return p
end

local function switchTab(name)
    if currentTab == name then return end
    local old = currentTab
    currentTab = name

    for n, b in pairs(tabButtons) do
        local active = (n == name)
        tw(b, { BackgroundColor3 = active and THEME.panel2 or THEME.panel }, 0.2)
        tw(b, { TextColor3 = active and THEME.text or THEME.sub }, 0.2)
    end

    local btn = tabButtons[name]
    if btn then
        tw(indicator, { Position = UDim2.new(0, 0, 0, btn.Position.Y.Offset + btn.AbsoluteSize.Y / 2 - 9) }, 0.28)
    end

    if old and pages[old] then pages[old].Visible = false end
    local p = pages[name]
    p.Visible = true
    p.Position = UDim2.new(0, 12, 0, 0)
    tw(p, { Position = UDim2.new(0, 0, 0, 0) }, 0.26)
end

local function makeTab(name, label, order)
    local b = new("TextButton", {
        Name = name, Size = UDim2.new(1, -12, 0, 36), Position = UDim2.new(0, 12, 0, 12 + (order - 1) * 40),
        BackgroundColor3 = THEME.panel, Text = label, Font = Enum.Font.GothamMedium,
        TextSize = 13, TextColor3 = THEME.sub, AutoButtonColor = false, BorderSizePixel = 0,
        TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = order,
    }, sidebar)
    corner(b, 9)
    new("UIPadding", { PaddingLeft = UDim.new(0, 14) }, b)
    bind(b.MouseEnter:Connect(function()
        if currentTab ~= name then tw(b, { BackgroundColor3 = THEME.panel2 }, 0.15) end
    end))
    bind(b.MouseLeave:Connect(function()
        if currentTab ~= name then tw(b, { BackgroundColor3 = THEME.panel }, 0.15) end
    end))
    bind(b.MouseButton1Click:Connect(function() switchTab(name) end))
    tabButtons[name] = b
    makePage(name)
    return b
end

-- --- элементы управления ---
local function row(page, h)
    local f = new("Frame", {
        Size = UDim2.new(1, 0, 0, h or 40), BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0, LayoutOrder = #page:GetChildren(),
    }, page)
    corner(f, 9)
    bind(f.MouseEnter:Connect(function() tw(f, { BackgroundColor3 = THEME.panel2 }, 0.15) end))
    bind(f.MouseLeave:Connect(function() tw(f, { BackgroundColor3 = THEME.panel }, 0.15) end))
    return f
end

local function section(page, text)
    local l = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Text = text,
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = THEME.accent2,
        TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = #page:GetChildren(),
    }, page)
    new("UIPadding", { PaddingLeft = UDim.new(0, 4) }, l)
    return l
end

local function labelText(page, text, h)
    local l = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, h or 20), BackgroundTransparency = 1, Text = text,
        Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = THEME.sub,
        TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
        LayoutOrder = #page:GetChildren(),
    }, page)
    new("UIPadding", { PaddingLeft = UDim.new(0, 4) }, l)
    return l
end

local function toggle(page, text, key, cb)
    local f = row(page, 40)
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -74, 1, 0),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)

    local track = new("Frame", {
        Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -54, 0.5, -10),
        BackgroundColor3 = CFG[key] and THEME.on or THEME.off, BorderSizePixel = 0,
    }, f)
    corner(track, 10)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = CFG[key] and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, track)
    corner(knob, 7)

    local function render(instant)
        local on = CFG[key]
        local props = { BackgroundColor3 = on and THEME.on or THEME.off }
        local kp = on and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        if instant then
            track.BackgroundColor3 = props.BackgroundColor3
            knob.Position = kp
        else
            tw(track, props, 0.2)
            tw(knob, { Position = kp }, 0.2)
        end
    end

    local hit = new("TextButton", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "" }, f)
    bind(hit.MouseButton1Click:Connect(function()
        CFG[key] = not CFG[key]
        render()
        if cb then cb(CFG[key]) end
    end))
    return render
end

local function slider(page, text, key, min, max, decimals, cb)
    local f = row(page, 52)
    local lbl = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 6), Size = UDim2.new(1, -74, 0, 16),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)
    local val = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(1, -80, 0, 6), Size = UDim2.new(0, 66, 0, 16),
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = THEME.accent2,
        TextXAlignment = Enum.TextXAlignment.Right, Text = tostring(CFG[key]),
    }, f)

    local bar = new("TextButton", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 28), Size = UDim2.new(1, -28, 0, 16),
        Text = "", AutoButtonColor = false,
    }, f)
    local track = new("Frame", {
        Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0.5, -3),
        BackgroundColor3 = THEME.off, BorderSizePixel = 0,
    }, bar)
    corner(track, 3)
    local pct = math.clamp((CFG[key] - min) / (max - min), 0, 1)
    local fill = new("Frame", { Size = UDim2.new(pct, 0, 1, 0), BackgroundColor3 = THEME.accent, BorderSizePixel = 0 }, track)
    corner(fill, 3)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(pct, 0, 0.5, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
    }, track)
    corner(knob, 6)

    local function setValue(v, instant)
        v = math.clamp(v, min, max)
        CFG[key] = tonumber(string.format("%." .. decimals .. "f", v))
        local p = (CFG[key] - min) / (max - min)
        val.Text = tostring(CFG[key])
        if instant then
            fill.Size = UDim2.new(p, 0, 1, 0)
            knob.Position = UDim2.new(p, 0, 0.5, 0)
        else
            tw(fill, { Size = UDim2.new(p, 0, 1, 0) }, 0.08)
            tw(knob, { Position = UDim2.new(p, 0, 0.5, 0) }, 0.08)
        end
        if cb then cb(CFG[key]) end
    end

    local dragging = false
    bind(bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            local w = bar.AbsoluteSize.X
            if w > 0 then setValue(min + (max - min) * math.clamp((input.Position.X - bar.AbsolutePosition.X) / w, 0, 1)) end
        end
    end))
    bind(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local w = bar.AbsoluteSize.X
        if w > 0 then setValue(min + (max - min) * math.clamp((input.Position.X - bar.AbsolutePosition.X) / w, 0, 1)) end
    end))
    bind(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    setValue(CFG[key], true)
    return setValue
end

local function button(page, text, cb, accent)
    local b = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = accent or THEME.panel,
        Text = text, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = THEME.text,
        AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = #page:GetChildren(),
    }, page)
    corner(b, 9)
    bind(b.MouseEnter:Connect(function() tw(b, { BackgroundColor3 = accent or THEME.panel2 }, 0.15) end))
    bind(b.MouseLeave:Connect(function() tw(b, { BackgroundColor3 = accent or THEME.panel }, 0.15) end))
    bind(b.MouseButton1Click:Connect(function()
        tw(b, { Size = UDim2.new(0.97, 0, 0, 38) }, 0.08)
        tw(b, { Size = UDim2.new(1, 0, 0, 38) }, 0.12)
        if cb then cb() end
    end))
    return b
end

local function dropdown(page, text, key, options, cb)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = #page:GetChildren(),
    }, page)
    corner(holder, 9)

    local head = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Text = "",
        AutoButtonColor = false,
    }, holder)
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -110, 1, 0),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, head)
    local cur = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(1, -110, 0, 0), Size = UDim2.new(0, 78, 1, 0),
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = THEME.accent2,
        Text = tostring(CFG[key]), TextXAlignment = Enum.TextXAlignment.Right,
    }, head)
    local arrow = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(1, -28, 0, 0), Size = UDim2.new(0, 20, 1, 0),
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = THEME.sub, Text = "v",
    }, head)

    local list = new("Frame", {
        Size = UDim2.new(1, 0, 0, #options * 28), Position = UDim2.new(0, 0, 0, 40),
        BackgroundTransparency = 1,
    }, holder)
    new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, list)

    local open = false
    local function setOpen(v)
        open = v
        tw(holder, { Size = UDim2.new(1, 0, 0, v and (40 + #options * 30) or 40) }, 0.25)
        arrow.Text = v and "^" or "v"
    end

    local rowButtons = {}
    for i, opt in ipairs(options) do
        local b = new("TextButton", {
            Size = UDim2.new(1, -12, 0, 28), Position = UDim2.new(0, 6, 0, 0),
            BackgroundColor3 = (CFG[key] == opt) and THEME.panel2 or Color3.fromRGB(20, 20, 25),
            Text = "  " .. opt, Font = Enum.Font.Gotham, TextSize = 12,
            TextColor3 = (CFG[key] == opt) and THEME.accent2 or THEME.sub,
            AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = i,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, list)
        corner(b, 7)
        rowButtons[opt] = b
        bind(b.MouseEnter:Connect(function() tw(b, { BackgroundColor3 = THEME.panel2 }, 0.12) end))
        bind(b.MouseLeave:Connect(function()
            if CFG[key] ~= opt then tw(b, { BackgroundColor3 = Color3.fromRGB(20, 20, 25) }, 0.12) end
        end))
        bind(b.MouseButton1Click:Connect(function()
            CFG[key] = opt
            for o, rb in pairs(rowButtons) do
                rb.TextColor3 = (o == opt) and THEME.accent2 or THEME.sub
                rb.BackgroundColor3 = (o == opt) and THEME.panel2 or Color3.fromRGB(20, 20, 25)
            end
            cur.Text = opt
            setOpen(false)
            if cb then cb(opt) end
        end))
    end

    bind(head.MouseButton1Click:Connect(function() setOpen(not open) end))
    return holder
end

local awaitingKey = false
local function keybindRow(page, text, key, cb)
    local f = row(page, 40)
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -140, 1, 0),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)
    local b = new("TextButton", {
        Size = UDim2.new(0, 110, 0, 26), Position = UDim2.new(1, -124, 0.5, -13),
        BackgroundColor3 = THEME.panel2, Text = CFG[key].Name, Font = Enum.Font.GothamMedium,
        TextSize = 12, TextColor3 = THEME.accent2, AutoButtonColor = false, BorderSizePixel = 0,
    }, f)
    corner(b, 8)
    bind(b.MouseButton1Click:Connect(function()
        awaitingKey = true
        b.Text = "нажми клавишу..."
    end))
    VMS._setKey = function(k)
        CFG[key] = k
        b.Text = k.Name
        if cb then cb(k) end
    end
    return b
end

-- --- наполнение вкладок ---
local tabMines = makeTab("Mines", "МИНЫ", 1)
local tabVisual = makeTab("Visual", "ВИЗУАЛЫ", 2)
local tabSet = makeTab("Settings", "НАСТРОЙКИ", 3)

section(tabMines, "РЕШАТЕЛЬ")
local renderShow = toggle(tabMines, "Показать все мины", "showMines", function(v)
    if not v then clearAllPaint() end
end)
toggle(tabMines, "Auto Flag (ставить флаги)", "autoFlag")
toggle(tabMines, "Auto Reveal (прыгать по безопасным)", "autoReveal")
button(tabMines, "Пересобрать доску", function()
    Board.lastCount = -1
end)
button(tabMines, "Сбросить подсветку", clearAllPaint)
labelText(tabMines, "Красное — мина, зелёное — безопасная клетка. Данные берутся из логики цифр; если игра отдаёт атрибуты мин, они используются напрямую.", 44)

section(tabVisual, "КАМЕРА")
slider(tabVisual, "FOV (поле зрения)", "fov", 50, 130, 0, applyFOV)
toggle(tabVisual, "Fullbright", "fullbright", applyFullbright)

section(tabVisual, "НЕБО")
dropdown(tabVisual, "Пресет неба", "sky", {
    "Default", "Ночь / звёзды", "Космос", "Закат", "Неон-сити", "Кровавая луна", "Лёд",
}, function(v) applySky(v); applyFullbright() end)

section(tabVisual, "СКИН НА ФЛАГ")
dropdown(tabVisual, "Скин флага", "flagSkin", {
    "Default", "Neon Violet", "Cyan Ice", "Gold", "Blood", "Ghost", "Rainbow", "Custom Hue",
})
slider(tabVisual, "Оттенок (Custom Hue)", "skinHue", 0, 360, 0)

section(tabSet, "УПРАВЛЕНИЕ")
keybindRow(tabSet, "Клавиша меню", "keybind")
slider(tabSet, "Прозрачность окна", "_t", 0, 1, 2, function(v)
    main.BackgroundTransparency = v
end)
button(tabSet, "Выгрузить скрипт", function() VMS.destroy() end)
labelText(tabSet, "Venice Hub 1.0 · Minesweeper Edition", 18)

-- тосты
local toastHolder = new("Frame", {
    Size = UDim2.new(0, 250, 0, 400), Position = UDim2.new(1, -18, 1, -18),
    AnchorPoint = Vector2.new(1, 1), BackgroundTransparency = 1,
}, gui)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
                      VerticalAlignment = Enum.VerticalAlignment.Bottom }, toastHolder)

local function notify(text)
    local outer = new("Frame", { Size = UDim2.new(1, 0, 0, 42), BackgroundTransparency = 1,
                                 LayoutOrder = #toastHolder:GetChildren() }, toastHolder)
    local inner = new("Frame", {
        Size = UDim2.new(1, 0, 1, 0), Position = UDim2.new(0, 250, 0, 0),
        BackgroundColor3 = THEME.panel, BorderSizePixel = 0,
    }, outer)
    corner(inner, 10)
    stroke(inner, THEME.accent, 1, 0.6)
    new("TextLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(1, -18, 1, 0), Position = UDim2.new(0, 12, 0, 0),
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, inner)

    tw(inner, { Position = UDim2.new(0, 0, 0, 0) }, 0.3)
    task.delay(2.6, function()
        tw(inner, { Position = UDim2.new(0, 260, 0, 0) }, 0.25)
        task.delay(0.3, function() outer:Destroy() end)
    end)
end

switchTab("Mines")

--====================== 6. ГЛАВНЫЙ ЦИКЛ ==============================
local lastSolve, mineSet, safeSet = 0, {}, {}
local solveMode = "логика"

local function tick(t)
    local folder = findBoard()
    if folder ~= Board.folder then
        Board.folder, Board.lastCount = folder, folder and #folder:GetChildren() or -1
        if folder then buildGrid(folder) end
        clearAllPaint()
    elseif folder and #folder:GetChildren() ~= Board.lastCount then
        Board.lastCount = #folder:GetChildren()
        buildGrid(folder)
        clearAllPaint()
    end

    if not Board.folder or #Board.cells == 0 then
        statusbar.Text = "Ожидание доски..."
        return
    end

    refresh()

    local needSolve = CFG.showMines or CFG.autoFlag or CFG.autoReveal
    if needSolve and t - lastSolve > 0.3 then
        lastSolve = t
        mineSet, safeSet = solve()
    end

    if CFG.showMines then
        local painted = 0
        for i = 1, #Board.covered do
            local c = Board.covered[i]
            local want = mineSet[c] and "mine" or (safeSet[c] and "safe" or nil)
            setPaint(c, want)
            if want then painted += 1 end
        end
        if CFG.autoFlag then autoFlag(mineSet) end
    else
        if CFG.autoFlag then autoFlag(mineSet) end
    end

    if CFG.autoReveal then autoReveal() end
    applySkins(t)
    applyFOV()

    local mines, safe = 0, 0
    for _ in pairs(mineSet) do mines += 1 end
    for _ in pairs(safeSet) do safe += 1 end
    statusbar.Text = string.format("Доска %dx%d  |  мины: %d  |  безопасно: %d  |  режим: %s",
        Board.w, Board.h, mines, safe, Board.attrKey and "атрибуты" or "логика")
end

task.spawn(function()
    local t = 0
    while alive do
        t += 0.12
        local ok, err = pcall(tick, t)
        if not ok then warnOnce("tick", tostring(err)) end
        task.wait(0.12)
    end
end)

--====================== 7. ВВОД ======================================
bind(UIS.InputBegan:Connect(function(input, gp)
    if not alive then return end

    if awaitingKey then
        awaitingKey = false
        if input.KeyCode ~= Enum.KeyCode.Unknown and VMS._setKey then VMS._setKey(input.KeyCode) end
        return
    end

    if input.KeyCode == CFG.keybind and not gp then
        toggleWindow()
    end
end))

bind(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera
    applyFOV()
end))

--====================== 8. ВЫГРУЗКА ==================================
function VMS.destroy()
    if not alive then return end
    alive = false

    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}

    pcall(clearAllPaint)
    pcall(function()
        for part, o in pairs(flagOrig) do
            if part and part.Parent then
                part.Color, part.Material = o.Color, o.Material
                part.Transparency, p.Reflectance = o.Transparency, o.Reflectance
            end
        end
    end)

    if lightingOrig then
        Lighting.ClockTime, Lighting.Ambient, Lighting.OutdoorAmbient = lightingOrig.clock, lightingOrig.amb, lightingOrig.out
        Lighting.Brightness, Lighting.FogColor = lightingOrig.bright, lightingOrig.fog
        Lighting.FogEnd, Lighting.FogStart = lightingOrig.fogEnd, lightingOrig.fogStart
        local sky = Lighting:FindFirstChild("VeniceSky")
        if sky and not hadSky then sky:Destroy() end
    end
    if cc then cc:Destroy() end
    if bloom then bloom:Destroy() end
    if Camera then Camera.FieldOfView = savedFOV end
    if gui then gui:Destroy() end

    _G.__VENICE_MS = nil
    print("[Venice Hub] выгружен")
end

--====================== 9. СТАРТ =====================================
applyFOV()
notify("Venice Hub загружен — " .. CFG.keybind.Name .. " = меню")
print("[Venice Hub] загружен. RightShift — открыть меню.")
