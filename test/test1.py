# Test file A (original) - Python
# Tests: Move, Update, Delete, Rename, Value update, Insert


def calculate_sum(a, b):
    """Add two numbers."""
    return a + b


def calculate_difference(a, b):
    """Subtract two numbers."""
    return a - b


def multiply(x, y):
    """Multiply two numbers."""
    result = x * y
    return result


def get_user(user_id):
    """Fetch user info."""
    return {"id": user_id, "active": True}


def deprecated_helper():
    return "deprecated"


class ApiClient:
    def __init__(self, base_url):
        self.base_url = base_url

    def fetch_data(self, path):
        return self.base_url + path


# Configuration
API_URL = "https://api.example.com/v1"
CACHE_DIR = "/tmp/app/cache"
DEBUG_MODE = True

SETTINGS = {
    "retries": 3,
    "timeout": 30,
    "mode": "basic",
}

PORTS = [8000, 8001, 8002]

# Old variable that will be deleted
legacy_timeout = 30

# Variable to be renamed
timeout = 30
