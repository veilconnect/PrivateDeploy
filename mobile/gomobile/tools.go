//go:build tools

package gomobile

import (
	// Keep the bind package in the module graph so gomobile bind remains reproducible.
	_ "golang.org/x/mobile/bind"
)
