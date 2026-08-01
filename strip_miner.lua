-- strip_miner.lua
-- Mines a 3x3 main tunnel with 1x2 branch tunnels off both sides.
--
-- SETUP: turtle starts under the home chest (fuel/coal ONLY) facing the
-- direction the main tunnel should go. A 2x1 chest sits to its LEFT for
-- everything that isn't fuel.
--
-- Each iteration = one main-tunnel segment + its left AND right branches,
-- done together and checkpointed as a single unit - so it's always safe to
-- stop right after an iteration finishes. The turtle ends each iteration
-- back under the home chest.
--
-- Ctrl-T saves progress with a terminated flag. The next run goes home,
-- clears the flag, and exits so you can start a clean run after that.
--
-- Save file lives on THIS TURTLE'S computer (run `ls` in its terminal),
-- not in your PC project folder. Default: strip_miner_state.txt
--
-- USAGE: strip_miner <iterations> <branch_length> [main_step]
--   iterations    how many MORE main-tunnel-segment + left/right-branch units
--                 to dig this run - always required, and always additive on
--                 top of whatever's already been completed (the save file
--                 tracks a running total, it's never deleted on completion)
--   branch_length how many blocks long each branch is (always required)
--   main_step     main-tunnel blocks dug per iteration before branching
--                 (optional, default 2 - or the saved value if omitted)

local VERSION = "1.0.5"

package.loaded["turtle_lib"] = nil
local turtle_lib = require("turtle_lib")

local STATE_FILE = "strip_miner_state.txt"
local TUNNEL_DIR = vector.new(0, 0, -1) -- facing 0 = main tunnel direction

local args = { ... }
local iterations = tonumber(args[1])
local branch_length = tonumber(args[2])

if not iterations or not branch_length then
    print("Usage: strip_miner <iterations> <branch_length> [main_step]")
    return
end

print("strip_miner " .. VERSION)

local bot = turtle_lib.new()
local resumed, progress = bot.load_state(STATE_FILE)

local main_step = tonumber(args[3]) or (resumed and progress.main_step) or 2
local completed = (resumed and progress.completed) or 0
local main_tunnel_distance = (resumed and progress.torch_progress) or 0

local function checkpoint(bot, opts)
    opts = opts or {}
    local extra = {
        completed = completed,
        branch_length = branch_length,
        main_step = main_step,
        torch_progress = main_tunnel_distance,
    }
    if opts.terminated then
        extra.terminated = true
    end
    bot.log("checkpoint completed=" .. completed .. " torch_progress=" .. main_tunnel_distance
        .. (opts.terminated and " TERMINATED" or ""))
    bot.save_state(STATE_FILE, extra)
end

local function autosave_on_terminate()
    print("Ctrl-T: autosaving to " .. STATE_FILE .. "...")
    checkpoint(bot, { terminated = true })
    if fs.exists(STATE_FILE) then
        print("Autosave complete. Run `ls` on this turtle to see the file.")
    else
        print("WARNING: autosave failed - " .. STATE_FILE .. " was not written.")
    end
end

bot.on_terminate(autosave_on_terminate)

-- Recover from a Ctrl-T stop: go home, clear the flag, exit.
if resumed and turtle_lib.was_terminated(progress) then
    print("Previous run was terminated (Ctrl-T). Returning home and clearing flag...")
    bot.recover_to_home(0)
    bot.save_state(STATE_FILE, turtle_lib.extra_without_terminated({
        completed = progress.completed or 0,
        branch_length = progress.branch_length or branch_length,
        main_step = progress.main_step or main_step,
        torch_progress = progress.torch_progress or 0,
    }))
    print("Ready. Run strip_miner again to continue mining.")
    return
end

if resumed then
    print(completed .. " iterations completed so far. Running " .. iterations .. " more.")
end

local FUEL_NAME = "minecraft:coal" -- change to whatever you're stocking
local FUEL_TARGET = 1000

local TORCH_NAME = "minecraft:torch"
local TORCH_TARGET = 64
local TORCH_SPACING = 15

local LIQUID_NAMES = {
    ["minecraft:water"] = true,
    ["minecraft:flowing_water"] = true,
    ["minecraft:lava"] = true,
    ["minecraft:flowing_lava"] = true,
}
local BUILD_NAMES = {
    "minecraft:cobblestone",
    "minecraft:cobbled_deepslate", -- what mined deepslate actually drops (not "minecraft:deepslate")
}

local TORCH_BLOCK_NAMES = {
    ["minecraft:torch"] = true,
    ["minecraft:wall_torch"] = true,
}

local function mining_face_pos()
    return bot.home_pos + TUNNEL_DIR * main_tunnel_distance
end

