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

-- Set true to append every movement/dig/chest action to debug.txt on the turtle.
-- Or pass { debug = true } to turtle_lib.new().
local DEBUG = true
local DEBUG_FILE = "debug.txt"

local function debug_timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function debug_log(self, message)
    if not self.debug then
        return
    end

    local fuel = turtle.getFuelLevel()
    local line = string.format(
        "[%s] pos=%s facing=%d fuel=%s %s\n",
        debug_timestamp(),
        tostring(self.pos),
        self.facing,
        tostring(fuel),
        message
    )

    local handle = fs.open(DEBUG_FILE, "a")
    if handle then
        handle.write(line)
        handle.close()
    end
end

local function clear_debug_file()
    if fs.exists(DEBUG_FILE) then
        fs.delete(DEBUG_FILE)
    end
end

local function upload_debug_file()
    if not fs.exists(DEBUG_FILE) then
        print("No " .. DEBUG_FILE)
        return false
    end

    local handle = fs.open(DEBUG_FILE, "r")
    local content = handle.readAll()
    handle.close()

    -- One-time setup: create pastebin_key.txt on this turtle with your dev API key.
    local api_key = nil
    if settings and settings.get then
        api_key = settings.get("pastebin.apiKey")
    end
    if (not api_key or api_key == "") and fs.exists("pastebin_key.txt") then
        local key_handle = fs.open("pastebin_key.txt", "r")
        if key_handle then
            api_key = key_handle.readAll():gsub("%s+", "")
            key_handle.close()
            if settings and settings.set then
                settings.set("pastebin.apiKey", api_key)
                print("Saved pastebin key to computer settings (no more typing it).")
            end
        end
    end

    if api_key and api_key ~= "" and http then
        print("Uploading " .. DEBUG_FILE .. " to Pastebin...")
        local body = "api_dev_key=" .. textutils.urlEncode(api_key)
            .. "&api_option=paste"
            .. "&api_paste_code=" .. textutils.urlEncode(content)
            .. "&api_paste_name=" .. textutils.urlEncode("turtle debug")
            .. "&api_paste_format=text"
            .. "&api_paste_private=1"
            .. "&api_paste_expire_date=1D"
        local response = http.post(
            "https://pastebin.com/api/api_post.php",
            body,
            { ["Content-Type"] = "application/x-www-form-urlencoded" }
        )
        if response then
            local url = response.readAll():gsub("%s+", "")
            response.close()
            if url:match("^https://pastebin%.com/") then
                print("Debug log: " .. url)
                return true
            end
            print("Pastebin error: " .. url)
        end
    end

    print("Uploading via pastebin program...")
    if shell.run("pastebin", "put", DEBUG_FILE) then
        print("Paste URL printed above.")
        return true
    end

    print("Upload failed. Create pastebin_key.txt on this turtle (one line = dev API key).")
    print("Printing log to screen:")
    print(content)
    return false
end

local function print_debug_file()
    if not fs.exists(DEBUG_FILE) then
        print("No " .. DEBUG_FILE)
        return false
    end

    local handle = fs.open(DEBUG_FILE, "r")
    if handle then
        print(handle.readAll())
        handle.close()
    end
    return true
