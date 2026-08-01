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

local VERSION = "1.0.15"

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

bot.log("strip_miner " .. VERSION .. " iterations=" .. iterations
    .. " branch_length=" .. branch_length .. " main_step=" .. main_step
    .. " resumed=" .. tostring(resumed) .. " completed=" .. completed
    .. " torch_progress=" .. main_tunnel_distance)

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
local BUILD_KEEP = 64 -- keep up to one stack of plugging material; dump the rest

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

local function clear_fluid_above(bot)
    local ok, data = turtle.inspectUp()
    if is_liquid(ok, data) then
        place_build(turtle.placeUp, bot)
        turtle.digUp()
        bot.log("cleared fluid above")
    end
end

-- While at mid height facing along the branch: dig the block ahead so placeUp
-- won't hang the torch on it. Side walls were already sealed this step — no
-- need to look left/right again.
local function clear_torch_forward_support()
    if turtle.detect() then
        turtle.dig()
        bot.log("torch cleared forward support")
    end
end

-- placeUp() from the floor into the prepared cell above.
local function try_place_torch_above(bot, prefer_side)
    local slot = bot.find_slot(TORCH_NAME)
    local count_before = bot.count_item(TORCH_NAME)
    if not slot then
        bot.log("torch skip: none in inventory count=" .. count_before)
        return false
    end

    if torch_block_above() then
        bot.log("torch OK already present")
        return true
    end

    clear_fluid_above(bot)

    local up_ok, up_data = turtle.inspectUp()
    if up_ok and not TORCH_BLOCK_NAMES[up_data.name] then
        bot.log("torch skip: blocked above by " .. tostring(up_data.name)
            .. " count=" .. count_before)
        return false
    end

    bot.log("torch try count=" .. count_before .. " prefer=" .. tostring(prefer_side)
        .. " facing=" .. bot.facing)

    turtle.select(slot)
    local placed, reason = turtle.placeUp()
    turtle.select(1)

    local count_after = bot.count_item(TORCH_NAME)
    if torch_block_above() or (placed and count_after < count_before) then
        bot.log("torch OK prefer_side=" .. tostring(prefer_side)
            .. " count " .. count_before .. "->" .. count_after)
        return true
    end

    bot.log("torch skip placed=" .. tostring(placed) .. " reason=" .. tostring(reason)
        .. " count " .. count_before .. "->" .. count_after)
    return false
end

-- Fill air or liquid (used by both sealers; each sealer picks WHICH faces).
local function should_seal_hole(ok, data)
    if not ok then return true end
    return is_liquid(ok, data)
end

local function fill_hole(inspect_fn, place_fn, bot, tag)
    local ok, data = inspect_fn()
    if not should_seal_hole(ok, data) then return end
    local placed = place_build(place_fn, bot)
    bot.log((tag or "fill") .. " block=" .. tostring(ok and data.name or "air")
        .. " placed=" .. tostring(placed))
end

-- =====================================================================
-- MAIN TUNNEL sealer (3x3 dig / outer shell only)
--
-- Cross-section looking along the tunnel:
--   0 0 0 0 0
--   0 X X X 0
--   0 X X X 0
--   0 X X X 0
--   0 0 0 0 0
-- X = dig, 0 = seal if air/liquid.
-- Only seal faces pointing OUT of the 3x3 — never into dig cells,
-- never backward into the previous slice.
-- =====================================================================

-- Outer wall facing relative to main tunnel direction (facing 0).
local function main_outer_facing(side)
    return side == "left" and 3 or 1
end

local function seal_main_outer(bot, side)
    local home = bot.facing
    bot.turn_to(main_outer_facing(side))
    fill_hole(turtle.inspect, turtle.place, bot, "fill_main_wall")
    bot.turn_to(home)
end

-- Dig one vertical column of the 3x3 and seal only its outer shell faces.
-- outer_side: "left"/"right" for side columns; nil for center.
local function clear_main_column(bot, outer_side)
    -- Floor of dig (y=0): seal below; side columns also seal outer wall.
    fill_hole(turtle.inspectDown, turtle.placeDown, bot, "fill_main_floor")
    if outer_side then seal_main_outer(bot, outer_side) end

    contain_up(bot)
    bot.move_up()
    -- Mid dig (y=1): side columns seal outer wall only — do NOT fill up/down into dig.
    if outer_side then seal_main_outer(bot, outer_side) end

    contain_up(bot)
    bot.move_up()
    -- Ceiling of dig (y=2): seal above; side columns also seal outer wall.
    fill_hole(turtle.inspectUp, turtle.placeUp, bot, "fill_main_ceil")
    if outer_side then seal_main_outer(bot, outer_side) end

    contain_down(bot)
    bot.move_down()
    contain_down(bot)
    bot.move_down()
end

local function clear_main_side_column(bot, side)
    if side == "left" then bot.turn_left() else bot.turn_right() end
    contain_forward(bot)
    bot.move_forward()
    -- Facing outward into the side column — clear + seal outer shell.
    clear_main_column(bot, side)
    bot.move_back()
    if side == "left" then bot.turn_right() else bot.turn_left() end
end

