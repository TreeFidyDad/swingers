addon.name    = 'nextauto'
addon.author  = 'TreeFidyDad'
addon.version = '2.0'
addon.desc    = 'Configurable next-auto-attack swing timer (arc or bar) with color gradient.'
addon.link    = 'https://github.com/TreeFidyDad/swingers'

require('common')
local imgui = require('imgui')
local settings = require('settings')

------------------------------------------------------------
-- Default settings
------------------------------------------------------------
local defaultConfig = T{
    -- Geometry
    length    = 84,     -- end-to-end span in pixels
    thickness = 5,      -- bar/arc thickness (height of the stroke)
    segments  = 32,     -- smoothness (number of segments)
    curve     = 1.0,    -- 0 = straight line, 1 = full semicircle arc
    vertical  = false,  -- run vertically instead of horizontally
    reverse   = false,  -- fill from the opposite end

    -- Appearance
    color_start = T{ 0.30, 0.90, 1.00 }, -- cyan  (just swung)
    color_mid   = T{ 1.00, 0.90, 0.20 }, -- yellow (mid)
    color_end   = T{ 1.00, 0.20, 0.15 }, -- red   (swing imminent)
    show_bob    = true,                  -- pendulum bob at the leading edge
    background  = false,                 -- draw a backing window
    bg_color    = T{ 0.05, 0.05, 0.08, 0.60 },

    -- Behavior
    hide_out_of_combat  = true,   -- hide entirely when not engaged
    pause_out_of_combat = true,   -- (when not hiding) freeze instead of run

    -- Window
    locked  = false,
    visible = true,
}

local config = settings.load(defaultConfig)

-- settings.load can leave nested tables shallow; make sure colors are tables.
local function ensure_color(key, def)
    if type(config[key]) ~= 'table' then config[key] = T{ def[1], def[2], def[3], def[4] } end
end
ensure_color('color_start', defaultConfig.color_start)
ensure_color('color_mid',   defaultConfig.color_mid)
ensure_color('color_end',   defaultConfig.color_end)
ensure_color('bg_color',    defaultConfig.bg_color)

-- Curated color presets (/nextauto preset <name>). Start = just swung,
-- End = swing ready; End is intentionally the most aggressive color.
local COLOR_PRESETS = {
    classic = { name = 'Classic Pulse', s = { 0.20, 1.00, 0.55 }, m = { 1.00, 0.85, 0.10 }, e = { 1.00, 0.15, 0.15 } },
    ion     = { name = 'Ion',           s = { 0.10, 0.65, 1.00 }, m = { 1.00, 0.20, 0.80 }, e = { 1.00, 0.45, 0.05 } },
    frost   = { name = 'Frost to Fire',  s = { 0.30, 0.85, 1.00 }, m = { 0.75, 0.55, 1.00 }, e = { 1.00, 0.30, 0.20 } },
}

------------------------------------------------------------
-- Swing tracking state
------------------------------------------------------------
local swing = {
    last_swing    = 0,
    interval      = nil,
    samples       = {},
    action_frozen = false, -- an action (cast/WS/JA/ranged charge) is in progress; arc held
    pause_frac    = 0,     -- arc fraction captured when the freeze/pause began
    pause_until   = 0,     -- os.clock() until which the arc is frozen (post-action lock)
    freeze_safety = 0,     -- absolute backstop release time for an open-ended freeze
    was_engaged   = nil,
}

-- Post-action animation lock (seconds). Per Nerf's LSB analysis, auto-attack
-- delay is frozen for the action's animation time AFTER the finish packet, then
-- resumes from the same fraction. ~2.0s covers the vast majority of JA/WS/spell
-- animations; the cast/charge portion itself is handled by freezing from the
-- start packet until the finish packet arrives, so it needs no estimate.
local DEFAULT_ANIM_LOCK = 2.0
local PET_EXTRA_LOCK    = 1.0   -- extra buffer after pet-command (BST/SMN) finish
local FREEZE_TIMEOUT    = 20.0  -- auto-release an open-ended freeze if finish packet never comes

-- Resource-derived post-action lock. Units of CastTime/AnimationTime vary by
-- Ashita build and are unverified here, so we clamp to a sane range and fall
-- back to the 2.0s default. The freeze-until-finish already covers cast time,
-- so this only needs the post-finish animation portion.
local function anim_lock_from(res_obj)
    local ok, lock = pcall(function()
        if res_obj and res_obj.AnimationTime and res_obj.AnimationTime > 0 then
            local s = res_obj.AnimationTime / 1000.0
            if s >= 0.5 and s <= 6.0 then return s end
        end
        return DEFAULT_ANIM_LOCK
    end)
    return (ok and lock) or DEFAULT_ANIM_LOCK
