package bridge

import (
	"runtime"
	"testing"
)

func TestPathHasPrefix(t *testing.T) {
	defer func(prev string) { Env.OS = prev }(Env.OS)

	cases := []struct {
		name string
		os   string
		p    string
		base string
		want bool
	}{
		// Common ancestor checks
		{"posix exact match", "linux", "/opt/app", "/opt/app", true},
		{"posix child", "linux", "/opt/app/data/sing-box/sing-box", "/opt/app", true},
		{"posix sibling prefix not nested", "linux", "/opt/app-other/bin", "/opt/app", false},
		{"posix unrelated", "linux", "/usr/bin/sing-box", "/opt/app", false},

		// Windows case-insensitive and separator normalization
		{
			name: "windows lowercased child under Program Files",
			os:   "windows",
			p:    `C:\Program Files\PrivateDeploy\PrivateDeploy\data\sing-box\sing-box.exe`,
			base: `c:\program files\privatedeploy\privatedeploy`,
			want: true,
		},
		{
			name: "windows LOCALAPPDATA match",
			os:   "windows",
			p:    `C:\Users\Administrator\AppData\Local\PrivateDeploy\data\sing-box\sing-box.exe`,
			base: `C:\Users\Administrator\AppData\Local\PrivateDeploy`,
			want: true,
		},
		{
			name: "windows sibling install not matched",
			os:   "windows",
			p:    `C:\Users\Administrator\AppData\Local\PrivateDeployOther\data\sing-box\sing-box.exe`,
			base: `C:\Users\Administrator\AppData\Local\PrivateDeploy`,
			want: false,
		},
		{
			name: "windows path outside base",
			os:   "windows",
			p:    `C:\Some\Other\Place\sing-box.exe`,
			base: `C:\Users\Administrator\AppData\Local\PrivateDeploy`,
			want: false,
		},
	}

	for _, tc := range cases {
		// pathHasPrefix branches on Env.OS, not runtime.GOOS, so Windows cases
		// are exercisable on a Linux host. Skip the negative posix-only cases
		// when running on Windows because filepath.Clean swaps separators.
		if tc.os != "windows" && runtime.GOOS == "windows" {
			continue
		}
		Env.OS = tc.os
		if got := pathHasPrefix(tc.p, tc.base); got != tc.want {
			t.Errorf("%s: pathHasPrefix(%q, %q) = %v, want %v", tc.name, tc.p, tc.base, got, tc.want)
		}
	}
}
