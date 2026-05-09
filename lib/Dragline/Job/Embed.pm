package Dragline::Job::Embed;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::Embed;
use Data::UUID;

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_; my $args = $self->args;

    my $raw_content_id = $args->{raw_content_id}
        or die "Embed: raw_content_id required";

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $content = $dbh->selectrow_hashref(
        q{SELECT id, content_text FROM raw_content WHERE id=?},
        undef, $raw_content_id,
    );
    die "Embed: raw_content $raw_content_id not found" unless $content;

    my $already = $dbh->selectrow_array(
        q{SELECT id FROM raw_content_embeddings WHERE raw_content_id=?},
        undef, $raw_content_id,
    );
    if ($already) {
        $log->info("Embed: already embedded, skipping $raw_content_id");
        return;
    }

    my $airgap = $self->app->airgap_mode;

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

    my $embedding = Dragline::Embed::embed($dbh, $settings_getter, $content->{content_text});
    unless (defined $embedding && ref $embedding eq 'ARRAY' && @$embedding) {
        die "Embed: embedding failed for $raw_content_id";
    }

    my $model          = $airgap ? 'nomic-embed-text' : 'text-embedding-v4';
    my $expected_dims  = $airgap ? 768 : 1024;
    my $dims           = scalar @$embedding;
    unless ($dims == $expected_dims) {
        die "Embed: unexpected dimension count $dims (expected $expected_dims) for model $model";
    }

    my $blob  = pack('f*', @$embedding);
    my $id    = $_uuid->create_str;

    $dbh->do(
        q{INSERT INTO raw_content_embeddings
            (id, raw_content_id, embedding, model, dimensions)
          VALUES (?, ?, ?, ?, ?)},
        undef, $id, $raw_content_id, $blob, $model, $dims,
    );

    $self->app->minion->enqueue(score       => [{raw_content_id => $raw_content_id}], {attempts => 3});
    $self->app->minion->enqueue(ner_extract => [{raw_content_id => $raw_content_id}], {attempts => 3});

    $log->info("Embed: $raw_content_id embedded ($dims dims, model=$model)");
}

1;