local function go_to_mining_face(bot)
    bot.move_to(mining_face_pos())
    bot.turn_to(0)
end

local function is_liquid(ok, data)
    return ok and LIQUID_NAMES[data.name]
end

local function find_build_slot(bot)
    for _, name in ipairs(BUILD_NAMES) do
        local slot = bot.find_slot(name)
        if slot then return slot end
    end
    return nil
end

local function place_build(place_fn, bot)
    local build = find_build_slot(bot)
    if not build then return false end
    turtle.select(build)
    local ok = place_fn()
    turtle.select(1)
    return ok
end

local function contain_fluid(inspect_fn, place_fn, bot)
    local ok, data = inspect_fn()
    if not is_liquid(ok, data) then return end
    place_build(place_fn, bot)
end

local function contain_forward(bot) contain_fluid(turtle.inspect, turtle.place, bot) end
local function contain_up(bot) contain_fluid(turtle.inspectUp, turtle.placeUp, bot) end
local function contain_down(bot) contain_fluid(turtle.inspectDown, turtle.placeDown, bot) end

local function retreat_to_main_center(bot)
    while bot.pos.x ~= bot.home_pos.x do
        bot.turn_to(bot.pos.x < bot.home_pos.x and 1 or 3)
        contain_forward(bot)
        bot.move_forward()
    end
end

local function abort_to_home(bot, message)
    bot.log("ABORT " .. message)
    print("Abort: " .. message)
    retreat_to_main_center(bot)
    bot.recover_to_home(0)
    checkpoint(bot)
    error(message)
end

local function torch_block_above()
    local ok, data = turtle.inspectUp()
    return ok and TORCH_BLOCK_NAMES[data.name]
end

local function try_place_up_with_hint(hint)
    if hint then
        local ok, placed, reason = pcall(function()
            return turtle.placeUp(hint)
        end)
        if ok then
            return placed, reason
        end
    end
    return turtle.placeUp()
end

local function clear_fluid_above(bot)
    local ok, data = turtle.inspectUp()
    if is_liquid(ok, data) then
        place_build(turtle.placeUp, bot)
        turtle.digUp()
        bot.log("cleared fluid above")
    end
end

local function try_place_torch_above(bot, prefer_side)
    local slot = bot.find_slot(TORCH_NAME)
    if not slot then
        bot.log("torch skip: none in inventory")
        return false
    end

    clear_fluid_above(bot)

    local count_before = bot.count_item(TORCH_NAME)
    turtle.select(slot)

    local hints
    if prefer_side == "left" then
        hints = { "left", "right", nil }
    elseif prefer_side == "right" then
        hints = { "right", "left", nil }
    else
        hints = { "left", "right", nil }
    end

    local placed, reason
    for _, hint in ipairs(hints) do
        placed, reason = try_place_up_with_hint(hint)
        if placed then break end
    end

    turtle.select(1)

    local count_after = bot.count_item(TORCH_NAME)
    local verified = placed and (torch_block_above() or count_after < count_before)

    if not verified then
        bot.log("torch skip placed=" .. tostring(placed) .. " reason=" .. tostring(reason)
            .. " count " .. count_before .. "->" .. count_after)
        return false
    end

    bot.log("torch OK prefer_side=" .. tostring(prefer_side))
    return true
end

-- Main tunnel sides: liquids only (air stays open for the 3-wide cross-section).
local function fill_liquid_face(inspect_fn, place_fn, bot)
    local ok, data = inspect_fn()
    if not is_liquid(ok, data) then return end
    local placed = place_build(place_fn, bot)
    bot.log("fill_liquid block=" .. data.name .. " placed=" .. tostring(placed))
end

-- Branch outer walls: seal air and liquids (prevents water ingress).
local function should_fill_branch_face(ok, data)
    if not ok then return true end
    return is_liquid(ok, data)
end

local function fill_branch_face(inspect_fn, place_fn, bot)
    local ok, data = inspect_fn()
    if not should_fill_branch_face(ok, data) then return end
    local placed = place_build(place_fn, bot)
    bot.log("fill_branch block=" .. tostring(ok and data.name or "air") .. " placed=" .. tostring(placed))
end

local function seal_outer_wall(bot, branch_side)
    if branch_side == "left" then bot.turn_left() else bot.turn_right() end
    fill_branch_face(turtle.inspect, turtle.place, bot)
    if branch_side == "left" then bot.turn_right() else bot.turn_left() end
end

-- Seal one side wall (perpendicular to travel). Never forward/back along the tunnel.
local function seal_side_face(bot, side)
    if side == "left" then bot.turn_left() else bot.turn_right() end
    fill_liquid_face(turtle.inspect, turtle.place, bot)
    if side == "left" then bot.turn_right() else bot.turn_left() end
end

