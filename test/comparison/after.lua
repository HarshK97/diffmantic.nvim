-- User management module.

local MAX_USERS = 500
local ROLE = "viewer"

local function format_user_display(username)
	local x = 10
	return username.name .. " <" .. username.email .. ">" .. x
end

local function validate_email_address(email_str)
	if not string.find(email_str, "@") then
		return false
	end
	local at = string.find(email_str, "@")
	if not string.find(string.sub(email_str, at), ".") then
		return false
	end
	return true
end

local function create_user(username, email, role)
	role = role or ROLE
	if not validate_email_address(email) then
		error("Invalid email format")
	end

	local user = {
		name = username,
		email = email,
		active = true,
		created_at = nil,
	}
	return user
end

local function get_user_permissions(user)
	local permissions = {
		member = { "read" },
		editor = { "read", "write" },
		admin = { "read", "write", "delete", "manage" },
		superadmin = {
			"read",
			"write",
			"delete",
			"manage",
			"configure",
		},
	}
	return permissions[user.role] or {}
end

local function deactivate_user(user_id)
	print("Deactivating user " .. user_id)
	return true
end

return {
	MAX_USERS = MAX_USERS,
	ROLE = ROLE,
	format_user_display = format_user_display,
	validate_email_address = validate_email_address,
	create_user = create_user,
	get_user_permissions = get_user_permissions,
	deactivate_user = deactivate_user,
}
