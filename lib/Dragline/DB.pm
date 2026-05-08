package Dragline::DB;
use strict;
use warnings;
use utf8;

use DBI;
use Path::Tiny;

our $VERSION = '0.1.0';

sub get_dbh {
    my ($db_path) = @_;

    my $is_new = !-e $db_path || -z $db_path;

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$db_path",
        undef,
        undef,
        {
            RaiseError     => 1,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        }
    ) or die "Cannot connect to database: $DBI::errstr\n";

    $dbh->do('PRAGMA foreign_keys = ON');
    $dbh->do('PRAGMA journal_mode = WAL');

    if ($is_new) {
        my $schema_file = path($INC{'Dragline/DB.pm'})->parent->parent->parent->child('schema.sql');
        unless (-e $schema_file) {
            # Fall back to cwd-relative path
            $schema_file = path('schema.sql');
        }
        die "schema.sql not found\n" unless -e $schema_file;

        my $sql = $schema_file->slurp_utf8;

        # Split into statements, respecting BEGIN...END blocks (triggers)
        my @statements;
        my $depth   = 0;
        my $current = '';
        for my $token (split /(\bBEGIN\b|\bEND\b|;)/i, $sql) {
            if    (uc($token) eq 'BEGIN') { $depth++;  $current .= $token }
            elsif (uc($token) eq 'END')   { $depth--;  $current .= $token }
            elsif ($token eq ';') {
                $current .= ';';
                if ($depth == 0) {
                    (my $stmt = $current) =~ s/^\s+|\s+$//g;
                    push @statements, $stmt if $stmt =~ /\S/;
                    $current = '';
                }
            }
            else { $current .= $token }
        }

        for my $stmt (@statements) {
            eval { $dbh->do($stmt) };
            if ($@ && $stmt !~ /^\s*PRAGMA/i) {
                die "Schema error in statement: $stmt\n$@\n";
            }
        }
    }

    return $dbh;
}

1;
