# Root Cause Analysis: MetalBond Deadlock Incident

**Incident Date**: Wednesday, October 30, 2025
**Resolution**: Friday, November 1, 2025 (48 hours)
**Severity**: High - Service Degradation
**Status**: Fix completed, currently testing on OSC stages
**Team**: Lead Engineering Team

---

## Executive Summary

During a planned deployment on Wednesday, October 30, 2025 (CHG01223242), the osc-peering-controller v2.2.1-a43d1c2 update triggered a software bug in the MetalBond library. This caused route inconsistencies across all MetalBond servers in each region.

**Impact**: Route distribution inconsistencies across the 4 MetalBond servers per region. Mitigation attempts caused temporary outages (1-2 minutes) for a small subset of customers with large peering configurations.

**Resolution**: The lead engineering team identified and fixed the issue within 48 hours. The fix is currently being tested on OSC stages before production deployment.

**Root Cause**: A race condition in the connection shutdown code caused peer connections to permanently freeze when handling large route tables, preventing proper route synchronization between MetalBond servers.

---

## Root Cause (In Simple Terms)

MetalBond uses persistent connections to exchange route information between servers and controllers. When networks with large route tables (hundreds or thousands of routes) were processed:

1. **The internal message queue filled up** - The system has a queue with a default capacity of 100 messages. Large route updates exceeded this capacity.

2. **Heartbeat signals got blocked** - While the system was busy processing the full queue, it couldn't receive "heartbeat" messages (keepalives) that verify the connection is alive.

3. **The system detected a timeout** - Without receiving heartbeats, the system assumed the connection failed and triggered an automatic reconnection.

4. **A timing bug caused a permanent freeze** - During the reconnection process, two threads got stuck waiting for each other: one thread was waiting for data from the network, while another was trying to close the connection. Due to poor coordination, they ended up in deadlock - waiting for each other forever.

**The Result**: The connection froze permanently. Routes could not be exchanged between systems. Each MetalBond server ended up with different route information, causing inconsistencies across the region.

**Why Now**: This bug existed before but was only exposed when processing networks with very large route tables, which filled the message queue and triggered the problematic reconnection sequence.

**The Fix**: The lead engineering team implemented a graceful shutdown mechanism that coordinates between threads:
- Added a shutdown flag that threads check before blocking operations
- Introduced a 1-second grace period to allow threads to exit cleanly before closing connections
- Added timeouts to network operations so they can't block indefinitely
- Added multiple checkpoint locations where threads verify if they should continue or exit

This ensures threads coordinate properly during shutdown, preventing the deadlock condition.

**Next Release**: The rx channel capacity will be increased to ensure keepalive messages are always processed promptly, even under high route update load, preventing the timeout condition that triggers reconnection.

---

**For detailed technical analysis, see**: `TECHNICAL_ANALYSIS_DEADLOCK.md`
**Fix Commit**: `1ed11964f2b050dd065451b7211969d38391bad3` (osc/main branch)
