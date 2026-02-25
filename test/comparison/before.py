"""User management module."""

MAX_USERS = 100
DEFAULT_ROLE = "viewer"


def validate_email(email):
    """Check if email format is valid."""
    if "@" not in email:
        return False
    if "." not in email.split("@")[1]:
        return False
    return True


def create_user(name, email, role=DEFAULT_ROLE):
    """Create a new user with the given details."""
    if not validate_email(email):
        raise ValueError("Invalid email format")

    user = {
        "name": name,
        "email": email,
        "role": role,
        "active": True,
    }
    return user


def get_user_permissions(user):
    """Get permissions based on user role."""
    permissions = {
        "viewer": ["read"],
        "editor": ["read", "write"],
        "admin": ["read", "write", "delete", "manage"],
    }
    return permissions.get(user["role"], [])


def format_user_display(user):
    """Format user for display."""
    return f"{user['name']} <{user['email']}>"


def delete_user(user_id):
    """Delete a user by ID."""
    print(f"Deleting user {user_id}")
    return True
