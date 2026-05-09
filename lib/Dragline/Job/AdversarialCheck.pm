package Dragline::Job::AdversarialCheck;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Minion::Job', -signatures;

use Dragline::LLM;
use Data::UUID;

my $_uuid = Data::UUID->new;

sub run {
    my ($self) = @_;
    my $args = $self->args;

    my $dbh = $self->app->db_for_job;
    my $log = $self->app->log;

    my $enabled = $dbh->selectrow_array(
        q{SELECT value FROM settings WHERE key='adversarial_check_enabled'},
        undef,
    ) // '0';
    unless ($enabled eq '1') {
        $log->info("AdversarialCheck: disabled, skipping");
        return;
    }

    my $sample_rate = $dbh->selectrow_array(
        q{SELECT value FROM settings WHERE key='adversarial_check_sample_rate'},
        undef,
    ) // 10;
    $sample_rate = 10 unless $sample_rate =~ /^\d+$/;
    $sample_rate = 100 if $sample_rate > 100;
    $sample_rate = 1   if $sample_rate < 1;

    my $target_id = $args->{target_id};
    my $dossier_id = $args->{dossier_id};

    my @where;
    my @bind;
    if ($target_id) {
        push @where, 'd.target_id = ?';
        push @bind, $target_id;
    }
    if ($dossier_id) {
        push @where, 'd.id = ?';
        push @bind, $dossier_id;
    }
    if (!@where) {
        # Default: check dossiers generated in last 24h
        push @where, "d.generated_at >= datetime('now', '-1 day')";
    }
    push @where, "d.status = 'current'";

    my $where_sql = 'WHERE ' . join(' AND ', @where);

    my $sections = $dbh->selectall_arrayref(
        qq{SELECT ds.dossier_id, d.target_id, ds.section_number, ds.section_name,
                  ds.content, ds.model_used
           FROM dossier_sections ds
           JOIN dossiers d ON d.id = ds.dossier_id
           $where_sql
           ORDER BY d.generated_at DESC, ds.section_number ASC},
        { Slice => {} }, @bind,
    );

    return unless @$sections;

    # Sample randomly based on sample_rate (e.g. 10 = check ~10% of sections)
    # Use deterministic seed per section for reproducibility
    my @sample = grep {
        srand($_->{dossier_id} . $_->{section_number});
        rand(100) < $sample_rate
    } @$sections;
    @sample = @$sections if !@sample;

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

    for my $sec (@sample) {
        my $check_id = $_uuid->create_str;
        eval {
            $dbh->do(
                q{INSERT INTO adversarial_checks
                    (id, target_id, dossier_id, section_number, original_text, status)
                  VALUES (?, ?, ?, ?, ?, 'pending')},
                undef,
                $check_id, $sec->{target_id}, $sec->{dossier_id},
                $sec->{section_number}, $sec->{content},
            );
        };
        next if $@;

        my $sys = "You are an expert intelligence analyst. Generate the '$sec->{section_name}'"
            . " section of a structured intelligence dossier. Be precise and factual.";

        my ($cv_text, $model, $tokens) = Dragline::LLM::complete(
            $dbh, $settings_getter,
            task_type     => 'section_synthesis',
            system_prompt => $sys,
            user_prompt   => $sec->{content},
            max_tokens    => 2048,
            target_id     => $sec->{target_id},
        );

        my $score;
        my $status = 'complete';
        if (defined $cv_text && length $cv_text) {
            $score = _simple_similarity($sec->{content} // '', $cv_text);
        } else {
            $status = 'failed';
        }

        $dbh->do(
            q{UPDATE adversarial_checks
              SET cross_validation_text = ?,
                  agreement_score = ?,
                  model_used = ?,
                  status = ?,
                  updated_at = datetime('now')
              WHERE id = ?},
            undef,
            ($cv_text // ''), ($score // 0), ($model // 'unknown'), $status, $check_id,
        );

        $log->info("AdversarialCheck: dossier $sec->{dossier_id} section $sec->{section_number}"
            . " score=$score model=$model");
    }
}

sub _simple_similarity {
    my ($a, $b) = @_;
    my %words_a = map { $_ => 1 } split(/\W+/, lc($a));
    my %words_b = map { $_ => 1 } split(/\W+/, lc($b));
    my $common = 0;
    for my $w (keys %words_a) {
        $common++ if exists $words_b{$w};
    }
    my $total = scalar(keys %words_a) + scalar(keys %words_b);
    return 0 unless $total > 0;
    return 2 * $common / $total;
}

1;
