// User management module.

const MAX_USERS = 100;
const DEFAULT_ROLE = "viewer";

function validateEmail(email) {
  if (!email.includes("@")) {
    return false;
  }
  if (!email.split("@")[1].includes(".")) {
    return false;
  }
  return true;
}

function createUser(name, email, role = DEFAULT_ROLE) {
  if (!validateEmail(email)) {
    throw new Error("Invalid email format");
  }

  return {
    name,
    email,
    role,
    active: true,
  };
}

function getUserPermissions(role) {
  if (role === "viewer") {
    return ["read"];
  }
  if (role === "editor") {
    return ["read", "write"];
  }
  if (role === "admin") {
    return ["read", "write", "delete", "manage"];
  }
  return [];
}

function deleteUser(userId) {
  console.log(`Deleting user ${userId}`);
  return true;
}

function formatUserDisplay(user) {
  return `${user.name} <${user.email}>`;
}
