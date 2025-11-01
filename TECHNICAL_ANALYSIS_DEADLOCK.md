# Technical Analysis: MetalBond Deadlock Issue

## Executive Summary

A deadlock condition was discovered in the MetalBond peer connection handling code that caused clients to become permanently stuck during reconnection attempts when processing large route tables. This issue manifested in production after deploying osc-peering-controller v2.2.1-a43d1c2, resulting in inconsistent route distribution across MetalBond servers and temporary service disruptions.

## System Architecture

### OSC MetalBond Deployment
- **4 MetalBond servers per region**: One per Availability Zone (AZ1, AZ2, AZ3) + 1 floating between AZs
- **4 osc-peering-controller instances**: One per MetalBond server
- **Purpose**: High Availability (HA) route distribution for customer network peerings
- **Design principle**: As long as one MetalBond server with peering controller is operational, routes are distributed properly

### MetalBond Protocol
MetalBond is a custom routing protocol with the following characteristics:
- TCP-based persistent connections between peers
- Keepalive mechanism to detect connection failures
- VNI (Virtual Network Identifier) based route subscription model
- Separate channels for different message types (HELLO, KEEPALIVE, SUBSCRIBE, UPDATE)

## The Deadlock Scenario

### Initial Trigger
The deadlock was triggered when processing networks with large route tables (hundreds to thousands of routes) under the following conditions:

### Detailed Execution Flow

#### Phase 1: Channel Saturation
1. **Large route update arrives** from a peer with many routes
2. **rxLoop** (`peer.go:346-443`) reads packets and deserializes UPDATE messages
3. UPDATE messages are sent to the `rxUpdate` channel (buffered, capacity: 100)
4. With large route tables, this channel **fills up rapidly**

```go
// Original code - fixed capacity
p.rxUpdate = make(chan msgUpdate, 100)  // Only 100 messages!
```

5. When channel is full, rxLoop **blocks** at line 427:
```go
p.rxUpdate <- *upd  // BLOCKS here when channel is full
```

#### Phase 2: Keepalive Timeout
6. While rxLoop is blocked sending to rxUpdate channel, it **cannot process new incoming messages**
7. Incoming KEEPALIVE messages from the peer **accumulate in the TCP buffer** but are not read
8. **keepaliveLoop** (`peer.go:606-646`) doesn't receive keepalive confirmation
9. After timeout (2.5 × keepalive interval), keepaliveLoop detects timeout:
```go
case <-p.keepaliveTimer.C:
    p.log().Infof("Connection timed out. Closing.")
    go p.Reset()
```

#### Phase 3: The Deadlock
10. **Reset()** is called (`peer.go:567-604`):
```go
func (p *metalBondPeer) Reset() {
    p.setState(RETRY)
    p.txChanClose <- true
    p.shutdown <- true
    p.keepaliveStop <- true
    p.wg.Wait()  // DEADLOCK: Waits forever!
    ...
}
```

11. **The race condition occurs:**
    - Thread A (rxLoop): Still blocked in `(*p.conn).Read(buf)` at line 354
    - Thread B (Reset): Sends shutdown signal and immediately waits for all goroutines: `p.wg.Wait()`

12. **Original rxLoop code structure:**
```go
func (p *metalBondPeer) rxLoop() {
    p.wg.Add(1)
    defer p.wg.Done()

    for {
        bytesRead, err := (*p.conn).Read(buf)  // BLOCKS HERE
        if p.GetState() == CLOSED || p.GetState() == RETRY {  // Check AFTER read
            return
        }
        // ... process data
    }
}
```

13. **The deadlock:**
    - rxLoop is blocked in kernel space on the Read() syscall
    - shutdown channel signal is sent, but rxLoop can't receive it (blocked in Read)
    - Connection close happens, but Read() doesn't properly unblock due to race condition
    - rxLoop never calls `wg.Done()`
    - Reset() waits forever on `p.wg.Wait()`
    - **Client is permanently stuck**

#### Phase 4: System Impact
14. Peer connection is now **permanently stuck in RETRY state**
15. Routes from this peer are **never announced** to the MetalBond server
16. Route table becomes **inconsistent across MetalBond servers**
17. Restarting peering controllers doesn't help (deadlock reproduces)
18. Restarting MetalBond servers causes **temporary outage** (1-2 minutes) for affected peerings

