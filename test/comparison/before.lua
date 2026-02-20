-- User management module.

local MAX_USERS = 100
local DEFAULT_ROLE = "viewer"

local function validate_email(email)
	if not string.find(email, "@") then
		return false
	end
	local at = string.find(email, "@")
	if not string.find(string.sub(email, at), ".") then
		return false
	end
	return true
end

local function create_user(name, email, role)
	role = role or DEFAULT_ROLE
	if not validate_email(email) then
		error("Invalid email format")
	end

	local user = {
		name = name,
		email = email,
		role = role,
		active = true,
	}
	return user
end

local function get_user_permissions(user)
	local permissions = {
		viewer = { "read" },
		editor = { "read", "write" },
		admin = { "read", "write", "delete", "manage" },
	}
	return permissions[user.role] or {}
end

local function delete_user(user_id)
	print("Deleting user " .. user_id)
	return true
end

local function format_user_display(user)
	return user.name .. " <" .. user.email .. ">"
end

return {
	MAX_USERS = MAX_USERS,
	DEFAULT_ROLE = DEFAULT_ROLE,
	validate_email = validate_email,
	create_user = create_user,
	get_user_permissions = get_user_permissions,
	delete_user = delete_user,
	format_user_display = format_user_display,
}
