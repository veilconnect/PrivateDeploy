// Package defaults provides the standard production provider registry.
// It lives in a separate package to avoid a circular import between
// bridge/cloud and the individual provider packages.
package defaults

import (
	"privatedeploy/bridge/cloud"
	"privatedeploy/bridge/cloud/providers/digitalocean"
	sshprovider "privatedeploy/bridge/cloud/providers/ssh"
	"privatedeploy/bridge/cloud/providers/vultr"
)

// Registry creates a registry with all production providers pre-registered.
func Registry() *cloud.Registry {
	registry := cloud.NewRegistry()
	registry.Register("vultr", vultr.New(nil))
	registry.Register("digitalocean", digitalocean.New(nil))
	registry.Register("ssh", sshprovider.New(nil))
	return registry
}
