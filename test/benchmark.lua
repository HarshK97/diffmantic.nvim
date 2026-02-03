-- AI generated benchmark
-- Benchmark tests for nvim-gumtree-diff
-- Tests performance with files from 100 to 10000 lines

local core = require("diffmantic.core")
local ts = require("diffmantic.treesitter")

-- Redirect output to file for headless mode
local output_file = io.open("/tmp/gumtree_benchmark.txt", "w")
local function log(msg)
	output_file:write(msg .. "\n")
	output_file:flush()
end

-- Generate synthetic Lua code of specified size
local function generate_lua_code(num_functions, vars_per_function)
	local lines = {}
	table.insert(lines, "-- Auto-generated benchmark file")
	table.insert(lines, "local M = {}")
	table.insert(lines, "")

	for i = 1, num_functions do
		table.insert(lines, string.format("function M.func_%d()", i))
		for j = 1, vars_per_function do
			table.insert(lines, string.format("  local var_%d_%d = %d", i, j, i * 100 + j))
		end
		table.insert(lines, string.format("  return var_%d_1 + var_%d_%d", i, i, vars_per_function))
		table.insert(lines, "end")
		table.insert(lines, "")
	end

	table.insert(lines, "return M")
	return table.concat(lines, "\n")
end

-- Generate modified version (swaps some functions, changes some values)
local function generate_modified_lua(num_functions, vars_per_function, changes)
	local lines = {}
	table.insert(lines, "-- Auto-generated benchmark file (modified)")
	table.insert(lines, "local M = {}")
	table.insert(lines, "")

	-- Build function order with some swaps
	local order = {}
	for i = 1, num_functions do
		order[i] = i
	end

	-- Swap some adjacent functions
	for i = 1, math.min(changes.swaps or 0, math.floor(num_functions / 2)) do
		local idx = i * 2 - 1
		if idx + 1 <= num_functions then
			order[idx], order[idx + 1] = order[idx + 1], order[idx]
		end
	end

	for _, i in ipairs(order) do
		table.insert(lines, string.format("function M.func_%d()", i))
		for j = 1, vars_per_function do
			local value = i * 100 + j
			-- Change some values
			if i <= (changes.updates or 0) and j == 1 then
				value = value + 1000
			end
			table.insert(lines, string.format("  local var_%d_%d = %d", i, j, value))
		end
		table.insert(lines, string.format("  return var_%d_1 + var_%d_%d", i, i, vars_per_function))
		table.insert(lines, "end")
		table.insert(lines, "")
	end

	table.insert(lines, "return M")
	return table.concat(lines, "\n")
end

