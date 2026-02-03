if vim.g.loaded_diffmantic then
	return
end

vim.g.loaded_diffmantic = 1

vim.api.nvim_create_user_command("Diffmantic", function(opts)
	require("diffmantic").diff(opts.args)
end, {
	nargs = "+",
	complete = "file",
	desc = "Semantic diff using Treesitter",
})
