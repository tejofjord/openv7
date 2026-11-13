#!/usr/bin/perl
# Wait for ONE control gesture in the bridge's -v log and summarise it.
#
# This is how the NS7 map (docs/NS7-CONTROL-MAP.md) was measured: run the bridge
# verbose into a log, then call this once per control while someone moves just
# that control. Each call reports exactly what that one gesture sent.
#
#   ./openv7 -v > /tmp/ns7.log 2>&1 &
#   wc -c < /tmp/ns7.log > /tmp/ns7.st          # start after the startup chatter
#   tools/wait-control.pl /tmp/ns7.log /tmp/ns7.st 60 2   # repeat per control
#
#   wait-control.pl LOG STATEFILE [TIMEOUT_S] [QUIET_S]
#
# Reads only what the log gained since the byte offset in STATEFILE, ignoring
# known background traffic (strip search, platters, startup CC).
# Waits for the first relevant message, then until QUIET_S of silence, so a
# whole fader sweep counts as one gesture. Prints one line per address:
#   KEY  n=COUNT  min..max  first->last
# or "TIMEOUT: nothing" if nothing relevant arrived. Advances STATEFILE.
#
# Set NS7_KEEP="b0 45,b0 00" to stop ignoring specific noise addresses (needed
# when the control under test IS a strip or a platter).
#
# NS7_FLOOR=N ignores values below N on a NS7_KEEP address entirely. Use it
# for a strip that sends small values while untouched; otherwise those count as
# activity and the gesture never goes quiet.
use strict; use warnings; use Time::HiRes qw(time sleep);

my ($log, $state, $timeout, $quiet) = @ARGV;
$timeout //= 90; $quiet //= 2.0;
my %noise = map { $_ => 1 } ('b0 45', 'b0 4d', 'b0 00', 'b0 02', 'b0 6e');
my %keep  = map { $_ => 1 } grep { length } split /\s*,\s*/, ($ENV{NS7_KEEP} // '');
delete $noise{$_} for keys %keep;
my $keep_ts = grep { /^b0 0[02]$/ } keys %keep;   # platter under test: keep its timestamps too
my $floor   = $ENV{NS7_FLOOR} // 0;                # low-value cut-off (see above)

my $off = 0;
if (open my $s, '<', $state) { $off = <$s> // 0; chomp $off; close $s; }

open my $fh, '<', $log or die "cannot open $log: $!\n";
seek $fh, $off, 0;

my (%n, %min, %max, %first, %last, @order);
my ($start, $lastev) = (time, undef);
my $buf = '';
while (1) {
    while (defined(my $line = <$fh>)) {
        $buf .= $line;
        next unless $buf =~ /\n\z/;           # wait for a complete line
        my $l = $buf; $buf = '';
        next unless $l =~ /^\s*in\s+([0-9a-f]{2})\s+([0-9a-f]{2})(?:\s+([0-9a-f]{2}))?/;
        my ($st, $d0, $d1) = ($1, $2, $3);
        my $key = ($st =~ /^e/) ? $st : "$st $d0";   # pitch-bend: whole status
        next if $noise{$key};
        next if $st =~ /^e[02]$/ && !$keep_ts;
        my $v = hex(defined $d1 ? $d1 : $d0);
        next if $keep{$key} && $v < $floor;   # below the floor: neither a gesture nor activity
        push @order, $key unless $n{$key}++;
        $min{$key} = $v if !defined $min{$key} || $v < $min{$key};
        $max{$key} = $v if !defined $max{$key} || $v > $max{$key};
        $first{$key} //= $v; $last{$key} = $v;
        $lastev = time;
    }
    seek $fh, 0, 1;                           # clear EOF so new lines are seen
    my $now = time;
    last if defined $lastev && $now - $lastev >= $quiet;
    last if !defined $lastev && $now - $start >= $timeout;
    sleep 0.1;
}
my $pos = tell($fh) - length($buf);
open my $w, '>', $state or die; print $w "$pos\n"; close $w;

if (!@order) { print "TIMEOUT: nothing in ${timeout}s\n"; exit 1; }
for my $k (@order) {
    printf "%s  n=%d  %d..%d  %d->%d\n", $k, $n{$k}, $min{$k}, $max{$k}, $first{$k}, $last{$k};
}
