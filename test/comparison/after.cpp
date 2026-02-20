#include <string>
#include <stdexcept>
#include <cstdio>

const int MAX_USERS = 500;
const std::string ROLE = "viewer";

struct User {
    std::string name;
    std::string email;
    bool active;
    std::string created_at;
};

std::string format_user_display(const User &user) {
    std::string result = user.name + " <" + user.email + ">";
    return result;
}

bool validate_email_address(const std::string &email_str) {
    if (email_str.find('@') == std::string::npos) {
        return false;
    }
    if (email_str.find('.') == std::string::npos) {
        return false;
    }
    return true;
}

User create_user(const std::string &username, const std::string &email, const std::string &role = ROLE) {
    if (!validate_email_address(email)) {
        throw std::runtime_error("Invalid email format");
    }

    User user;
    user.name = username;
    user.email = email;
    user.active = true;
    user.created_at = "";
    (void)role;
    return user;
}

std::string get_user_permissions(const std::string &role) {
    if (role == "member") {
        return "read";
    }
    if (role == "editor") {
        return "read,write";
    }
    if (role == "admin") {
        return "read,write,delete,manage";
    }
    if (role == "superadmin") {
        return "read,write,delete,manage,configure";
    }
    return "";
}

void deactivate_user(int user_id) {
    std::printf("Deactivating user %d\n", user_id);
}
