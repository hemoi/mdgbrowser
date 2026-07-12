#!/bin/sh

# Used only by Tests/ssh_server_probe.exp. The password stays in the inherited
# process environment and is never embedded in a command line or test log.
printf '%s\n' "$TEST_PASSWD"
