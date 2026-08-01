-- turtle_lib.lua
-- Shared movement / position-tracking / refuel utilities for CC: Tweaked (ComputerCraft: Tweaked) turtles.
--
-- Usage:
--   local turtle_lib = require("turtle_lib")
--   local bot = turtle_lib.new({ fuel_chest_pos = vector.new(2, 0, -1) })
--   bot.move_to(vector.new(5, 0, 5))
--   bot.refuel()
--
-- Ctrl-T autosave (opt-in):
--   bot.on_terminate(function() ... save with terminated = true ... end)
--   run main logic directly — do NOT wrap it in parallel.waitForAny.
--   if resumed and turtle_lib.was_terminated(progress) then ... end
--
-- pos/facing are LOCAL to wherever the turtle was standing when the program started.
-- facing 0..3 is relative to the turtle's own starting orientation (we have no compass
-- reference, so "0" just means "however it was pointing when the program booted").

local DIRS = {
    [0] = vector.new(0, 0, -1),
    [1] = vector.new(1, 0, 0),
    [2] = vector.new(0, 0, 1),
    [3] = vector.new(-1, 0, 0),
}

local MAX_DIG_ATTEMPTS = 10

-- Ctrl-T handler state (module-level; os.pullEvent is global).
local terminate_callback = nil
local terminate_installed = false

local function dispatch_terminate()
    print("Ctrl-T: autosaving...")
    if terminate_callback then
        local ok, err = pcall(terminate_callback)
        if not ok then
            print("Terminate save failed: " .. tostring(err))
        end
    end
    error("Terminated", 0)
end

local function install_terminate_handler()
    if terminate_installed then return end
    terminate_installed = true

    local orig_pullEventRaw = os.pullEventRaw
    local unpack_fn = table.unpack or unpack

    -- Hook pullEventRaw (required by CC:T docs — terminate is delivered here).
    -- Do NOT use parallel.waitForAny alongside this; parallel coroutines get
    -- separate event queues and Ctrl-T will not reliably reach your callback.
    function os.pullEventRaw(filter)
        while true do
            local event = { orig_pullEventRaw(filter) }
            if event[1] == "terminate" then
                dispatch_terminate()
            end
            if not filter or event[1] == filter then
                return unpack_fn(event)
            end
        end
    end

    function os.pullEvent(filter)
        local event = { os.pullEventRaw(filter) }
        return unpack_fn(event)
    end
end

-- turtle.suck() only ever pulls from slot 1 of the inventory it's facing.
-- If slot 1 is occupied by something OTHER than the item we want, shove
-- whatever's there into any free slot first so slot 1 is free to receive it.
local function make_room_in_slot1(chest, chest_name, list, item_name)
    local slot1 = list[1]
    if slot1 and slot1.name ~= item_name then
        for slot = 2, chest.size() do
            if not list[slot] then
                chest.pushItems(chest_name, 1, slot1.count, slot)
                return
            end
        end
    end
end

