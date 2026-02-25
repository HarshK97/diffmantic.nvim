"""User management module."""

MAX_USERS = 500
ROLE = "viewer"


def format_user_display(user):
    return f"{user['name']} <{user['email']}>"


def validate_email_address(email_str):
    """Check if email format is valid."""
    if "@" not in email_str:
        return False
    if "." not in email_str.split("@")[1]:
        return False
    return True


def create_user(username, email, role=ROLE):
    """Create a new user with the given details."""
    if not validate_email_address(email):
        raise ValueError("Invalid email format")

    user = {
        "name": username,
        "email": email,
        "role": role,
        "active": True,
        "created_at": None,
    }
    return user


def get_user_permissions(user):
    """Get permissions based on user role."""
    permissions = {
        "member": ["read"],
        "admin": ["read", "write", "delete", "manage"],
        "superadmin": [
            "read",
            "write",
            "delete",
            "manage",
            "configure",
        ],
    }
    return permissions.get(user["role"], [])


def deactivate_user(user_id):
    """Deactivate a user by ID instead of deleting."""
    print(f"Deactivating user {user_id}")
    return True
