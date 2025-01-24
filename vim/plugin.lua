package.path = './?.lua;' .. package.path

local StringChunker = require("StringChunker")

local uv = vim.uv
local pipe = uv.new_pipe(false)

local message_types = {
    file_data = 0,
    file_end = 1,
    file_patch = 2,
    cursor_update = 3,
}

local connected = false
-- FIXME reconnect if droped
-- FIXME hardcoded ugly path
pipe:connect('/home/streamer/work/code-map/test.sock', function(data)
	if not data then
		connected = true
	end
end)
--local count = 0
--code_map_timer = uv.new_timer()
--code_map_timer:start(1000, 1000, function ()
--	vim.schedule(function()
--		local name = vim.api.nvim_buf_get_name(0)
--		local cursor = vim.api.nvim_win_get_cursor(0)
--		local message = string.format(
--			'{"name": "%s", "line": %d, "col": %d}\0',
--			name,
--			cursor[1],
--			cursor[2]
--		);
--		pipe:write(message)
--	end)
--end)

--{
--   "range": {
--       "start": 5,
--       "end": 10,
--   }
--   "new_content": [
--      "line_1",
--      "line_2",
--      "line_3",
--   ]
--}


-- Timer
-- This stuff changed, but don't send for some time
-- New stuff happened IF its in the same block, modify
-- Else send then add new
-- Delete lines 5 -> 7
-- add stuff at line 6
--
-- Delete lines 5 -> 8
-- "line_6"
local pending_change = nil

-- firstline == line being edited
-- lastline == 1 past lines edited
-- lastlineupdated == new 1 past lines edited
local function pendingRangeLines(handle, firstline, lastline)
	if not pending_change then
		return nil
	end

	if handle ~= pending_change.handle then
		return nil
	end

	local pending_start = pending_change.range.first
	local pending_len = #pending_change.lines

	local start_offs = firstline - pending_start
	local end_offs = lastline - pending_start

	if (start_offs <= pending_len and start_offs >= 0) or (end_offs <= pending_len and end_offs > 0) then
		return {start_offs, end_offs}
	end

	return nil
end

local function leEncode(num, size)
    local ret = ""
    for i=1,size do
        local this_num = num % 0x100
        ret = ret .. string.char(this_num)
        num = num / 0x100
    end
    return ret
end


local function serializePendingChange()
    if not pending_change then
        return nil
    end

    local serialized = ""

    serialized = serialized .. leEncode(pending_change.range.first, 4)
    serialized = serialized .. leEncode(pending_change.range.last, 4)
    serialized = serialized .. leEncode(#pending_change.lines, 4)
    for i=1,#pending_change.lines do
        local line = pending_change.lines[i];
        serialized = serialized .. leEncode(#line, 4)
        serialized = serialized .. line
    end

    return serialized
end

local function sendServerMessage(message_type, content)
    local to_send = leEncode(message_type, 2) .. leEncode(#content, 4) .. content
    pipe:write(to_send)
end

local function sendPendingChange()
    local content = serializePendingChange()
    if not content then
        return
    end
    sendServerMessage(message_types.file_patch, content)
	pending_change = nil
end

local function pushChange(handle, firstline, lastline, lastlineupdated)
	vim.print("firstline " .. firstline .. " lastline " .. lastline .. " updated " .. lastlineupdated)
	local pending_range_lines = pendingRangeLines(handle, firstline, lastline)

	if not pending_range_lines then
		sendPendingChange()
		pending_change = {
			handle = handle,
			range = {
				first = firstline,
				last = lastline,
			},
			-- FIXME: Retrieve lines
			lines = vim.api.nvim_buf_get_lines(handle, firstline, lastlineupdated, true),
		}
	else
		local start_offs = pending_range_lines[1]
		local end_offs = pending_range_lines[2]

		vim.print("start_offs" .. start_offs)
		vim.print("end_offs" .. end_offs)
		while start_offs < 0 do
			pending_change.range.first = pending_change.range.first - 1
			start_offs = start_offs + 1
			end_offs = end_offs + 1

			table.insert(pending_change.lines, 1, "")
		end

		local buf_lines = vim.api.nvim_buf_get_lines(handle, firstline, lastlineupdated, true)
		local new_lines = {}

		for i=1,start_offs do
			new_lines[i] = pending_change.lines[i]
		end

		for i=1,#buf_lines do
			new_lines[start_offs + i] = buf_lines[i]
		end

		for i=1,#pending_change.lines - end_offs do
			new_lines[start_offs + #buf_lines + i] = pending_change.lines[i + end_offs]
		end
		pending_change.lines = new_lines
	end
end

local max_file_content_len = 50 -- 2^32 - 1

local function sendFileData(handle)
    -- FIXME: \r\n users are unhappy :)
    local text = table.concat(vim.api.nvim_buf_get_lines(handle, 0, -1, true), '\n')

    local chunker = StringChunker:init(text, max_file_content_len)
    while chunker:next() do
        local message_type = message_types.file_data
        if chunker:isLast() then
            message_type = message_types.file_end
        end

        sendServerMessage(message_type, chunker:data())
    end
end

-- FIXME: Work with already open buffers
vim.api.nvim_create_autocmd({"BufWinEnter"}, {
    callback = function(ev)
        sendFileData(ev.buf)
        vim.api.nvim_buf_attach(ev.buf, false, {
            on_lines = function(_, handle, changedtick, firstline, lastline, lastlineupdated )
            vim.print("hi\n")
                --pcall(function()
                    pushChange(handle, firstline, lastline, lastlineupdated)
                    vim.print(pending_change)
                    --end)
                end,
            })
        end
    })
