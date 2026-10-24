--[[=====================================================================
      V E N I C E   H U B   |   bLockerman's Minesweeper   v2.2
      ------------------------------------------------------------------
      Меню     : Home   (меняется в «Настройках»)
      Мины     : точные мины/безопасные (логика + подмножества),
                 тепловая карта риска по ВСЕЙ доске,
                 регулируемая прозрачность подсветки,
                 открытые клетки не закрашиваются,
                 авто-флаги, rage-вскрытие карты
      Визуалы  : FOV, Fullbright, 6 пресетов неба, скины на флаг
      Игра     : roblox.com/games/7871169780
=======================================================================]]

--====================== 0. ЧИСТКА ====================================
if _G.__VENICE_MS and type(_G.__VENICE_MS.destroy) == "function" then
    pcall(_G.__VENICE_MS.destroy)
end

local Players           = game:GetService("Players")
local UIS               = game:GetService("UserInputService")
local Tween             = game:GetService("TweenService")
local Lighting          = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = workspace

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer:WaitForChild("PlayerGui")
local Camera      = Workspace.CurrentCamera

local VMS = { version = "2.2" }
_G.__VENICE_MS = VMS

local alive = true
local conns = {}
local function bind(c) conns[#conns + 1] = c; return c end

local warned = {}
local function warnOnce(k, m)
    if warned[k] then return end
    warned[k] = true
    warn("[Venice Hub] " .. m)
end

--====================== 1. НАСТРОЙКИ =================================
local CFG = {
    showMines  = true,
    heatmap    = true,
    autoFlag   = false,
    autoReveal = false,
    density    = 0.16,
    paintTrans = 0.35,     -- прозрачность подсветки (0 = сплошная заливка)
    fov        = 70,
    fullbright = false,
    sky        = "Default",
    flagSkin   = "Default",
    skinHue    = 280,
    keybind    = Enum.KeyCode.Home,
    uiTrans    = 0,
}

--====================== 2. ТЕМА И ХЕЛПЕРЫ ============================
local THEME = {
    bg      = Color3.fromRGB(9, 9, 11),
    panel   = Color3.fromRGB(16, 16, 20),
    panel2  = Color3.fromRGB(24, 24, 30),
    stroke  = Color3.fromRGB(42, 42, 52),
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
        TweenInfo.new(dur or 0.22, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
    t:Play()
    return t
end

local function corner(o, r) return new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
local function stroke(o, c, th, tr)
    return new("UIStroke", { Color = c, Thickness = th or 1, Transparency = tr or 0.4,
                             ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end
local function colorClose(a, b, tol)
    tol = tol or 0.03
    return math.abs(a.R - b.R) < tol and math.abs(a.G - b.G) < tol and math.abs(a.B - b.B) < tol
end

--====================== 3. ЛОГИКА ДОСКИ ==============================
local Board = {
    folder = nil, cells = {}, covered = {}, numbers = {},
    w = 0, h = 0, lastCount = -1, truthMode = "логика", coverColor = nil,
}

local PAINTS = {
    mine  = Color3.fromRGB(255, 45, 45),
    safe  = Color3.fromRGB(0, 255, 110),
    gmine = Color3.fromRGB(255, 150, 40),
    gsafe = Color3.fromRGB(80, 165, 255),
    guess = Color3.fromRGB(0, 255, 255),
}

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

-- (объявлено ДО buildGrid — buildGrid их использует)
local function numberAt(part)
    local gui = part:FindFirstChild("NumberGui")
    local lbl = gui and gui:FindFirstChild("TextLabel")
    return lbl and tonumber(lbl.Text) or nil
end

local function probeTruth(part)
    for k, v in pairs(part:GetAttributes()) do
        local lk = string.lower(k)
        if type(v) == "boolean" then
            if lk:find("mine") or lk:find("bomb") then return v and "mine" or "safe" end
            if lk:find("safe") then return v and "safe" or "mine" end
        end
    end
    for _, ch in ipairs(part:GetChildren()) do
        if ch:IsA("BoolValue") then
            local n = string.lower(ch.Name)
            if n:find("mine") or n:find("bomb") then return ch.Value and "mine" or "safe" end
            if n:find("safe") then return ch.Value and "safe" or "mine" end
        end
    end
    return nil
end

local function isGreen(col)
    return col.G > col.R + 0.03 and col.G > col.B + 0.03 and col.G > 0.18
end

-- закрытая клетка = зелёная ИЛИ совпадает с авто-определённым цветом закрытых
local function isCoveredColor(col)
    if isGreen(col) then return true end
    local cc = Board.coverColor
    if cc and colorClose(col, cc, 0.09) then return true end
    return false
end

local function buildGrid(folder)
    local parts = {}
    for _, ch in ipairs(folder:GetChildren()) do
        if ch:IsA("BasePart") then parts[#parts + 1] = ch end
    end
    if #parts < 4 then Board.cells, Board.w, Board.h = {}, 0, 0; return end

    -- авто-определение цвета закрытой клетки (самый частый цвет среди неоткрытых)
    do
        local counts, sample = {}, {}
        for i = 1, #parts do
            local p = parts[i]
            if not numberAt(p) and not p:FindFirstChildOfClass("Model") then
                local key = ("%d_%d_%d"):format(math.floor(p.Color.R * 8), math.floor(p.Color.G * 8), math.floor(p.Color.B * 8))
                counts[key] = (counts[key] or 0) + 1
                sample[key] = p.Color
            end
        end
        local bk, bn
        for k, n in pairs(counts) do
            if not bn or n > bn then bk, bn = k, n end
        end
        Board.coverColor = bk and sample[bk] or nil
    end

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
    Board.covered, Board.numbers = {}, {}
end

local function setPaint(cell, kind)
    local part = cell.part
    if not part or not part.Parent then return end

    -- уже так покрашено: синхронизируем только прозрачность (живой слайдер)
    if kind == cell.painted then
        if kind and math.abs(part.Transparency - CFG.paintTrans) > 0.001 then
            part.Transparency = CFG.paintTrans
        end
        return
    end

    if kind == nil then
        if cell.painted then
            if cell.origColor then part.Color = cell.origColor end
            if cell.origMaterial then part.Material = cell.origMaterial end
            if cell.origTrans ~= nil then part.Transparency = cell.origTrans end
            cell.painted, cell.applied = nil, nil
            cell.origColor, cell.origMaterial, cell.origTrans = nil, nil, nil
        end
        return
    end

    if not cell.origColor then
        cell.origColor, cell.origMaterial, cell.origTrans = part.Color, part.Material, part.Transparency
    end
    part.Color = PAINTS[kind] or PAINTS.gsafe
    part.Material = Enum.Material.Neon
    part.Transparency = CFG.paintTrans
    cell.painted, cell.applied = kind, part.Color
end

local function clearAllPaint()
    for i = 1, #Board.cells do setPaint(Board.cells[i], nil) end
end

local function refresh()
    Board.covered, Board.numbers = {}, {}
    local cells, truthHits = Board.cells, 0
    for i = 1, #cells do
        local c = cells[i]
        local part = c.part
        if part and part.Parent then
            -- игра перекрасила клетку => она открылась, снимаем подсветку и возвращаем вид
            if c.painted and c.applied and not colorClose(part.Color, c.applied) then
                if c.origMaterial then part.Material = c.origMaterial end
                if c.origTrans ~= nil then part.Transparency = c.origTrans end
                c.painted, c.applied = nil, nil
                c.origColor, c.origMaterial, c.origTrans = nil, nil, nil
            end

            c.truth = probeTruth(part)
            if c.truth then truthHits += 1 end

            local num = numberAt(part)
            if num then
                c.state, c.number = "number", num
                Board.numbers[#Board.numbers + 1] = c
            else
                c.number = nil
                if part:FindFirstChildOfClass("Model") then
                    c.state = "flagged"
                elseif c.painted then
                    c.state = "unknown"                 -- стоит наша краска => ещё закрыта
                elseif isCoveredColor(part.Color) then
                    c.state = "unknown"
                elseif c.truth == "mine" then
                    c.state = "unknown"
                else
                    c.state = "blank"                   -- открытая пустая клетка
                end
                if c.state == "unknown" or c.state == "flagged" then
                    Board.covered[#Board.covered + 1] = c
                end
            end
        end
    end
    Board.truthMode = truthHits > 0 and "атрибуты" or "логика"
end

local function solve()
    local mine, safe = {}, {}
    local covered = Board.covered

    for i = 1, #covered do
        local c = covered[i]
        if c.state == "flagged" or c.painted == "mine" or c.truth == "mine" then mine[c] = true end
        if c.painted == "safe" or c.truth == "safe" then safe[c] = true end
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

local function computeRisk(mine, safe)
    local risk = {}
    local unknown, knownMines = 0, 0
    for i = 1, #Board.covered do
        local c = Board.covered[i]
        if not mine[c] and not safe[c] then unknown += 1 end
    end
    for _ in pairs(mine) do knownMines += 1 end

    local totalEst = math.max(knownMines, math.floor(#Board.cells * CFG.density))
    local prior = unknown > 0 and math.clamp((totalEst - knownMines) / unknown, 0, 1) or CFG.density

    local remOf, unkOf = {}, {}
    for i = 1, #Board.numbers do
        local n = Board.numbers[i]
        local unk, m = {}, 0
        for k = 1, #n.neigh do
            local nb = n.neigh[k]
            if mine[nb] then m += 1
            elseif not safe[nb] and nb.state == "unknown" then unk[#unk + 1] = nb end
        end
        remOf[n], unkOf[n] = (n.number or 0) - m, unk
    end

    local best, bestR
    for i = 1, #Board.covered do
        local c = Board.covered[i]
        if not mine[c] and not safe[c] then
            local sum, cnt = 0, 0
            for k = 1, #c.neigh do
                local n = c.neigh[k]
                local u = unkOf[n]
                if u and #u > 0 then
                    sum += math.clamp((remOf[n] or 0) / #u, 0, 1)
                    cnt += 1
                end
            end
            local r = cnt > 0 and (sum / cnt) or prior
            risk[c] = r
            if not bestR or r < bestR then best, bestR = c, r end
        end
    end
    return risk, best
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

local function autoReveal(safe)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local best, bd
    for i = 1, #Board.covered do
        local c = Board.covered[i]
        if safe[c] and c.state == "unknown" then
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

--====================== 4. ВИЗУАЛЫ ===================================
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
    if not s then s = new("Sky", { Name = "VeniceSky" }, Lighting) end
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

local flagOrig = setmetatable({}, { __mode = "k" })
local function skinDefault(p)
    local o = flagOrig[p]
    if o then
        p.Color, p.Material, p.Transparency, p.Reflectance =
            o.Color, o.Material, o.Transparency, o.Reflectance
    end
end

local SKINS = {
    ["Default"]     = skinDefault,
    ["Neon Violet"] = function(p) p.Color = Color3.fromRGB(170, 92, 255); p.Material = Enum.Material.Neon; p.Transparency = 0 end,
    ["Cyan Ice"]    = function(p) p.Color = Color3.fromRGB(120, 225, 255); p.Material = Enum.Material.Glass; p.Transparency = 0.25; p.Reflectance = 0.2 end,
    ["Gold"]        = function(p) p.Color = Color3.fromRGB(255, 200, 70); p.Material = Enum.Material.Metal; p.Reflectance = 0.35 end,
    ["Blood"]       = function(p) p.Color = Color3.fromRGB(205, 20, 35); p.Material = Enum.Material.Neon end,
    ["Ghost"]       = function(p) p.Color = Color3.fromRGB(255, 255, 255); p.Material = Enum.Material.ForceField; p.Transparency = 0.35 end,
    ["Rainbow"]     = function(p, t) p.Color = Color3.fromHSV((t * 0.22) % 1, 0.75, 1); p.Material = Enum.Material.Neon end,
    ["Custom Hue"]  = function(p) p.Color = Color3.fromHSV((CFG.skinHue % 360) / 360, 0.85, 1); p.Material = Enum.Material.Neon end,
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

--====================== 5. UI ========================================
local gui = new("ScreenGui", {
    Name = "VeniceMinesweeper", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
}, PlayerGui)

local W, H = 660, 470

local main = new("Frame", {
    Name = "Main", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(W, H), BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0, ClipsDescendants = true, Visible = false,
}, gui)
corner(main, 16)
stroke(main, THEME.accent, 1, 0.7)
new("UIGradient", { Rotation = 90,
    Color = ColorSequence.new(Color3.fromRGB(17, 17, 22), Color3.fromRGB(8, 8, 10)) }, main)
local mainScale = new("UIScale", { Scale = 1 }, main)

local sidebar, content, statusbar, indicator

local top = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1 }, main)

local title = new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 18, 0, 12), Size = UDim2.new(0, 340, 0, 20),
    Font = Enum.Font.GothamBold, TextSize = 16, Text = "VENICE HUB",
    TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left,
}, top)
new("UIGradient", { Color = ColorSequence.new(THEME.accent2, THEME.accent) }, title)

new("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.new(0, 18, 0, 30), Size = UDim2.new(0, 340, 0, 14),
    Font = Enum.Font.Gotham, TextSize = 11, Text = "bLockerman's Minesweeper  ·  Home = меню",
    TextColor3 = THEME.sub, TextXAlignment = Enum.TextXAlignment.Left,
}, top)

local collapsed = false
local function toggleWindow()
    if main.Visible then
        tw(mainScale, { Scale = 0.92 }, 0.16)
        local t = tw(main, { BackgroundTransparency = 1 }, 0.16, Enum.EasingStyle.Quad)
        t.Completed:Connect(function()
            if not main.Visible then return end
            main.Visible = false
        end)
    else
        main.Visible = true
        mainScale.Scale = 0.92
        tw(main, { BackgroundTransparency = CFG.uiTrans }, 0.2)
        tw(mainScale, { Scale = 1 }, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    end
end

local function topButton(txt, x, cb)
    local b = new("TextButton", {
        Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(1, x, 0, 13),
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
    tw(main, { Size = UDim2.fromOffset(W, collapsed and 52 or H) }, 0.3)
    if not collapsed then
        sidebar.Visible, content.Visible, statusbar.Visible = true, true, true
    else
        task.delay(0.15, function()
            if collapsed then sidebar.Visible, content.Visible, statusbar.Visible = false, false, false end
        end)
    end
end)

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

sidebar = new("Frame", {
    Size = UDim2.new(0, 158, 1, -82), Position = UDim2.new(0, 0, 0, 52),
    BackgroundTransparency = 1,
}, main)

indicator = new("Frame", {
    Size = UDim2.fromOffset(3, 20), Position = UDim2.new(0, 0, 0, 20),
    BackgroundColor3 = THEME.accent, BorderSizePixel = 0,
}, sidebar)
corner(indicator, 2)

content = new("Frame", {
    Size = UDim2.new(1, -182, 1, -94), Position = UDim2.new(0, 170, 0, 60),
    BackgroundTransparency = 1,
}, main)

statusbar = new("TextLabel", {
    Size = UDim2.new(1, -36, 0, 22), Position = UDim2.new(0, 18, 1, -30),
    BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 12,
    TextColor3 = THEME.sub, TextXAlignment = Enum.TextXAlignment.Left, Text = "ожидание доски...",
}, main)

local pages, cursors, tabButtons, currentTab = {}, {}, {}, nil
local syncers = {}
local function syncUI() for _, f in ipairs(syncers) do pcall(f) end end

local function makePage(name)
    local p = new("ScrollingFrame", {
        Name = name, Size = UDim2.new(1, 0, 1, 0), Position = UDim2.new(0, 0, 0, 0),
        BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
        ScrollBarThickness = 3, ScrollBarImageColor3 = THEME.accent,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.new(0, 0, 0, 400),
    }, content)
    pages[name] = p
    cursors[p] = 0
    return p
end

local function switchTab(name)
    if currentTab == name then return end
    currentTab = name
    for n, p in pairs(pages) do p.Visible = (n == name) end
    for n, b in pairs(tabButtons) do
        local active = (n == name)
        tw(b, { BackgroundColor3 = active and THEME.panel2 or THEME.panel }, 0.2)
        tw(b, { TextColor3 = active and THEME.text or THEME.sub }, 0.2)
    end
    local btn = tabButtons[name]
    if btn and indicator then
        tw(indicator, { Position = UDim2.new(0, 0, 0, btn.Position.Y.Offset + 8) }, 0.26)
    end
end

local function makeTab(name, label, order)
    local b = new("TextButton", {
        Name = name, Size = UDim2.new(1, -12, 0, 38), Position = UDim2.new(0, 12, 0, 12 + (order - 1) * 44),
        BackgroundColor3 = THEME.panel, Text = label, Font = Enum.Font.GothamMedium,
        TextSize = 13, TextColor3 = THEME.sub, AutoButtonColor = false, BorderSizePixel = 0,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, sidebar)
    corner(b, 9)
    new("UIPadding", { PaddingLeft = UDim.new(0, 16) }, b)
    bind(b.MouseEnter:Connect(function()
        if currentTab ~= name then tw(b, { BackgroundColor3 = THEME.panel2 }, 0.15) end
    end))
    bind(b.MouseLeave:Connect(function()
        if currentTab ~= name then tw(b, { BackgroundColor3 = THEME.panel }, 0.15) end
    end))
    bind(b.MouseButton1Click:Connect(function() switchTab(name) end))
    tabButtons[name] = b
    return makePage(name)
end

local function item(page, h, gap, transparent)
    local y = cursors[page] or 0
    cursors[page] = y + h + (gap or 6)
    page.CanvasSize = UDim2.new(0, 0, 0, cursors[page] + 6)
    local f = new("Frame", {
        Size = UDim2.new(1, -10, 0, h), Position = UDim2.new(0, 0, 0, y),
        BackgroundColor3 = THEME.panel, BackgroundTransparency = transparent and 1 or 0,
        BorderSizePixel = 0, ZIndex = 1,
    }, page)
    if not transparent then corner(f, 9) end
    return f
end

local function hoverable(f)
    bind(f.MouseEnter:Connect(function() tw(f, { BackgroundColor3 = THEME.panel2 }, 0.15) end))
    bind(f.MouseLeave:Connect(function() tw(f, { BackgroundColor3 = THEME.panel }, 0.15) end))
end

local function addSection(page, text)
    local f = item(page, 22, 4, true)
    new("TextLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(1, -12, 1, 0), Position = UDim2.new(0, 6, 0, 0),
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = THEME.accent2,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)
    return f
end

local function addNote(page, text, h)
    local f = item(page, h or 34, 6, true)
    new("TextLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(1, -12, 1, 0), Position = UDim2.new(0, 6, 0, 0),
        Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = THEME.sub,
        Text = text, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
    }, f)
    return f
end

local function addToggle(page, text, key, cb)
    local f = item(page, 38)
    hoverable(f)
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -76, 1, 0),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)

    local track = new("Frame", {
        Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -54, 0, 9),
        BackgroundColor3 = CFG[key] and THEME.on or THEME.off, BorderSizePixel = 0, ZIndex = 2,
    }, f)
    corner(track, 10)
    local knob = new("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = CFG[key] and UDim2.new(1, -17, 0, 3) or UDim2.new(0, 3, 0, 3),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3,
    }, track)
    corner(knob, 7)

    local function render()
        local on = CFG[key]
        tw(track, { BackgroundColor3 = on and THEME.on or THEME.off }, 0.18)
        tw(knob, { Position = on and UDim2.new(1, -17, 0, 3) or UDim2.new(0, 3, 0, 3) }, 0.18)
    end
    syncers[#syncers + 1] = render

    local hit = new("TextButton", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 4 }, f)
    bind(hit.MouseButton1Click:Connect(function()
        CFG[key] = not CFG[key]
        render()
        if cb then cb(CFG[key]) end
    end))
    return f
end

local function addSlider(page, text, key, min, max, decimals, cb)
    if CFG[key] == nil then CFG[key] = min end
    local f = item(page, 48)

    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 6), Size = UDim2.new(1, -100, 0, 16),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)
    local val = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(1, -90, 0, 6), Size = UDim2.new(0, 76, 0, 16),
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = THEME.accent2,
        TextXAlignment = Enum.TextXAlignment.Right, Text = tostring(CFG[key]),
    }, f)

    local bar = new("TextButton", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 26), Size = UDim2.new(1, -28, 0, 16),
        Text = "", AutoButtonColor = false, ZIndex = 2,
    }, f)
    local track = new("Frame", {
        Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0, 5),
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
    local function fromInput(input)
        local w = bar.AbsoluteSize.X
        if w <= 0 then return end
        setValue(min + (max - min) * math.clamp((input.Position.X - bar.AbsolutePosition.X) / w, 0, 1))
    end

    bind(bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            fromInput(input)
        end
    end))
    bind(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
        fromInput(input)
    end))
    bind(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    setValue(CFG[key], true)
    return f
end

local function addButton(page, text, cb, accent)
    local y = cursors[page] or 0
    local b = new("TextButton", {
        Size = UDim2.new(1, -10, 0, 36), Position = UDim2.new(0, 0, 0, y),
        BackgroundColor3 = accent or THEME.panel, Text = text, Font = Enum.Font.GothamMedium,
        TextSize = 13, TextColor3 = THEME.text, AutoButtonColor = false, BorderSizePixel = 0,
    }, page)
    cursors[page] = y + 42
    page.CanvasSize = UDim2.new(0, 0, 0, cursors[page] + 6)
    corner(b, 9)
    bind(b.MouseEnter:Connect(function() tw(b, { BackgroundColor3 = accent or THEME.panel2 }, 0.15) end))
    bind(b.MouseLeave:Connect(function() tw(b, { BackgroundColor3 = accent or THEME.panel }, 0.15) end))
    bind(b.MouseButton1Click:Connect(function()
        tw(b, { Size = UDim2.new(1, -14, 0, 36) }, 0.08)
        tw(b, { Size = UDim2.new(1, -10, 0, 36) }, 0.12)
        if cb then cb() end
    end))
    return b
end

local function addDropdown(page, text, key, options, cb)
    local f = item(page, 38)
    hoverable(f)
    f.ZIndex = 5

    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -120, 1, 0),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)
    local cur = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(1, -112, 0, 0), Size = UDim2.new(0, 80, 1, 0),
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = THEME.accent2,
        Text = tostring(CFG[key]), TextXAlignment = Enum.TextXAlignment.Right,
    }, f)
    local arrow = new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(1, -28, 0, 0), Size = UDim2.new(0, 20, 1, 0),
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = THEME.sub, Text = "v",
    }, f)

    local list = new("Frame", {
        Size = UDim2.new(1, -10, 0, #options * 28 + 6), Position = UDim2.new(0, 0, 0, 40),
        BackgroundColor3 = Color3.fromRGB(12, 12, 16), BorderSizePixel = 0,
        Visible = false, ZIndex = 5,
    }, f)
    corner(list, 8)
    stroke(list, THEME.stroke, 1, 0.3)

    local rows = {}
    for i, opt in ipairs(options) do
        local b = new("TextButton", {
            Size = UDim2.new(1, -8, 0, 26), Position = UDim2.new(0, 4, 0, 3 + (i - 1) * 28),
            BackgroundColor3 = (CFG[key] == opt) and THEME.panel2 or Color3.fromRGB(12, 12, 16),
            Text = "  " .. opt, Font = Enum.Font.Gotham, TextSize = 12,
            TextColor3 = (CFG[key] == opt) and THEME.accent2 or THEME.sub,
            AutoButtonColor = false, BorderSizePixel = 0, TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 6,
        }, list)
        corner(b, 6)
        rows[opt] = b
        bind(b.MouseEnter:Connect(function() tw(b, { BackgroundColor3 = THEME.panel2 }, 0.12) end))
        bind(b.MouseLeave:Connect(function()
            if CFG[key] ~= opt then tw(b, { BackgroundColor3 = Color3.fromRGB(12, 12, 16) }, 0.12) end
        end))
        bind(b.MouseButton1Click:Connect(function()
            CFG[key] = opt
            for o, rb in pairs(rows) do
                rb.TextColor3 = (o == opt) and THEME.accent2 or THEME.sub
                rb.BackgroundColor3 = (o == opt) and THEME.panel2 or Color3.fromRGB(12, 12, 16)
            end
            cur.Text = opt
            list.Visible = false
            arrow.Text = "v"
            page.CanvasSize = UDim2.new(0, 0, 0, (cursors[page] or 0) + 6)
            if cb then cb(opt) end
        end))
    end

    local function render()
        cur.Text = tostring(CFG[key])
        for o, rb in pairs(rows) do
            rb.TextColor3 = (o == CFG[key]) and THEME.accent2 or THEME.sub
            rb.BackgroundColor3 = (o == CFG[key]) and THEME.panel2 or Color3.fromRGB(12, 12, 16)
        end
    end
    syncers[#syncers + 1] = render

    local hit = new("TextButton", {
        Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 7,
    }, f)
    bind(hit.MouseButton1Click:Connect(function()
        list.Visible = not list.Visible
        arrow.Text = list.Visible and "^" or "v"
        page.CanvasSize = UDim2.new(0, 0, 0, (cursors[page] or 0) + (list.Visible and 160 or 6))
    end))
    return f
end

local awaitingKey = false
local function addKeybind(page, text, key, cb)
    local f = item(page, 38)
    hoverable(f)
    new("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -150, 1, 0),
        Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, f)
    local b = new("TextButton", {
        Size = UDim2.new(0, 116, 0, 26), Position = UDim2.new(1, -128, 0, 6),
        BackgroundColor3 = THEME.panel2, Text = CFG[key].Name, Font = Enum.Font.GothamMedium,
        TextSize = 12, TextColor3 = THEME.accent2, AutoButtonColor = false, BorderSizePixel = 0,
        ZIndex = 2,
    }, f)
    corner(b, 8)
    bind(b.MouseButton1Click:Connect(function()
        awaitingKey = true
        b.Text = "жми клавишу..."
    end))
    VMS._setKey = function(k)
        CFG[key] = k
        b.Text = k.Name
        if cb then cb(k) end
    end
    return f
end

local toastHolder = new("Frame", {
    Size = UDim2.new(0, 260, 0, 420), Position = UDim2.new(1, -18, 1, -18),
    AnchorPoint = Vector2.new(1, 1), BackgroundTransparency = 1,
}, gui)

local notify
function notify(text)
    local outer = new("Frame", {
        Size = UDim2.new(1, 0, 0, 42), BackgroundTransparency = 1,
    }, toastHolder)
    local inner = new("Frame", {
        Size = UDim2.new(1, 0, 1, 0), Position = UDim2.new(0, 260, 0, 0),
        BackgroundColor3 = THEME.panel, BorderSizePixel = 0,
    }, outer)
    corner(inner, 10)
    stroke(inner, THEME.accent, 1, 0.6)
    new("TextLabel", {
        BackgroundTransparency = 1, Size = UDim2.new(1, -18, 1, 0), Position = UDim2.new(0, 12, 0, 0),
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = THEME.text,
        Text = text, TextXAlignment = Enum.TextXAlignment.Left,
    }, inner)
    tw(inner, { Position = UDim2.new(0, 0, 0, 0) }, 0.28)
    task.delay(2.6, function()
        tw(inner, { Position = UDim2.new(0, 270, 0, 0) }, 0.24)
        task.delay(0.3, function() outer:Destroy() end)
    end)
end

--====================== 6. НАПОЛНЕНИЕ ================================
local tabMines  = makeTab("Mines", "МИНЫ", 1)
local tabVisual = makeTab("Visual", "ВИЗУАЛЫ", 2)
local tabSet    = makeTab("Settings", "НАСТРОЙКИ", 3)
local tabDebug  = makeTab("Debug", "ДЕБАГ", 4)

addSection(tabMines, "РЕШАТЕЛЬ И ПОДСВЕТКА")
addToggle(tabMines, "Показывать мины и риск", "showMines", function(v)
    if not v then clearAllPaint() end
end)
addToggle(tabMines, "Тепловая карта по всей доске", "heatmap")
addSlider(tabMines, "Прозрачность подсветки", "paintTrans", 0, 0.9, 2)
addToggle(tabMines, "Auto Flag (ставить флаги)", "autoFlag")
addToggle(tabMines, "Auto Reveal (вскрывать безопасные)", "autoReveal")
addButton(tabMines, "RAGE: вскрыть всю карту", function()
    CFG.showMines, CFG.heatmap, CFG.autoFlag, CFG.autoReveal = true, true, true, true
    syncUI()
    notify("Rage-режим: карта вскрывается полностью")
end, THEME.accent)
addButton(tabMines, "Сбросить подсветку", clearAllPaint)
addNote(tabMines, "Красный — мина (точно).  Зелёный — безопасно (точно).  Оранжевый — скорее мина.  Синий — скорее безопасно.  Голубой — лучший ход.  Прозрачность регулируется слайдером; уже открытые клетки не закрашиваются.", 58)

addSection(tabVisual, "КАМЕРА")
addSlider(tabVisual, "FOV (поле зрения)", "fov", 50, 130, 0, applyFOV)
addToggle(tabVisual, "Fullbright", "fullbright", applyFullbright)
addSection(tabVisual, "НЕБО")
addDropdown(tabVisual, "Пресет неба", "sky", {
    "Default", "Ночь / звёзды", "Космос", "Закат", "Неон-сити", "Кровавая луна", "Лёд",
}, function(v) applySky(v); applyFullbright() end)
addSection(tabVisual, "СКИН НА ФЛАГ")
addDropdown(tabVisual, "Скин флага", "flagSkin", {
    "Default", "Neon Violet", "Cyan Ice", "Gold", "Blood", "Ghost", "Rainbow", "Custom Hue",
})
addSlider(tabVisual, "Оттенок (Custom Hue)", "skinHue", 0, 360, 0)

addSection(tabSet, "УПРАВЛЕНИЕ")
addKeybind(tabSet, "Клавиша меню", "keybind")
addSlider(tabSet, "Прозрачность окна", "uiTrans", 0, 1, 2, function(v)
    main.BackgroundTransparency = v
end)
addSlider(tabSet, "Плотность мин (приор)", "density", 0.05, 0.35, 2)
addButton(tabSet, "Вернуть окно в центр", function()
    main.Position = UDim2.fromScale(0.5, 0.5)
end)
addButton(tabSet, "Выгрузить скрипт", function() VMS.destroy() end)

addSection(tabDebug, "ДИАГНОСТИКА")
addButton(tabDebug, "Дамп структуры в консоль (F9)", function()
    local folder = Board.folder
    print("===== VENICE HUB DEBUG =====")
    print("Доска:", folder and folder:GetFullName() or "НЕ НАЙДЕНА")
    print("Цвет закрытой клетки (авто):", tostring(Board.coverColor))
    if folder then
        local kids = folder:GetChildren()
        print("Клеток:", #kids, "| сетка:", Board.w .. "x" .. Board.h)
        for i = 1, math.min(3, #kids) do
            local p = kids[i]
            print(("-- %s [%s] Color=%s BrickColor=%s"):format(p:GetFullName(), p.ClassName,
                tostring(p.Color), p.BrickColor.Name))
            for _, ch in ipairs(p:GetChildren()) do
                print("   child:", ch.ClassName, ch.Name,
                    ch:IsA("ValueBase") and tostring(ch.Value) or "")
            end
            for k, v in pairs(p:GetAttributes()) do
                print("   attr:", k, tostring(v))
            end
        end
    end
    print("--- ReplicatedStorage ---")
    for _, o in ipairs(ReplicatedStorage:GetChildren()) do print("RS:", o.ClassName, o.Name) end
    print("--- Workspace ---")
    for _, o in ipairs(Workspace:GetChildren()) do print("WS:", o.ClassName, o.Name) end
    print("===== END DEBUG =====")
end)
addButton(tabDebug, "Пересобрать доску", function() Board.lastCount = -1 end)
addNote(tabDebug, "Дамп покажет, есть ли у клеток атрибуты/значения про мины — тогда режим в статусе станет «атрибуты» и мины будут точными сразу.", 40)

switchTab("Mines")

--====================== 7. ЦИКЛ ======================================
local lastSolve, mineSet, safeSet, riskSet, bestGuess = 0, {}, {}, {}, nil

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
        statusbar.Text = "ожидание доски..."
        return
    end

    refresh()

    if (CFG.showMines or CFG.autoFlag or CFG.autoReveal) and t - lastSolve > 0.25 then
        lastSolve = t
        mineSet, safeSet = solve()
        riskSet, bestGuess = computeRisk(mineSet, safeSet)
    end

    if CFG.showMines then
        for i = 1, #Board.covered do
            local c = Board.covered[i]
            local want
            if mineSet[c] then want = "mine"
            elseif safeSet[c] then want = "safe"
            elseif CFG.heatmap and riskSet[c] then
                want = (riskSet[c] >= 0.5) and "gmine" or "gsafe"
            end
            setPaint(c, want)
        end
        if CFG.heatmap and bestGuess and bestGuess.part then
            setPaint(bestGuess, "guess")
        end
    else
        for i = 1, #Board.cells do setPaint(Board.cells[i], nil) end
    end

    if CFG.autoFlag then autoFlag(mineSet) end
    if CFG.autoReveal then autoReveal(safeSet) end

    applySkins(t)
    applyFOV()

    local mines, safe, unknown = 0, 0, 0
    for _ in pairs(mineSet) do mines += 1 end
    for _ in pairs(safeSet) do safe += 1 end
    for i = 1, #Board.covered do
        local c = Board.covered[i]
        if not mineSet[c] and not safeSet[c] then unknown += 1 end
    end
    statusbar.Text = ("Доска %dx%d  |  мины: %d  |  безопасно: %d  |  ?%d  |  режим: %s")
        :format(Board.w, Board.h, mines, safe, unknown, Board.truthMode)
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

--====================== 8. ВВОД ======================================
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

--====================== 9. ВЫГРУЗКА ==================================
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
                part.Transparency, part.Reflectance = o.Transparency, o.Reflectance
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

--====================== 10. СТАРТ ====================================
applyFOV()
notify("Venice Hub 2.2 · Home = меню")
print("[Venice Hub 2.2] загружен. Home — меню.")
