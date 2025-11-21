# regional reachability Detection and Response Guide

## Overview

PrivateDeploy now includes comprehensive regional reachability (regional network filtering) detection and automatic response capabilities to help you maintain stable connections even when nodes are blocked.

## Features

### 1. Connectivity Auto-Detection

After deploying a new node, PrivateDeploy automatically tests its connectivity to detect potential blocking:

- **ICMP Reachability**: Tests if the node responds to ping
- **Port Testing**: Verifies all configured protocol ports (Shadowsocks, Hysteria2, VLESS, Trojan)
- **Status Classification**:
  - 🟢 **Reachable**: All tests passed, node is fully accessible
  - 🔵 **ICMP Blocked**: ICMP blocked but ports accessible (common with some providers)
  - 🔴 **Blocked**: All connectivity tests failed, likely regional reachability blocked

### 2. Manual Connectivity Testing

You can manually test node connectivity at any time:

1. Navigate to **Cloud** page
2. Click the **"Test All Nodes"** button to test all nodes simultaneously
3. Results appear in the **Connectivity** column of the node table

### 3. Smart IP Rotation

When a node is detected as blocked, PrivateDeploy offers automatic IP rotation:

**How it works:**
1. PrivateDeploy detects the node status as "Blocked"
2. A **"Rotate IP"** button appears in the node's action column
3. Click the button to:
   - Destroy the blocked node
   - Create a new node with the same configuration (region, plan, label)
   - Automatically apply the new node to your active profile
   - Test connectivity of the new node

**Important Notes:**
- IP rotation is only available for cloud-deployed nodes (not manual nodes)
- The process takes 2-5 minutes as a new instance is provisioned
- Your VPN connection will be briefly interrupted during the rotation

### 4. Reachability Risk Rating for Regions

When selecting a deployment region, each region displays a risk indicator:

- 🟢 **Low Risk**: Generally stable, less likely to be blocked
  - Examples: Singapore (sgp), Tokyo (nrt), Seoul (icn), Taipei (tpe)
- 🟡 **Medium Risk**: Occasional blocking, moderate risk
  - Examples: Los Angeles (lax), Amsterdam (ams), Frankfurt (fra), Hong Kong (hkg)
- 🟠 **High Risk**: Frequently targeted, higher blocking rate
  - Examples: New York (ewr), Chicago (ord), Dallas (dfw), Atlanta (atl)
- 🔴 **Critical Risk**: Very unstable, highest blocking risk

**Region Selection Best Practices:**
1. Prefer 🟢 Low Risk regions for stable connections
2. Test latency to find the best balance between speed and stability
3. If a region becomes blocked, consider switching to a different region

### 5. Enhanced Node List Display

The node table now includes:

- **Connectivity Column**: Real-time connectivity status for each node
- **Status Indicators**: Visual tags showing node state (Active, Pending, Error)
- **Protocol Display**: Shows all configured protocols (SS, HY2, VLESS, Trojan)
- **IP Addresses**: Both IPv4 and IPv6 when available
- **Risk-Sorted Regions**: Regions are sorted by risk level, then by latency

## Usage Workflow

### Initial Deployment

1. **Choose a Region**
   - Look for 🟢 Low Risk regions for best stability
   - Consider latency (use "Test Latency" button)
   - Balance between proximity and reachability risk

2. **Deploy Node**
   - Click "Create & Deploy"
   - Wait 2-5 minutes for provisioning
   - Connectivity is tested automatically after deployment

3. **Monitor Status**
   - Check the Connectivity column for test results
   - Green "Reachable" status indicates the node is ready

### Handling Blocked Nodes

If a node shows "Blocked" status:

1. **Option 1: IP Rotation (Recommended)**
   - Click the "Rotate IP" button that appears
   - Confirm the rotation
   - Wait for the new node to be created (2-5 minutes)
   - New node is automatically tested and applied

2. **Option 2: Deploy to Different Region**
   - Choose a region with lower risk rating
   - Deploy a new node there
   - Destroy the blocked node

3. **Option 3: Manual Node Entry**
   - If you have a working node from another source
   - Use "Add Manual Node" to import it

### Maintenance

**Regular Testing:**
- Click "Test All Nodes" periodically to verify connectivity
- Especially useful before important events or meetings

**Proactive Monitoring:**
- Watch for nodes transitioning from "Reachable" to "ICMP Blocked"
- This may indicate gradual blocking - consider rotating IP preemptively

## Technical Details

### Connectivity Testing

**Backend Implementation** (`bridge/net.go:TestConnectivity`):
- Uses TCP connection tests (not ICMP which requires root)
- Tests port 80 for general reachability
- Tests all configured protocol ports individually
- Returns detailed status including per-port results

