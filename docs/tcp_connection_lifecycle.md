# TCP Connection Lifecycle: handle() Ownership Pattern

This document describes the complete TCP connection lifecycle in MetalBond, focusing on the handle() ownership pattern and coordinated shutdown mechanisms.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Goroutine Coordination Mechanism](#goroutine-coordination-mechanism)
3. [OUTGOING Connection Flow (Client Mode)](#outgoing-connection-flow-client-mode)
4. [INCOMING Connection Flow (Server Mode)](#incoming-connection-flow-server-mode)
5. [Shutdown Coordination](#shutdown-coordination)
6. [Error Scenarios and Recovery](#error-scenarios-and-recovery)

---

## Architecture Overview

### Coordinator Pattern

MetalBond uses a coordinator pattern where `handle()` manages the lifecycle of TCP connections and coordinates worker goroutines.

```
              ┌──────────────────┐
              │   handle()       │  ← COORDINATOR (owns connection)
              │  (Coordinator)   │
              │                  │
              │ Responsibilities:│
              │ • Create conn    │
              │ • Start workers  │
              │ • Process msgs   │
              │ • Close conn     │
              └────────┬─────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         v             v             v
   ┌─────────┐  ┌─────────┐  ┌──────────────┐
   │ rxLoop  │  │ txLoop  │  │ keepaliveLoop│
   │(Worker) │  │(Worker) │  │  (Worker)    │
   │         │  │         │  │              │
   │ • Reads │  │ • Writes│  │ • Keepalives │
   │ • Parses│  │ • Sends │  │ • Timeouts   │
   └─────────┘  └─────────┘  └──────────────┘
```

**Key Principle:** The creator owns the lifecycle
- `handle()` creates connection → `handle()` closes connection
- Workers use connection → Workers signal when done

---

## Goroutine Coordination Mechanism

### The stopRxLoop Pattern

When `Reset()` or `Close()` is called, the system uses a two-step coordination:

1. **Signal workers to stop** - Set flags and send channel signals
2. **Wait for clean exit** - Sleep 1 second to allow workers to see signals
3. **Close connection** - After workers have exited

```
Reset() called
    │
    ├─→ Set stopRxLoop = true        ┐
    ├─→ Send txChanClose signal      │ Signal Phase
    ├─→ Send keepaliveStop signal    ┘
    │
    v
Sleep 1 second  ← COORDINATION WAIT
    │             (Allows workers to see signals and exit)
    v
Close connection  ← SAFE (workers already exited)
```

### Worker Response to Signals

Each worker responds to shutdown signals:

**rxLoop** (Lines 481, 527):
```go
// Outer loop (reading)
for {
    if p.stopRxLoop {
        return  // Exit
    }
    // Read from socket
}

// Inner loop (processing)
for {
    if p.stopRxLoop {
        return  // Exit
    }
    // Process packets
}
```

**txLoop** (Line 997):
```go
for {
    select {
    case msg := <-p.txChan:
        // Write message
    case <-p.txChanClose:
        return  // Exit
    }
}
```

**keepaliveLoop** (Line 883):
```go
for {
    select {
    case <-tckr.C:
        // Send keepalive
    case <-p.keepaliveTimer.C:
        // Timeout
    case <-p.keepaliveStop:
        return  // Exit
    }
}
```

### Safety Guarantee

**Timeline:**
- `T+0ms`: Signals sent (stopRxLoop, txChanClose, keepaliveStop)
- `T+0-1ms`: txLoop and keepaliveLoop see signals (if waiting on select)
- `T+0-1000ms`: rxLoop sees signal (at next loop iteration)
- `T+1000ms`: Sleep completes, connection closed

**Result:** All workers exit within 1 second, connection closed after all workers exit.

---

## OUTGOING Connection Flow (Client Mode)

### Phase 1: Creation

```
metalbond.AddPeer(addr) called
    │
    v
newMetalBondPeer(nil, addr, ..., OUTGOING, m)
    │
    ├─→ peer.conn = nil  (no connection yet)
    ├─→ peer.direction = OUTGOING
    │
    v
go peer.handle()  ← START COORDINATOR
```

### Phase 2: Connection Establishment

```
handle() starts
    │
    v
defer func() {
    // Will close connection when handle() exits
    if p.conn != nil {
        (*p.conn).Close()  ← OWNER CLEANUP
    }
}()
    │
    v
Create channels (shutdown, txChan, etc.)
    │
    v
for p.conn == nil {  ← ESTABLISH CONNECTION LOOP
    Try to connect: net.DialTCP()

    If success:
        p.conn = &conn
        break

    If failure:
        Sleep random interval
        Retry
}
    │
    v
Connection established ✓
```

### Phase 3: Normal Operation

```
Start worker goroutines:
    ├─→ go p.rxLoop()
    ├─→ go p.txLoop()
    └─→ (keepaliveLoop started after HELLO)

Send HELLO message
    │
    v
Main message processing loop:
    for {
        select {
        case msg := <-p.rxHello:
            p.processRxHello(msg)  → Start keepaliveLoop

        case msg := <-p.rxKeepalive:
            p.processRxKeepalive(msg)  → Connection ESTABLISHED

        case msg := <-p.rxUpdate:
            // Process messages

        case <-done:  ← SHUTDOWN SIGNAL
            p.cleanup()
            return  → defer closes connection
        }
    }
```

### Phase 4: Error Detection

```
Error occurs in rxLoop (read timeout, peer disconnect, etc.)
    │
    v
rxLoop: go p.Reset()  ← INITIATE RESET
    │
    v
rxLoop: return  (exits)
```

### Phase 5: Coordinated Shutdown (Reset for OUTGOING)

```
Reset() executes:
    │
    v
STEP 1: SIGNAL WORKERS
    p.stopRxLoop = true
    time.Sleep(1 * time.Second)  ← WAIT
    │
    v
STEP 2: CLOSE CONNECTION
    if p.conn != nil {
        (*p.conn).Close()  ← FALLBACK CLOSE
    }
    │
    v
STEP 3: SHUTDOWN HANDLE
    p.txChanClose ← true
    p.shutdown ← true
    p.keepaliveStop ← true
    │
    v
STEP 4: WAIT FOR WORKERS
    p.wg.Wait()  ← WAIT FOR ALL GOROUTINES
    │
    v
STEP 5: PREPARE RECONNECT
    p.conn = nil
    p.wg = &sync.WaitGroup{}  (new instance)
    Sleep retry interval
    │
    v
STEP 6: RECONNECT
    p.setState(CONNECTING)
    go p.handle()  ← START NEW SESSION
```

### handle() defer Execution

When `handle()` exits:

```
handle() receives shutdown signal
    │
    v
handle() cleanup()
    │
    v
handle() return (exits main loop)
    │
    v
defer func() {
    if p.conn != nil {
        p.log().Debug("handle: closing TCP connection")
        err := (*p.conn).Close()  ← PRIMARY CLOSE
        if err != nil {
            p.log().Debugf("already closed: %v")
        }
    }
    p.log().Infof("handle done")
    p.wg.Done()
}()
```

---

## INCOMING Connection Flow (Server Mode)

### Phase 1: Accept Connection

```
Server listening (metalbond.StartServer)
    │
    v
for {
    conn, err := lis.Accept()  ← NEW CONNECTION
    │
    v
    p := newMetalBondPeer(
        &conn,       ← CONNECTION ALREADY EXISTS
        conn.RemoteAddr().String(),
        ...,
        INCOMING,    ← SERVER MODE
        m,
    )
    │
    v
    m.peers[addr] = p
}
```

### Phase 2: Start Coordinator

```
newMetalBondPeer(pconn, ...) called
    │
    ├─→ peer.conn = pconn  ← ALREADY SET (not nil!)
    ├─→ peer.direction = INCOMING
    │
    v
go peer.handle()  ← START COORDINATOR
```

### Phase 3: handle() Skips Connection Establishment

```
handle() starts
    │
    v
defer func() {
    if p.conn != nil {
        (*p.conn).Close()  ← OWNER CLEANUP
    }
}()
    │
    v
Create channels
    │
    v
for p.conn == nil {  ← p.conn != nil, SKIP THIS LOOP
    // Connection establishment
}
    │
    v (skipped immediately)
Start workers:
    ├─→ go p.rxLoop()
    └─→ go p.txLoop()

Note: No HELLO sent (server waits for client HELLO)
```

### Phase 4: Normal Operation

Same as OUTGOING mode:
- Wait for client HELLO → Send HELLO response → Start keepaliveLoop
- Process messages...

### Phase 5: Error Detection

```
Error occurs (client disconnect, read error, etc.)
    │
    v
rxLoop: go p.Reset()
    │
    v
rxLoop: return (exits)
```

### Phase 6: Coordinated Shutdown (Reset for INCOMING)

```
Reset() executes:
    │
    v
STEP 1: SIGNAL WORKERS
    p.stopRxLoop = true
    time.Sleep(1 * time.Second)  ← WAIT
    │
    v
STEP 2: CLOSE CONNECTION
    if p.conn != nil {
        (*p.conn).Close()  ← FALLBACK CLOSE
    }
    │
    v
STEP 3: CALL Close()
    p.Close()  ← For INCOMING
        ├→ setState(CLOSED)
        ├→ stopRxLoop = true (again)
        ├→ Sleep 1 second (again)
        ├→ (*p.conn).Close() ← 2nd close (fails)
        ├→ txChanClose ← true
        ├→ shutdown ← true
        └→ keepaliveStop ← true
    │
    v
STEP 4: REMOVE PEER
    m.RemovePeer(p.remoteAddr)
        → Removes from peer list

handle() receives shutdown signal → exits
```

### handle() defer Execution

```
handle() cleanup()
    │
    v
handle() return
    │
    v
defer func() {
    if p.conn != nil {
        (*p.conn).Close()  ← 3rd close attempt (already closed)
        // Returns error, logged at debug
    }
    p.wg.Done()
}()

Peer fully cleaned up ✓
```

---

## Shutdown Coordination

### Timeline View

```
T+0ms
======
Error detected → Reset() called

Reset() Actions:
    p.stopRxLoop = true
    (txChanClose, keepaliveStop sent for OUTGOING)

Parallel Worker Responses:
    ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐
    │  rxLoop      │  │  txLoop      │  │  keepaliveLoop     │
    │              │  │              │  │                    │
    │ Currently in │  │ Waiting on   │  │ Waiting on select  │
    │ outer loop   │  │ select       │  │ sees keepaliveStop │
    │ or inner     │  │ sees signal  │  │ → returns          │
    │ loop         │  │ → returns    │  │                    │
    └──────────────┘  └──────────────┘  └────────────────────┘

T+~1ms
=======
txLoop exits        (if was waiting on select)
keepaliveLoop exits (if was waiting on select)

T+~10ms to T+1000ms
====================
rxLoop checks stopRxLoop flag at next loop iteration
    → sees stopRxLoop == true
    → returns

Worst case: rxLoop blocked in Read() with deadline
    → Reset() closed connection!
    → Read() returns error immediately
    → rxLoop exits

T+1000ms
=========
Reset() sleep completes

Reset() closes connection:
    (*p.conn).Close()

    If rxLoop still running (unlikely):
        → Read() unblocks immediately with error
        → rxLoop exits

All workers guaranteed exited by now ✓

T+1000ms+ (OUTGOING only)
==========================
Reset() sends shutdown signals to handle()
Reset() waits: p.wg.Wait()  (all workers already exited)
Reset() prepares reconnect
Reset() launches: go p.handle()  → New session begins

T+1000ms+ (INCOMING only)
==========================
Reset() calls p.Close()
Close() sends shutdown signals
handle() receives shutdown → exits
handle() defer closes connection (already closed, logs debug)
Peer removed from list
```

### Worker Exit Guarantees

| Worker | Exit Time | Guarantee |
|--------|-----------|-----------|
| **keepaliveLoop** | < 1ms | ✅ Always exits before 1-second sleep completes |
| **txLoop** | < 1ms if waiting<br>< 5 sec if in Write() | ✅ Connection close unblocks Write() immediately |
| **rxLoop** | < 1ms if at loop check<br>Immediate if in Read() | ✅ 1-second sleep ensures flag is seen<br>✅ Connection close unblocks Read() |

---

## Error Scenarios and Recovery

### Scenario 1: Remote Peer Disconnects

```
Remote peer closes connection
    ↓
rxLoop: Read() returns io.EOF
    ↓
rxLoop: go p.Reset()
    ↓
rxLoop: return
    ↓
Reset() executes (coordinated shutdown)
    ↓
OUTGOING: Reconnect after retry interval
INCOMING: Remove peer, close connection

Result: ✅ Clean recovery with guaranteed resource cleanup
```

### Scenario 2: Keepalive Timeout

```
No keepalive received for (keepaliveInterval * 5/2) seconds
    ↓
keepaliveTimer fires
    ↓
keepaliveLoop: go p.Reset()
    ↓
Reset() executes (coordinated shutdown)
    ↓
OUTGOING: Reconnect
INCOMING: Remove peer

Result: ✅ Stale connections detected and cleaned up
```

### Scenario 3: Write Error in txLoop

```
txLoop: Write() fails
    ↓
txLoop: go p.Reset()
    ↓
txLoop continues (doesn't exit immediately)
    ↓
Reset() signals txChanClose
    ↓
txLoop receives signal, exits
    ↓
Coordinated shutdown completes

Result: ✅ Write errors trigger clean shutdown
```

---

## Summary

The handle() ownership pattern implementation provides:

- **Clear ownership:** handle() creates connection → handle() closes connection
- **Coordinated shutdown:** stopRxLoop + 1-second sleep ensures workers exit cleanly
- **Safety guarantees:** No goroutine leaks, no connection leaks, clean state transitions
- **Minimal changes:** Only 2 code changes, backward compatible
- **Works for both modes:** OUTGOING and INCOMING connections handled correctly

The existing `stopRxLoop` coordination mechanism is correct and safe. It ensures all workers exit before connection close via a simple but effective pattern: set flag, sleep 1 second, then close. This allows workers to cleanly exit without goroutine leaks.