end

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
        debug = opts.debug ~= nil and opts.debug or DEBUG,
    }

    if self.debug then
        clear_debug_file()
        debug_log(self, "debug session start")
    end

    -- ---------- rotation ----------

    function self.turn_left()
        turtle.turnLeft()
        self.facing = (self.facing - 1) % 4
        debug_log(self, "turn_left -> facing=" .. self.facing)
    end

    function self.turn_right()
        turtle.turnRight()
        self.facing = (self.facing + 1) % 4
        debug_log(self, "turn_right -> facing=" .. self.facing)
    end

    function self.turn_to(target_facing)
        debug_log(self, "turn_to target=" .. target_facing .. " from=" .. self.facing)
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

    local function try_clear_and(action, dig_fn, detect_fn, action_name)
        for attempt = 1, MAX_DIG_ATTEMPTS do
            if action() then
                debug_log(self, action_name .. " OK attempt=" .. attempt)
                return true
            end
            if detect_fn() then
                debug_log(self, action_name .. " blocked dig attempt=" .. attempt)
                dig_fn()
            else
                debug_log(self, action_name .. " blocked attack attempt=" .. attempt)
                turtle.attack() -- probably a mob blocking the way
            end
            sleep(0.4)
        end
        debug_log(self, action_name .. " FAIL attempts=" .. MAX_DIG_ATTEMPTS)
        return false
    end

    function self.move_forward()
        debug_log(self, "move_forward START")
        local ok = try_clear_and(turtle.forward, turtle.dig, turtle.detect, "move_forward")
        if ok then
            self.pos = self.pos + DIRS[self.facing]
        end
        debug_log(self, "move_forward END ok=" .. tostring(ok) .. " pos=" .. tostring(self.pos))
        return ok
    end

    function self.move_back()
        debug_log(self, "move_back START")
        -- turtle.back() can't dig, so if it's blocked: turn around, clear, walk, turn back
        if turtle.back() then
            self.pos = self.pos - DIRS[self.facing]
            debug_log(self, "move_back OK direct pos=" .. tostring(self.pos))
            return true
        end
        self.turn_right()
        self.turn_right()
        local ok = self.move_forward()
        self.turn_right()
        self.turn_right()
        debug_log(self, "move_back END ok=" .. tostring(ok) .. " pos=" .. tostring(self.pos))
        return ok
    end

    function self.move_up()
        debug_log(self, "move_up START")
        local ok = try_clear_and(turtle.up, turtle.digUp, turtle.detectUp, "move_up")
        if ok then
            self.pos = self.pos + vector.new(0, 1, 0)
        end
        debug_log(self, "move_up END ok=" .. tostring(ok) .. " pos=" .. tostring(self.pos))
        return ok
    end

    function self.move_down()
        debug_log(self, "move_down START")
        local ok = try_clear_and(turtle.down, turtle.digDown, turtle.detectDown, "move_down")
        if ok then
            self.pos = self.pos - vector.new(0, 1, 0)
        end
        debug_log(self, "move_down END ok=" .. tostring(ok) .. " pos=" .. tostring(self.pos))
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
        debug_log(self, "move_to START target=" .. tostring(target) .. " from=" .. tostring(self.pos))
        move_vertical(target.y - self.pos.y)
        move_horizontal(target.x - self.pos.x, 1, 3)
        move_horizontal(target.z - self.pos.z, 2, 0)
        debug_log(self, "move_to END pos=" .. tostring(self.pos))
    end

    -- ---------- fuel ----------

    -- Moves to fuel_chest_pos and sucks fuel from a chest directly ABOVE that position.
    function self.refuel()
        debug_log(self, "refuel START")
        self.move_to(self.fuel_chest_pos)
        local sucked = turtle.suckUp()
        debug_log(self, "refuel suckUp=" .. tostring(sucked))
        for slot = 1, 16 do
            turtle.select(slot)
            if turtle.refuel() then
                debug_log(self, "refuel burned slot=" .. slot)
            end
        end
        turtle.select(1)
        debug_log(self, "refuel END fuel=" .. tostring(turtle.getFuelLevel()))
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
        debug_log(self, "take_item START side=" .. side .. " item=" .. item_name .. " amount=" .. amount)
        local chest = peripheral.wrap(side)
        if not chest then
            debug_log(self, "take_item FAIL no chest on " .. side)
            return 0
        end
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
            local sucked = suck(take)
            debug_log(self, "take_item suck take=" .. take .. " ok=" .. tostring(sucked))
            pulled = pulled + take
        end

        debug_log(self, "take_item END pulled=" .. pulled)
        return pulled
    end

    -- Drops everything from the turtle's inventory into the chest at `side`,
    -- except any item names present as keys in `exclude_names`.
    function self.push_items(side, exclude_names)
        exclude_names = exclude_names or {}
        debug_log(self, "push_items START side=" .. side)
        local drop = drop_fn_for(side)
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            if detail and not exclude_names[detail.name] then
                turtle.select(slot)
                local dropped = drop()
                debug_log(self, "push_items slot=" .. slot .. " item=" .. detail.name .. " ok=" .. tostring(dropped))
            end
        end
        turtle.select(1)
        debug_log(self, "push_items END")
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
        debug_log(self, "deposit_all_at_home")
        self.move_to(self.home_pos)
        self.push_items("top")
    end

    -- Tops up every item in item_targets up to its target count, pulling
    -- from the chest above home_pos.
    function self.restock_at_home()
        debug_log(self, "restock_at_home")
        self.move_to(self.home_pos)
        for item_name, target_count in pairs(self.item_targets) do
            local need = target_count - self.count_item(item_name)
            if need > 0 then
                debug_log(self, "restock_at_home need=" .. need .. " of " .. item_name)
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
        debug_log(self, "save_state " .. filename)
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
        debug_log(self, "load_state " .. filename .. " pos=" .. tostring(self.pos) .. " facing=" .. self.facing)
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
        debug_log(self, "recover_to_home facing=" .. facing)
        self.move_to(self.home_pos)
        self.turn_to(facing)
    end

    function self.on_terminate(callback)
        terminate_callback = callback
        install_terminate_handler()
    end

    function self.log(message)
        debug_log(self, message)
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
    upload_debug = upload_debug_file,
    print_debug = print_debug_file,
    DEBUG = DEBUG,
    DEBUG_FILE = DEBUG_FILE,
}