-- From the center lane facing along the tunnel: seal left, right, down, and up only.
local function seal_main_cross_section(bot)
    local home = bot.facing

    fill_liquid_face(turtle.inspectDown, turtle.placeDown, bot)

    for row = 1, 3 do
        if row > 1 then bot.move_up() end
        seal_side_face(bot, "left")
        seal_side_face(bot, "right")
    end

    fill_liquid_face(turtle.inspectUp, turtle.placeUp, bot)

    bot.move_down()
    bot.move_down()
    bot.turn_to(home)
end

-- Seal branch cross-section at current height: down, outer wall only.
local function seal_branch_level(bot, branch_side)
    local home = bot.facing
    fill_branch_face(turtle.inspectDown, turtle.placeDown, bot)
    seal_outer_wall(bot, branch_side)
    bot.turn_to(home)
end

-- ---------- tunnel shape helpers ----------

-- Clears the 2 blocks above the turtle and returns to the floor.
local function clear_vertical(bot)
    contain_up(bot)
    bot.move_up()
    contain_up(bot)
    bot.move_up()
    contain_down(bot)
    bot.move_down()
    contain_down(bot)
    bot.move_down()
end

-- Clears a side column (dig only — sealing happens from the center lane afterward).
local function clear_side_column(bot, side)
    if side == "left" then bot.turn_left() else bot.turn_right() end
    contain_forward(bot)
    bot.move_forward()
    clear_vertical(bot)
    bot.move_back()
    if side == "left" then bot.turn_right() else bot.turn_left() end
end

local function mine_main_step(bot, place_torch_here)
    bot.log("mine_main_step torch=" .. tostring(place_torch_here) .. " distance=" .. main_tunnel_distance)
    contain_forward(bot)
    bot.move_forward()
    clear_vertical(bot)
    clear_side_column(bot, "left")
    clear_side_column(bot, "right")
    seal_main_cross_section(bot)
    if place_torch_here then
        try_place_torch_above(bot, "left")
    end
end

-- Branch step: dig 1x2 ahead, seal outer walls (step 1 skips seal — open to main tunnel).
local function mine_branch_step(bot, branch_side, do_seal)
    bot.log("mine_branch_step side=" .. branch_side .. " seal=" .. tostring(do_seal))

    contain_forward(bot)
    bot.move_forward()

    if do_seal then
        seal_branch_level(bot, branch_side)
    end

    contain_up(bot)
    bot.move_up()

    if do_seal then
        local home = bot.facing
        fill_branch_face(turtle.inspectUp, turtle.placeUp, bot)
        seal_outer_wall(bot, branch_side)
        bot.turn_to(home)
    end

    bot.move_down()
end

local function retreat_branch(bot, steps)
    for _ = 1, steps do
        contain_forward(bot)
        if not bot.move_back() then
            bot.turn_right()
            bot.turn_right()
            contain_forward(bot)
            bot.move_forward()
            bot.turn_right()
            bot.turn_right()
        end
    end
end

local function mine_branch(bot, side, length)
    bot.log("mine_branch START side=" .. side .. " length=" .. length)
    if side == "left" then bot.turn_left() else bot.turn_right() end
    local branch_facing = bot.facing

    for step = 1, length do
        mine_branch_step(bot, side, step > 1)
        if step == 1 or step % TORCH_SPACING == 0 then
            try_place_torch_above(bot)
        end
    end

    bot.turn_to((branch_facing + 2) % 4)
    retreat_branch(bot, length)
    bot.turn_to(0)

    bot.log("mine_branch END side=" .. side)
end

-- ---------- home chest ----------

local function resupply(bot)
    bot.recover_to_home(0)

    bot.turn_left()
    bot.push_items("front", { [FUEL_NAME] = true, [TORCH_NAME] = true })

    local torch_need = TORCH_TARGET - bot.count_item(TORCH_NAME)
    if torch_need > 0 then
        bot.take_item("front", TORCH_NAME, torch_need)
    end

    bot.turn_right()

    bot.refuel_to(FUEL_TARGET, FUEL_NAME, "top")
end

-- ---------- main loop ----------

resupply(bot)

for i = 1, iterations do
    go_to_mining_face(bot)

    for _ = 1, main_step do
        main_tunnel_distance = main_tunnel_distance + 1
        mine_main_step(bot, main_tunnel_distance % TORCH_SPACING == 0)
    end

    mine_branch(bot, "left", branch_length)
    mine_branch(bot, "right", branch_length)

    resupply(bot)

    completed = completed + 1
    checkpoint(bot)
    print(completed .. " iterations complete total (" .. i .. "/" .. iterations .. " this run) - safe to stop now.")
end

print("Batch complete: " .. iterations .. " iterations this run, " .. completed .. " total.")
