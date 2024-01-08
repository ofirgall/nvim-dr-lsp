local M = {}
local lsp = vim.lsp
local fn = vim.fn
--------------------------------------------------------------------------------

local lspCount = {}
local uv = vim.loop

local function calc_request(elements, uri_key, range_key, curr)
	local res = {
		file = 0,
		workspace = 0,
		location = 0,
	}
	local loc = 0
	if not elements then return res end
	res.workspace = #elements

	for _, e in pairs(elements) do
		if e[uri_key] == curr.uri then
			res.file = res.file + 1
			local range = e[range_key]

			if range.start.line < curr.line then
				-- In a previous line
				loc = loc + 1
			elseif range.start.line == curr.line then
				-- In current line

				if range.start.character <= curr.character then
					-- Previous range in same line
					loc = loc + 1
					if curr.line == range["end"].line and curr.character < range["end"].character then
						-- In current word
						res.location = loc
					end
				end
			end
		end
	end

	return res
end

local function request_finished(finish_callback)
	if finish_callback and lspCount.references ~= nil and lspCount.definitions ~= nil then
		if lspCount.references.location > 0 then
			lspCount.location = {
				type = "references",
				index = lspCount.references.location,
			}
		elseif lspCount.definitions.location > 0 then
			lspCount.location = {
				type = "definitions",
				index = lspCount.definitions.location,
			}
		else
			lspCount.location = {}
		end
		finish_callback()
	end
end

---calculate number of references for entity under cursor asynchronously
---@async
local function requestLspRefCount(finish_callback)
	if fn.mode() ~= "n" then
		lspCount = {}
		return
	end
	local params = lsp.util.make_position_params(0) ---@diagnostic disable-line: missing-parameter
	params.context = { includeDeclaration = false }

	local cursor = vim.api.nvim_win_get_cursor(0)

	local curr = {
		-- identifier in LSP response
		uri = vim.uri_from_fname(fn.expand("%:p")),

		-- Minus 1 because lsp lines are indexed by 0
		line = cursor[1] - 1,
		character = cursor[2],
	}

	lsp.buf_request(0, "textDocument/references", params, function(error, refs)
		if not error then
			lspCount.references = calc_request(refs, "uri", "range", curr)

			request_finished(finish_callback)
		end
	end)
	lsp.buf_request(0, "textDocument/definition", params, function(error, defs)
		if not error then
			lspCount.definitions = calc_request(defs, "targetUri", "targetRange", curr)

			request_finished(finish_callback)
		end
	end)
end

---Shows the number of definitions/references as identified by LSP. Shows count
---for the current file and for the whole workspace.
---@return string statusline text
---@nodiscard
function M.lspCount()
	local count = M.lspCountTable()
	if count == nil then return "" end

	-- format lsp references/definitions count to be displayed in the status bar
	local defs, refs = "", ""
	if count.workspace.definitions then
		defs = tostring(count.file.definitions)
		if count.file.definitions ~= count.workspace.definitions then
			defs = defs .. "(" .. tostring(count.workspace.definitions) .. ")"
		end
		defs = defs .. "D"
	end
	if count.workspace.references then
		refs = tostring(count.file.references)
		if count.file.references ~= count.workspace.references then
			refs = refs .. "(" .. tostring(count.workspace.references) .. ")"
		end
		refs = refs .. "R"
	end
	return "LSP: " .. defs .. " " .. refs
end

local function lspCountToResult()
	if lspCount.references.workspace == 0 and lspCount.definitions.workspace == 0 then return nil end
	if not lspCount.references.workspace then return nil end

	return {
		file = {
			definitions = lspCount.definitions.file,
			references = lspCount.references.file,
		},
		workspace = {
			definitions = lspCount.definitions.workspace,
			references = lspCount.references.workspace,
		},
		location = {
			type = lspCount.location.type,
			index = lspCount.location.index,
		},
	}
end

---@class LspCountSingleResult
---@field definitions number amount of definitions
---@field references number amount of references

---@class LspCountLocationResult
---@field type string location type (definitions|references)
---@field index number location index of the references/definitions

---@class LspCountResult
---@field file LspCountSingleResult local file result
---@field workspace LspCountSingleResult workspace result
---@field location LspCountLocationResult workspace result

local lastLspCount = 0

---Returns the number of definitions/references as identified by LSP as table
---for the current file and for the whole workspace.
---@return LspCountResult? table contains the lsp count results
function M.lspCountTable(throttle, on_finish_callback)
	if throttle then
		local now = uv.now()
		if now - lastLspCount < throttle then
			-- return last lsp count in cache
			return lspCountToResult()
		end
		lastLspCount = now
		-- print("new lsp results " .. uv.now())
	end

	-- abort when lsp loading or not capable of references
	local currentBufNr = fn.bufnr()
	local bufClients = lsp.get_active_clients { bufnr = currentBufNr }
	local lspProgress = (vim.version().minor > 9 and vim.version().major == 0) and vim.lsp.status()
		or vim.lsp.util.get_progress_messages()
	local lspLoading = lspProgress.title and lspProgress.title:find("[Ll]oad")
	local lspCapable = false
	for _, client in pairs(bufClients) do
		local capable = client.server_capabilities
		if capable.referencesProvider and capable.definitionProvider then lspCapable = true end
	end
	if vim.api.nvim_get_mode().mode ~= "n" or lspLoading or not lspCapable then return nil end

	-- trigger count, abort when none
	requestLspRefCount(on_finish_callback) -- needs to be separated due to lsp calls being async

	return lspCountToResult()
end

--------------------------------------------------------------------------------

-- Simple alternative to fidget.nvim, ignoring null-ls
-- based on snippet from u/folke https://www.reddit.com/r/neovim/comments/o4bguk/comment/h2kcjxa/
function M.lspProgress()
	local messages = (vim.version().minor > 9 and vim.version().major == 0) and vim.lsp.status()
		or vim.lsp.util.get_progress_messages()
	if #messages == 0 then return "" end
	local client = messages[1].name and messages[1].name .. ": " or ""
	if client:find("null%-ls") or client:find("none%-ls") then return "" end
	local progress = messages[1].percentage or 0
	local task = messages[1].title or ""
	task = task:gsub("^(%w+).*", "%1") -- only first word

	local spinners = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
	local ms = vim.loop.hrtime() / 1000000
	local frame = math.floor(ms / 120) % #spinners
	return spinners[frame + 1] .. " " .. client .. progress .. "%% " .. task
end

--------------------------------------------------------------------------------

return M
