// User management module.

type Role = "viewer" | "editor" | "admin" | "superadmin";

type User = {
  name: string;
  email: string;
  role: Role;
  active: boolean;
  createdAt: string | null;
};

const MAX_USERS: number = 500;
const ROLE: Role = "viewer";

function formatUserDisplay(user: User): string {
  const result = `${user.name} <${user.email}>`;
  return result;
}

function validateEmailAddress(emailStr: string): boolean {
  if (!emailStr.includes("@")) {
    return false;
  }
  if (!emailStr.split("@")[1].includes(".")) {
    return false;
  }
  return true;
}

function createUser(username: string, email: string, role: Role = ROLE): User {
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

function getUserPermissions(role: Role): string[] {
  if (role === "member") {
    return ["read"];
  }
  if (role === "editor") {
    return ["read", "write"];
  }
  if (role === "admin") {
    return ["read", "write", "delete", "manage"];
  }
  return ["read", "write", "delete", "manage", "configure"];
}

function deactivateUser(userId: number): boolean {
  console.log(`Deactivating user ${userId}`);
  return true;
}
