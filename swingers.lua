addon.name    = 'swingers'
addon.author  = 'TreeFidyDad'
addon.version = '1.0'
addon.desc    = 'Standalone pendulum swing timer arc with color gradient.'
addon.link    = 'https://github.com/TreeFidyDad/huntpartner'

require('common')
local imgui = require('imgui')
local settings = require('settings')

------------------------------------------------------------
-- Default settings
------------------------------------------------------------
local defaultConfig = T{
    radius    = 40,
    thickness = 4,
    segments  = 24,
    locked    = false,
    visible   = true,
}

local config = settings.load(defaultConfig)

------------------------------------------------------------
-- Swing tracking state
------------------------------------------------------------
local swing = {
    last_swing = 0,
    interval   = nil,
    samples    = {},
}

------------------------------------------------------------
-- Martial Arts delay reduction (MNK trait)
-- Only MNK main job gets this. Sub-MNK does not.
-- Tiers match HorizonXI (retail base-era values).
------------------------------------------------------------
local MNK_MARTIAL_ARTS = {
    { lvl = 15, reduction =  50 },
    { lvl = 25, reduction =  75 },
    { lvl = 40, reduction = 100 },
    { lvl = 55, reduction = 125 },
    { lvl = 70, reduction = 150 },
}

local function get_martial_arts_reduction()
    local ok, r = pcall(function()
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        if pl:GetMainJob() ~= 2 then return 0 end  -- not MNK main
        local mlvl = pl:GetMainJobLevel() or 0
        local best = 0
        for _, tier in ipairs(MNK_MARTIAL_ARTS) do
            if mlvl >= tier.lvl then best = tier.reduction end
        end
        return best
    end)
    return (ok and r) or 0
end

local function get_main_weapon_delay()
    local ok, delay = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory()
        local eq = inv:GetEquippedItem(0)  -- slot 0 = main hand
        local has_main = eq and eq.Index ~= 0
        local res = nil
        if has_main then
            local container = math.floor(eq.Index / 0x100)
            local slot = eq.Index % 0x100
            local item = inv:GetContainerItem(container, slot)
            if item and item.Id ~= 0 then
                res = AshitaCore:GetResourceManager():GetItemById(item.Id)
            end
        end

        -- H2H / bare-hand MNK detection
        local pl = AshitaCore:GetMemoryManager():GetPlayer()
        local is_mnk_main = pl:GetMainJob() == 2
        local is_h2h_weapon = res and res.Skill == 1
        local is_barehand = (not has_main) and is_mnk_main

        if is_h2h_weapon or is_barehand then
            local base = 480
            local weapon_delay = (res and res.Delay) or 0
            local ma = get_martial_arts_reduction()
            local effective = base + weapon_delay - ma
            if effective < 96 then effective = 96 end
            return effective / 60.0
        end

        if not res or not res.Delay or res.Delay == 0 then return nil end
        return res.Delay / 60.0
    end)
    return ok and delay or nil
end

local function record_swing()
    local t_now = os.clock()
    if swing.last_swing > 0 then
        local gap = t_now - swing.last_swing
        local ceiling
        if swing.interval then
            ceiling = swing.interval * 1.5
        else
            local gear = get_main_weapon_delay()
            ceiling = gear and (gear * 1.5) or 12
        end
        if gap > 0.3 and gap < ceiling then
            table.insert(swing.samples, gap)
            while #swing.samples > 5 do
                table.remove(swing.samples, 1)
            end
            local s = 0
            for _, g in ipairs(swing.samples) do s = s + g end
            swing.interval = s / #swing.samples
        end
    end
    swing.last_swing = t_now
end

local function get_swing_data()
    local interval = swing.interval or get_main_weapon_delay()
    if not interval then return nil end
    local src
    if swing.interval then src = 'observed'
    elseif swing.last_swing > 0 then src = 'gear'
    else src = 'idle' end
    return {
        interval   = interval,
        last_swing = swing.last_swing,
        source     = src,
    }
end

------------------------------------------------------------
-- Packet handler: melee swing detection + zone clear
------------------------------------------------------------
ashita.events.register('packet_in', 'swingtimer_pkt_cb', function(e)
    if e.id == 0x000A or e.id == 0x000B then
        swing.last_swing = 0
        swing.interval   = nil
        swing.samples    = {}
        return
    end
    if e.id ~= 0x28 then return end
    pcall(function()
        local me = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)
        if not me or me == 0 then return end
        local b = e.data:totable()
        local actor_id = ashita.bits.unpack_be(b, 40, 32)
        if actor_id ~= me then return end
        local category = ashita.bits.unpack_be(b, 82, 4)
        if category == 1 then record_swing() end
    end)
end)

------------------------------------------------------------
-- Commands: /swingtimer [show|hide|lock|unlock|radius N|thickness N]
------------------------------------------------------------
ashita.events.register('command', 'swingtimer_cmd_cb', function(e)
    local args = e.command:args()
    if not args[1] or args[1]:lower() ~= '/swingers' then return end
    e.blocked = true

    local sub = (args[2] or ''):lower()
    if sub == 'show' then
        config.visible = true
        print('[Swingers] Visible')
    elseif sub == 'hide' then
        config.visible = false
        print('[Swingers] Hidden')
    elseif sub == 'lock' then
        config.locked = true
        print('[Swingers] Locked')
    elseif sub == 'unlock' then
        config.locked = false
        print('[Swingers] Unlocked')
    elseif sub == 'radius' and args[3] then
        config.radius = tonumber(args[3]) or config.radius
        print('[Swingers] Radius = ' .. config.radius)
    elseif sub == 'thickness' and args[3] then
        config.thickness = tonumber(args[3]) or config.thickness
        print('[Swingers] Thickness = ' .. config.thickness)
    elseif sub == 'segments' and args[3] then
        config.segments = tonumber(args[3]) or config.segments
        print('[Swingers] Segments = ' .. config.segments)
    else
        print('[Swingers] Usage: /swingers [show|hide|lock|unlock|radius N|thickness N|segments N]')
    end
    settings.save()
end)

