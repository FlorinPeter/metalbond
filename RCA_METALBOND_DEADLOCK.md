# Root Cause Analysis: MetalBond Deadlock Incident

**Incident Date**: Wednesday, October 30, 2025
**Resolution**: Friday, November 1, 2025 (48 hours)
**Severity**: High - Service Degradation
**Status**: Fix completed, currently testing on OSC stages
**Team**: Lead Engineering Team

---

## Executive Summary

During a planned maintenance window on Wednesday, October 30, 2025 (CHG01223242), the deployment of osc-peering-controller v2.2.1-a43d1c2 triggered a software bug in the MetalBond library. This caused route inconsistencies across MetalBond servers in all availability zones.

**Impact**: Route distribution inconsistencies; temporary outages (1-2 minutes) for a small subset of customers with large peering configurations during mitigation attempts.

**Resolution**: Lead engineering team identified and fixed the issue within 48 hours. The fix is currently being tested on OSC stages before production deployment.

**Root Cause**: A race condition in the connection shutdown code caused peer connections to freeze permanently when handling large route tables, preventing proper route synchronization.

---

## What Happened

### Timeline

**Wednesday, October 30, 2025**
- **Morning**: Planned deployment of osc-peering-controller v2.2.1-a43d1c2 started (CHG01223242)
- **Post-deployment**: Monitoring detected different route counts across the 4 MetalBond servers per region
- **Initial mitigation**: Restarted all peering controllers → Issue persisted
- **Second mitigation**: Restarted MetalBond servers one-by-one → Caused 1-2 minute outages for small subset of customers
- **Escalation**: Lead engineering team engaged for root cause analysis

**Thursday - Friday, October 31 - November 1, 2025**
- **Thursday**: Deep code analysis identified race condition in connection handling
- **Thursday evening**: Fix implemented and committed to osc/main branch
- **Friday**: Testing initiated on OSC stages

### System Context

- **4 MetalBond servers per region**: AZ1, AZ2, AZ3 + 1 floating
- **4 peering controllers**: One per MetalBond server
- **Purpose**: Distribute customer network routing information across availability zones for high availability

---

## Root Cause (In Simple Terms)

MetalBond maintains persistent connections between servers and controllers to exchange route information. When a large number of routes needs to be processed:

1. **The internal message queue filled up** (default capacity: 100 messages)
2. **While processing routes, the system couldn't receive "heartbeat" signals** (keepalive messages)
3. **The system thought the connection failed** and triggered an automatic reconnect
4. **During reconnect, a timing bug caused the connection to freeze forever**

**The Bug**: When closing a connection, the code didn't properly coordinate shutdown between different threads. One thread was stuck waiting for data from the network, while another thread tried to close the connection. Due to poor timing, they got stuck waiting for each other forever (deadlock).

**Why It Happened Now**: Networks with large route tables (hundreds/thousands of routes) filled the message queue, triggering the reconnection sequence that exposed this bug.

---

## Technical Root Cause

**Location**: `peer.go` - peer connection handling
**Issue**: Race condition during connection shutdown

**Sequence**:
1. Large route updates fill the `rxUpdate` channel (100-message capacity)
2. Receive loop blocks while channel is full
3. Keepalive messages cannot be processed → timeout occurs
4. `Reset()` attempts reconnection, waits for receive thread to finish: `p.wg.Wait()`
5. Receive thread stuck in blocking read: `(*p.conn).Read(buf)`
6. Connection closes, but read doesn't properly unblock due to race condition
7. Receive thread never exits → `Reset()` waits forever → **Deadlock**

**Contributing Factors**:
- No timeout on network read operations
- No graceful shutdown coordination between threads
- Default message queue capacity insufficient for large route tables

**Detailed technical analysis**: See `TECHNICAL_ANALYSIS_DEADLOCK.md`

---

## The Fix

**Solution**: Graceful shutdown coordination mechanism

**Key Changes**:
1. **Shutdown flag**: Added `stopRxLoop` flag that threads check before blocking operations
2. **Grace period**: Wait 1 second after signaling shutdown before closing connection
3. **Read timeouts**: Network operations now have bounded wait times (5× keepalive interval)
4. **Multiple exit checks**: Threads check for shutdown signals at multiple points

**How It Works**:
```
Before: Close connection → Thread stuck → Waits forever
After:  Set flag → Wait 1 second → Thread exits cleanly → Close connection → Success
```