local function mine_main_step(bot, place_torch_here)
    bot.log("mine_main_step torch=" .. tostring(place_torch_here) .. " distance=" .. main_tunnel_distance)
    contain_forward(bot)
    bot.move_forward()
    clear_main_column(bot, nil)
    clear_main_side_column(bot, "left")
    clear_main_side_column(bot, "right")
    if place_torch_here then
        try_place_torch_above(bot, "left")
    end
end

-- =====================================================================
-- BRANCH sealer (1x2 dig): floor + left/right walls + ceiling.
-- Relative to travel direction along the branch.
-- =====================================================================

local function fill_branch_face(inspect_fn, place_fn, bot)
    fill_hole(inspect_fn, place_fn, bot, "fill_branch")
end

local function seal_branch_sides(bot)
    local home = bot.facing
    fill_branch_face(turtle.inspectDown, turtle.placeDown, bot)
    bot.turn_left()
    fill_branch_face(turtle.inspect, turtle.place, bot)
    bot.turn_right()
    bot.turn_right()
    fill_branch_face(turtle.inspect, turtle.place, bot)
    bot.turn_left()
    bot.turn_to(home)
end

-- Branch step: dig 1x2, seal sides (step 1 skips seal — open to main tunnel).
-- Torch is placed LAST so digUp doesn't destroy it.
local function mine_branch_step(bot, step, do_seal, place_torch, prefer_side)
    bot.log("mine_branch_step step=" .. step .. " seal=" .. tostring(do_seal)
        .. " torch=" .. tostring(place_torch))

    contain_forward(bot)
    bot.move_forward()

    if do_seal then
        seal_branch_sides(bot)
    end

    contain_up(bot)
    local ok, data = turtle.inspectUp()
    if ok and not is_liquid(ok, data) then
        turtle.digUp()
    end
    bot.move_up()

    if do_seal then
        local home = bot.facing
        fill_branch_face(turtle.inspectUp, turtle.placeUp, bot)
        bot.turn_left()
        fill_branch_face(turtle.inspect, turtle.place, bot)
        bot.turn_right()
        bot.turn_right()
        fill_branch_face(turtle.inspect, turtle.place, bot)
        bot.turn_left()
        bot.turn_to(home)
    end

    -- Dig ahead while still at mid height so placeUp attaches to a side wall.
    if place_torch then
        clear_torch_forward_support()
    end

    bot.move_down()

    if place_torch then
        try_place_torch_above(bot, prefer_side)
    end
end

local function retreat_branch(bot, steps)
    for _ = 1, steps do
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
    bot.log("mine_branch START side=" .. side .. " length=" .. length
        .. " torches=" .. bot.count_item(TORCH_NAME))
    if side == "left" then bot.turn_left() else bot.turn_right() end
    -- Both branches prefer the north wall (consistent lighting along the strip).
    local prefer_side = side == "left" and "right" or "left"

    for step = 1, length do
        -- Step 1 is the main tunnel's side column (already dug). Step 2 is the
        -- first real branch block — place the entrance torch there, then every 15.
        local place_torch = step >= 2 and (step - 2) % TORCH_SPACING == 0
        mine_branch_step(bot, step, step > 1, place_torch, prefer_side)
    end

    -- Still facing along the branch — walk back to the main tunnel.
    retreat_branch(bot, length)
    bot.turn_to(0)

    bot.log("mine_branch END side=" .. side)
end

-- ---------- home chest ----------

local function count_build_items(bot)
    local total = 0
    for _, name in ipairs(BUILD_NAMES) do
        total = total + bot.count_item(name)
    end
    return total
end

local function is_build_item(name)
    for _, build_name in ipairs(BUILD_NAMES) do
        if name == build_name then return true end
    end
    return false
end

-- Dump junk to the chest we're facing. Keep fuel, torches, and up to
-- BUILD_KEEP plugging blocks (cobble / cobbled deepslate).
local function dump_inventory(bot)
    local keep = { [FUEL_NAME] = true, [TORCH_NAME] = true }
    for _, name in ipairs(BUILD_NAMES) do
        keep[name] = true
    end
    bot.push_items("front", keep)

    -- Trim plugging material down to one stack so mining drops don't fill us.
    local excess = count_build_items(bot) - BUILD_KEEP
    if excess <= 0 then return end

    for slot = 1, 16 do
        if excess <= 0 then break end
        local detail = turtle.getItemDetail(slot)
        if detail and is_build_item(detail.name) then
            local drop_n = math.min(detail.count, excess)
            turtle.select(slot)
            turtle.drop(drop_n)
            excess = excess - drop_n
            bot.log("dump excess build slot=" .. slot .. " n=" .. drop_n)
        end
    end
    turtle.select(1)
end

local function resupply(bot)
    bot.recover_to_home(0)

    bot.turn_left()
    dump_inventory(bot)

    local torch_need = TORCH_TARGET - bot.count_item(TORCH_NAME)
    if torch_need > 0 then
        bot.take_item("front", TORCH_NAME, torch_need)
    end
    torch_need = TORCH_TARGET - bot.count_item(TORCH_NAME)
    if torch_need > 0 then
        bot.take_item("top", TORCH_NAME, torch_need)
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

if bot.debug then
    print("Uploading debug log...")
    turtle_lib.upload_debug()
end