## Root Cause Analysis - Technical Details

### Primary Root Cause
**Blocking I/O operation prevents graceful shutdown coordination**

The rxLoop goroutine uses a blocking `Read()` call without:
- Read timeout
- Ability to be interrupted
- State checking before blocking
- Proper shutdown coordination

### Contributing Factors

#### 1. Default Channel Capacity Too Small
```go
p.rxUpdate = make(chan msgUpdate, p.rxChanDataUpdateCapacity)
// Where p.rxChanDataUpdateCapacity defaults to 100
```
- Default capacity of 100 messages insufficient for large route tables
- Although configurable, the default was not tuned for production workloads with thousands of routes

#### 2. No Read Timeout
```go
bytesRead, err := (*p.conn).Read(buf)  // Can block indefinitely
```
- No `SetReadDeadline()` configured
- Blocking syscall cannot be interrupted by Go runtime

#### 3. State Check After Blocking Operation
```go
bytesRead, err := (*p.conn).Read(buf)
if p.GetState() == CLOSED || p.GetState() == RETRY {  // Too late!
    return
}
```
- State is checked only after Read() returns
- If connection is being closed during Read(), state check is ineffective

#### 4. No Graceful Shutdown Mechanism
- No flag or signal that rxLoop can check while blocked
- Immediate connection close without coordination
- No grace period for goroutines to exit

#### 5. Single-Buffer Read Pattern
```go
buf := make([]byte, 65535)
// Read directly into fixed buffer, process immediately
bytesRead, err := (*p.conn).Read(buf)
```
- No packet buffering
- Can't continue processing partial packets while handling backpressure

## The Fix - Detailed Implementation

### 1. Graceful Shutdown Flag
```go
type metalBondPeer struct {
    // ... existing fields
    stopRxLoop bool  // NEW: Explicit stop signal
}
```

### 2. Coordinated Shutdown with Grace Period

**In Close() method:**
```go
func (p *metalBondPeer) Close() {
    if p.GetState() != CLOSED {
        p.stopRxLoop = true              // Signal first
        time.Sleep(1 * time.Second)       // Grace period
        err := (*p.conn).Close()          // Close after
        // ...
    }
}
```

**In Reset() method:**
```go
func (p *metalBondPeer) Reset() {
    p.mtxReset.Lock()
    p.stopRxLoop = true                   // Signal first
    time.Sleep(1 * time.Second)           // Grace period
    if p.conn != nil {
        (*p.conn).Close()                 // Close after
    }
    p.mtxReset.Unlock()
    // ... rest of reset logic
}
```

### 3. Read Timeout
```go
readTimeout := time.Duration(p.keepaliveInterval) * time.Second * 5 * 2
(*p.conn).SetReadDeadline(time.Now().Add(readTimeout))
```
- Prevents indefinite blocking
- Allows periodic checking of shutdown conditions

### 4. Multiple Exit Points in rxLoop
```go
func (p *metalBondPeer) rxLoop() {
    for {
        if p.stopRxLoop {  // Check BEFORE blocking
            return
        }

        // ... state checks

        bytesRead, err := (*p.conn).Read(buf)

        for {  // Packet processing loop
            if p.stopRxLoop {  // Check during processing
                return
            }
            // ... process packets
        }
    }
}
```

### 5. Packet Buffering
```go
var pktBuf []byte  // Accumulation buffer

for {
    // Read into temp buffer
    bytesRead, err := (*p.conn).Read(buf)

    // Append to packet buffer
    pktBuf = append(pktBuf, buf[:bytesRead]...)

    // Process all complete packets
    for {
        if len(pktBuf) < 4 {  // Not enough for header
            break
        }
        // Extract and process complete packets
        // Can check stopRxLoop between packets
    }
}
```

### 6. Broadcast Shutdown Pattern
```go
done := make(chan struct{})
go func() {
    <-p.shutdown
    close(done)  // Closing broadcasts to ALL select statements
}()

// All loops now use:
select {
case <-done:  // Instead of <-p.shutdown
    // cleanup and return
}
```

### 7. Enhanced Logging and Cleanup
```go
defer func() {
    p.log().Infof("rxLoop done")
    p.stopRxLoop = false  // Reset flag
    p.wg.Done()
}()
```

