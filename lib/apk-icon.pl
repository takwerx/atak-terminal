#!/usr/bin/perl
# apk-icon.pl NAME < resources.arsc
# Prints the APK file path of the PNG behind the resource entry NAME, at the highest density
# the resource table has it in; nothing when there is none. Release builds of ATAK scramble
# resource file names (res/3k.png), so ic_atak_launcher.png exists by that name only in the
# SDK's development build; the table still maps the name to the file (DECISIONS 2026-09-27).
# Perl because every Mac has it. The same reader, in C#, is Takwerx.Apk in lib/windows.
use strict; use warnings;
binmode STDIN; local $/; my $d = <STDIN>; my $name = shift or exit 1;
defined $d && length($d) >= 12 or exit 0;
sub u16 { unpack('v', substr($d, $_[0], 2)) }
sub u32 { unpack('V', substr($d, $_[0], 4)) }
sub pool {
    my $o = shift; my $hsz = u16($o + 2); my $cnt = u32($o + 8);
    my $utf8 = u32($o + 16) & 0x100; my $start = u32($o + 20); my @r;
    for my $i (0 .. $cnt - 1) {
        my $p = $o + $start + u32($o + $hsz + 4 * $i);
        if ($utf8) {
            my $n = ord(substr($d, $p, 1)); $p++; $p++ if $n & 0x80;
            $n = ord(substr($d, $p, 1)); $p++;
            if ($n & 0x80) { $n = (($n & 0x7f) << 8) | ord(substr($d, $p, 1)); $p++; }
            push @r, substr($d, $p, $n);
        } else {
            my $n = u16($p); $p += 2;
            if ($n & 0x8000) { $n = (($n & 0x7fff) << 16) | u16($p); $p += 2; }
            (my $s = substr($d, $p, 2 * $n)) =~ s/(.)\0/$1/gs;
            push @r, $s;
        }
    }
    return \@r;
}
my ($best, $bestd) = (undef, -1);
eval {
    my $o = u16(2); my $values = pool($o); $o += u32($o + 4);
    while ($o + 8 <= length $d) {
        my ($type, $size) = (u16($o), u32($o + 4)); last if $size <= 0;
        if ($type == 0x0200) {
            my $keys = pool($o + u32($o + 276));
            my $p = $o + u16($o + 2);
            while ($p + 8 <= $o + $size) {
                my ($t, $tsize) = (u16($p), u32($p + 4)); last if $tsize <= 0;
                if ($t == 0x0201) {
                    my ($th, $flags, $cnt, $start) = (u16($p + 2), ord(substr($d, $p + 9, 1)), u32($p + 12), u32($p + 16));
                    my $density = u16($p + 20 + 14); $density = 0 if $density >= 0xfff0;
                    for my $i (0 .. $cnt - 1) {
                        my $eo;
                        if ($flags & 0x01) { $eo = u16($p + $th + 4 * $i + 2) * 4; }                              # sparse
                        elsif ($flags & 0x02) { $eo = u16($p + $th + 2 * $i); next if $eo == 0xFFFF; $eo *= 4; }    # 16-bit offsets
                        else { $eo = u32($p + $th + 4 * $i); next if $eo == 0xFFFFFFFF; }
                        my $e = $p + $start + $eo; my $ef = u16($e + 2); my ($key, $vt, $vd);
                        if ($ef & 0x08) { ($key, $vt, $vd) = (u16($e), ($ef >> 8) & 0xff, u32($e + 4)); }          # compact
                        else { next if $ef & 0x01; my $esz = u16($e); $key = u32($e + 4); $vt = ord(substr($d, $e + $esz + 3, 1)); $vd = u32($e + $esz + 4); }
                        next unless $key < @$keys && $keys->[$key] eq $name && $vt == 0x03 && $vd < @$values;
                        my $path = $values->[$vd];
                        next unless $path =~ /\.png$/i;
                        ($best, $bestd) = ($path, $density) if $density > $bestd;
                    }
                }
                $p += $tsize;
            }
        }
        $o += $size;
    }
};
print "$best\n" if defined $best;