end

local function get_ability_lock(id)
    local ok, r = pcall(function() return AshitaCore:GetResourceManager():GetAbilityById(id) end)
    return anim_lock_from(ok and r or nil)
end

local function get_spell_post_lock(id)
    local ok, r = pcall(function() return AshitaCore:GetResourceManager():GetSpellById(id) end)
    return anim_lock_from(ok and r or nil)
end

local function get_ws_lock(_id)
    -- GetWeaponSkillById isn't reliably present across Ashita builds; default.
    return DEFAULT_ANIM_LOCK
end

local debug_log = false   -- /na debug : print each self 0x28 action packet

local show_config = false

------------------------------------------------------------
-- Martial Arts delay reduction (MNK trait, main job only)
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
        if pl:GetMainJob() ~= 2 then return 0 end
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
        local eq = inv:GetEquippedItem(0)
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

------------------------------------------------------------
-- Combat (engaged) detection
------------------------------------------------------------
local function is_engaged()
    local ok, r = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty()
        local idx = party:GetMemberTargetIndex(0)
        local ent = AshitaCore:GetMemoryManager():GetEntity()
        return ent:GetStatus(idx) == 1   -- 1 = Engaged
    end)
    return ok and r or false
end

------------------------------------------------------------
-- Swing math
------------------------------------------------------------
local function current_frac()
    local interval = swing.interval or get_main_weapon_delay()
    if not interval or interval <= 0 or swing.last_swing <= 0 then return 0 end
    return math.min((os.clock() - swing.last_swing) / interval, 1.0)
end

local function record_swing()
    local t_now = os.clock()
    if swing.last_swing > 0 then
        local gap = t_now - swing.last_swing
        local interval = swing.interval or get_main_weapon_delay()
        local ceiling
        if swing.interval then
            ceiling = swing.interval * 1.5
        else
            ceiling = interval and (interval * 1.5) or 12
        end
        if gap > 0.3 and gap < ceiling then
            table.insert(swing.samples, gap)
            while #swing.samples > 5 do table.remove(swing.samples, 1) end
            local s = 0
            for _, g in ipairs(swing.samples) do s = s + g end
            swing.interval = s / #swing.samples
        end
    end
    swing.last_swing    = t_now
    swing.action_frozen = false
    swing.pause_until   = 0
    swing.pause_frac    = 0
end

-- Freeze the arc in place (open-ended) until a matching finish packet or the
-- safety timeout. Used for WS/JA/ranged/spell START packets.
local function freeze_now()
    if not swing.action_frozen then
        swing.pause_frac = current_frac()
    end
    swing.action_frozen = true
    swing.freeze_safety = os.clock() + FREEZE_TIMEOUT
end

-- Apply a post-action animation lock and schedule resume from `frac` (defaults
-- to the current live fraction for instant actions that have no start packet).
local function pause_and_resume(lock, frac)
    local interval = swing.interval or get_main_weapon_delay()
    local pf = frac or current_frac()
    swing.pause_frac    = pf
    swing.pause_until   = os.clock() + lock
    swing.action_frozen = false
    if interval then
        -- last_swing placed so elapsed == pf*interval exactly when the lock ends
        swing.last_swing = swing.pause_until - pf * interval
    end
end

-- Action finished: continue from the frozen fraction if we were holding from a
-- start packet, otherwise from the live fraction (instant WS/JA).
local function finish_action(lock)
    local frac = swing.action_frozen and swing.pause_frac or nil
    pause_and_resume(lock, frac)
end

