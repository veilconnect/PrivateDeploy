package cloud

import (
	"context"
	"errors"
	"fmt"
	"sync"
)

// Registry manages all registered cloud providers
type Registry struct {
	mu        sync.RWMutex
	providers map[string]CloudProvider
}

// NewRegistry constructs an empty provider registry.
func NewRegistry() *Registry {
	return &Registry{
		providers: make(map[string]CloudProvider),
	}
}

// Register adds a provider to the registry
func (r *Registry) Register(name string, provider CloudProvider) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.providers[name] = provider
}

// Get retrieves a provider by name
func (r *Registry) Get(name string) (CloudProvider, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	provider, ok := r.providers[name]
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrProviderNotFound, name)
	}
	return provider, nil
}

// List returns all registered provider names
func (r *Registry) List() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()

	names := make([]string, 0, len(r.providers))
	for name := range r.providers {
		names = append(names, name)
	}
	return names
}

// Has checks if a provider is registered
func (r *Registry) Has(name string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.providers[name]
	return ok
}

// Manager provides a unified interface for managing multiple cloud providers
type Manager struct {
	mu             sync.RWMutex // protects activeProvider
	registry       *Registry
	activeProvider string
	ctx            context.Context
}

// NewManager creates a new cloud provider manager
func NewManager(ctx context.Context, registry *Registry) *Manager {
	if registry == nil {
		registry = NewRegistry()
	}
	return &Manager{
		registry: registry,
		ctx:      ctx,
	}
}

// RegisterProvider adds a provider to the underlying registry.
func (m *Manager) RegisterProvider(name string, provider CloudProvider) {
	if m.registry == nil {
		m.registry = NewRegistry()
	}
	m.registry.Register(name, provider)
}

// SetActiveProvider sets the active cloud provider
func (m *Manager) SetActiveProvider(name string) error {
	if !m.registry.Has(name) {
		return fmt.Errorf("%w: %s", ErrProviderNotRegistered, name)
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.activeProvider = name
	return nil
}

// GetActiveProvider returns the currently active provider
func (m *Manager) GetActiveProvider() (CloudProvider, error) {
	m.mu.RLock()
	activeProviderName := m.activeProvider
	m.mu.RUnlock()

	if activeProviderName == "" {
		return nil, errors.New("no active provider set")
	}
	return m.registry.Get(activeProviderName)
}

// GetProvider retrieves a specific provider by name
func (m *Manager) GetProvider(name string) (CloudProvider, error) {
	return m.registry.Get(name)
}

// ListProviders returns all available provider names
func (m *Manager) ListProviders() []string {
	if m.registry == nil {
		return nil
	}
	return m.registry.List()
}

// ListRegions returns regions from the active provider
func (m *Manager) ListRegions() ([]Region, error) {
	provider, err := m.GetActiveProvider()
	if err != nil {
		return nil, err
	}
	return provider.ListRegions(m.ctx)
}

// ListPlans returns plans from the active provider
func (m *Manager) ListPlans(region string) ([]Plan, error) {
	provider, err := m.GetActiveProvider()
	if err != nil {
		return nil, err
	}
	return provider.ListPlans(m.ctx, region)
}

// ListInstances returns instances from the active provider
func (m *Manager) ListInstances() ([]Instance, error) {
	provider, err := m.GetActiveProvider()
	if err != nil {
		return nil, err
	}
	return provider.ListInstances(m.ctx)
}

// CreateInstance creates a new instance using the active provider
func (m *Manager) CreateInstance(opts *CreateInstanceOptions) (*Instance, error) {
	provider, err := m.GetActiveProvider()
	if err != nil {
		return nil, err
	}
	return provider.CreateInstance(m.ctx, opts)
}

// DestroyInstance destroys an instance using the active provider
func (m *Manager) DestroyInstance(instanceID string) error {
	provider, err := m.GetActiveProvider()
	if err != nil {
		return err
	}
	return provider.DestroyInstance(m.ctx, instanceID)
}
