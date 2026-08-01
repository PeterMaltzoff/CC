-- upload_debug.lua
-- Send debug.txt from this turtle to the PC receiver (receive_debug.py).
--
-- Usage: upload_debug

package.loaded["turtle_lib"] = nil
local turtle_lib = require("turtle_lib")

if turtle_lib.upload_debug() then
    print("Done.")
else
    print("Failed. Is `python receive_debug.py` running on the PC?")
end
