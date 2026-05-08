package Dragline::Job::WebhookDeliver;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP qw(encode_json);
use Mojo::UserAgent;

my $_ua_singleton;
sub _ua {
    return $_ua_singleton ||= do {
        my $ua = Mojo::UserAgent->new;
        $ua->connect_timeout(10);
        $ua->request_timeout(30);
        $ua;
    };
}

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $webhook_id = $args->{webhook_id} or die "WebhookDeliver: webhook_id required";
    my $event_type = $args->{event_type} or die "WebhookDeliver: event_type required";
    my $payload    = $args->{payload}    // {};

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $config = $dbh->selectrow_hashref(
        q{SELECT * FROM webhook_configs WHERE id = ? AND active = 1},
        undef, $webhook_id,
    );
    unless ($config) {
        $log->info("WebhookDeliver: webhook $webhook_id not found or inactive");
        return;
    }

    my $event_types = eval { decode_json($config->{event_types}) } // ['*'];
    my $matches = 0;
    for my $et (@$event_types) {
        if ($et eq '*' || $et eq $event_type) {
            $matches = 1;
            last;
        }
    }
    unless ($matches) {
        $log->info("WebhookDeliver: event $event_type not matched for webhook $webhook_id");
        return;
    }

    my $body = encode_json({
        event_type => $event_type,
        timestamp  => _now_iso(),
        payload    => $payload,
    });

    my $sig = '';
    if ($config->{secret}) {
        $sig = 'sha256=' . hmac_sha256_hex($body, $config->{secret});
    }

    my $ua = _ua();
    my $tx = $ua->post(
        $config->{url} => {
            'Content-Type'  => 'application/json',
            'X-Webhook-Signature' => $sig,
        } => $body,
    );

    my $res = $tx->result;
    my $delivery_id = $self->app->new_uuid;

    if ($res && $res->is_success) {
        $dbh->do(
            q{INSERT INTO webhook_deliveries
              (id, webhook_id, event_type, payload, response_status, response_body, delivered_at, created_at)
              VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef,
            $delivery_id, $webhook_id, $event_type, $body,
            $res->code, substr($res->body // '', 0, 2000),
        );
        $log->info("WebhookDeliver: delivered $event_type to webhook $webhook_id (" . $res->code . ")");
    } else {
        my $err = $tx->error;
        my $err_msg = $err ? ($err->{message} // $err->{code} // 'unknown') : 'no response';
        my $status  = $res ? $res->code : undef;
        $dbh->do(
            q{INSERT INTO webhook_deliveries
              (id, webhook_id, event_type, payload, response_status, error_message, created_at)
              VALUES (?, ?, ?, ?, ?, ?, datetime('now'))},
            undef,
            $delivery_id, $webhook_id, $event_type, $body,
            $status, $err_msg,
        );
        $log->warn("WebhookDeliver: failed $event_type to webhook $webhook_id ($err_msg)");
    }
}

sub _now_iso {
    my @t = gmtime;
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;
