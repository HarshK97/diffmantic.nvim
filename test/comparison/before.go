package main

import "fmt"

type User struct {
	Name   string
	Email  string
	Role   string
	Active bool
}

const MAX_USERS = 100
const DEFAULT_ROLE = "viewer"

func validateEmail(email string) bool {
	if len(email) == 0 {
		return false
	}
	return true
}

func createUser(name string, email string, role string) User {
	if role == "" {
		role = DEFAULT_ROLE
	}
	if !validateEmail(email) {
		panic("invalid email")
	}
	return User{Name: name, Email: email, Role: role, Active: true}
}

func getUserPermissions(role string) []string {
	if role == "viewer" {
		return []string{"read"}
	}
	if role == "editor" {
		return []string{"read", "write"}
	}
	if role == "admin" {
		return []string{"read", "write", "delete", "manage"}
	}
	return []string{}
}

func deleteUser(userID int) bool {
	fmt.Printf("Deleting user %d\n", userID)
	return true
}

func formatUserDisplay(user User) string {
	return fmt.Sprintf("%s <%s>", user.Name, user.Email)
}
