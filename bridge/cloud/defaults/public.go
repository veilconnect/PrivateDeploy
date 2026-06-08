package defaults

// PublicProviderNames is the stable list of production cloud providers that are
// exposed to product UIs and public control surfaces.
var PublicProviderNames = map[string]struct{}{
	"vultr":        {},
	"digitalocean": {},
	"ssh":          {},
}

func IsPublicProvider(name string) bool {
	_, ok := PublicProviderNames[name]
	return ok
}
