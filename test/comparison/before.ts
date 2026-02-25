// User management module.

type Role = "viewer" | "editor" | "admin";

type User = {
  name: string;
  email: string;
  role: Role;
  active: boolean;
};

const MAX_USERS: number = 100;
const DEFAULT_ROLE: Role = "viewer";

function validateEmail(email: string): boolean {
  if (!email.includes("@")) {
    return false;
  }
  if (!email.split("@")[1].includes(".")) {
    return false;
  }
  return true;
}

function createUser(name: string, email: string, role: Role = DEFAULT_ROLE): User {
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

function getUserPermissions(role: Role): string[] {
  if (role === "viewer") {
    return ["read"];
  }
  if (role === "editor") {
    return ["read", "write"];
  }
  return ["read", "write", "delete", "manage"];
}

function deleteUser(userId: number): boolean {
  console.log(`Deleting user ${userId}`);
  return true;
}

function formatUserDisplay(user: User): string {
  return `${user.name} <${user.email}>`;
}
