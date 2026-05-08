package Dragline::Job::WebhookDeliver;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP qw(encode_json decode_json);
use Mojo::UserAgent;

my $_ua_singleton;
sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(10);
        $ua->inactivity_timeout(10);
        $ua;
    };
}

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $config_id  = $args->{config_id}  or die "WebhookDeliver: config_id required";
    my $event_type = $args->{event_type} or die "WebhookDeliver: event_type required";
    my $payload    = $args->{payload}    // {};
    my $target_id  = $args->{target_id}  // undef;

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $config = $dbh->selectrow_hashref(
        q{SELECT * FROM webhook_configs WHERE id = ? AND is_active = 1},
        undef, $config_id,
    );
    unless ($config) {
        $log->info("WebhookDeliver: config $config_id not found or inactive");
        return;
    }

    # Check SSRF
    unless ($self->app->check_ssrf($config->{url})) {
        die "WebhookDeliver: URL blocked by SSRF policy";
    }

    # Decrypt secret if present
    my $secret = undef;
    if ($config->{secret}) {
        $secret = eval { $self->app->decrypt_value($config->{secret}) };
    }

    my $body = encode_json({
        event_type => $event_type,
        target_id  => $target_id,
        data       => $payload,
        timestamp  => _now_iso(),
        version    => '1',
    });

    my $sig = '';
    if ($secret) {
        $sig = 'sha256=' . hmac_sha256_hex($body, $secret);
    }

    my $ua = _ua();
    my $tx = $ua->post(
        $config->{url} => {
            'Content-Type'         => 'application/json',
            'X-Dragline-Signature' => $sig,
        } => $body,
    );

    my $res = $tx->result;
    my $delivery_id = $self->app->new_uuid;
    my $now = _now_iso();

    if ($res && $res->is_success) {
        $dbh->do(
            q{INSERT INTO webhook_deliveries
              (id, webhook_config_id, event_type, payload, last_response_status, last_response_body, delivered_at, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)},
            undef,
            $delivery_id, $config_id, $event_type, $body,
            $res->code, substr($res->body // '', 0, 500), $now, $now,
        );
        $log->info("WebhookDeliver: delivered $event_type to config $config_id (" . $res->code . ")");
    } else {
        my $err = $tx->error;
        my $err_msg = $err ? ($err->{message} // $err->{code} // 'unknown') : 'no response';
        my $status  = $res ? $res->code : undef;
        $dbh->do(
            q{INSERT INTO webhook_deliveries
              (id, webhook_config_id, event_type, payload, last_response_status, last_error, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?)},
            undef,
            $delivery_id, $config_id, $event_type, $body,
            $status, $err_msg, $now,
        );
        $log->warn("WebhookDeliver: failed $event_type to config $config_id ($err_msg)");
        die "WebhookDeliver: delivery failed ($err_msg)";
    }
}

sub _now_iso {
    my @t = gmtime;
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