**Validation**:
- Stress test with 100 concurrent clients and large route tables
- No deadlock observed after 60 seconds of high load
- Fix commit: `1ed11964f2b050dd065451b7211969d38391bad3` (osc/main branch)

---

## Impact Assessment

**Affected Systems**:
- All OSC regions running osc-peering-controller v2.2.1-a43d1c2
- MetalBond servers across all availability zones
- Customers with large peering configurations (most impacted)

**Service Impact**:
- Route inconsistencies across MetalBond servers
- Temporary outages (1-2 minutes) during mitigation for subset of customers
- High availability compromised (all 4 servers had inconsistent state)

**What Was NOT Affected**:
- No security breach or data compromise
- No data corruption
- No billing impact
- Management interfaces remained operational

---

## Current Status

✅ **Completed**:
- Root cause identified
- Fix developed and code reviewed
- Comprehensive stress test added
- Code committed to osc/main branch

🔄 **In Progress**:
- Testing on OSC stages
- Validation across different availability zones
- Performance impact assessment

📋 **Next Steps**:
- Complete stage validation
- Plan production deployment
- Prepare rollback procedures
- Customer communication if needed

---

## Preventive Measures

### Immediate (Completed)
- ✅ Fix implemented with graceful shutdown mechanism
- ✅ Stress test added to prevent regression
- ✅ Code review of all connection handling logic
- ✅ Testing in progress on OSC stages

### Short-Term (Next 2 Weeks)
- Add monitoring for message queue saturation
- Alert on route count discrepancies between servers
- Alert on abnormal reconnection rates
- Document channel capacity tuning for large deployments

### Long-Term (Next Quarter)
- Enhance pre-deployment stress testing with production-like workloads
- Implement gradual rollout (canary deployments) for critical components
- Review default configuration values against production metrics
- Add automated deadlock detection to CI/CD pipeline

---

## Lessons Learned

### What Went Well ✓
- Monitoring quickly detected the issue
- Fast escalation to lead engineering team
- 48-hour turnaround from incident to fix
- Thorough testing before production deployment

### What to Improve ⚠
- Need better stress testing before releases (simulate production load)
- Consider gradual rollout for critical components (deploy to one AZ first)
- Default configurations should be validated against production metrics
- Need proactive monitoring for queue saturation

### Key Takeaways
- **Blocking operations need timeouts**: Network I/O must have bounded wait times
- **Graceful shutdown is critical**: Thread coordination prevents race conditions
- **Test with production scenarios**: Stress tests must use realistic data volumes
- **Monitor before problems occur**: Track queue depths and saturation proactively

---

## Recommendations

### For Management

**Approve After Stage Validation**:
- Production deployment of fix (coordinate deployment window with operations)
- Customer communication plan if broader notification needed

**Resource Allocation**:
- Enhanced monitoring infrastructure for MetalBond
- Test environment sizing to match production scale
- Engineering time for long-term improvements

**Process Improvements**:
- Strengthen pre-deployment testing requirements (load testing mandatory)
- Implement gradual rollout procedures for critical components
- Update incident playbooks based on lessons learned

---

## Appendices

### A. Technical Details
- **Detailed Technical Analysis**: `TECHNICAL_ANALYSIS_DEADLOCK.md`
- **Fix Commit**: `1ed11964f2b050dd065451b7211969d38391bad3`
- **Branch**: `osc/main`
- **Files Changed**: `peer.go`, `peer_test.go`, `cmd/cmd.go`, `http.go`

### B. Monitoring Recommendations
**Key Metrics**:
- `metalbond_channel_depth{type="rxUpdate"}` - Alert if > 80% capacity
- `metalbond_route_count{server="X"}` - Alert on >5% variance across servers
- `metalbond_reconnection_count` - Alert if > 3 per hour per peer
- `metalbond_connection_state` - Track state transitions

### C. References
- **Change Request**: CHG01223242
- **Affected Version**: osc-peering-controller v2.2.1-a43d1c2
- **Fix Version**: TBD (pending stage validation)

---

## Approval

**Prepared By**: Lead Engineering Team
**Date**: November 1, 2025

**Reviewers**:
- [ ] Engineering Manager
- [ ] Operations Manager
- [ ] Service Delivery Manager

**Document Version**: 1.0
**Next Review**: After production deployment