------------------------------------------------------------
-- Packet handler: full 0x28 action-category coverage + zone clear
--
-- Auto-attack delay freezes while you perform another action and resumes from
-- the same fraction once the action's animation lock ends. We freeze on START
-- packets (held until the matching finish) and apply a post-action lock on
-- FINISH packets. See AUTO_ATTACK_TIMING.md (Nerf) for the full rationale.
------------------------------------------------------------
ashita.events.register('packet_in', 'nextauto_pkt_cb', function(e)
    if e.id == 0x000A or e.id == 0x000B then
        swing.last_swing    = 0
        swing.interval      = nil
        swing.samples       = {}
        swing.action_frozen = false
        swing.pause_until   = 0
        swing.pause_frac    = 0
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
        local param    = ashita.bits.unpack_be(b, 86, 32)  -- action id (WS/JA/spell)

        if debug_log then
            print(string.format('[NextAuto] 0x28 cat=%d param=%d frac=%.2f%s',
                category, param, current_frac(),
                swing.action_frozen and ' (frozen)' or ''))
        end

        if category == 1 then
            -- Melee swing landed (clears any pause state).
            record_swing()
        elseif category == 7 then
            -- Weaponskill START: freeze until the finish packet.
            freeze_now()
        elseif category == 3 then
            -- Weaponskill FINISH: post-WS animation lock.
            finish_action(get_ws_lock(param))
        elseif category == 10 then
            -- Job ability START (cast/ready time): freeze until finish.
            freeze_now()
        elseif category == 6 then
            -- Job ability FINISH: post-JA animation lock.
            finish_action(get_ability_lock(param))
        elseif category == 8 then
            -- Spell cast START: freeze for the whole cast (held until finish).
            freeze_now()
        elseif category == 4 then
            -- Spell cast FINISH: post-cast animation lock.
            finish_action(get_spell_post_lock(param))
        elseif category == 12 then
            -- Ranged START: freeze until the shot resolves.
            freeze_now()
        elseif category == 2 then
            -- Ranged FINISH: post-shot animation lock.
            finish_action(DEFAULT_ANIM_LOCK)
        elseif category == 13 then
            -- Pet ability finished: extra buffer (pet may animate past player lock).
            finish_action(DEFAULT_ANIM_LOCK + PET_EXTRA_LOCK)
        elseif category == 14 then
            -- Dancer step: freeze + lock like a JA.
            finish_action(DEFAULT_ANIM_LOCK)
        elseif category == 15 then
            -- RUN ward/effusion: freeze + lock like a JA.
            finish_action(DEFAULT_ANIM_LOCK)
        end
    end)
end)

------------------------------------------------------------
-- Geometry: morph between a straight line (curve=0) and a
-- semicircle (curve=1) with fixed endpoints. Returns local coords.
------------------------------------------------------------
local function path_at(cfg, t)
    local L = cfg.length
    local curve = cfg.curve
    local arc_along = L * 0.5 - (L * 0.5) * math.cos(math.pi * t)
    local arc_bulge = (L * 0.5) * math.sin(math.pi * t)
    -- abs(curve) controls the along-axis spacing (so the negative side keeps a
    -- true circular profile); the sign of curve flips the bulge direction.
    local along = t * L + (arc_along - t * L) * math.abs(curve)
    local bulge = arc_bulge * curve
    if cfg.vertical then
        return bulge, along
    else
        return along, bulge
    end
end

local function build_path(cfg)
    local segs = math.max(math.floor(cfg.segments), 2)
    local pts = {}
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for i = 0, segs do
        local t = i / segs
        local x, y = path_at(cfg, t)
        pts[i] = { x = x, y = y, t = t }
        if x < minx then minx = x end
        if x > maxx then maxx = x end
        if y < miny then miny = y end
        if y > maxy then maxy = y end
    end
    return pts, segs, minx, miny, maxx, maxy
end

------------------------------------------------------------
-- Color helpers
------------------------------------------------------------
local function lerp(a, b, t) return a + (b - a) * t end

local function grad_color(tprog, cfg)
    local cs, cm, ce = cfg.color_start, cfg.color_mid, cfg.color_end
    if tprog < 0.5 then
        local t = tprog * 2
        return lerp(cs[1], cm[1], t), lerp(cs[2], cm[2], t), lerp(cs[3], cm[3], t)
    else
        local t = (tprog - 0.5) * 2
        return lerp(cm[1], ce[1], t), lerp(cm[2], ce[2], t), lerp(cm[3], ce[3], t)
    end
end

