package cloud

import (
	"strings"

	"privatedeploy/bridge/cloud/deploy"
)

// EnsureManagedTLSDefaults backfills server-name / insecure-TLS defaults for any
// managed protocol that has a port+credential but is missing its TLS metadata.
// It returns whether the record was modified.
//
// This was historically copy-pasted byte-for-byte into every provider
// (vultr/digitalocean/catalog/ssh); it now lives here as the single source so
// the protocol defaults can't drift between providers.
func EnsureManagedTLSDefaults(record *InstanceRecord) bool {
	if record == nil {
		return false
	}

	changed := false

	if record.HysteriaPort != 0 && record.HysteriaPassword != "" {
		if strings.TrimSpace(record.HysteriaServerName) == "" {
			record.HysteriaServerName = deploy.DefaultHysteriaServerName
			changed = true
		}
		if record.HysteriaInsecure == nil {
			record.HysteriaInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.TrojanPort != 0 && record.TrojanPassword != "" {
		if strings.TrimSpace(record.TrojanServerName) == "" {
			record.TrojanServerName = deploy.DefaultTrojanServerName
			changed = true
		}
		if record.TrojanInsecure == nil {
			record.TrojanInsecure = deploy.BoolPtr(true)
			changed = true
		}
	}

	if record.VLESSPort != 0 && record.VLESSUUID != "" {
		if strings.TrimSpace(record.VLESSServerName) == "" {
			if strings.TrimSpace(record.TrojanServerName) != "" {
				record.VLESSServerName = record.TrojanServerName
			} else {
				record.VLESSServerName = deploy.DefaultVLESSServerName
			}
			changed = true
		}
	}

	return changed
}

// HasMinimumProxyConfig reports whether a record carries at least a working
// Shadowsocks configuration (the minimum for a usable node). Used to decide
// whether a record is complete or needs recovery.
func HasMinimumProxyConfig(record InstanceRecord) bool {
	if record.SSPort == 0 || record.SSPassword == "" {
		return false
	}
	// Port is a legacy mirror of SSPort; if set it must agree.
	if record.Port != 0 && record.Port != record.SSPort {
		return false
	}
	return true
}
