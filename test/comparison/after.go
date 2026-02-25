package main

import "fmt"

type User struct {
	Name      string
	Email     string
	Role      string
	Active    bool
	CreatedAt *string
}

const MAX_USERS = 500
const ROLE = "viewer"

func formatUserDisplay(user User) string {
	result := fmt.Sprintf("%s <%s>", user.Name, user.Email)
	return result
}

func validateEmailAddress(emailStr string) bool {
	if len(emailStr) == 0 {
		return false
	}
	return true
}

func createUser(username string, email string, role string) User {
	if role == "" {
		role = ROLE
	}
	if !validateEmailAddress(email) {
		panic("invalid email")
	}
	return User{Name: username, Email: email, Role: role, Active: true, CreatedAt: nil}
}

func getUserPermissions(role string) []string {
	if role == "member" {
		return []string{"read"}
	}
	if role == "editor" {
		return []string{"read", "write"}
	}
	if role == "admin" {
		return []string{"read", "write", "delete", "manage"}
	}
	if role == "superadmin" {
		return []string{"read", "write", "delete", "manage", "configure"}
	}
	return []string{}
}

func deactivateUser(userID int) bool {
	fmt.Printf("Deactivating user %d\n", userID)
	return true
}
