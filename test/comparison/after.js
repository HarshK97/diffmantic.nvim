// User management module.

const MAX_USERS = 500;
const ROLE = "viewer";

function formatUserDisplay(user) {
  const result = `${user.name} <${user.email}>`;
  return result;
}

function validateEmailAddress(emailStr) {
  if (!emailStr.includes("@")) {
    return false;
  }
  if (!emailStr.split("@")[1].includes(".")) {
    return false;
  }
  return true;
}

function createUser(username, email, role = ROLE) {
  if (!validateEmailAddress(email)) {
    throw new Error("Invalid email format");
  }

  return {
    name: username,
    email,
    role,
    active: true,
    createdAt: null,
  };
}

function getUserPermissions(role) {
  if (role === "member") {
    return ["read"];
  }
  if (role === "editor") {
    return ["read", "write"];
  }
  if (role === "admin") {
    return ["read", "write", "delete", "manage"];
  }
  if (role === "superadmin") {
    return ["read", "write", "delete", "manage", "configure"];
  }
  return [];
}

function deactivateUser(userId) {
  console.log(`Deactivating user ${userId}`);
  return true;
}
