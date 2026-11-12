#!/usr/bin/perl
# Platter tachometer: measure platter speed from the bridge's -v log, live.
#
#   ./openv7 -v > /tmp/ns7.log 2>&1 &
#   tools/platter-tach.pl /tmp/ns7.log [SECONDS] [INTERVAL]
#
# Follows the log from its CURRENT end (only new traffic counts), for SECONDS
# (default 8), and every INTERVAL seconds (default 0.5) prints each deck's net
# position change and the speed it implies:
#
#   t=1.0s  A: +1000 cnt  2000/s  33.3 rpm  | B: idle
#
# The position counter is the 7-bit wrapping CC (B0 00 deck A, B0 02 deck B).
# Steps are unwrapped assuming no more than +-63 counts between reports, which
# holds at the 1 kHz report rate up to far beyond any motor speed. RPM assumes
# the V7's 3600 counts per revolution (CONTROL-MAP.md); "cnt" is printed raw
# so that assumption can be checked rather than trusted. Positive = clockwise.
#
# This is the Mac twin of tools/win/motor-probe.ps1: the platter's own encoder
# is the tachometer, so no other sensor is needed.
use strict; use warnings; use Time::HiRes qw(time sleep);

my ($log, $secs, $iv) = @ARGV;
die "usage: $0 LOG [SECONDS] [INTERVAL]\n" unless defined $log;
$secs //= 8; $iv //= 0.5;
my $CPR = 3600;
my %cc = ("00" => "A", "02" => "B");

open my $fh, '<', $log or die "cannot open $log: $!\n";
seek $fh, 0, 2;                                # start at the current end

my (%last, %win, %tot);
my $buf = '';
my $t0 = time; my $next = $t0 + $iv; my $tprev = $t0;
while (1) {
    while (defined(my $line = <$fh>)) {
        $buf .= $line;
        next unless $buf =~ /\n\z/;
        my $l = $buf; $buf = '';
        next unless $l =~ /^\s*in\s+b0\s+(00|02)\s+([0-9a-f]{2})/;
        my ($d, $v) = ($cc{$1}, hex $2);
        if (defined $last{$d}) {
            my $s = $v - $last{$d};
            $s -= 128 if $s > 63; $s += 128 if $s < -64;
            $win{$d} += $s; $tot{$d} += $s;
        }
        $last{$d} = $v;
    }
    seek $fh, 0, 1;
    my $now = time;
    if ($now >= $next) {
        # Divide by the time that ACTUALLY elapsed, not the nominal interval:
        # the loop wakes a little late each time, and using $iv made each
        # reading wobble by a few percent around the true speed.
        my $span = $now - $tprev; $tprev = $now;
        my @out;
        for my $d ("A", "B") {
            my $c = $win{$d} // 0;
            if (!$c) { push @out, "$d: idle"; next; }
            my $rate = $c / $span;
            push @out, sprintf("%s: %+5d cnt %6.0f/s %6.1f rpm", $d, $c, $rate, $rate * 60 / $CPR);
        }
        printf "t=%4.1fs  %s\n", $now - $t0, join("  | ", @out);
        %win = (); $next += $iv;
    }
    last if $now - $t0 >= $secs;
    sleep 0.02;
}
printf "total  A: %+d cnt (%.2f rev)  B: %+d cnt (%.2f rev)\n",
    $tot{A} // 0, ($tot{A} // 0) / $CPR, $tot{B} // 0, ($tot{B} // 0) / $CPR;