-- Run benchmark with given parameters
local function run_benchmark(name, num_functions, vars_per_function, changes)
	local src_code = generate_lua_code(num_functions, vars_per_function)
	local dst_code = generate_modified_lua(num_functions, vars_per_function, changes)

	local src_lines = vim.split(src_code, "\n")
	local dst_lines = vim.split(dst_code, "\n")

	log(string.format("\n=== %s ===", name))
	log(string.format("Source: %d lines, Dest: %d lines", #src_lines, #dst_lines))
	log(string.format("Functions: %d, Vars/function: %d", num_functions, vars_per_function))
	log(string.format("Changes: %d swaps, %d updates", changes.swaps or 0, changes.updates or 0))

	-- Create buffers
	local src_buf = vim.api.nvim_create_buf(false, true)
	local dst_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, src_lines)
	vim.api.nvim_buf_set_lines(dst_buf, 0, -1, false, dst_lines)
	vim.bo[src_buf].filetype = "lua"
	vim.bo[dst_buf].filetype = "lua"

	-- Parse trees
	local src_parser = vim.treesitter.get_parser(src_buf, "lua")
	local dst_parser = vim.treesitter.get_parser(dst_buf, "lua")
	local src_tree = src_parser:parse()[1]
	local dst_tree = dst_parser:parse()[1]
	local src_root = src_tree:root()
	local dst_root = dst_tree:root()

	-- Benchmark the full matching pipeline
	local start_total = vim.loop.hrtime()

	-- Top-down match (includes preprocessing internally)
	local start_topdown = vim.loop.hrtime()
	local mappings, src_info, dst_info = core.top_down_match(src_root, dst_root, src_buf, dst_buf)
	local topdown_time = (vim.loop.hrtime() - start_topdown) / 1e6

	-- Bottom-up match
	local start_bottomup = vim.loop.hrtime()
	mappings = core.bottom_up_match(mappings, src_info, dst_info, src_root, dst_root, src_buf, dst_buf)
	local bottomup_time = (vim.loop.hrtime() - start_bottomup) / 1e6

	-- Recovery match (simple recovery)
	local start_recovery = vim.loop.hrtime()
	mappings = core.recovery_match(src_root, dst_root, mappings, src_info, dst_info, src_buf, dst_buf)
	local recovery_time = (vim.loop.hrtime() - start_recovery) / 1e6

	-- Generate actions
	local start_actions = vim.loop.hrtime()
	local actions = core.generate_actions(src_root, dst_root, mappings, src_info, dst_info)
	local actions_time = (vim.loop.hrtime() - start_actions) / 1e6

	local total_time = (vim.loop.hrtime() - start_total) / 1e6

	-- Count actions
	local move_count, update_count, delete_count, insert_count = 0, 0, 0, 0
	for _, action in ipairs(actions) do
		if action.type == "move" then
			move_count = move_count + 1
		elseif action.type == "update" then
			update_count = update_count + 1
		elseif action.type == "delete" then
			delete_count = delete_count + 1
		elseif action.type == "insert" then
			insert_count = insert_count + 1
		end
	end

	log(string.format("\nTiming (ms):"))
	log(string.format("  Top-down:    %8.2f ms (includes preprocessing)", topdown_time))
	log(string.format("  Bottom-up:   %8.2f ms", bottomup_time))
	log(string.format("  Recovery:    %8.2f ms", recovery_time))
	log(string.format("  Actions:     %8.2f ms", actions_time))
	log(string.format("  TOTAL:       %8.2f ms", total_time))

	log(string.format("\nResults:"))
	log(string.format("  Mappings: %d", #mappings))
	log(
		string.format(
			"  Actions: %d (moves=%d, updates=%d, deletes=%d, inserts=%d)",
			#actions,
			move_count,
			update_count,
			delete_count,
			insert_count
		)
	)

	-- Cleanup
	vim.api.nvim_buf_delete(src_buf, { force = true })
	vim.api.nvim_buf_delete(dst_buf, { force = true })

	return {
		lines = #src_lines,
		total_time = total_time,
		topdown = topdown_time,
		bottomup = bottomup_time,
		recovery = recovery_time,
		actions = actions_time,
		mappings = #mappings,
		action_count = #actions,
	}
end

-- Main benchmark suite
log("========================================")
log("    GUMTREE DIFF BENCHMARK SUITE")
log("========================================")
log(string.format("Date: %s", os.date()))

local results = {}

-- Test cases: (name, functions, vars_per_func, {swaps, updates})
local test_cases = {
	{ "~100 lines", 10, 5, { swaps = 2, updates = 2 } },
	{ "~250 lines", 25, 5, { swaps = 5, updates = 5 } },
	{ "~500 lines", 50, 5, { swaps = 10, updates = 10 } },
	{ "~750 lines", 75, 5, { swaps = 15, updates = 15 } },
	{ "~1000 lines", 100, 5, { swaps = 20, updates = 20 } },
	{ "~2500 lines", 280, 5, { swaps = 50, updates = 50 } },
	{ "~5000 lines", 560, 5, { swaps = 100, updates = 100 } },
	{ "~7500 lines", 840, 5, { swaps = 150, updates = 150 } },
	{ "~10000 lines", 1120, 5, { swaps = 200, updates = 200 } },
}

for _, tc in ipairs(test_cases) do
	local result = run_benchmark(tc[1], tc[2], tc[3], tc[4])
	table.insert(results, { name = tc[1], result = result })
end

-- Summary table
log("\n========================================")
log("              SUMMARY")
log("========================================")
log(
	string.format(
		"%-12s %6s %10s %10s %10s %10s %10s",
		"Test",
		"Lines",
		"TopDown",
		"BottomUp",
		"Recovery",
		"Actions",
		"TOTAL"
	)
)
log(string.rep("-", 80))
for _, r in ipairs(results) do
	log(
		string.format(
			"%-12s %6d %10.2f %10.2f %10.2f %10.2f %10.2f",
			r.name,
			r.result.lines,
			r.result.topdown,
			r.result.bottomup,
			r.result.recovery,
			r.result.actions,
			r.result.total_time
		)
	)
end

log("\n========================================")
log("    BENCHMARK COMPLETE")
log("========================================")

output_file:close()
vim.cmd("qa!")