local function new(opts)
    opts = opts or {}

    local self = {
        pos = opts.pos or vector.new(0, 0, 0),
        facing = opts.facing or 0,
        fuel_chest_pos = opts.fuel_chest_pos or vector.new(0, 0, 0),
        home_pos = opts.home_pos or vector.new(0, 0, 0),
        item_targets = opts.item_targets or {}, -- { [item_name] = desired_count }
    }

    -- ---------- rotation ----------

    function self.turn_left()
        turtle.turnLeft()
        self.facing = (self.facing - 1) % 4
    end

    function self.turn_right()
        turtle.turnRight()
        self.facing = (self.facing + 1) % 4
    end

    function self.turn_to(target_facing)
        local diff = (target_facing - self.facing) % 4
        if diff == 1 then
            self.turn_right()
        elseif diff == 2 then
            self.turn_right()
            self.turn_right()
        elseif diff == 3 then
            self.turn_left()
        end
    end

    -- ---------- low level movement (auto-dig through obstructions) ----------

    local function try_clear_and(action, dig_fn, detect_fn)
        for _ = 1, MAX_DIG_ATTEMPTS do
            if action() then
                return true
            end
            if detect_fn() then
                dig_fn()
            else
                turtle.attack() -- probably a mob blocking the way
            end
            sleep(0.4)
        end
        return false
    end

    function self.move_forward()
        local ok = try_clear_and(turtle.forward, turtle.dig, turtle.detect)
        if ok then
            self.pos = self.pos + DIRS[self.facing]
        end
        return ok
    end

    function self.move_back()
        -- turtle.back() can't dig, so if it's blocked: turn around, clear, walk, turn back
        if turtle.back() then
            self.pos = self.pos - DIRS[self.facing]
            return true
        end
        self.turn_right()
        self.turn_right()
        local ok = self.move_forward()
        self.turn_right()
        self.turn_right()
        return ok
    end

    function self.move_up()
        local ok = try_clear_and(turtle.up, turtle.digUp, turtle.detectUp)
        if ok then
            self.pos = self.pos + vector.new(0, 1, 0)
        end
        return ok
    end

    function self.move_down()
        local ok = try_clear_and(turtle.down, turtle.digDown, turtle.detectDown)
        if ok then
            self.pos = self.pos - vector.new(0, 1, 0)
        end
        return ok
    end

    -- ---------- high level movement ----------

    local function move_vertical(delta)
        local step = delta > 0 and self.move_up or self.move_down
        for _ = 1, math.abs(delta) do
            step()
        end
    end

    local function move_horizontal(delta, pos_facing, neg_facing)
        if delta == 0 then return end
        self.turn_to(delta > 0 and pos_facing or neg_facing)
        for _ = 1, math.abs(delta) do
            self.move_forward()
        end
    end

    -- Naive straight-line-per-axis mover: does Y, then X, then Z.
    -- Fine for open/known terrain; it will dig through anything in a direct line.
    function self.move_to(target)
        move_vertical(target.y - self.pos.y)
        move_horizontal(target.x - self.pos.x, 1, 3)
        move_horizontal(target.z - self.pos.z, 2, 0)
    end

    -- ---------- fuel ----------

    -- Moves to fuel_chest_pos and sucks fuel from a chest directly ABOVE that position.
    function self.refuel()
        self.move_to(self.fuel_chest_pos)
        turtle.suckUp()
        for slot = 1, 16 do
            turtle.select(slot)
            turtle.refuel()
        end
        turtle.select(1)
    end

    function self.fuel_low(threshold)
        threshold = threshold or 200
        local level = turtle.getFuelLevel()
        return level ~= "unlimited" and level < threshold
    end

    -- ---------- inventory helpers ----------

    function self.count_item(item_name)
        local total = 0
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            if detail and detail.name == item_name then
                total = total + detail.count
            end
        end
        return total
    end

    function self.find_slot(item_name)
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            if detail and detail.name == item_name then
                return slot
            end
        end
        return nil
    end

    function self.inventory_full()
        for slot = 1, 16 do
            if turtle.getItemCount(slot) == 0 then
                return false
            end
        end
        return true
    end

    -- Runs turtle.refuel() over every slot; non-fuel items are silently
    -- skipped (turtle.refuel() just returns false, nothing is consumed).
    function self.refuel_from_inventory()
        for slot = 1, 16 do
            turtle.select(slot)
            turtle.refuel()
        end
        turtle.select(1)
    end

    -- ---------- generic chest interaction ----------
    -- side must be "top", "bottom", or "front" - the only directions a
    -- turtle can actually access a peripheral from. If your chest is to the
    -- side, turn to face it first and use "front".

    local function suck_fn_for(side)
        if side == "top" then return turtle.suckUp end
        if side == "bottom" then return turtle.suckDown end
        return turtle.suck
    end

    local function drop_fn_for(side)
        if side == "top" then return turtle.dropUp end
        if side == "bottom" then return turtle.dropDown end
        return turtle.drop
    end

    -- Pulls up to `amount` of item_name from the chest at `side` into the
    -- turtle's inventory. Returns how many were actually pulled.
    function self.take_item(side, item_name, amount)
        local chest = peripheral.wrap(side)
        if not chest then return 0 end
        local chest_name = peripheral.getName(chest)
        local suck = suck_fn_for(side)
        local pulled = 0

        while pulled < amount do
            local list = chest.list()
            local source_slot, source_data = nil, nil
            for slot, data in pairs(list) do
                if data.name == item_name then
                    source_slot, source_data = slot, data
                    break
                end
            end
            if not source_slot then break end

            if source_slot ~= 1 then
                make_room_in_slot1(chest, chest_name, list, item_name)
                list = chest.list()
                source_data = list[source_slot] or source_data
            end

            local take = math.min(amount - pulled, source_data.count)
            if source_slot ~= 1 then
                chest.pushItems(chest_name, source_slot, take, 1)
            end
            suck(take)
            pulled = pulled + take
        end

        return pulled
    end

    -- Drops everything from the turtle's inventory into the chest at `side`,
    -- except any item names present as keys in `exclude_names`.
    function self.push_items(side, exclude_names)
        exclude_names = exclude_names or {}
        local drop = drop_fn_for(side)
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            if detail and not exclude_names[detail.name] then
                turtle.select(slot)
                drop()
            end
        end
        turtle.select(1)
    end

    -- Pulls fuel_item_name from the chest at `side` and burns it, repeating
    -- until getFuelLevel() reaches target_level or the chest runs dry.
    function self.refuel_to(target_level, fuel_item_name, side)
        side = side or "top"
        while turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < target_level do
            local pulled = self.take_item(side, fuel_item_name, 8)
            if pulled == 0 then break end
            self.refuel_from_inventory()
        end
    end

    -- ---------- home chest (deposit / restock) ----------
    -- Assumes a chest directly ABOVE home_pos. For the fuel-only-chest-up /
    -- dump-chest-to-the-side layout, use take_item/push_items/refuel_to
    -- directly instead - see spruce_corridor_farm.lua vs strip_miner.lua.

    function self.deposit_all_at_home()
        self.move_to(self.home_pos)
        self.push_items("top")
    end

    -- Tops up every item in item_targets up to its target count, pulling
    -- from the chest above home_pos.
    function self.restock_at_home()
        self.move_to(self.home_pos)
        for item_name, target_count in pairs(self.item_targets) do
            local need = target_count - self.count_item(item_name)
            if need > 0 then
                self.take_item("top", item_name, need)
            end
        end
        return true
    end

    -- ---------- persistence (survive reboots/crashes) ----------
    -- `extra` is any script-specific progress data you want saved alongside
    -- pos/facing (e.g. which loop iteration you were on). load_state returns
    -- (found, extra) so callers can resume their own loop logic too.

    function self.save_state(filename, extra)
        filename = filename or "turtle_state.txt"
        local f = fs.open(filename, "w")
        if not f then
            print("save_state: could not open " .. filename .. " for writing")
            return false
        end
        f.write(textutils.serialize({
            pos = { x = self.pos.x, y = self.pos.y, z = self.pos.z },
            facing = self.facing,
            extra = extra or {},
        }))
        f.close()
        return true
    end

    function self.load_state(filename)
        filename = filename or "turtle_state.txt"
        if not fs.exists(filename) then return false, {} end
        local f = fs.open(filename, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        self.pos = vector.new(data.pos.x, data.pos.y, data.pos.z)
        self.facing = data.facing
        return true, data.extra or {}
    end

    function self.clear_state(filename)
        filename = filename or "turtle_state.txt"
        if fs.exists(filename) then
            fs.delete(filename)
        end
    end

    -- ---------- Ctrl-T terminate handling (opt-in) ----------

    function self.recover_to_home(facing)
        facing = facing or 0
        self.move_to(self.home_pos)
        self.turn_to(facing)
    end

    function self.on_terminate(callback)
        terminate_callback = callback
        install_terminate_handler()
    end

    return self
end

local function was_terminated(extra)
    return extra and extra.terminated == true
end

-- Returns a copy of extra with the terminated flag removed.
local function extra_without_terminated(extra)
    local cleared = {}
    for key, value in pairs(extra or {}) do
        if key ~= "terminated" then
            cleared[key] = value
        end
    end
    return cleared
end

return {
    new = new,
    was_terminated = was_terminated,
    extra_without_terminated = extra_without_terminated,
}