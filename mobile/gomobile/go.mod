module github.com/privatedeploy/mobile

go 1.21

require (
	github.com/sagernet/sing-box v1.8.0
	golang.org/x/mobile v0.0.0-20231127183840-76ac6878050a
)

// Local development
replace github.com/privatedeploy/mobile => ./