------------------------------------------------------------
-- Render
------------------------------------------------------------
ashita.events.register('d3d_present', 'nextauto_render_cb', function()
    if show_config then
        -- Config GUI is drawn even if the bar is hidden.
        render_config()
    end

    if not config.visible then return end

    local cfg = config
    local interval = swing.interval or get_main_weapon_delay()
    if not interval or interval <= 0 then return end

    local now = os.clock()

    -- Safety: if an open-ended freeze never received its finish packet (e.g. a
    -- spell interrupted by movement sends no 0x28 finish), release it so the arc
    -- doesn't stay stuck forever.
    if swing.action_frozen and now > swing.freeze_safety then
        pause_and_resume(0, swing.pause_frac)
    end

    -- Combat state + transitions (reset the round on engage/disengage).
    local engaged = is_engaged()
    if swing.was_engaged == nil then swing.was_engaged = engaged end
    if engaged ~= swing.was_engaged then
        swing.last_swing    = 0
        swing.action_frozen = false
        swing.pause_until   = 0
        swing.pause_frac    = 0
        if not engaged then swing.samples = {} end
        swing.was_engaged = engaged
    end

    local frozen_ooc = false
    if not engaged then
        if cfg.hide_out_of_combat then return end
        if cfg.pause_out_of_combat then frozen_ooc = true end
    end

    -- Current fill fraction.
    local casting = swing.action_frozen
    local locked  = now < swing.pause_until
    local paused  = casting or locked or frozen_ooc

    local frac
    if casting or locked then
        frac = swing.pause_frac or 0
    elseif frozen_ooc then
        frac = 0
    elseif swing.last_swing > 0 then
        frac = math.min((now - swing.last_swing) / interval, 1.0)
    else
        frac = 0
    end

    -- Build geometry.
    local pts, segs, minx, miny, maxx, maxy = build_path(cfg)
    local pad = cfg.thickness * 0.5 + 3
    local win_w = (maxx - minx) + pad * 2
    local win_h = (maxy - miny) + pad * 2

    local swFlags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBringToFrontOnFocus)
    if not cfg.background then
        swFlags = bit.bor(swFlags, ImGuiWindowFlags_NoBackground)
    end
    if cfg.locked then
        swFlags = bit.bor(swFlags, ImGuiWindowFlags_NoMove)
    end

    imgui.SetNextWindowSize({ win_w, win_h }, ImGuiCond_Always)

    -- Zero the window padding so our own `pad` margin fully controls spacing;
    -- otherwise ImGui's default padding shifts the content past the window edge
    -- and the draw-list clip rect slices off the arc's corners.
    -- Also drop the minimum window size: when the curve is near-flat the arc is
    -- only a few pixels tall, and the default 32px minimum would otherwise pad
    -- the background window out with empty space on the thin axis.
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 })

    local pushed_bg = false
    if cfg.background then
        imgui.PushStyleColor(ImGuiCol_WindowBg, { cfg.bg_color[1], cfg.bg_color[2], cfg.bg_color[3], cfg.bg_color[4] or 0.6 })
        pushed_bg = true
    end

    if imgui.Begin('NextAuto', true, swFlags) then
        local ox, oy = imgui.GetCursorScreenPos()
        local offx = ox + pad - minx
        local offy = oy + pad - miny
        local dl
        pcall(function() dl = imgui.GetWindowDrawList() end)
        if dl then
            local th = cfg.thickness

            -- Background track (dim)
            for i = 0, segs - 1 do
                local p1, p2 = pts[i], pts[i + 1]
                dl:AddLine({ offx + p1.x, offy + p1.y }, { offx + p2.x, offy + p2.y },
                    imgui.GetColorU32({ 0.15, 0.15, 0.20, 0.5 }), th)
            end

            -- Filled progress
            if frac > 0 then
                for i = 0, segs - 1 do
                    local p1, p2 = pts[i], pts[i + 1]
                    local t_mid = (i + 0.5) / segs
                    local filled
                    if cfg.reverse then
                        filled = t_mid >= (1.0 - frac)
                    else
                        filled = t_mid <= frac
                    end
                    if filled then
                        local rC, gC, bC, aC
                        if paused then
                            rC, gC, bC = 0.40, 0.30, 0.80
                            aC = 0.50 + 0.15 * math.sin(now * 4)
                        else
                            local tprog = cfg.reverse and (1.0 - t_mid) or t_mid
                            rC, gC, bC = grad_color(tprog, cfg)
                            aC = 0.92
                        end
                        dl:AddLine({ offx + p1.x, offy + p1.y }, { offx + p2.x, offy + p2.y },
                            imgui.GetColorU32({ rC, gC, bC, aC }), th)
                    end
                end

                -- Pendulum bob at the leading edge
                if cfg.show_bob and not paused then
                    local bob_t = cfg.reverse and (1.0 - frac) or frac
                    local bx, by = path_at(cfg, bob_t)
                    local bob_col = (frac >= 0.95)
                        and imgui.GetColorU32({ 1.0, 0.3, 0.2, 0.9 })
                        or  imgui.GetColorU32({ 1.0, 0.9, 0.4, 0.8 })
                    dl:AddCircleFilled({ offx + bx, offy + by }, th + 1, bob_col, 12)
                end

                -- White flash on swing land
                if (not paused) and swing.last_swing > 0 then
                    local elapsed = now - swing.last_swing
                    if elapsed >= 0 and elapsed < 0.18 then
                        local fa = 0.6 * (1.0 - elapsed / 0.18)
                        for i = 0, segs - 1 do
                            local p1, p2 = pts[i], pts[i + 1]
                            dl:AddLine({ offx + p1.x, offy + p1.y }, { offx + p2.x, offy + p2.y },
                                imgui.GetColorU32({ 1.0, 1.0, 1.0, fa }), th + 2)
                        end
                    end
                end
            end
        end
        imgui.Dummy({ win_w - 4, win_h - 4 })
    end
    imgui.End()

    if pushed_bg then imgui.PopStyleColor(1) end
    imgui.PopStyleVar(2)