**Note on Channel Capacities**: The system already had configurable channel capacities (`txChanCapacity`, `rxChanEventCapacity`, `rxChanDataUpdateCapacity`), but the default of 100 for `rxChanDataUpdateCapacity` was insufficient for large route tables. While not changed in this fix, operators can increase these values to prevent channel saturation

## Why The Fix Works

### Shutdown Sequence (Fixed Version)
1. **Signal**: `stopRxLoop = true` sets flag in shared memory
2. **Grace Period**: `time.Sleep(1 * time.Second)` allows goroutines to:
   - Complete current operations
   - Check stopRxLoop flag
   - Exit their loops gracefully
   - Call `wg.Done()`
3. **Close**: Connection is closed only after grace period
4. **Read Timeout**: If Read() was blocked, timeout ensures it returns within bounded time
5. **Multiple Exit Points**: stopRxLoop is checked in multiple locations, ensuring detection
6. **Clean Exit**: All goroutines exit cleanly, `wg.Wait()` returns normally

### Comparison: Before vs After

| Aspect | Before (Deadlock) | After (Fixed) |
|--------|------------------|---------------|
| Read Timeout | None (indefinite) | 2.5 × keepalive interval |
| Shutdown Signal | Channel only | Channel + stopRxLoop flag |
| Exit Check Points | 1 (after Read) | 3+ (before/during/after) |
| Grace Period | None | 1 second |
| Buffer Strategy | Single-shot read | Packet accumulation |
| Shutdown Coordination | Immediate close | Flag + grace period + close |
| State Checks | After blocking | Before and after |

## Testing

### New Test Case
A comprehensive stress test was added in `peer_test.go`:

```go
It("metalbond timeout with deadlock", func() {
    totalClients := 100
    var wg sync.WaitGroup

    for i := 1; i <= totalClients; i++ {
        wg.Add(1)
        go func(index int) {
            // Create client and establish connection
            // Fill up txChan by sending many updates
            // Stop keepalives to trigger timeout
            // Wait 60 seconds
            // Verify peer state is ESTABLISHED (no deadlock)
        }(i)
    }
    wg.Wait()
})
```

This test:
- Simulates 100 concurrent clients
- Floods update channels
- Stops keepalive responses
- Verifies no deadlock occurs during reconnection

## Additional Improvements in the Fix

### 1. TargetVNI Handling (`cmd/cmd.go`)
```go
targetVNI := uint32(0)
if len(parts) > 3 {
    if vni, err := strconv.ParseUint(parts[3], 10, 32); err == nil {
        targetVNI = uint32(vni)
    } else {
        routeType = pb.ConvertCmdLineStrToEnumValue(parts[3])
    }
}
```
Allows specifying target VNI in route announcements for better routing control.

### 2. Health Check Endpoint (`http.go`)
```go
http.HandleFunc("/health", js.healthHandler)

func (j *jsonServer) healthHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(200)
    fmt.Fprint(w, "OK")
}
```
Enables proper health monitoring in Kubernetes/container environments.

### 3. Enhanced Logging
```go
defer func() {
    p.log().Infof("rxLoop done")
    p.stopRxLoop = false
    p.wg.Done()
}()
```
Helps track goroutine lifecycle for debugging.

## Performance Implications

### Resource Usage
- **Memory**: Packet buffering requires additional memory per peer (up to 65KB)
- **CPU**: Multiple stopRxLoop checks add negligible CPU overhead
- **Latency**: 1-second grace period during shutdown is acceptable for reconnection scenarios

### Scalability
- Configurable channel capacities allow tuning for large route tables
- Read timeouts prevent resource leaks from stuck connections
- Proper cleanup ensures resources are released

## Lessons Learned

1. **Blocking I/O requires timeout protection**: Network operations must always have timeouts
2. **Graceful shutdown needs coordination**: Flags + grace periods work better than immediate forceful shutdown
3. **Channel capacities must match workload**: Fixed small capacities fail under load
4. **State checks before blocking operations**: Check conditions before entering blocking calls
5. **Multiple exit points for robustness**: Check shutdown conditions frequently
6. **Testing must simulate production load**: Stress tests with large data volumes are essential

## References

- Commit: `1ed11964f2b050dd065451b7211969d38391bad3`
- Branch: `osc/main`
- Files affected:
  - `peer.go` (primary fix)
  - `peer_test.go` (stress test)
  - `cmd/cmd.go` (targetVNI support)
  - `http.go` (health check)
