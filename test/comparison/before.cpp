#include <string>
#include <stdexcept>
#include <cstdio>

const int MAX_USERS = 100;
const std::string DEFAULT_ROLE = "viewer";

bool validate_email(const std::string &email) {
    if (email.find('@') == std::string::npos) {
        return false;
    }
    if (email.find('.') == std::string::npos) {
        return false;
    }
    return true;
}

struct User {
    std::string name;
    std::string email;
    std::string role;
    bool active;
};

User create_user(const std::string &name, const std::string &email, const std::string &role = DEFAULT_ROLE) {
    if (!validate_email(email)) {
        throw std::runtime_error("Invalid email format");
    }

    User user;
    user.name = name;
    user.email = email;
    user.role = role;
    user.active = true;
    return user;
}

std::string get_user_permissions(const std::string &role) {
    if (role == "viewer") {
        return "read";
    }
    if (role == "editor") {
        return "read,write";
    }
    if (role == "admin") {
        return "read,write,delete,manage";
    }
    return "";
}

void delete_user(int user_id) {
    std::printf("Deleting user %d\n", user_id);
}

std::string format_user_display(const User &user) {
    return user.name + " <" + user.email + ">";
}
