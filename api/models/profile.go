package models

import "time"

// Profile represents a VPN configuration profile persisted via GORM.
type Profile struct {
	ID              uint       `json:"id" gorm:"primaryKey"`
	Name            string     `json:"name" gorm:"not null"`
	Type            string     `json:"type"` // local, remote
	Config          string     `json:"config" gorm:"type:text"`
	SubscriptionURL string     `json:"subscriptionUrl,omitempty" gorm:"column:subscription_url"`
	Active          bool       `json:"active"`
	LastUpdated     *time.Time `json:"lastUpdated,omitempty" gorm:"column:last_updated"`
	CreatedAt       time.Time  `json:"createdAt"`
	UpdatedAt       time.Time  `json:"updatedAt"`
}
