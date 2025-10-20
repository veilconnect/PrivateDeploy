package cloud

import "errors"

// Common errors
var (
	ErrProviderNotFound     = errors.New("cloud provider not found")
	ErrProviderNotRegistered = errors.New("cloud provider not registered")
	ErrInvalidConfig        = errors.New("invalid provider configuration")
	ErrMissingAPIKey        = errors.New("missing API key")
	ErrInvalidAPIKey        = errors.New("invalid API key")
	ErrInstanceNotFound     = errors.New("instance not found")
	ErrRegionNotFound       = errors.New("region not found")
	ErrPlanNotFound         = errors.New("plan not found")
	ErrCreateFailed         = errors.New("failed to create instance")
	ErrDestroyFailed        = errors.New("failed to destroy instance")
	ErrAPIRequestFailed     = errors.New("API request failed")
	ErrTimeout              = errors.New("operation timed out")
)