**Test Timing:**
- Automatic: After node creation (5-10 seconds delay)
- Manual: On-demand via "Test All Nodes" button
- Timeout: 5 seconds per port, 3 seconds for general reachability

### IP Rotation

**Implementation** (`frontend/src/stores/cloud.ts:rotateIP`):
```typescript
// Preserves node configuration
const nodeConfig = {
  label: node.label,
  region: node.region,
  plan: node.plan,
}

// Destroys old node
await destroyInstance(instanceId)

// Creates replacement with same config
const newNode = await createInstance(nodeConfig)
```

**Automatic Steps:**
1. Extract node configuration (region, plan, label)
2. Destroy the blocked instance
3. Create new instance with identical configuration
4. Wait for new IP assignment
5. Generate new proxy configurations
6. Apply to active profile
7. Test connectivity
8. Restart proxy core

### Risk Rating Data

Risk ratings are based on:
- Historical blocking patterns
- Geographic proximity to China
- ISP cooperation levels
- Community reports and feedback

**Data Structure** (`frontend/src/views/CloudView/index.vue`):
```typescript
const reachabilityRiskRating: Record<string, 'low' | 'medium' | 'high' | 'critical'> = {
  'sgp': 'low',        // Singapore
  'nrt': 'low',        // Tokyo
  'lax': 'medium',     // Los Angeles
  'ewr': 'high',       // New York
  // ... more regions
}
```

## Troubleshooting

### "Rotate IP" Button Not Appearing

**Possible Causes:**
- Node is a manual node (IP rotation not supported)
- Connectivity status is not "Blocked"
- Node hasn't been tested yet

**Solutions:**
- Click "Test All Nodes" to update connectivity status
- For manual nodes, use "Edit" to update IP manually

### IP Rotation Fails

**Common Issues:**
1. **Insufficient API Credits**: Check your cloud provider account balance
2. **Region Out of Capacity**: Try a different region
3. **API Key Expired**: Update your cloud provider API key

**Recovery:**
- The old node is already destroyed
- Manually create a new node if auto-creation failed
- Check cloud provider dashboard for error details

### Connectivity Tests Show "Unknown"

**Causes:**
- Network timeout during testing
- Firewall blocking test connections
- Node still provisioning (not fully ready)

**Solutions:**
- Wait 30 seconds and click "Test All Nodes" again
- Check your local firewall settings
- Ensure node status shows "Active" before testing

## Best Practices

1. **Regular Testing**: Test connectivity weekly, especially if experiencing connection issues

2. **Diversify Regions**: Deploy nodes to multiple low-risk regions for redundancy

3. **Monitor Trends**: If a previously stable region starts showing "ICMP Blocked" frequently, consider migrating

4. **Quick Response**: When a node shows "Blocked", rotate IP promptly to minimize downtime

5. **Backup Nodes**: Keep 1-2 spare nodes in different regions as fallback options

## API Reference

### TestConnectivity

**Go Function**: `bridge/net.go:TestConnectivity(ip string, portsJSON string)`

**Parameters:**
- `ip`: Target IP address to test
- `portsJSON`: JSON array of ports to test, e.g., "[8388, 443, 1080]"

**Returns:**
```json
{
  "ip": "1.2.3.4",
  "icmpReachable": true,
  "portsOpen": {
    "8388": true,
    "443": true,
    "1080": false
  },
  "status": "icmp_blocked"
}
```

**Status Values:**
- `reachable`: ICMP works and all ports open
- `icmp_blocked`: ICMP fails but ports accessible
- `blocked`: All tests failed
- `unknown`: Testing error occurred

### Frontend Store Methods

**testNodeConnectivity(instanceId: string)**
- Tests a single node's connectivity
- Updates node's `connectivityStatus` property
- Returns: Promise<void>

**testAllNodesConnectivity()**
- Tests all nodes in parallel
- Updates all nodes' connectivity status
- Returns: Promise<void>

**rotateIP(instanceId: string)**
- Rotates IP for a blocked node
- Destroys and recreates the node
- Returns: Promise<CloudNode> (new node)

## Future Enhancements

Potential improvements being considered:

1. **Automatic IP Rotation**: Automatically rotate IPs for blocked nodes without user intervention
2. **Blocking Prediction**: Machine learning to predict blocking risk before deployment
3. **Smart Region Recommendation**: Suggest best regions based on user location and current blocking patterns
4. **Connectivity History**: Track and visualize connectivity trends over time
5. **Multi-Node Failover**: Automatically switch to backup nodes when primary is blocked

## Support

For issues or questions:
- Check troubleshooting section above
- Review application logs for detailed error messages
- Consult cloud provider documentation for API-related issues

---

**Version**: Phase 2 Complete
**Last Updated**: 2025-11-21
**Compatibility**: PrivateDeploy v2.0+
