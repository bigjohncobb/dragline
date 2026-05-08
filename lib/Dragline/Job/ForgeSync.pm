package Dragline::Job::ForgeSync;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::Forge;
use Mojo::UserAgent;

# Singleton HTTP client to prevent connection pool and socket churn
my $_ua_singleton;
sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(30);
        $ua->request_timeout(60);
        $ua;
    };
}

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $target_id = $args->{target_id} or die "ForgeSync: target_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $target = $dbh->selectrow_hashref(
        q{SELECT id, canonical_name FROM targets WHERE id=?},
        undef, $target_id,
    );
    die "ForgeSync: target $target_id not found" unless $target;

    my $settings_getter = sub {
        my ($key) = @_;
        my $row = $dbh->selectrow_hashref(
            q{SELECT value, is_encrypted FROM settings WHERE key=?},
            undef, $key,
        );
        return undef unless $row;
        return undef unless defined($row->{value}) && $row->{value} ne '';
        return $row->{is_encrypted}
            ? $self->app->decrypt_value($row->{value})
            : $row->{value};
    };

    my $ua = _ua();

    my ($count, $err) = Dragline::Forge::sync_target(
        $dbh, $ua, $settings_getter,
        $target_id, $target->{canonical_name}, $log,
    );

    if ($err && $err ne 'forge not configured'
             && $err ne 'forge api not implemented'
             && $err ne 'airgap mode') {
        die "ForgeSync: $err";
    }

    # Mark existing dossier as stale if currently current
    if ($count > 0) {
        eval {
            $dbh->do(
                q{UPDATE dossiers SET status='stale', updated_at=datetime('now')
                  WHERE target_id=? AND status='current'},
                undef, $target_id,
            );
        };
    }

    $dbh->do(
        q{UPDATE target_monitoring SET last_forge_sync_at=datetime('now') WHERE target_id=?},
        undef, $target_id,
    );

    $log->info("ForgeSync: target $target_id synced ($count new items)");
}

1;
