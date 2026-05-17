//go:build !windows

package main

func handleInstallerQuitRequest(_ []string) bool {
	return false
}