end)

------------------------------------------------------------
-- Config GUI
------------------------------------------------------------
function render_config()
    imgui.SetNextWindowSize({ 320, 0 }, ImGuiCond_FirstUseEver)
    local is_open = { show_config }
    if imgui.Begin('NextAuto Config', is_open, ImGuiWindowFlags_AlwaysAutoResize) then
        local changed = false

        imgui.TextColored({ 0.5, 0.9, 1.0, 1.0 }, 'Geometry')
        imgui.Separator()

        local len = { config.length }
        if imgui.SliderInt('Length', len, 20, 600) then config.length = len[1]; changed = true end

        local th = { config.thickness }
        if imgui.SliderInt('Thickness / Height', th, 1, 24) then config.thickness = th[1]; changed = true end

        local seg = { config.segments }
        if imgui.SliderInt('Smoothness', seg, 2, 128) then config.segments = seg[1]; changed = true end

        local cv = { config.curve }
        if imgui.SliderFloat('Curve (-1..1, 0=straight)', cv, -1.0, 1.0, '%.2f') then
            -- Snap to exact 0 within a small deadzone so a flat bar is easy to hit.
            if math.abs(cv[1]) < 0.04 then cv[1] = 0.0 end
            config.curve = cv[1]; changed = true
        end
        imgui.SameLine()
        if imgui.SmallButton('Straight') then config.curve = 0.0; changed = true end

        local vert = { config.vertical }
        if imgui.Checkbox('Vertical', vert) then config.vertical = vert[1]; changed = true end
        imgui.SameLine()
        local rev = { config.reverse }
        if imgui.Checkbox('Reverse fill', rev) then config.reverse = rev[1]; changed = true end

        imgui.Spacing()
        imgui.TextColored({ 0.5, 0.9, 1.0, 1.0 }, 'Colors')
        imgui.Separator()

        local cflags = bit.bor(ImGuiColorEditFlags_NoInputs, ImGuiColorEditFlags_NoLabel)
        local function color3(label, key)
            local c = { config[key][1], config[key][2], config[key][3] }
            if imgui.ColorEdit3('##' .. key, c, cflags) then
                config[key] = T{ c[1], c[2], c[3] }; changed = true
            end
            imgui.SameLine(); imgui.Text(label)
        end
        color3('Start (just swung)', 'color_start')
        color3('Mid', 'color_mid')
        color3('End (swing ready)', 'color_end')

        imgui.Text('Presets:'); imgui.SameLine()
        local function preset_btn(label, key)
            if imgui.SmallButton(label) then
                local p = COLOR_PRESETS[key]
                config.color_start = T{ p.s[1], p.s[2], p.s[3] }
                config.color_mid   = T{ p.m[1], p.m[2], p.m[3] }
                config.color_end   = T{ p.e[1], p.e[2], p.e[3] }
                changed = true
            end
        end
        preset_btn('Classic', 'classic'); imgui.SameLine()
        preset_btn('Ion', 'ion');         imgui.SameLine()
        preset_btn('Frost', 'frost')

        local bob = { config.show_bob }
        if imgui.Checkbox('Show pendulum bob', bob) then config.show_bob = bob[1]; changed = true end

        imgui.Spacing()
        imgui.TextColored({ 0.5, 0.9, 1.0, 1.0 }, 'Background')
        imgui.Separator()
        local bg = { config.background }
        if imgui.Checkbox('Background window', bg) then config.background = bg[1]; changed = true end
        if config.background then
            local bc = { config.bg_color[1], config.bg_color[2], config.bg_color[3], config.bg_color[4] or 0.6 }
            if imgui.ColorEdit4('##bg_color', bc, ImGuiColorEditFlags_AlphaBar) then
                config.bg_color = T{ bc[1], bc[2], bc[3], bc[4] }; changed = true
            end
        end

        imgui.Spacing()
        imgui.TextColored({ 0.5, 0.9, 1.0, 1.0 }, 'Behavior')
        imgui.Separator()
        local hooc = { config.hide_out_of_combat }
        if imgui.Checkbox('Hide out of combat', hooc) then config.hide_out_of_combat = hooc[1]; changed = true end
        if not config.hide_out_of_combat then
            local pooc = { config.pause_out_of_combat }
            if imgui.Checkbox('Freeze out of combat', pooc) then config.pause_out_of_combat = pooc[1]; changed = true end
        end

        imgui.Spacing()
        imgui.Separator()
        local lock = { config.locked }
        if imgui.Checkbox('Lock position', lock) then config.locked = lock[1]; changed = true end
        imgui.SameLine()
        if imgui.Button('Close') then show_config = false end

        if changed then settings.save() end
    end
    imgui.End()
    if not is_open[1] then show_config = false end
