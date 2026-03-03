#!/bin/bash
# =============================================================================
# fix-e3372h-dhcp.sh
# Patches dhclient to work with Huawei E3372h-320 HiLink modems
#
# Problem: The E3372h-320's built-in DHCP server generates its own transaction
#          IDs (xid) in OFFER replies instead of echoing back the client's xid.
#          This violates RFC 2131, causing dhclient to silently ignore all
#          offers. The modem works on Windows because Windows is more lenient
#          about xid matching.
#
# Fix:     Patches dhclient source to accept DHCP offers based on MAC address
#          matching instead of strict xid matching, and syncs the client xid
#          to the server's xid so REQUESTs are also accepted.
#
# Usage:   sudo bash fix-e3372h-dhcp.sh
# Revert:  sudo bash fix-e3372h-dhcp.sh --revert
#
# Tested on: BELABOX (Ubuntu 22.04 Jammy, arm64) with isc-dhcp-client 4.4.1
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BACKUP_DIR="/var/lib/dhclient-patch-backup"
BUILD_DIR="$HOME/dhclient-e3372h-patch"

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

# Handle revert
if [ "$1" = "--revert" ]; then
    if [ -f "$BACKUP_DIR/dhclient.backup" ]; then
        log_info "Reverting to original dhclient..."
        cp "$BACKUP_DIR/dhclient.backup" /sbin/dhclient
        log_info "Reverted successfully. Restart dhclient to use the original version."
    else
        log_error "No backup found at $BACKUP_DIR/dhclient.backup"
        exit 1
    fi
    exit 0
fi

# Check if already patched
if [ -f "$BACKUP_DIR/patched.flag" ]; then
    log_warn "dhclient appears to already be patched."
    read -p "Repatch anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

log_info "=== Huawei E3372h-320 dhclient XID patch ==="
log_info ""
log_info "This script will:"
log_info "  1. Install build dependencies"
log_info "  2. Download isc-dhcp-client source"
log_info "  3. Patch the xid matching logic"
log_info "  4. Build and install the patched dhclient"
log_info ""
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Clean up any previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$BACKUP_DIR"
cd "$BUILD_DIR"

# Step 1: Install build dependencies
log_info "Step 1/5: Installing build dependencies..."
apt-get update -qq
apt-get install -y -qq gcc make autoconf automake libtool dpkg-dev >/dev/null 2>&1
apt-get build-dep -y -qq isc-dhcp-client >/dev/null 2>&1
log_info "Dependencies installed."

# Step 2: Download source
log_info "Step 2/5: Downloading isc-dhcp-client source..."
cd "$BUILD_DIR"
apt-get source isc-dhcp-client >/dev/null 2>&1
SRC_DIR=$(find . -maxdepth 1 -type d -name "isc-dhcp-*" | head -1)
if [ -z "$SRC_DIR" ]; then
    log_error "Failed to download source"
    exit 1
fi
cd "$SRC_DIR"
chmod +x debian/rules
log_info "Source downloaded: $SRC_DIR"

# Step 3: Apply patch
log_info "Step 3/5: Patching dhclient xid matching..."

DHCLIENT_SRC="client/dhclient.c"

if [ ! -f "$DHCLIENT_SRC" ]; then
    log_error "Cannot find $DHCLIENT_SRC"
    exit 1
fi

# Count matches before patching
MATCH_COUNT=$(grep -c "if (client -> xid == packet -> raw -> xid)" "$DHCLIENT_SRC" || true)
if [ "$MATCH_COUNT" -lt 3 ]; then
    log_error "Expected 3 xid match lines, found $MATCH_COUNT. Source may have changed."
    exit 1
fi

# Patch 1: Skip xid matching in all three locations (DHCPOFFER, DHCPACK, DHCPNAK)
# Instead of matching by xid, accept any packet where MAC address matches
# (the MAC check happens immediately after and is unmodified)
sed -i 's/if (client -> xid == packet -> raw -> xid)/if (1 \|\| client -> xid == packet -> raw -> xid)/' "$DHCLIENT_SRC"

# Patch 2: After accepting a DHCPOFFER, sync client xid to the modem's xid
# so the subsequent DHCPREQUEST uses an xid the modem recognises
OFFER_SPRINTF_LINE=$(grep -n 'sprintf (obuf, "%s of %s from %s", name,' "$DHCLIENT_SRC" | head -1 | cut -d: -f1)
if [ -z "$OFFER_SPRINTF_LINE" ]; then
    log_error "Cannot find offer sprintf line for xid sync patch"
    exit 1
fi
sed -i "${OFFER_SPRINTF_LINE}i\\\\tclient -> xid = packet -> raw -> xid;" "$DHCLIENT_SRC"

# Verify patches applied
PATCHED_COUNT=$(grep -c "if (1 || client -> xid == packet -> raw -> xid)" "$DHCLIENT_SRC" || true)
XID_SYNC=$(grep -c "client -> xid = packet -> raw -> xid;" "$DHCLIENT_SRC" || true)

if [ "$PATCHED_COUNT" -ne 3 ]; then
    log_error "xid bypass patch failed (expected 3, got $PATCHED_COUNT)"
    exit 1
fi
if [ "$XID_SYNC" -lt 1 ]; then
    log_error "xid sync patch failed"
    exit 1
fi

log_info "Patches applied successfully ($PATCHED_COUNT xid bypasses, $XID_SYNC xid sync)"

# Step 4: Build
log_info "Step 4/5: Building patched dhclient (this may take a few minutes)..."
if ! dpkg-buildpackage -b -uc -us 2>&1 | tee /tmp/dhclient-build.log | tail -5; then
    log_error "Build failed. See /tmp/dhclient-build.log for details."
    exit 1
fi
log_info "Build complete."

# Step 5: Backup and install
log_info "Step 5/5: Backing up original and installing patched dhclient..."

# Backup original
if [ ! -f "$BACKUP_DIR/dhclient.backup" ]; then
    cp /sbin/dhclient "$BACKUP_DIR/dhclient.backup"
    log_info "Original dhclient backed up to $BACKUP_DIR/dhclient.backup"
fi

# Install
cd "$BUILD_DIR"
dpkg -i isc-dhcp-client_*.deb >/dev/null 2>&1
touch "$BACKUP_DIR/patched.flag"
log_info "Patched dhclient installed."

# Clean up
log_info "Cleaning up build files..."
rm -rf "$BUILD_DIR"

# Summary
echo ""
log_info "=== Patch complete! ==="
echo ""
log_info "The patched dhclient will now accept DHCP offers from the"
log_info "Huawei E3372h-320 despite its non-compliant xid behaviour."
echo ""
log_info "Test with:  killall dhclient; ip addr flush dev eth1; dhclient -v -4 eth1"
log_info "Revert with: sudo bash fix-e3372h-dhcp.sh --revert"
echo ""
log_warn "Note: System updates to isc-dhcp-client will overwrite this patch."
log_warn "Re-run this script after any dhclient package updates."
