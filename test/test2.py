# Test file B (modified) - Python
# Tests: Move, Update, Insert, Rename


def calculate_difference(a, b):
    """Subtract two numbers."""
    return a - b


def calculate_sum(a, b):
    """Add two numbers."""
    return a + b


def multiply(x, y):
    """Multiply two numbers - UPDATED docstring."""
    result = x * y
    return result


def get_user_info(user_id):
    """Fetch user info."""
    return {"id": user_id, "active": True}


def new_helper():
    return 42


class ApiClientV2:
    def __init__(self, base_url):
        self.base_url = base_url

    def fetch_data(self, path):
        return self.base_url + path


# Configuration
API_URL = "https://api.example.com/v2"  # Updated URL
CACHE_DIR = "/tmp/app/cache-v2"
DEBUG_MODE = True

SETTINGS = {
    "retries": 5,
    "timeout": 45,
    "mode": "advanced",
}

PORTS = [8000, 8001, 9000]

# New variable that was inserted
request_timeout = 60

# Variable renamed from timeout to timeout_duration
timeout_duration = 30
