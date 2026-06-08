//go:build darwin

package gomobile

import libbox "github.com/sagernet/sing-box/experimental/libbox"

func GetTunnelFileDescriptor() int32 {
	return libbox.GetTunnelFileDescriptor()
}
