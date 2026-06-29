package models

import "time"

// Subscription represents a VPN subscription record persisted via GORM.
type Subscription struct {
	ID        uint      `json:"id" gorm:"primaryKey"`
	Name      string    `json:"name" gorm:"not null"`
	URL       string    `json:"url" gorm:"not null"`
	NodeCount int       `json:"nodeCount"`
	UpdatedAt time.Time `json:"updatedAt"`
	CreatedAt time.Time `json:"createdAt"`
}
