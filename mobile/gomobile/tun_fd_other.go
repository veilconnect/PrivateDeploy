//go:build !darwin

package gomobile

func GetTunnelFileDescriptor() int32 {
	return -1
}
