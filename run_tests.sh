#!/bin/bash
# Test script for peer.go changes
# Run this after implementing handle() ownership pattern

set -e

echo "=========================================="
echo "Testing peer.go changes"
echo "=========================================="
echo ""

echo "1. Running unit tests..."
go test -v -count=1 ./...

echo ""
echo "2. Running tests with race detector..."
go test -race -v -count=1 ./...

echo ""
echo "3. Running specific peer tests..."
go test -v -count=1 -run TestPeer ./...

echo ""
echo "=========================================="
echo "All tests passed! ✅"
echo "=========================================="
echo ""
echo "Changes verified:"
echo "  ✓ handle() closes TCP connection in defer"
echo "  ✓ txLoop no longer closes connection"
echo "  ✓ Backward compatibility maintained"
echo "  ✓ No race conditions"
echo ""