end

------------------------------------------------------------
-- Commands: /nextauto (aliases /na, /swingers)
------------------------------------------------------------
local function handle_command(args)
    local sub = (args[2] or ''):lower()
    if sub == '' or sub == 'config' or sub == 'gui' or sub == 'menu' then
        show_config = not show_config
    elseif sub == 'show' then
        config.visible = true;  print('[NextAuto] Visible')
    elseif sub == 'hide' then
        config.visible = false; print('[NextAuto] Hidden')
    elseif sub == 'lock' then
        config.locked = true;   print('[NextAuto] Locked')
    elseif sub == 'unlock' then
        config.locked = false;  print('[NextAuto] Unlocked')
    elseif sub == 'reset' then
        for k, v in pairs(defaultConfig) do config[k] = v end
        print('[NextAuto] Settings reset to defaults')
    elseif sub == 'radius' or sub == 'length' then
        config.length = tonumber(args[3]) or config.length;       print('[NextAuto] Length = ' .. config.length)
    elseif sub == 'thickness' then
        config.thickness = tonumber(args[3]) or config.thickness; print('[NextAuto] Thickness = ' .. config.thickness)
    elseif sub == 'segments' then
        config.segments = tonumber(args[3]) or config.segments;   print('[NextAuto] Smoothness = ' .. config.segments)
    elseif sub == 'curve' then
        config.curve = tonumber(args[3]) or config.curve;         print('[NextAuto] Curve = ' .. config.curve)
    elseif sub == 'debug' then
        debug_log = not debug_log
        print('[NextAuto] Action-packet debug ' .. (debug_log and 'ON (watch the log)' or 'OFF'))
    elseif sub == 'preset' then
        local p = COLOR_PRESETS[(args[3] or ''):lower()]
        if p then
            config.color_start = T{ p.s[1], p.s[2], p.s[3] }
            config.color_mid   = T{ p.m[1], p.m[2], p.m[3] }
            config.color_end   = T{ p.e[1], p.e[2], p.e[3] }
            print('[NextAuto] Color preset: ' .. p.name)
        else
            print('[NextAuto] Presets: classic, ion, frost')
        end
    else
        print('[NextAuto] Usage: /nextauto [config|show|hide|lock|unlock|reset|preset NAME|length N|thickness N|segments N|curve F|debug]')
    end
    settings.save()
end

ashita.events.register('command', 'nextauto_cmd_cb', function(e)
    local args = e.command:args()
    if not args[1] then return end
    local cmd = args[1]:lower()
    if cmd ~= '/nextauto' and cmd ~= '/na' and cmd ~= '/swingers' then return end
    e.blocked = true
    handle_command(args)
end)

------------------------------------------------------------
-- Load / Unload
------------------------------------------------------------
ashita.events.register('load', 'nextauto_load_cb', function()
    print('[NextAuto] Loaded. /nextauto (or /na) for the config menu.')
end)

ashita.events.register('unload', 'nextauto_unload_cb', function()
    settings.save()
end)
