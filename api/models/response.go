package models

// Response represents a standard API response
type Response struct {
	Success bool        `json:"success"`
	Data    interface{} `json:"data,omitempty"`
	Error   *ErrorInfo  `json:"error,omitempty"`
}

// ErrorInfo represents error information
type ErrorInfo struct {
	Code    string      `json:"code"`
	Message string      `json:"message"`
	Details interface{} `json:"details,omitempty"`
}

// SuccessResponse creates a success response
func SuccessResponse(data interface{}) Response {
	return Response{
		Success: true,
		Data:    data,
	}
}

// ErrorResponse creates an error response
func ErrorResponse(code, message string) Response {
	return Response{
		Success: false,
		Error: &ErrorInfo{
			Code:    code,
			Message: message,
		},
	}
}

// ErrorResponseWithDetails creates an error response with details
func ErrorResponseWithDetails(code, message string, details interface{}) Response {
	return Response{
		Success: false,
		Error: &ErrorInfo{
			Code:    code,
			Message: message,
			Details: details,
		},
	}
}

// Common error codes
const (
	ErrInvalidToken     = "INVALID_TOKEN"
	ErrUnauthorized     = "UNAUTHORIZED"
	ErrNotFound         = "NOT_FOUND"
	ErrValidationError  = "VALIDATION_ERROR"
	ErrProviderError    = "PROVIDER_ERROR"
	ErrVPNError         = "VPN_ERROR"
	ErrInternalError    = "INTERNAL_ERROR"
	ErrBadRequest       = "BAD_REQUEST"
	ErrInvalidCredentials = "INVALID_CREDENTIALS"
)