------------------------------------------------------------
-- Render: pendulum half-arc with cyan->yellow->red gradient
------------------------------------------------------------
ashita.events.register('d3d_present', 'swingtimer_render_cb', function()
    if not config.visible then return end

    local ps = get_swing_data()
    if not ps or not ps.interval or ps.interval <= 0 then return end

    local now = os.clock()
    local sw_int = ps.interval
    local sw_radius = config.radius
    local sw_thickness = config.thickness
    local segs = config.segments

    local swFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_NoBringToFrontOnFocus)
    if config.locked then
        swFlags = bit.bor(swFlags, ImGuiWindowFlags_NoMove)
    end

    local win_w = (sw_radius + sw_thickness) * 2 + 8
    local win_h = sw_radius + sw_thickness + 12
    imgui.SetNextWindowSize({win_w, win_h}, ImGuiCond_FirstUseEver)

    if imgui.Begin('SwingTimer', true, swFlags) then
        local wx, wy = imgui.GetCursorScreenPos()
        local cx = wx + sw_radius + sw_thickness + 2
        local cy = wy + 4
        local dl
        pcall(function() dl = imgui.GetWindowDrawList() end)
        if dl then
            local is_idle = (not ps.last_swing) or ps.last_swing == 0
            local elapsed = is_idle and 0 or (now - ps.last_swing)

            -- Arc sweep: 0° (right) to 180° (left) — bottom half-circle
            local arc_start = math.rad(0)
            local arc_sweep = math.rad(180)

            -- Background track (dim)
            for i = 0, segs - 1 do
                local a1 = arc_start + (arc_sweep * i / segs)
                local a2 = arc_start + (arc_sweep * (i + 1) / segs)
                dl:AddLine(
                    {cx + math.cos(a1) * sw_radius, cy + math.sin(a1) * sw_radius},
                    {cx + math.cos(a2) * sw_radius, cy + math.sin(a2) * sw_radius},
                    imgui.GetColorU32({0.15, 0.15, 0.20, 0.5}), sw_thickness)
            end

            -- Filled progress arc
            if not is_idle and elapsed >= 0 and elapsed <= sw_int * 2.0 then
                local frac = math.min(elapsed / sw_int, 1.0)
                local fill_segs = math.floor(segs * frac)

                for i = 0, fill_segs - 1 do
                    local a1 = arc_start + (arc_sweep * i / segs)
                    local a2 = arc_start + (arc_sweep * (i + 1) / segs)
                    local t_f = i / segs
                    local rC, gC, bC
                    if t_f < 0.5 then
                        rC = 0.30 + 0.70 * (t_f * 2)
                        gC = 0.85 + 0.05 * (t_f * 2)
                        bC = 1.00 - t_f * 2
                    else
                        local t2 = (t_f - 0.5) * 2
                        rC = 1.00
                        gC = 0.90 - 0.60 * t2
                        bC = 0
                    end
                    dl:AddLine(
                        {cx + math.cos(a1) * sw_radius, cy + math.sin(a1) * sw_radius},
                        {cx + math.cos(a2) * sw_radius, cy + math.sin(a2) * sw_radius},
                        imgui.GetColorU32({rC, gC, bC, 0.92}), sw_thickness)
                end

                -- Pendulum "bob" at the tip
                if fill_segs > 0 then
                    local tip_a = arc_start + (arc_sweep * fill_segs / segs)
                    local tip_x = cx + math.cos(tip_a) * sw_radius
                    local tip_y = cy + math.sin(tip_a) * sw_radius
                    local bob_col = (frac >= 0.95)
                        and imgui.GetColorU32({1.0, 0.3, 0.2, 0.9})
                        or  imgui.GetColorU32({1.0, 0.9, 0.4, 0.8})
                    dl:AddCircleFilled({tip_x, tip_y}, sw_thickness + 1, bob_col, 12)
                end

                -- White flash on swing land
                if elapsed < 0.18 then
                    local fa = 0.6 * (1.0 - elapsed / 0.18)
                    for i = 0, segs - 1 do
                        local a1 = arc_start + (arc_sweep * i / segs)
                        local a2 = arc_start + (arc_sweep * (i + 1) / segs)
                        dl:AddLine(
                            {cx + math.cos(a1) * sw_radius, cy + math.sin(a1) * sw_radius},
                            {cx + math.cos(a2) * sw_radius, cy + math.sin(a2) * sw_radius},
                            imgui.GetColorU32({1.0, 1.0, 1.0, fa}), sw_thickness + 2)
                    end
                end
            end
        end
        imgui.Dummy({win_w - 4, win_h - 4})
    end
    imgui.End()
end)

------------------------------------------------------------
-- Load / Unload
------------------------------------------------------------
ashita.events.register('load', 'swingtimer_load_cb', function()
    print('[Swingers] Loaded. /swingers for commands.')
end)

ashita.events.register('unload', 'swingtimer_unload_cb', function()
    settings.save()
end)
