#include <stdio.h>
#include <string.h>

#define MAX_USERS 100
const char *DEFAULT_ROLE = "viewer";

int validate_email(const char *email) {
    const char *at = strchr(email, '@');
    if (!at) {
        return 0;
    }
    if (!strchr(at, '.')) {
        return 0;
    }
    return 1;
}

struct User {
    char name[64];
    char email[64];
    char role[32];
    int active;
};

struct User create_user(const char *name, const char *email, const char *role) {
    if (!validate_email(email)) {
        fprintf(stderr, "Invalid email format\n");
    }

    struct User user;
    memset(&user, 0, sizeof(user));
    strncpy(user.name, name, sizeof(user.name) - 1);
    strncpy(user.email, email, sizeof(user.email) - 1);
    strncpy(user.role, role, sizeof(user.role) - 1);
    user.active = 1;
    return user;
}

const char *get_user_permissions(const char *role) {
    if (strcmp(role, "viewer") == 0) {
        return "read";
    }
    if (strcmp(role, "editor") == 0) {
        return "read,write";
    }
    if (strcmp(role, "admin") == 0) {
        return "read,write,delete,manage";
    }
    return "";
}

void delete_user(int user_id) {
    printf("Deleting user %d\n", user_id);
}

void format_user_display(const struct User *user, char *out, size_t out_size) {
    snprintf(out, out_size, "%s <%s>", user->name, user->email);
}
