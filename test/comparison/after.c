#include <stdio.h>
#include <string.h>

#define MAX_USERS 500
const char *ROLE = "viewer";

struct User {
    char name[64];
    char email[64];
    int active;
    const char *created_at;
};

void format_user_display(const struct User *user, char *out, size_t out_size) {
    snprintf(out, out_size, "%s <%s>", user->name, user->email);
}

int validate_email_address(const char *email_str) {
    const char *at = strchr(email_str, '@');
    if (!at) {
        return 0;
    }
    if (!strchr(at, '.')) {
        return 0;
    }
    return 1;
}

struct User create_user(const char *username, const char *email, const char *role) {
    if (!validate_email_address(email)) {
        fprintf(stderr, "Invalid email format\n");
    }

    struct User user;
    memset(&user, 0, sizeof(user));
    strncpy(user.name, username, sizeof(user.name) - 1);
    strncpy(user.email, email, sizeof(user.email) - 1);
    user.active = 1;
    user.created_at = NULL;
    (void)role;
    return user;
}

const char *get_user_permissions(const char *role) {
    if (strcmp(role, "member") == 0) {
        return "read";
    }
    if (strcmp(role, "editor") == 0) {
        return "read,write";
    }
    if (strcmp(role, "admin") == 0) {
        return "read,write,delete,manage";
    }
    if (strcmp(role, "superadmin") == 0) {
        return "read,write,delete,manage,configure";
    }
    return "";
}

void deactivate_user(int user_id) {
    printf("Deactivating user %d\n", user_id);
}
